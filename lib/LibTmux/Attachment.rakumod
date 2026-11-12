use v6.d;

#| Own one interactive tmux child on a caller-supplied terminal, with explicit cleanup.
unit class LibTmux::Attachment;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Engine;
use LibTmux::Command :DEFAULT, :internals;
use LibTmux::Transport;
use LibTmux::Format;
use LibTmux::Client;
use LibTmux::Operations;

#| State established by process completion or the most recent explicit inspection.
enum AttachmentState is export <AttachmentPending AttachmentAttached AttachmentExited>;

my class Environment {
    has Map:D $.entries is required;
    method Bool(--> Bool:D) { True }
    method hash(--> Hash:D) { $!entries.Hash }
}

#| Socket and executable configuration used for this child and explicit inspections.
has Endpoint:D $.endpoint is required;
#| Daemon identity captured before attachment; a replacement daemon is rejected.
has Incarnation:D $.incarnation is required;
#| Initial session ID; later interactive switching does not change this value.
has SessionId:D $.session is required;
has IO::Handle:D $!terminal is required;
#| Retained stderr byte limit; exceeding it terminates the child and fails when-exited.
has Positive:D $.max-stderr-bytes = 64 * 1024;
has Int $!pid = 0;
has Proc::Async $!process;
has Promise $!process-exit;
has Promise $!exited .= new;
has $!exit-vow;
has Promise $!closed;
has Lock $!lock .= new;
has Buf $!stderr .= new;
has Exception $!stream-error;
has Bool $!overflow = False;
has AttachmentState $!state = AttachmentPending;

submethod BUILD(:$!endpoint!, :$!incarnation!, :$!session!, :$!terminal!,
                :$!max-stderr-bytes = 64 * 1024) { }
submethod TWEAK() { $!exit-vow = $!exited.vow }

#| Construction requires spawn so an unstarted process owner cannot escape.
method new(|) { invalid-argument('Use Attachment.spawn with an explicit terminal handle') }
#| Refuse copying an owner, which would duplicate cleanup authority over one child.
method clone(|) { invalid-argument('An owning Attachment cannot be cloned') }

#| Spawn a tmux client on a supplied terminal. This does not prove attachment.
method spawn(Endpoint:D :$endpoint!, Incarnation:D :$incarnation!,
             SessionId:D :$session!, IO::Handle:D :$terminal!,
             Positive:D :$timeout-ms = 10_000, Positive:D :$max-stderr-bytes = 64 * 1024,
             Bool:D :$read-only = False, Bool:D :$detach-others = False,
             Bool:D :$update-environment = False,
             Cancellation :$cancel = Cancellation --> LibTmux::Attachment:D) is single-operation {
    invalid-argument('Attachment requires an open terminal handle')
        unless $terminal.opened && $terminal.t;
    X::LibTmux::StaleReference.new(:message('Attachment endpoint and incarnation disagree')).throw
        unless $endpoint.key eq $incarnation.endpoint-key;
    my $deadline = now + $timeout-ms / 1000;
    my $runtime = Runtime.new(:$endpoint, :$timeout-ms);
    LEAVE $runtime.close if $runtime.defined;
    my $projection = Projection.new(:entity<session>, :fields(['id']),
        :capabilities(operation-capabilities($incarnation)));
    my @sessions = $runtime.read($projection, Invocation.new(:argv(['list-sessions'])),
        :$incarnation, :$cancel, :$deadline);
    X::LibTmux::StaleReference.new(:message('Attachment session no longer exists')).throw
        unless @sessions.first(*.value('id') eq $session).defined;
    my @argv = 'attach-session', '-t', $session;
    @argv.push('-r') if $read-only;
    @argv.push('-d') if $detach-others;
    @argv.push('-E') unless $update-environment;
    my $attach = Invocation.new(:argv(@argv));
    my $condition = '#{==:#{pid}/#{start_time},' ~ $incarnation.pid ~ '/'
        ~ $incarnation.start-time ~ '}';
    my $guard = Invocation.new(:argv(['if-shell', '-F', $condition,
        $attach.source, 'libtmux-attachment-stale=']));
    my $owner = self.bless(:$endpoint, :$incarnation, :$session, :$terminal, :$max-stderr-bytes);
    my $failure;
    try {
        $owner!launch($guard, $deadline, $cancel);
        CATCH { default { $failure = $_ } }
    }
    if $failure.defined {
        my $cleanup;
        try { $owner.close; CATCH { default { $cleanup = $_ } } }
        X::LibTmux::Command.new(:kind<cleanup>, :outcome(Indeterminate),
            :pid($owner.pid), :!reaped, :cause($failure),
            :message('Attachment startup failed and child cleanup did not complete')).throw
            if $cleanup.defined;
        $failure.throw;
    }
    $owner
}

