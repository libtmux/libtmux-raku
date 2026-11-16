use v6.d;

#| An owned PTY application. Construct it through C<Server.start-program>.
unit class LibTmux::Program;

use NativeCall;
use nqp;
use JSON::Fast;
use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Command :DEFAULT, :internals;
use LibTmux::Transport :DEFAULT, :internals;
use LibTmux::Engine;
need LibTmux::Program::Owner;
use LibTmux::Model;

#| Immutable application completion and its final bounded rendered screen.
class Completion {
    #| Normal exit code, or an undefined Int when a signal ended the process.
    has Int $.exitcode;
    #| Signal number or native signal name, or an undefined Str on normal exit.
    has Str $.signal;
    #| Final terminal-rendered bytes, including configured retained history.
    has Blob:D $.screen is required;
    #| Bytes omitted from the capture because max-output-bytes bounded the result.
    has Count:D $.dropped-bytes = 0;
    #| Whether history reached its bound; earlier output may have been discarded.
    has Bool:D $.history-limited = False;

    submethod TWEAK() {
        invalid('Completion needs exactly one exit status or signal')
            unless $!exitcode.defined != $!signal.defined;
        invalid('Invalid normal application exit status')
            if $!exitcode.defined && ! (0 <= $!exitcode <= 255);
        invalid('Invalid terminating signal')
            if $!signal.defined && (!$!signal.chars || $!signal.contains("\0"));
        $!screen = Blob.new($!screen.list);
    }

    #| Reconstruct a value with validated fields and independently owned screen bytes.
    method clone(*%changes --> Completion:D) {
        my %values = exitcode => $!exitcode, signal => $!signal, screen => $!screen,
            dropped-bytes => $!dropped-bytes, history-limited => $!history-limited;
        for %changes.kv -> $key, $value {
            invalid('Unknown completion field ' ~ $key) unless %values{$key}:exists;
            %values{$key} = $value;
        }
        self.WHAT.new(|%values)
    }
}

sub pidfd_open(int32, uint32 --> int32) is native { * }
sub pidfd_send_signal(int32, int32, Pointer, uint32 --> int32) is native { * }
sub native-close(int32 --> int32) is native is symbol('close') { * }
sub native-open(Str, int32 --> int32) is native is symbol('open') { * }
sub native-write(int32, CArray[uint8], size_t --> ssize_t) is native is symbol('write') { * }
sub errno-location(--> CArray[int32]) is native is symbol('__errno_location') { * }

sub failure(Str:D $kind, Str:D $message, Outcome:D $outcome = Indeterminate) {
    X::LibTmux::Command.new(:$kind, :$message, :$outcome)
}
sub invalid(Str:D $message) { failure('argument', $message, NotStarted).throw }
sub nonce(--> Str:D) {
    my $random = '/dev/urandom'.IO.open(:r, :bin);
    LEAVE $random.close;
    my $bytes = $random.read(16);
    failure('identity', 'Cannot obtain a program ownership nonce', NotStarted).throw
        unless $bytes.elems == 16;
    $bytes.list.map(*.fmt('%02x')).join
}

sub prepare-program(Mu $argv, *%options --> Map:D) is export(:internals) {
    my %allowed = set(<directory environment width height history-limit
        max-output-bytes max-pending setup-timeout-ms cancel>);
    invalid('Unknown program option') if %options.keys.first({ !%allowed{$_} }).defined;
    invalid('argv must be a nonempty positional collection')
        unless $argv ~~ Positional:D && !nqp::istype($argv, Junction) && $argv.elems;
    invalid('argv exceeds 256 arguments') if $argv.elems > 256;
    my @args;
    for $argv.list -> $value {
        invalid('argv entries must be defined NUL-free strings')
            unless $value ~~ Str:D && !nqp::istype($value, Junction) && !$value.contains("\0");
        @args.push($value.Str);
    }
    invalid('argv must name an executable without a leading dash')
        unless @args[0].chars && !@args[0].starts-with('-');
    my $directory = %options<directory> // $*CWD.Str;
    invalid('directory must be an absolute NUL-free path')
        unless $directory ~~ Str:D && !$directory.contains("\0") && $directory.IO.is-absolute;
    my $environment = %options<environment> // Map.new;
    invalid('environment must be associative')
        unless $environment ~~ Associative:D && !nqp::istype($environment, Junction);
    my %environment;
    invalid('environment exceeds 256 entries') if $environment.elems > 256;
    for $environment.kv -> $key, $value {
        invalid('Invalid program environment entry') unless $key ~~ Str:D
            && $key.chars && !$key.contains(any('=', "\0"))
            && $key ne 'LIBTMUX_PROGRAM_TOKEN'
            && !nqp::istype($value, Junction) && $value ~~ Str:D && !$value.contains("\0");
        %environment{$key.Str} = $value.Str;
    }
    my %spec = argv => @args.List, :$directory, environment => %environment.Map,
        width => 80, height => 24, history-limit => 2000,
        max-output-bytes => 1024 * 1024, max-pending => 32, setup-timeout-ms => 5000,
        cancel => Cancellation;
    for <width height history-limit max-output-bytes max-pending setup-timeout-ms cancel> -> $key {
        %spec{$key} = %options{$key} if %options{$key}:exists;
    }
    for <width height> -> $key {
        invalid('Program dimensions must be integers in 1..10000')
            unless %spec{$key} ~~ Int:D && 1 <= %spec{$key} <= 10000;
    }
    invalid('history-limit must be an integer in 0..100000')
        unless %spec<history-limit> ~~ Int:D && 0 <= %spec<history-limit> <= 100000;
    invalid('max-output-bytes must be in 1..8388608')
        unless %spec<max-output-bytes> ~~ Int:D && 1 <= %spec<max-output-bytes> <= 8388608;
    invalid('setup-timeout-ms must be in 1..600000')
        unless %spec<setup-timeout-ms> ~~ Int:D && 1 <= %spec<setup-timeout-ms> <= 600000;
    invalid('max-pending must be in 1..128')
        unless %spec<max-pending> ~~ Int:D && 1 <= %spec<max-pending> <= 128;
    invalid('cancel must be a Cancellation token')
        unless %spec<cancel> === Cancellation || %spec<cancel> ~~ Cancellation:D;
    failure('cancelled', 'Program setup was cancelled', NotStarted).throw
        if %spec<cancel>.defined && %spec<cancel>.cancelled;
    %spec.Map
}