method !signal(Int:D $signal --> Nil) {
    try $!process.kill($signal) if $!process.defined
        && $!process-exit.defined && $!process-exit.status == Planned;
}

method !launch(Invocation:D $command, Instant:D $deadline, Cancellation $cancel --> Nil) {
    X::LibTmux::Command.new(:kind<cancelled>, :outcome(NotStarted),
        :message('Attachment spawn was cancelled')).throw
        if $cancel.defined && $cancel.cancelled;
    X::LibTmux::Command.new(:kind<timeout>, :outcome(NotStarted),
        :message('Attachment startup deadline expired')).throw if now >= $deadline;
    $!process = Proc::Async.new(|$!endpoint.argv, '-N', |$command.as-argv);
    $!process.bind-stdin($!terminal);
    $!process.bind-stdout($!terminal);
    my $stream-done = Promise.new;
    my $stream-vow = $stream-done.vow;
    my $tap = $!process.stderr(:bin).tap(-> Blob:D $bytes {
        my $overflow = $!lock.protect({
            if $!stderr.elems + $bytes.elems > $!max-stderr-bytes { $!overflow = True }
            else { $!stderr.append($bytes); False }
        });
        self!signal(9) if $overflow;
    }, :done({ $stream-vow.keep(True) }), :quit(-> $error {
        $!lock.protect({ $!stream-error //= $error });
        $stream-vow.keep(True);
        self!signal(9);
    }));
    my $spawn-error;
    try {
        $!process-exit = $!process.start(:ENV(Environment.new(:entries($!endpoint.environment))),
            :cwd($!endpoint.cwd));
        CATCH { default { $spawn-error = $_ } }
    }
    if $spawn-error.defined {
        $tap.close;
        $!state = AttachmentExited;
        $!exit-vow.break(X::LibTmux::Command.new(:kind<spawn>, :outcome(NotStarted),
            :cause($spawn-error), :message('Could not spawn attachment client')));
        await $!exited;
    }
    start {
        LEAVE $tap.close;
        my $pid = try await $!process.pid;
        $!lock.protect({ $!pid = $pid }) if $pid.defined;
        my $proc;
        my $failure;
        try { $proc = await $!process-exit; CATCH { default { $failure = $_ } } }
        await $stream-done;
        my ($stderr, $overflow, $stream-error) = $!lock.protect({
            $!state = AttachmentExited;
            (Blob.new($!stderr.list), $!overflow, $!stream-error).List
        });
        if $failure.defined || $stream-error.defined || $overflow {
            $!exit-vow.break(X::LibTmux::Command.new(
                :kind($overflow ?? 'output-limit' !! ($!pid ?? 'io' !! 'spawn')),
                :outcome($!pid ?? Indeterminate !! NotStarted), :pid($!pid), :$stderr, :reaped,
                :cause($failure // $stream-error // Exception),
                :message('Attachment process or stderr acquisition failed')));
        } else {
            $!exit-vow.keep(Result.new(:$stderr, :exitcode($proc.exitcode),
                :signal($proc.signal), :pid($!pid),
                :outcome($proc.exitcode || $proc.signal ?? Failed !! Complete)));
        }
    }
    my $remaining = ($deadline - now).Num max 0;
    my @events = $!process.pid, Promise.in($remaining);
    @events.push($cancel.when-cancelled) if $cancel.defined;
    my $wait = try await Promise.anyof(|@events);
    my $failure;
    try {
        X::LibTmux::Command.new(:kind<cancelled>, :outcome(Indeterminate),
            :message('Attachment startup was cancelled')).throw
            if $cancel.defined && $cancel.cancelled;
        X::LibTmux::Command.new(:kind<timeout>, :outcome(Indeterminate),
            :message('Attachment startup deadline expired')).throw
            if $!process.pid.status == Planned;
        $!pid = await $!process.pid;
        CATCH { default { $failure = $_ } }
    }
    if $failure.defined {
        $failure.throw if $failure ~~ X::LibTmux::Command;
        X::LibTmux::Command.new(:kind<spawn>, :outcome(NotStarted), :cause($failure),
            :message('Could not spawn attachment client')).throw;
    }
    self!signal(9) if $!lock.protect({ $!overflow || $!stream-error.defined });
}

#| Owned OS child identity; a nonzero PID does not establish attachment readiness.
method pid(--> Int:D) { $!pid }
#| Last explicit attachment observation, or the independently observed process exit.
method state(--> AttachmentState:D) { $!lock.protect({ $!state }) }
#| Resolve after the child exits and stderr is drained, preserving its exit status.
method when-exited(--> Promise:D) { $!exited }

#| Perform one explicit listing. Nil means no matching attached client was observed.
method inspect-client(Positive:D :$timeout-ms = 10_000 --> Mu) is single-operation {
    return Nil if self.state == AttachmentExited;
    my $runtime = Runtime.new(:endpoint($!endpoint), :$timeout-ms);
    LEAVE $runtime.close if $runtime.defined;
    my $projection = Projection.new(:entity<client>, :fields(<name pid created>),
        :capabilities(operation-capabilities($!incarnation)));
    my @rows = $runtime.read($projection, Invocation.new(:argv(['list-clients'])),
        :incarnation($!incarnation));
    my @matching = @rows.grep(*.value('pid') == $!pid);
    X::LibTmux::Decode.new(:schema($projection.schema),
        :message('Multiple attached clients share the owned process identity')).throw
        if @matching.elems > 1;
    $!lock.protect({
        $!state = @matching ?? AttachmentAttached !! AttachmentPending
            unless $!state == AttachmentExited;
    });
    return Nil if self.state == AttachmentExited;
    return Nil unless @matching;
    ClientTarget.new(:endpoint($!endpoint), :incarnation($!incarnation), :pid($!pid),
        :name(@matching[0].bytes('name').decode('utf8-c8')),
        :created(@matching[0].value('created')))
}

#| Terminate and reap only this child. The caller's terminal handle stays open.
method close(--> Nil) { await self.close-async }
#| Share idempotent child cleanup; failure to reap breaks the returned Promise.
method close-async(--> Promise:D) {
    $!lock.protect({
        $!closed //= start {
            if $!process-exit.defined {
                self!signal(15);
                my $wait = try await Promise.anyof($!exited, Promise.in(0.25));
                if $!exited.status == Planned {
                    self!signal(9);
                    $wait = try await Promise.anyof($!exited, Promise.in(0.75));
                }
                X::LibTmux::Command.new(:kind<cleanup>, :outcome(Indeterminate),
                    :pid($!pid), :!reaped, :message('Attachment child did not finish cleanup')).throw
                    if $!exited.status == Planned;
                my $result = try await $!exited;
            }
            Nil
        }
    })
}

=begin pod
=head1 Explicit interactive terminal ownership

spawn binds stdin and stdout to the supplied open terminal handle. It never
inherits the calling program's terminal implicitly. The caller owns that handle
and its terminal output; Attachment owns the child and bounded binary stderr.
close stops and reaps only that child, leaves the handle open, and does not stop
the daemon or other clients. Cancellation applies to startup, not the later
interactive lifetime. Use close to end that lifetime.

spawn proves OS process creation only. state starts as AttachmentPending;
inspect-client makes one explicit listing and records AttachmentAttached when
the owned PID is present. Child exit independently records AttachmentExited.
There is no polling loop or implicit readiness claim. An event from a separately
owned control connection may supply application-specific readiness evidence.

The initial session read checks Linux daemon identity, and the attach command
runs in a PID/start-time fence. The Engine's documented same-PID/same-second
replacement and normal builtin-dispatch assumptions also apply here. An exit
Result describes the tmux client process, not the lifetime of its session.
=end pod