sub require-process-groups(--> Nil) {
    my $fd = -1;
    LEAVE native-close($fd) if $fd.defined && $fd >= 0;
    CATCH {
        when X::LibTmux::Command { .rethrow }
        default { failure('platform', 'Native process-group pidfd support is unavailable', NotStarted).throw }
    }
    $fd = pidfd_open($*PID, 0);
    failure('platform', 'Cannot acquire a process pidfd', NotStarted).throw if $fd < 0;
    my $status = pidfd_send_signal($fd, 0, Pointer, 4);
    my $error = $status == 0 ?? 0 !! errno-location()[0];
    failure('platform', 'Managed programs require Linux process-group pidfds (6.9+); native errno ' ~ $error,
        NotStarted).throw unless $status == 0 || $error == 3;
}

has Runtime $!runtime;
has Observation $!observation;
has Map $!spec;
has Str $!token;
#| Unique owned session name; it is diagnostic, not mutation authority.
has Str $.session-name;
#| Native session ID accepted during setup.
has SessionId $.session-id;
has WindowId $!window-id;
#| Pane reference bound to the daemon incarnation accepted during setup.
has PaneRef $.pane;
has Int $!pid;
has Bool $!creation-dispatched = False;
has Proc::Async $!owner;
has Promise $!owner-done;
has @!taps;
has Buf $!stderr = Buf.new;
has Exception $!owner-error;
has Bool $!owner-serving = False;
has Exception $!cleanup-error;
has IO::Path $!directory;
has Int $!gate-inode;
has Int $!gate-device;
has Promise $!bootstrap-ready .= new;
has $!bootstrap-vow;
has Promise $!bootstrap-accepted .= new;
has $!bootstrap-accepted-vow;
has Promise $!ready .= new;
has Promise $!armed .= new;
has Promise $!done .= new;
has Promise $!closed .= new;
has Promise $!released .= new;
has $!released-vow;
has %!replies;
has %!waiters;
has %!work;
has Int $!next = 0;
has Bool $!starting = True;
has Bool $!stop-sent = False;
has Int $!generation;
has Str $!generation-marker = '';
has Bool $!invalid = False;
#| Whether cleanup claimed the original generation and removed its pane.
has Bool $.pane-removed = False;
#| Whether the retained native process group was observed empty during cleanup.
has Bool $.group-empty = False;
has Bool $!closed-frame = False;
has Promise $!replies-ended .= new;
has $!replies-ended-vow;
has Supplier $!owner-ended .= new;
has Supplier $!output-ended .= new;
has Supplier $!result-ready .= new;
has Promise $!finisher .= new;
has Promise $!checker .= new;
has $!finisher-vow;
has $!checker-vow;
has Bool $!finisher-started = False;
has Bool $!checker-started = False;
has Supplier $!finisher-ended .= new;
has Supplier $!checker-ended .= new;
has Promise $!quiesced;
has Supplier $!work-ended .= new;
has List $!quiescing = ().List;
has $!ready-vow;
has $!armed-vow;
has $!done-vow;
has $!closed-vow;
has Lock $!lock .= new;
has Lock $!actions .= new;
has Bool $!closing = False;

submethod BUILD(:$runtime!, :$observation!, :$spec!, :$token!, :$session-name!) {
    $!runtime = $runtime; $!observation = $observation; $!spec = $spec;
    $!token = $token; $!session-name = $session-name;
}
submethod TWEAK() {
    $!ready-vow = $!ready.vow; $!armed-vow = $!armed.vow;
    $!done-vow = $!done.vow; $!closed-vow = $!closed.vow;
    $!released-vow = $!released.vow;
    $!bootstrap-vow = $!bootstrap-ready.vow;
    $!bootstrap-accepted-vow = $!bootstrap-accepted.vow;
    $!finisher-vow = $!finisher.vow; $!checker-vow = $!checker.vow;
    $!replies-ended-vow = $!replies-ended.vow;
}

#| Refuse handles without accepted ownership. Use C<Server.start-program>.
method new(|) { invalid('Use Server.start-program') }
#| Owning handles cannot be shallow-cloned.
method clone(|) { invalid('Program ownership cannot be cloned') }
#| Show the owned session identity without application settings or environment.
method gist(--> Str:D) { "LibTmux::Program($!session-name)" }

method !command(@argv --> LibTmux::Transport::Result:D) {
    $!runtime.execute(Invocation.new(:argv(@argv.List)),
        :incarnation($!observation.incarnation),
        :cancel($!starting ?? $!spec<cancel> !! Cancellation))
}
method !operation(&body --> Promise:D) {
    my $done = Promise.new;
    my $vow = $done.vow;
    my $id = $!lock.protect({
        if $!closing {
            $vow.break(failure('closed', 'Program is closing', NotStarted)); 0
        } elsif %!work.elems >= $!spec<max-pending> {
            $vow.break(failure('capacity', 'Program operation capacity is exhausted', NotStarted)); 0
        } else {
            my $id = ++$!next; %!work{$id} = $done; $id
        }
    });
    return $done unless $id;
    start {
        my $value; my Exception $error;
        try { $value = body(); CATCH { default { $error = $_ } } }
        $!lock.protect({
            $error.defined ?? $vow.break($error) !! $vow.keep($value);
            %!work{$id}:delete;
        });
    };
    $done
}
method !condition(--> Str:D) {
    '#{&&:#{&&:#{||:#{pane_dead},#{==:#{pane_pid},' ~ $!pid
        ~ '}},#{==:#{LIBTMUX_PROGRAM_TOKEN},' ~ $!token
        ~ '}},#{==:#{window_id},' ~ $!window-id ~ '}}'
}
method !claim(Int:D $pid --> Str:D) {
    Invocation.new(:argv(['wait-for', '-E', '-w', "client-$pid", 'pane-created'])).source
}
method !mark(Str:D $value --> Str:D) {
    Invocation.new(:argv(['set-option', '-p', '-t', $!pane.id,
        '@libtmux-program-generation', $value])).source
}
method !guard(@argv, Int:D :$claim!, Int:D :$barrier!, Str:D :$marker! --> Invocation:D) {
    my $condition = self!condition;
    $condition = '#{&&:' ~ $condition ~ ',#{==:#{window_panes},1}}' if $!starting;
    Invocation.new(:argv(['if-shell', '-F', '-t', $!pane.id, $condition,
        self!claim($claim) ~ ' ; ' ~ self!mark($marker) ~ ' ; '
            ~ self!claim($barrier) ~ ' ; ' ~ Invocation.new(:argv(@argv.List)).source,
        'run-shell -C libtmux-program-stale-' ~ $!token]))
}
method !resolve-reply(Str:D $id, Mu $value = Mu, Exception :$error = Exception --> Nil) {
    my $vow = $!lock.protect({ %!replies{$id}:delete });
    return unless $vow.defined;
    $error.defined ?? $vow.break($error) !! $vow.keep($value);
}
method !owner-lost(Exception:D $error --> Nil) {
    my @pending = $!lock.protect({ %!replies.keys.List });
    self!resolve-reply($_, :$error) for @pending;
    self!settle-error($error) unless $!closing;
}
method !request(%request, Instant:D $deadline, Bool :$teardown = False) {
    $!owner-error.throw if $!owner-error.defined && !$teardown;
    my $id = nonce();
    my $reply = Promise.new;
    my $seconds = ($deadline - now).Num;
    failure('timeout', 'Program request deadline expired').throw unless $seconds > 0;
    $!lock.protect({ %!replies{$id} = $reply.vow });
    my $timer = $*SCHEDULER.cue({
        self!resolve-reply($id, :error(failure('timeout', 'Program request deadline expired')))
    }, :in($seconds));
    my Callable $unsubscribe = Callable;
    if $!starting && !$teardown && $!spec<cancel>.defined {
        $unsubscribe = subscribe-cancellation($!spec<cancel>, {
            self!resolve-reply($id, :error(failure('cancelled', 'Program setup was cancelled')))
        });
    }
    LEAVE {
        $timer.cancel if $timer.defined;
        $unsubscribe() if $unsubscribe.defined;
        $!lock.protect({ %!replies{$id}:delete });
    }
    await $!owner.write((to-json(%(|%request, :$id), :!pretty) ~ "\n").encode);
    await $reply
}
method !watch-event(Str:D $event, Str:D $filter, Instant:D $deadline,
                    Bool :$notify = False --> Int:D) {
    my $wait = Invocation.new(:argv(['wait-for', '-E', '-F', $filter, $event]));
    my @argv = $!runtime.prepare-owned-command($wait,
        :incarnation($!observation.incarnation));
    my $pid = self!request(%(kind => 'watch', :@argv, :$notify), $deadline).Int;
    loop {
        my @waiters = self!command(['wait-for', '-E', '-l', $event]).stdout.decode.lines;
        return $pid if @waiters.first(* eq "client-$pid").defined;
        failure('owner', 'Generation observer exited before registration').throw
            unless self!request(%(kind => 'status', :$pid), $deadline);
        failure('timeout', 'Program setup deadline expired').throw if now >= $deadline;
    }
}
method !watch(Instant:D $deadline --> Int:D) {
    self!watch-event('pane-created',
        $!pane.defined ?? '#{==:#{pane},' ~ $!pane.id ~ '}' !! '#{created_respawn}',
        $deadline)
}
method !cleanup(Int:D $generation, Str :$marker = $!generation-marker,
                Int :$fallback = Int --> Map:D) {
    return %(pane => '').Map unless $!pane.defined;
    my $target = $!pane.id;
    my $delete = Invocation.new(:argv(['kill-pane', '-t', $target]));
    my $remove = self!claim($generation) ~ ' ; ' ~ $delete.source;
    if $marker.chars {
        $remove = Invocation.new(:argv(['if-shell', '-F', '-t', $target,
            '#{==:#{@libtmux-program-generation},' ~ $marker ~ '}', $remove,
            $fallback.defined ?? self!claim($fallback) ~ ' ; ' ~ $delete.source
                !! 'run-shell -C libtmux-program-stale-' ~ $!token])).source;
    }
    my $cleanup = Invocation.new(:argv(['if-shell', '-F', '-t', $target,
        self!condition,
        $remove, 'run-shell -C libtmux-program-stale-' ~ $!token]));
    my @probe = $!runtime.prepare-owned-command(Invocation.new(:argv([
        'list-panes', '-a', '-f', '#{==:#{pane_id},' ~ $target ~ '}', '-F', '#{pane_id}'])),
        :incarnation($!observation.incarnation));
    my @inspect = $!runtime.prepare-owned-command(Invocation.new(:argv([
        'display-message', '-p', '-t', $target, '#{pane_id}|#{pane_pid}'])),
        :incarnation($!observation.incarnation));
    %(pane => $target, pid => $!pid, argv => $!runtime.prepare-owned-command($cleanup,
        :incarnation($!observation.incarnation)), probe => @probe.List, inspect => @inspect.List,
        refusals => ["unknown command: libtmux-program-stale-$!token\n",
            "waiter client-$generation not found\n",
            |($fallback.defined ?? ["waiter client-$fallback not found\n"] !! [])]).Map
}
method !action(@argv, Bool :$finishing = False --> LibTmux::Transport::Result:D) {
    $!actions.protect({
        CATCH {
            default {
                unless $_ ~~ X::LibTmux::Command && .outcome == NotStarted
                    && .kind eq any(<closed completed>) {
                    $!invalid = True; self!settle-error($_);
                }
                .rethrow;
            }
        }
        failure('closed', 'Program is closing', NotStarted).throw if $!closing && !$finishing;
        X::LibTmux::StaleReference.new(:message('Program generation was invalidated')).throw if $!invalid;
        failure('completed', 'Program has already completed', NotStarted).throw
            if @argv[0] eq 'send-keys' && $!done.status == Kept;
        my $deadline = now + $!runtime.timeout-ms / 1000;
        my $previous = $!generation;
        my $barrier = self!watch($deadline);
        my $next = self!watch($deadline);
        my $marker = nonce();
        my $cleanup = self!cleanup($next, :$marker, :fallback($previous));
        self!request(%(kind => 'cleanup', command => $cleanup), $deadline);
        my $result = $!runtime.execute(self!guard(@argv, :claim($previous), :$barrier, :$marker),
            :incarnation($!observation.incarnation), :!check,
            :cancel($!starting && !$finishing ?? $!spec<cancel> !! Cancellation));
        if $result.exitcode || $result.signal {
            $!invalid = True;
            my $error = X::LibTmux::StaleReference.new(:message('Program pane was removed or respawned'));
            self!settle-error($error);
            $error.throw;
        }
        $!generation = $next; $!generation-marker = $marker;
        self!request(%(kind => 'retire', pid => $previous), $deadline);
        self!request(%(kind => 'retire', pid => $barrier), $deadline);
        $result
    })
}
method !row(Bool :$finishing = False --> List:D) {
    my $text = self!action(['display-message', '-p', '-t', $!pane.id,
        '#{pane_pid}|#{pane_dead}|#{pane_dead_status}|#{pane_dead_signal}|#{history_size}'],
        :$finishing).stdout.decode;
    my @parts = $text.trim-trailing.split('|');
    failure('protocol', 'Invalid program observation').throw unless @parts.elems == 5;
    @parts.List
}
method !capture(Bool :$finishing = False --> Blob:D) {
    self!action(['capture-pane', '-p', '-J', '-N', '-S', '-', '-t', $!pane.id], :$finishing).stdout
}
method !finish-wait(Int:D $id, Mu $value = Mu, Exception :$error = Exception --> Nil) {
    my $entry = $!lock.protect({ %!waiters{$id}:delete });
    return unless $entry.defined;
    $entry<timer>.cancel if $entry<timer>.defined;
    $entry<unsubscribe>() if $entry<unsubscribe>.defined;
    $error.defined ?? $entry<vow>.break($error) !! $entry<vow>.keep($value);
}
method !publish(Mu $value, Exception :$error = Exception --> Nil) {
    my $changed = False;
    my @waiting = $!lock.protect({
        if $!done.status == Planned {
            $error.defined ?? $!done-vow.break($error) !! $!done-vow.keep($value);
            $changed = True;
            %!waiters.keys.List
        } else { ().List }
    });
    self!finish-wait($_.Int, $value, :$error) for @waiting;
    if $changed { $!result-ready.emit(True); $!result-ready.done }
}
method !settle-error(Exception:D $error) {
    self!publish(Mu, :$error);
}
method !complete(--> Nil) {
    my @row = self!row(:finishing);
    failure('outcome', 'Application exit status is not available').throw
        unless @row[1] eq '1' && (@row[2].chars || @row[3].chars);
    my $startup = $!directory.add('startup-error');
    if $startup.e {
        failure('identity', 'Program startup report was replaced').throw if $startup.l || !$startup.f;
        my $bytes = $startup.slurp(:bin);
        failure('overflow', 'Program startup report exceeds its bound').throw if $bytes.elems > 512;
        my %failure = from-json($bytes.decode('utf8'));
        failure('identity', 'Program startup report has another owner').throw
            unless %failure<token> eq $!token;
        X::LibTmux::Command.new(:kind<spawn>, :exitcode(@row[2].Int),
            :message('Program startup failed during ' ~ %failure<stage>
                ~ ' (errno ' ~ %failure<error> ~ ')')).throw;
    }
    my $screen = self!capture(:finishing);
    my $dropped = max(0, $screen.elems - $!spec<max-output-bytes>);
    my $bounded = Blob.new($screen.list.skip($dropped));
    my $result = Completion.new(:exitcode(@row[2].chars ?? @row[2].Int !! Int),
        :signal(@row[3].chars ?? @row[3].Str !! Str), :screen($bounded),
        :dropped-bytes($dropped),
        :history-limited(@row[4].Int >= $!spec<history-limit>));
    self!publish($result);
}
method !event(%event) {
    given %event<kind> {
        when 'ready' {
            $!gate-inode = %event<gate-inode>; $!gate-device = %event<gate-device>;
            $!ready-vow.keep(%event<directory>) if $!ready.status == Planned;
        }
        when 'armed' { $!armed-vow.keep(%event<observer>.Int) if $!armed.status == Planned }
        when 'watched' | 'ack' {
            self!resolve-reply(%event<id>, %event<pid> // %event<value> // True);
        }
        when 'termination-error' {
            self!resolve-reply(%event<id>, :error(failure('cleanup', %event<message>)));
        }
        when 'closed' {
            $!pane-removed = %event<pane-removed>;
            $!group-empty = %event<group-empty>;
            $!closed-frame = True;
        }
        when 'owner-error' | 'arm-error' {
            $!owner-serving = %event<kind> eq 'arm-error';
            $!owner-error = failure('owner', %event<message> // 'Program ownership helper failed');
            self!owner-lost($!owner-error);
        }
        when 'cleanup-error' {
            $!cleanup-error = failure('cleanup', %event<message> // 'Program cleanup failed');
        }
        when 'cleanup-incomplete' {
            $!cleanup-error = failure('cleanup', %event<message>);
        }
        when 'topology-changed' {
            $!invalid = True;
            self!settle-error(X::LibTmux::StaleReference.new(
                :message('Program pane placement or cardinality changed')));
        }
        when 'exited' {
            my $accepted = $!lock.protect({
                if $!finisher-started || ($!closing && $!done.status != Planned) { False }
                else { $!finisher-started = True; True }
            });
            if $accepted {
                start {
                    LEAVE {
                        $!finisher-vow.keep(True);
                        $!finisher-ended.emit(True); $!finisher-ended.done;
                    }
                    try {
                        $!starting
                            ?? self!settle-error(failure('owner', 'Program bootstrap exited before release'))
                            !! self!complete;
                        CATCH { default { self!settle-error($_) } }
                    }
                };
            }
        }
        when 'root-exit' {
            my $accepted = $!lock.protect({
                if $!checker-started || $!closing { False }
                else { $!checker-started = True; True }
            });
            if $accepted {
                start {
                    LEAVE {
                        $!checker-vow.keep(True);
                        $!checker-ended.emit(True); $!checker-ended.done;
                    }
                    try {
                        $!starting
                            ?? self!settle-error(failure('owner', 'Program bootstrap exited before release'))
                            !! self!row;
                        CATCH { default { self!settle-error($_) unless $!closing } } }
                };
            }
        }
        default {
            self!settle-error(failure('owner', %event<message> // 'Program observation owner failed'))
        }
    }
}
method !await-setup(Promise:D $pending, Instant:D $deadline, Bool :$teardown = False) {
    my $seconds = ($deadline - now).Num;
    failure('timeout', 'Program setup deadline expired').throw unless $seconds > 0;
    my $expired = Promise.new;
    my $vow = $expired.vow;
    my $timer = $*SCHEDULER.cue({ $vow.keep(True) }, :in($seconds));
    LEAVE $timer.cancel if $timer.defined;
    my Callable $unsubscribe = Callable;
    LEAVE $unsubscribe() if $unsubscribe.defined;
    my @wait = $pending, $!owner-done, $expired;
    @wait.push($!done) if !$teardown && $!done.status == Planned;
    my $cancel = $!starting && !$teardown ?? $!spec<cancel> !! Cancellation;
    if $cancel.defined {
        my $cancelled = Promise.new;
        my $cancel-vow = $cancelled.vow;
        $unsubscribe = subscribe-cancellation($cancel, { $cancel-vow.keep(True) });
        @wait.push($cancelled);
    }
    await Promise.anyof(@wait);
    failure('cancelled', 'Program setup was cancelled').throw
        if $cancel.defined && $cancel.cancelled;
    await $!done if !$teardown && $!done.status == Broken;
    failure('owner', 'Program owner stopped during setup').throw if $!owner-done.status != Planned;
    failure('timeout', 'Program setup deadline expired').throw if $pending.status == Planned;
    await $pending
}
method !await-state(Promise:D $state, Supplier:D $signal, Instant:D $deadline --> Bool:D) {
    return True if $state.status != Planned;
    my $ready = Promise.new;
    my $vow = $ready.vow;
    my $lock = Lock.new;
    my &notify = { $lock.protect({ $vow.keep(True) if $ready.status == Planned }) };
    my $tap = $signal.Supply.tap(-> $event { notify() }, :done(&notify));
    my $timer = $*SCHEDULER.cue(&notify, :in(max(0, ($deadline - now).Num)));
    LEAVE { $tap.close if $tap.defined; $timer.cancel if $timer.defined }
    notify() if $state.status != Planned;
    await $ready;
    $state.status != Planned
}
method !runner(--> List:D) {
    failure('package', 'Load LibTmux through its installed distribution or -I.', NotStarted).throw
        unless $?DISTRIBUTION.defined;
    my $metadata = $?DISTRIBUTION.meta;
    my $unit = $*REPO.resolve(CompUnit::DependencySpecification.new(
        :short-name<LibTmux::Program::Owner>, :ver($metadata<version>), :auth($metadata<auth>)));
    failure('package', 'Program ownership module is missing', NotStarted).throw unless $unit.defined;
    my $code = 'use LibTmux::Program::Owner:ver(' ~ $metadata<version>.raku
        ~ '):auth(' ~ $metadata<auth>.raku ~ ') :internals; run-owner(|@*ARGS)';
    ($*EXECUTABLE.Str, '-I' ~ $unit.repo.path-spec, '-e', $code).List
}
method !creation(Str:D $gate, List:D $runner --> Invocation:D) {
    my @environment = $!spec<environment>.sort.map({ (.key, .value).Slip });
    Invocation.new(:argv(['new-session', '-d', '-P', '-F', '#{session_id}|#{pane_id}|#{pane_pid}|#{window_id}',
        '-s', $!session-name, '-x', $!spec<width>.Str, '-y', $!spec<height>.Str,
        '-e', 'LIBTMUX_PROGRAM_TOKEN=' ~ $!token,
        '--', |$runner,
        '--bootstrap', $gate, $!token, $!spec<directory>,
        $!spec<environment>.elems.Str, |@environment, |$!spec<argv>]))
}
method !remember-creation(Blob:D $bytes --> Bool:D) {
    my @created = ($bytes.decode('utf8-c8').lines[0] // '').split('|');
    return False unless @created.elems == 4 && @created[0] ~~ SessionId
        && @created[1] ~~ PaneId && @created[2] ~~ /^ <[0..9]>+ $/
        && @created[3] ~~ WindowId;
    $!session-id = @created[0]; $!pid = @created[2].Int;
    $!window-id = @created[3];
    $!pane = PaneRef.new(:endpoint($!runtime.endpoint),
        :incarnation($!observation.incarnation), :id(@created[1]));
    True
}
method !write-grant(Str:D $gate, Instant:D $deadline, Blob:D $message --> Nil) {
    $!lock.protect({
        failure('timeout', 'Program setup deadline expired').throw if now >= $deadline;
        my $fd = -1;
        LEAVE native-close($fd) if $fd.defined && $fd >= 0;
        $fd = native-open($gate, 1 +| 0o4000 +| 0o2000000 +| 0o400000);
        failure('owner', 'Program gate is no longer available').throw if $fd < 0;
        my $opened = "/proc/$*PID/fd/$fd".IO;
        failure('identity', 'Program gate was replaced').throw
            unless $opened.inode == $!gate-inode && $opened.dev == $!gate-device;
        my $bytes = CArray[uint8].new(|$message.list);
        my $written = native-write($fd, $bytes, $message.elems);
        failure('owner', 'Program gate release was not accepted').throw
            unless $written == $message.elems;
        $!starting = False;
    });
}
method !release(Str:D $gate, Instant:D $deadline --> Nil) {
    $!actions.protect({
        my $previous = $!generation;
        my $barrier = self!watch($deadline);
        my $next = self!watch($deadline);
        my $marker = nonce();
        self!request(%(kind => 'cleanup', command =>
            self!cleanup($next, :$marker, :fallback($previous))), $deadline);
        my @argv = $!runtime.prepare-owned-command(self!guard([
            'set-option', '-t', $!session-id, 'history-limit', $!spec<history-limit>.Str],
            :claim($previous), :$barrier, :$marker), :incarnation($!observation.incarnation));
        my $grant = (to-json(%(token => $!token, pid => $!pid, :@argv), :!pretty) ~ "\n").encode;
        failure('overflow', 'Program release exceeds the atomic FIFO bound').throw
            if $grant.elems > 4096;
        $!generation = $next; $!generation-marker = $marker;
        if $!spec<cancel>.defined {
            commit-cancellation($!spec<cancel>, { self!write-grant($gate, $deadline, $grant) },
                failure('cancelled', 'Program setup was cancelled'));
        } else { self!write-grant($gate, $deadline, $grant) }
        my $accepted = self!await-setup($!bootstrap-accepted, min($deadline, now + 1));
        failure('owner', 'Program bootstrap did not claim its release generation').throw
            unless $accepted<token> eq $!token && $accepted<pid> == $!pid
                && $accepted<accepted>;
        self!request(%(kind => 'retire', pid => $previous), $deadline);
        self!request(%(kind => 'retire', pid => $barrier), $deadline);
    });
}
method !setup(--> Nil) {
    my $deadline = now + $!spec<setup-timeout-ms> / 1000;
    my $runner = self!runner;
    my $prototype = $*TMPDIR.add('libtmux-program-XXXXXX').add('gate').Str;
    $!runtime.validate-command(self!creation($prototype, $runner),
        :incarnation($!observation.incarnation));
    $!owner = Proc::Async.new(:w, |$runner);
    my $carry = '';
    my $size = 0;
    @!taps = $!owner.stdout.tap(-> $chunk {
        try {
            $carry ~= $chunk;
            failure('overflow', 'Program owner response exceeds its bound').throw
                if $carry.encode.elems > 65536;
            while $carry.contains("\n") {
                my ($line, $rest) = $carry.split("\n", 2);
                $carry = $rest;
                self!event(from-json($line));
            }
            CATCH { default { self!owner-lost($_) } }
        }
    }, :done({ $!replies-ended-vow.keep(True); $!output-ended.emit(True); $!output-ended.done }), :quit(-> $error {
        $!replies-ended-vow.break($error); $!output-ended.emit(True); $!output-ended.done;
        self!owner-lost($error)
    })), $!owner.stderr(:bin).tap(-> $chunk {
        $size += $chunk.elems;
        $!stderr.append($chunk) if $size <= 4096;
        self!owner-lost(X::LibTmux::Command.new(:kind<owner>,
            :stderr(Blob.new($!stderr.list)), :message('Program ownership helper failed')));
        try $!owner.kill(9) if $size > 4096;
    });
    $!owner-done = $!owner.start;
    start {
        LEAVE { $!owner-ended.emit(True); $!owner-ended.done }
        try {
            my $result = await $!owner-done;
            self!owner-lost(failure('owner', 'Program owner ended before completion'));
            CATCH { default { self!owner-lost($_) } }
        }
    };
    my $identity = $!observation.incarnation;
    await $!owner.write((to-json(%(root => $*TMPDIR.Str, token => $!token,
        daemon => %(pid => $identity.pid, boot-id => $identity.boot-id,
            start-ticks => $identity.start-ticks)), :!pretty) ~ "\n").encode);
    $!directory = self!await-setup($!ready, $deadline).IO;
    my $bootstrap-tap = IO::Notification.watch-path($!directory).act(-> $event {
        my $name = $event.path.IO.basename;
        my $path = $!directory.add($name);
        if $name eq any(<bootstrap-ready bootstrap-accepted>) && $path.e {
            try {
                failure('identity', 'Program bootstrap report was replaced').throw if $path.l || !$path.f;
                my $handle = $path.open(:r, :bin);
                my $bytes = $handle.read(513); $handle.close;
                failure('overflow', 'Program bootstrap report exceeds its bound').throw if $bytes.elems > 512;
                my $report = from-json($bytes.decode('utf8'));
                $!lock.protect({
                    if $name eq 'bootstrap-ready' {
                        $!bootstrap-vow.keep($report) if $!bootstrap-ready.status == Planned;
                    } else {
                        $!bootstrap-accepted-vow.keep($report)
                            if $!bootstrap-accepted.status == Planned;
                    }
                });
                CATCH { default { self!settle-error($_) } }
            }
        }
    });
    @!taps.push($bootstrap-tap);
    $!generation = self!watch($deadline);
    self!request(%(kind => 'cleanup', command => self!cleanup($!generation)), $deadline);
    my $gate = $!directory.add('gate').Str;
    self!request(%(kind => 'creating'), $deadline);
    $!creation-dispatched = True;
    my Blob $receipt;
    my Exception $creation-error;
    try {
        $receipt = $!runtime.execute(self!creation($gate, $runner),
            :incarnation($!observation.incarnation), :deadline($deadline),
            :cancel($!spec<cancel>)).stdout;
        CATCH {
            default {
                $creation-error = $_;
                if $_ ~~ X::LibTmux::Command {
                    $receipt = .stdout;
                    $!creation-dispatched = False if .outcome == NotStarted;
                }
            }
        }
    }
    self!remember-creation($receipt) if $receipt.defined && $receipt.elems;
    $creation-error.throw if $creation-error.defined;
    failure('protocol', 'Program creation returned invalid identities').throw
        unless $!pane.defined;
    self!request(%(kind => 'cleanup', command => self!cleanup($!generation)), $deadline);
    self!watch-event('window-unlinked', '#{&&:#{==:#{window},' ~ $!window-id
        ~ '},#{==:#{session},' ~ $!session-id ~ '}}', $deadline, :notify);
    # Event payloads have IDs but no default target. Native loops establish
    # the session/window context before reading its current pane count.
    my $count = '#{S:#{?#{==:#{session_id},' ~ $!session-id
        ~ '},#{W:#{?#{==:#{window_id},' ~ $!window-id ~ '},#{window_panes},}},}}';
    self!watch-event('window-layout-changed', '#{&&:#{==:#{window},' ~ $!window-id
        ~ '},#{!=:' ~ $count ~ ',1}}', $deadline, :notify);
    my $barrier = self!watch($deadline);
    my $next = self!watch($deadline);
    my $marker = nonce();
    my @admit = $!runtime.prepare-owned-command(
        Invocation.new(:argv(['if-shell', '-F', '-t', $!pane.id, self!condition,
            self!claim($!generation) ~ ' ; ' ~ self!mark($marker)
                ~ ' ; ' ~ self!claim($barrier),
            'run-shell -C libtmux-program-stale-' ~ $!token])),
        :incarnation($!observation.incarnation));
    my $accepted-cleanup = self!cleanup($next, :$marker);
    my $wait = Invocation.new(:argv(['wait-for', '-E', '-F',
        '#{==:#{pane},' ~ $!pane.id ~ '}', 'pane-died']));
    my @observer = $!runtime.prepare-owned-command($wait,
        :incarnation($!observation.incarnation));
    await $!owner.write((to-json(%(kind => 'arm', pid => $!pid,
        token => $!token, admit => @admit, cleanup => $accepted-cleanup,
        observer => @observer), :!pretty) ~ "\n").encode);
    my $observer = self!await-setup($!armed, $deadline);
    self!request(%(kind => 'retire', pid => $!generation), $deadline);
    self!request(%(kind => 'retire', pid => $barrier), $deadline);
    $!generation = $next; $!generation-marker = $marker;
    loop {
        my @waiters = self!command(['wait-for', '-E', '-l', 'pane-died']).stdout.decode.lines;
        last if @waiters.first(* eq "client-$observer").defined;
        failure('timeout', 'Exit observer registration deadline expired').throw if now >= $deadline;
    }
    self!action(['set-option', '-p', '-t', $!pane.id, 'remain-on-exit', 'on']);
    self!action(['set-option', '-p', '-t', $!pane.id, 'remain-on-exit-format', '']);
    my $bootstrap = self!await-setup($!bootstrap-ready, min($deadline, now + 1));
    failure('identity', 'Program bootstrap readiness has another owner').throw
        unless $bootstrap<token> eq $!token && $bootstrap<pid> == $!pid;
    self!release($gate, $deadline);
}

sub open-program(Runtime:D $runtime, Observation:D $observation, Map:D $spec) is export(:internals) {
    $observation.capabilities.require('managed-program');
    $observation.capabilities.require($_) for <event-wait event-wait-claim>;
    $observation.capabilities.require-field('pane', $_) for <pid dead dead-status dead-signal>;
    $observation.capabilities.require-field('window', 'id');
    require-process-groups;
    my $token = nonce();
    my $owned = Runtime.new(:endpoint($runtime.endpoint),
        :max-command-bytes($runtime.max-command-bytes), :max-output-bytes(8 * 1024 * 1024));
    my $program = LibTmux::Program.bless(:runtime($owned), :$observation, :$spec, :$token,
        :session-name('libtmux-program-' ~ $token));
    my $error;
    try { $program!setup; CATCH { default { $error = $_ } } }
    if $error.defined {
        my $cleanup;
        try { $program.close; CATCH { default { $cleanup = $_ } } }
        X::LibTmux::Program.new(:primary($error), :$cleanup, :owner($program),
            :message('Program setup and cleanup failed; ownership is retained')).throw
            if $cleanup.defined;
        $error.throw;
    }
    $program
}

#| Observe completion without ending the program when this wait is cancelled.
method wait-async(:$timeout-ms = Positive, Cancellation :$cancel = Cancellation --> Promise:D)
    is single-operation('async') {
    return Promise.broken(failure('argument', 'Invalid wait timeout', NotStarted))
        unless $timeout-ms === Positive || $timeout-ms ~~ Positive:D;
    return Promise.broken(failure('cancelled', 'Program wait was cancelled', NotStarted))
        if $cancel.defined && $cancel.cancelled;
    my $pending = Promise.new;
    my $vow = $pending.vow;
    my $id = $!lock.protect({
        if $!done.status == Kept { $vow.keep($!done.result); 0 }
        elsif $!done.status == Broken { $vow.break($!done.cause); 0 }
        elsif $!closing { $vow.break(failure('closed', 'Program is closing', NotStarted)); 0 }
        elsif %!waiters.elems >= $!spec<max-pending> {
            $vow.break(failure('capacity', 'Program waiter capacity is exhausted', NotStarted)); 0
        } else {
            my $id = ++$!next;
            %!waiters{$id} = %(vow => $vow, timer => Mu, unsubscribe => Callable);
            $id
        }
    });
    return $pending unless $id;
    if $cancel.defined {
        my &unsubscribe = subscribe-cancellation($cancel, {
            self!finish-wait($id, :error(failure('cancelled', 'Program wait was cancelled')))
        });
        my $retained = $!lock.protect({
            if %!waiters{$id}:exists { %!waiters{$id}<unsubscribe> = &unsubscribe; True }
            else { False }
        });
        unsubscribe() unless $retained;
    }
    if $timeout-ms.defined {
        my $timer = $*SCHEDULER.cue({
            self!finish-wait($id, :error(failure('timeout', 'Program wait deadline expired')))
        }, :in($timeout-ms / 1000));
        my $retained = $!lock.protect({
            if %!waiters{$id}:exists { %!waiters{$id}<timer> = $timer; True }
            else { False }
        });
        $timer.cancel unless $retained;
    }
    $pending
}
#| Await the same retained application result. A timeout leaves ownership intact.
method wait(*%options --> Completion:D) is single-operation { await self.wait-async(|%options) }
#| Capture rendered screen/history bytes; this does not wait for completion.
method screen-async(--> Promise:D) is single-operation('async') { self!operation({ self!capture }) }
#| Capture rendered screen/history bytes synchronously.
method screen(--> Blob:D) { await self.screen-async }
#| Send at most 512 literal input bytes without adding Enter.
method send-async(Blob:D $bytes --> Promise:D) is single-operation('async') {
    return Promise.broken(failure('argument', 'Program input exceeds 512 bytes', NotStarted))
        if $bytes.elems > 512;
    my @hex = $bytes.list.map(*.fmt('%02x'));
    self!operation({ self!action(['send-keys', '-H', '-t', $!pane.id, '--', |@hex]) })
}
#| Encode text as UTF8 and send it without shell interpretation or an added Enter.
method send-text-async(Str:D $text --> Promise:D) is single-operation('async') {
    self.send-async($text.encode('utf8-c8'))
}
#| Send literal UTF8 text synchronously, including explicitly supplied newlines.
method send-text(Str:D $text --> LibTmux::Transport::Result:D) is single-operation {
    await self.send-text-async($text)
}
#| Resolve once owned cleanup succeeds. Failed attempts leave this Promise pending.
method closed(--> Promise:D) { $!released }
#| Private temporary directory retained for inspection after incomplete cleanup.
method cleanup-location(--> IO::Path) { $!directory }
#| Close the owned process group/session. Every caller shares cleanup completion.
method close-async(--> Promise:D) {
    my $first = $!lock.protect({
        if $!closing && $!closed.status != Broken { False }
        else {
            if $!closed.status == Broken { $!closed = Promise.new; $!closed-vow = $!closed.vow }
            $!closing = True;
            unless $!quiesced.defined {
                $!quiescing = %!work.values.List;
                $!quiesced = Promise.allof(|$!quiescing);
                $!quiesced.then({ $!work-ended.emit(True); $!work-ended.done });
            }
            True
        }
    });
    if $first {
        start {
            my Exception $error;
            try {
                if $!owner.defined && $!owner-done.defined {
                    if $!owner-done.status == Planned && !$!stop-sent {
                        if !$!owner-error.defined || $!owner-serving {
                            self!request(%(kind => 'terminate'), now + 1, :teardown)
                                if $!armed.status == Kept;
                            if $!armed.status == Kept && $!done.status == Planned {
                                self!await-state($!done, $!result-ready, now + 0.75);
                                self!settle-error(failure('drain', 'Final program output is incomplete'))
                                    if $!done.status == Planned;
                            }
                            my $until = now + 1;
                            self!await-state($!quiesced, $!work-ended, $until);
                            self!await-state($!finisher, $!finisher-ended, $until)
                                if $!finisher-started;
                            self!await-state($!checker, $!checker-ended, $until)
                                if $!checker-started;
                            failure('cleanup', 'Program operations remain active').throw
                                if $!quiescing.first(*.status == Planned).defined
                                    || ($!finisher-started && $!finisher.status == Planned)
                                    || ($!checker-started && $!checker.status == Planned);
                            my %finish = kind => 'finish', created => $!creation-dispatched;
                            %finish<command> = self!cleanup($!generation)
                                if $!armed.status != Kept && $!pane.defined;
                            self!request(%finish, now + 1, :teardown);
                        }
                        $!owner.close-stdin;
                        $!stop-sent = True;
                    }
                    my $deadline = now + 1;
                    self!await-state($!owner-done, $!owner-ended, $deadline);
                    failure('cleanup', 'Program ownership cleanup remains incomplete').throw
                        if $!owner-done.status == Planned;
                    my $result = await $!owner-done;
                    self!await-state($!replies-ended, $!output-ended, $deadline);
                    failure('cleanup', 'Program ownership reply drain remains incomplete').throw
                        if $!replies-ended.status == Planned;
                    await $!replies-ended;
                    X::LibTmux::Command.new(:kind<cleanup>,
                        :cause($!cleanup-error // $!owner-error
                            // ($!done.status == Broken ?? $!done.cause !! Exception)),
                        :stderr(Blob.new($!stderr.list)),
                        :message('Program ownership cleanup failed')).throw
                            if $result.exitcode || $result.signal;
                    failure('cleanup', 'Program cleanup lacks its final receipt').throw
                        if $!directory.defined && (!$!closed-frame || !$!group-empty);
                }
                self!settle-error(failure('closed', 'Program was closed'));
                $!runtime.close;
                my $settled = try await $!quiesced;
                .close for @!taps;
                CATCH { default { $error = $_ } }
            }
            if $error.defined {
                my @waiting = $!lock.protect({ %!waiters.keys.List });
                self!finish-wait($_.Int, :$error) for @waiting;
            }
            if $error.defined { $!closed-vow.break($error) }
            else {
                $!released-vow.keep(True) if $!released.status == Planned;
                $!closed-vow.keep(True);
            }
        };
    }
    $!closed
}
#| Await owned cleanup. The borrowed daemon and other sessions remain intact.
method close(--> Nil) { await self.close-async; Nil }

=begin pod
=head1 Run and own a terminal application

Construct a Program with L<LibTmux::Server.start-program> or
L<LibTmux::Server.start-program-async>. A successful start accepts ownership of
the gated pane process and returns its daemon-bound L<LibTmux::Model::PaneRef>.
The target executable can still fail during startup; C<wait> reports that
failure separately from an application that exits with status 126 or 127.
Command acceptance and application readiness are separate facts. This surface
provides no application-specific readiness detector.

Before exec, the bootstrap consumes a bounded, PID-bound grant and claims the
original native pane generation itself. A respawned bootstrap cannot reuse
that grant. The caller waits for its token and PID acceptance receipt before
returning a running handle.

Argv is copied before asynchronous admission. Its executable is nonempty and
cannot start with a dash; later arguments can be empty. All arguments are
NUL-free strings. Only an explicitly requested shell interprets shell source.
C<directory> is an absolute path, defaulting to the caller's working directory.
C<environment> overlays inherited values only when the target executes; keys
and values remain literal text, with at most 256 entries.
The ownership variable C<LIBTMUX_PROGRAM_TOKEN> is reserved.

=head2 Discover support before starting

Use C<$server.capabilities.supports('managed-program')> on the Server that will
run the application. The first qualified profile is released tmux 3.8. Setup
also requires native C<event-wait>, C<event-wait-claim> and retained pane exit
fields through that observation. Older or unqualified daemon profiles refuse
before creating helpers, panes or temporary files. A newer client binary does
not upgrade a connected daemon. Replacing the daemon invalidates its handles.

Programs currently require a local Linux daemon, procfs and process-group
pidfds from Linux 6.9 or newer. Setup refuses when the native flag is absent.
This is process ownership, not filesystem, network or privilege confinement.

=head2 Bounds and output

C<width> and C<height> default to 80 by 24 and accept 1..10000. Retained history
defaults to 2000 rows; C<history-limit> accepts 0..100000. Final
C<max-output-bytes> defaults to 1048576 and accepts 1..8388608. C<max-pending>
defaults to 32 and accepts 1..128 independently for input/capture operations and
completion observers. Excess work is refused before admission. Setup has its
own C<setup-timeout-ms>, default 5000, with an accepted range of 1..600000.

Input accepts at most 512 bytes per call and adds no Enter. C<send-text> uses
UTF8-C8; explicit newlines remain input. The application receives a real PTY,
so stdout and stderr share one terminal and normal terminal line discipline
applies. C<screen> captures rendered screen and retained history with an 8 MiB
acquisition bound; it returns an overflow error if that bound is exceeded.

C<wait> retains one immutable L<Completion> after the native pane exit/output
barrier. C<screen> is rendered terminal data rather than a replayable output
stream. The final result keeps the last C<max-output-bytes> bytes, reports the
omitted byte count and conservatively marks history that reached its row bound.
Truncation can split a character; inspect bytes or decode with C<utf8-c8>.
Normal exit and signal termination are distinct result variants.

=head2 Cancellation and cleanup

A C<wait> deadline or Cancellation token ends only that observer and releases
its slot. A C<run-program> deadline or cancellation owns termination and cleanup
before reporting the primary failure. The run deadline starts after setup;
setup cancellation applies while acquiring ownership. Use a running handle
when a result must remain inspectable after an observer is cancelled.

C<close> stops new work, sends TERM, waits a short grace period and escalates
with KILL through the retained group descriptor. Successful cleanup includes
an observed empty group and drained ownership replies. A failed attempt throws
while retaining the owner for another C<close>; C<cleanup-location> identifies
its private recovery directory. C<closed> resolves only after successful
cleanup, and concurrent callers share each cleanup attempt.

When setup or an owning run has both a primary error and incomplete cleanup,
C<X::LibTmux::Program> retains C<primary>, C<cleanup> and C<owner>. Keep that
owner and retry C<owner.close> after restoring the endpoint. A thrown cleanup
error does not establish completed cleanup.

Pane writes and deletion consume a pending native generation witness in the
same command queue as the effect. External respawn invalidates the handle;
cleanup preserves the replacement and exposes C<pane-removed> as False.
Borrowed daemons and sibling sessions remain borrowed. A Server closes the
Programs it accepted when it closes itself.

The initial owner keeps one pane in its original window. External splits,
placement changes and window unlinking invalidate observation; resizing a
single-pane window remains valid. Cleanup still terminates the retained owned
group and preserves a pane moved outside the accepted window.

After ownership is accepted, the private watchdog's lifetime pipe is the
recovery lease if the caller VM exits. A caller crash during creation before
pane identity reaches the watchdog can retain an incomplete lease until the
original daemon exits. Setup cancellation reports a recoverable owner when
it cannot prove cleanup. Processes that leave the owned group through C<setsid> or
daemonization are outside that lease. Killing the watchdog, losing the host,
remote filesystems and daemon process migration have no cleanup guarantee.
Raw replayable streams, separate PTY stdout/stderr, OSC 133 and visible-text
waits remain separate capabilities.
=end pod
