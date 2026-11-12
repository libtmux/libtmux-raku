use v6.d;

unit class LibTmux::Server;

use NativeCall;
use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Catalogue;
use LibTmux::Capabilities;
use LibTmux::Command :DEFAULT, :internals;
use LibTmux::Engine;
use LibTmux::Transport;
use LibTmux::Model;
use LibTmux::Operations;
use LibTmux::Query::Plan :DEFAULT, :internal;
use LibTmux::Query::Execution;
need LibTmux::Configuration;
need LibTmux::Control::Connection;
need LibTmux::Attachment;
need LibTmux::Batch;

sub invalid(Str:D $message --> Nil) {
    X::LibTmux::Command.new(:$message, :kind<argument>, :outcome(NotStarted)).throw
}
sub limits($timeout, $output, $command --> Nil) {
    invalid('Timeout and output/command limits must be positive integers')
        unless $timeout ~~ Positive:D && $output ~~ Positive:D && $command ~~ Positive:D;
}
sub remaining(Instant:D $deadline, Outcome :$outcome = NotStarted --> Positive:D) {
    my $milliseconds = (($deadline - now) * 1000).ceiling.Int;
    X::LibTmux::Command.new(:kind<timeout>, :$outcome,
        :message('Server operation deadline expired')).throw unless $milliseconds > 0;
    $milliseconds
}
sub argument-text(Mu $value, Str:D $name --> Str:D) {
    invalid("$name must be nonempty text without NUL")
        unless $value.defined && $value.^isa(Str) && $value.chars && !$value.contains("\0");
    $value
}
sub argument-bool(Mu $value, Str:D $name --> Bool:D) {
    invalid("$name must be a defined Boolean") unless $value.defined && $value.^isa(Bool);
    $value
}
sub pane-argument(Mu $pane --> List:D) {
    return ().List if $pane === PaneId;
    invalid('pane must be one pane ID') unless $pane.defined && $pane.^isa(Str) && $pane ~~ PaneId;
    ('-t', $pane).List
}
sub session-name($name --> Str:D) {
    invalid('Session name must be nonempty text') unless $name ~~ Str:D && $name.chars;
    invalid('Session names cannot contain controls, backslash, dot or colon')
        if $name ~~ /<:Cc>/
            || $name.contains(any("\\", '.', ':'));
    my $valid = try $name.encode('utf8-c8').decode('utf8');
    invalid('Session name must contain valid Unicode text') unless $valid.defined;
    # FORMAT expands each generated character once, including style-shaped hashes.
    $name.subst('#', '#{a:35}', :g)
}
sub creation($name, $shell-command, $width, $height --> Invocation:D) {
    my $literal = session-name($name);
    invalid('Session dimensions must be positive integers')
        unless $width ~~ Positive:D && $height ~~ Positive:D;
    invalid('shell-command must be defined text without NUL when supplied')
        unless $shell-command === Str || ($shell-command ~~ Str:D && !$shell-command.contains("\0"));
    my @argv = 'new-session', '-d', '-P', '-F', 'LTM1-session-#{session_id}',
        '-s', $literal, '-x', $width.Str, '-y', $height.Str;
    @argv.append('--', $shell-command) if $shell-command.defined;
    Invocation.new(:@argv)
}
sub created(Runtime:D $runtime, Observation:D $observation, Invocation:D $command,
            Cancellation :$cancel = Cancellation, Instant :$deadline = Instant --> SessionRef:D) {
    my $result = $runtime.execute($command, :incarnation($observation.incarnation), :$cancel, :$deadline);
    my $text = $result.stdout.decode('utf8-c8');
    my $match = $text ~~ /^ 'LTM1-session-' $<id>=[ '$' <[0..9]>+ ] "\n" $/;
    X::LibTmux::Decode.new(:schema<new-session>,
        :message('Creation did not return exactly one session identifier')).throw unless $match;
    SessionRef.new(:id(~$match<id>), :endpoint($runtime.endpoint),
        :incarnation($observation.incarnation))
}

my class PollEvent is repr('CStruct') {
    has int32 $.fd is rw;
    has int16 $.events is rw = 1;
    has int16 $.revents is rw;
}
my class PollPair is repr('CStruct') {
    HAS PollEvent $.ready;
    HAS PollEvent $.exit;
}
sub mkdtemp(CArray[uint8] --> Pointer) is native { * }
sub pidfd_open(int32, uint32 --> int32) is native { * }
sub pidfd_send_signal(int32, int32, Pointer, uint32 --> int32) is native { * }
sub poll(Pointer, size_t, int32 --> int32) is native { * }
sub native-close(int32 --> int32) is native is symbol('close') { * }
sub native-read(int32, CArray[uint8], size_t --> ssize_t) is native is symbol('read') { * }
sub inotify_init1(int32 --> int32) is native { * }
sub inotify_add_watch(int32, Str, uint32 --> int32) is native { * }

my class Environment {
    has Map:D $.entries is required;
    method Bool(--> Bool:D) { True }
    method hash(--> Hash:D) { $!entries.Hash }
}
sub temporary-directory(--> IO::Path:D) {
    my $template = $*TMPDIR.add('libtmux-owned-XXXXXX').Str.encode('utf8');
    my $bytes = CArray[uint8].new(|$template.list, 0);
    X::LibTmux::Command.new(:kind<spawn>, :outcome(NotStarted),
        :message('Could not create an owned socket directory')).throw unless mkdtemp($bytes);
    Blob.new((^$template.elems).map({ $bytes[$_] })).decode('utf8').IO
}

# This process stays foregrounded: its pidfd identifies it even if the socket is replaced.
my class OwnedDaemon {
    #| Captured connection settings; retaining them owns no process.
    has Endpoint:D $.endpoint is required;
    has IO::Path:D $.directory is required;
    has Int $!directory-inode;
    has Int $!directory-device;
    has Int $!socket-inode;
    has Int $!socket-device;
    has int32 $!pidfd = -1;
    has int32 $!watch = -1;
    has Proc::Async $!process;
    has Promise $!done;
    has @!taps;
    has Buf $!stderr = Buf.new;
    has Lock $!output-lock .= new;
    has Exception $!io-failure;
    has Bool $!overflow = False;
    has Int $.pid = 0;

    submethod TWEAK() {
        $!directory-inode = $!directory.inode;
        $!directory-device = $!directory.dev;
    }
    method launch(--> Nil) {
        $!watch = inotify_init1(0o2000000 +| 0o4000);
        X::LibTmux::Command.new(:kind<spawn>, :outcome(NotStarted),
            :message('Cannot watch the owned socket directory')).throw
            if $!watch < 0 || inotify_add_watch($!watch, $!directory.Str, 4) < 0;
        $!process = Proc::Async.new(:w, |$!endpoint.argv, '-D');
        my &collect = -> Blob:D $chunk {
            my $overflow = $!output-lock.protect({
                if $!stderr.elems + $chunk.elems > 64 * 1024 { $!overflow = True }
                else { $!stderr.append($chunk); False }
            });
            self.signal(9) if $overflow && $!pidfd >= 0;
        };
        my &failed = -> $error {
            $!output-lock.protect({ $!io-failure //= $error });
            self.signal(9) if $!pidfd >= 0;
        };
        @!taps = $!process.stdout(:bin).tap(&collect, :quit(&failed)),
            $!process.stderr(:bin).tap(&collect, :quit(&failed));
        my $failure;
        try {
            $!done = $!process.start(:ENV(Environment.new(:entries($!endpoint.environment))),
                :cwd($!endpoint.cwd));
            $!pid = await $!process.pid;
            $!process.close-stdin;
            CATCH { default { $failure = $_ } }
        }
        X::LibTmux::Command.new(:kind<spawn>, :outcome($!pid ?? Indeterminate !! NotStarted),
            :pid($!pid), :cause($failure),
            :message('Could not launch the owned foreground daemon')).throw if $failure.defined;
        $!pidfd = pidfd_open($!pid, 0);
        X::LibTmux::Command.new(:kind<spawn>, :outcome(Indeterminate), :pid($!pid),
            :message('Cannot acquire owned daemon process identity')).throw if $!pidfd < 0;
        self.signal(9) if $!overflow || $!io-failure.defined;
    }
    method signal(Int:D $signal --> Nil) {
        if $!pidfd >= 0 { pidfd_send_signal($!pidfd, $signal, Pointer, 0) }
        elsif $!process.defined && $!done.defined && $!done.status == Planned {
            my $sent = try $!process.kill($signal);
        }
    }
    method bind(Observation:D $observation --> Nil) {
        my $path = $!endpoint.socket-path.IO;
        X::LibTmux::StaleReference.new(:message('Socket does not address the owned daemon')).throw
            unless $observation.incarnation.pid == $!pid && !$path.l && $path.e
                && $path.inode == $!socket-inode && $path.dev == $!socket-device;
    }
    method !ready(Instant:D $deadline --> Nil) {
        LEAVE { native-close($!watch) if $!watch >= 0; $!watch = -1 }
        my $events = PollPair.new;
        $events.ready.fd = $!watch; $events.ready.events = 1;
        $events.exit.fd = $!pidfd; $events.exit.events = 1;
        loop {
            my $count = poll(nativecast(Pointer, $events), 2,
                remaining($deadline, :outcome(Indeterminate)));
            X::LibTmux::Command.new(:kind<timeout>, :outcome(Indeterminate),
                :message('Owned daemon did not become ready')).throw unless $count > 0;
            my $ready = False;
            my $buffer = CArray[uint8].new; $buffer[4095] = 0;
            my $size = $events.ready.revents +& 1 ?? native-read($!watch, $buffer, 4096) !! 0;
            my $offset = 0;
            while $size >= $offset + 16 {
                my $length = [+] (0..3).map({ $buffer[$offset + 12 + $_] +< (8 * $_) });
                my $name = Blob.new(($offset + 16 ..^ $offset + 16 + $length)
                    .map({ $buffer[$_] })).decode('utf8').split("\0")[0];
                if $name eq 'socket' {
                    my $path = $!endpoint.socket-path.IO;
                    $!socket-inode = $path.inode; $!socket-device = $path.dev;
                    $ready = True;
                }
                $offset += 16 + $length;
            }
            X::LibTmux::Command.new(:kind<spawn>, :outcome(Failed), :pid($!pid),
                :stderr($!output-lock.protect({ Blob.new($!stderr.list) })),
                :message('Owned daemon exited during startup')).throw if $events.exit.revents;
            return if $ready;
        }
    }
    method ready(Instant:D $deadline, Cancellation :$cancel = Cancellation --> Nil) {
        my $ready = start { self!ready($deadline) };
        await Promise.anyof($ready, $cancel.when-cancelled) if $cancel.defined;
        if $cancel.defined && $cancel.cancelled {
            self.signal(9);
            my $settled = try await $ready;
            X::LibTmux::Command.new(:kind<cancelled>, :outcome(Indeterminate),
                :message('Owned server startup was cancelled')).throw;
        }
        await $ready;
    }
    method stop(--> Nil) {
        LEAVE {
            .close for @!taps;
            native-close($!watch) if $!watch >= 0; $!watch = -1;
            native-close($!pidfd) if $!pidfd >= 0; $!pidfd = -1;
        }
        if $!done.defined {
            self.signal(15);
            my $settled = await Promise.anyof($!done, Promise.in(1));
            if $!done.status == Planned {
                self.signal(9);
                $settled = await Promise.anyof($!done, Promise.in(1));
            }
            X::LibTmux::Command.new(:kind<cleanup>, :outcome(Indeterminate), :pid($!pid),
                :message('Owned daemon did not exit after termination')).throw
                if $!done.status == Planned;
            my $reaped = try await $!done;
            if $!pidfd >= 0 {
                my $event = PollEvent.new(:fd($!pidfd), :events(1));
                X::LibTmux::Command.new(:kind<cleanup>, :outcome(Indeterminate), :pid($!pid),
                    :message('Owned process completion lacks exit evidence')).throw
                    unless poll(nativecast(Pointer, $event), 1, 0) == 1 && $event.revents +& 1;
            }
        }
        # Remove only the original socket and an otherwise empty original directory.
        my $path = $!endpoint.socket-path.IO;
        if $!directory.e && !$!directory.l
            && $!directory.inode == $!directory-inode && $!directory.dev == $!directory-device {
            $path.unlink if $!socket-inode.defined && $path.e && !$path.l
                && $path.inode == $!socket-inode && $path.dev == $!socket-device;
            $!directory.rmdir unless $!directory.dir.elems;
        }
    }
}

#| Captured connection settings; retaining them owns no process.
has Endpoint:D $.endpoint is required;
#| Combined output-byte limit for one owned command response.
has Positive:D $.max-output-bytes = 8 * 1024 * 1024;
#| Maximum encoded command size in bytes, including tmux quoting.
has Positive:D $.max-command-bytes = 12 * 1024;
has Runtime $!runtime;
has OwnedDaemon $!owner;
has Incarnation $!owned-incarnation;
#| Pane ID explicitly imported from TMUX_PANE; undefined for ordinary construction.
has PaneId $.environment-pane-id;
#| Session ID explicitly imported from TMUX; undefined when tmux supplied -1.
has SessionId $.environment-session-id;
has Lock $!lock .= new;
has Bool $!closing = False;
has Promise $!closed .= new;
has $!closed-vow;
has %!work;
has Int $!next = 0;

submethod BUILD(:$!endpoint!, :$runtime!, :$owner = OwnedDaemon,
                :$owned-incarnation = Incarnation,
                :$!environment-pane-id = PaneId, :$!environment-session-id = SessionId,
                :$!max-output-bytes = 8 * 1024 * 1024,
                :$!max-command-bytes = 12 * 1024) {
    $!runtime = $runtime; $!owner = $owner; $!owned-incarnation = $owned-incarnation;
}
submethod TWEAK() { $!closed-vow = $!closed.vow }

#| Capture a borrowed endpoint without I/O. Closing it closes clients only.
method new(:$binary = 'tmux', :$socket-name = '', :$socket-path = '',
           :$config-file = '', :$environment = %*ENV, :$cwd = $*CWD,
           :$timeout-ms = 10_000, :$max-output-bytes = 8 * 1024 * 1024,
           :$max-command-bytes = 12 * 1024) is single-operation {
    limits($timeout-ms, $max-output-bytes, $max-command-bytes);
    my $endpoint = Endpoint.new(:$binary, :$socket-name, :$socket-path,
        :$config-file, :$environment, :$cwd);
    my $runtime = Runtime.new(:$endpoint, :$timeout-ms, :$max-output-bytes, :$max-command-bytes);
    self.bless(:$endpoint, :$runtime, :$max-output-bytes, :$max-command-bytes)
}

#| Import an explicit TMUX environment, verify its daemon PID and bind that incarnation.
method from-env(Mu :$environment = %*ENV, *%settings) is single-operation {
    invalid('environment must be one associative value')
        unless $environment.defined && !$environment.^isa(Junction) && $environment ~~ Associative;
    invalid('Environment import cannot override the socket')
        if (%settings<socket-path>:exists) || (%settings<socket-name>:exists);
    my $value = argument-text($environment<TMUX>, 'TMUX');
    # Parse from the right: a Unix socket path can itself contain commas.
    my @parts = $value.split(',');
    invalid('TMUX must contain socket path, positive PID and session number') unless @parts.elems >= 3;
    my $session = @parts.pop;
    my $pid = @parts.pop;
    my $path = @parts.join(',');
    invalid('TMUX requires an absolute socket path and decimal identity components')
        unless $path.chars && $path.IO.is-absolute
            && $pid ~~ /^ <[0..9]>+ $/ && $pid.Int > 0
            && ($session eq '-1' || $session ~~ /^ <[0..9]>+ $/);
    my $pane = ($environment<TMUX_PANE>:exists) ?? $environment<TMUX_PANE> !! PaneId;
    pane-argument($pane);
    my $server = self.new(:$environment, :socket-path($path), |%settings);
    my $failure;
    try {
        await $server!operation(-> $deadline {
            my $observation = $server!observation($deadline);
            X::LibTmux::StaleReference.new(:message('TMUX PID does not identify the observed daemon')).throw
                unless $observation.incarnation.pid == $pid.Int;
            $server!bind-environment($observation.incarnation, $pane,
                $session eq '-1' ?? SessionId !! '$' ~ $session.Int);
        });
        CATCH { default { $failure = $_ } }
    }
    if $failure.defined { $server.close; $failure.throw }
    $server
}

method !bind-environment(Incarnation:D $identity, $pane, $session --> Nil) {
    $!owned-incarnation = $identity;
    $!environment-pane-id = $pane;
    $!environment-session-id = $session;
}

#| Whether this facade owns the foreground daemon it started.
method owned(--> Bool:D) { $!owner.defined }
#| Refuse cloning of runtime admission and daemon ownership state.
method clone(|) { invalid('An owning Server cannot be cloned') }

method !operation(&body, Instant:D :$deadline = now + $!runtime.timeout-ms / 1000 --> Promise:D) {
    my $done = Promise.new;
    my $vow = $done.vow;
    my $id = $!lock.protect({
        if $!closing { Nil } else {
            my $id = ++$!next; %!work{$id} = $done; $id
        }
    });
    return Promise.broken(X::LibTmux::Command.new(:kind<closed>, :outcome(NotStarted),
        :message('Server is closed'))) unless $id.defined;
    my $worker = start {
        my $value; my $failure;
        try { $value = body($deadline); CATCH { default { $failure = $_ } } }
        $!lock.protect({
            $failure.defined ?? $vow.break($failure) !! $vow.keep($value);
            %!work{$id}:delete;
        });
    };
    $done
}
method !observation(Instant:D $deadline, Cancellation :$cancel = Cancellation --> Observation:D) {
    my $observation = $!runtime.observe(:$deadline, :$cancel);
    X::LibTmux::StaleReference.new(:message('Bound daemon has been replaced')).throw
        if $!owned-incarnation.defined && $observation.incarnation.key ne $!owned-incarnation.key;
    $observation
}

#| Acquire a captured graph explicitly. Existing snapshots remain unchanged.
method snapshot(Cancellation :$cancel = Cancellation --> Snapshot:D) is single-operation { await self.snapshot-async(:$cancel) }
#| Resolve a fresh captured graph; cancellation propagates through every acquisition stage.
method snapshot-async(Cancellation :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    self!operation(-> $deadline {
        capture($!runtime, :required-incarnation($!owned-incarnation), :$deadline, :$cancel)
    })
}
#| Observe the daemon's capabilities explicitly; this performs tmux I/O.
method capabilities(Cancellation :$cancel = Cancellation --> LibTmux::Capabilities:D) is single-operation {
    await self.capabilities-async(:$cancel)
}
#| Resolve to one fresh immutable daemon capability observation.
method capabilities-async(Cancellation :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    self!operation(-> $deadline { self!observation($deadline, :$cancel).capabilities })
}

#| Observe capabilities and explain an explicit source query without executing its listing.
method explain(Mu $entity, Mu :$where = Map.new, Mu :$pushdown = 'auto', *%unknown --> Plan:D) {
    invalid('Unknown query option ' ~ %unknown.keys.sort.join(', ')) if %unknown;
    await self!operation(-> $deadline {
        my $filter = query-filter($entity, $where);
        query-policy($pushdown);
        my $plan = Plan.compile($filter,
            :capabilities(self!observation($deadline).capabilities), :$pushdown);
        remaining($deadline);
        $plan
    })
}
#| Acquire a typed selection; only requested relationship predicates load the full graph.
method query(Mu $entity, *%options --> Positional:D) {
    await self.query-async($entity, |%options)
}
#| Copy and validate query data before scheduling acquisition within one shared deadline.
method query-async(Mu $entity, Mu :$where = Map.new, Mu :$pushdown = 'auto',
                   Mu :$cancel = Cancellation, *%unknown --> Promise:D) {
    my $deadline = now + $!runtime.timeout-ms / 1000;
    my $filter;
    my $error;
    try {
        invalid('Unknown query option ' ~ %unknown.keys.sort.join(', ')) if %unknown;
        invalid('cancel must be one Cancellation token')
            unless $cancel === Cancellation || ($cancel.^isa(Cancellation) && $cancel.defined);
        $filter = query-filter($entity, $where);
        query-policy($pushdown);
        remaining($deadline);
        CATCH { default { $error = $_ } }
    }
    return Promise.broken($error) if $error.defined;
    self!operation(-> $deadline {
        my $plan = Plan.compile($filter,
            :capabilities(self!observation($deadline, :$cancel).capabilities), :$pushdown);
        acquire-plan($!runtime, $plan, :$deadline, :$cancel)
    }, :$deadline)
}
#| Acquire panes explicitly; the resulting selection is local and replayable.
method query-panes(*%options --> PaneSelection:D) { self.query('pane', |%options) }
#| Explain pane acquisition, pushed restrictions and residual local work.
method explain-panes(*%options --> Plan:D) { self.explain('pane', |%options) }
#| Acquire sessions explicitly under the selected pushdown policy.
method query-sessions(*%options --> SessionSelection:D) { self.query('session', |%options) }
#| Acquire unique physical windows, preserving link context separately.
method query-windows(*%options --> WindowSelection:D) { self.query('window', |%options) }
#| Acquire session/index associations without deduplicating repeated window placements.
method query-window-links(*%options --> WindowLinkSelection:D) { self.query('window-link', |%options) }
#| Test one exact session ID or name. Acquisition and identity failures still throw.
method has-session(Mu :$id = SessionId, Mu :$name = Str --> Bool:D) is single-operation {
    invalid('Specify exactly one session id or name')
        unless ($id === SessionId) != ($name === Str);
    my %where;
    if $id !=== SessionId {
        argument-text($id, 'id');
        invalid('id must be a session ID') unless $id ~~ SessionId;
        %where<id> = $id;
    } else { %where<name> = argument-text($name, 'name') }
    so self.query-sessions(:where(%where)).elems
}
#| Create a detached session and return its value-only, identity-scoped reference.
method new-session(:$name!, :$shell-command = Str, :$width = 80, :$height = 24 --> SessionRef:D) is single-operation {
    my $command = creation($name, $shell-command, $width, $height);
    await self!operation(-> $deadline {
        created($!runtime, self!observation($deadline), $command, :$deadline)
    })
}

#| Execute explicit tmux command syntax in the currently observed daemon.
method command(Invocation:D $command, *%options --> Result:D) is single-operation {
    await self.command-async($command, |%options)
}
#| Copy input before scheduling one guarded command; retain exit status and raw streams.
method command-async(Invocation:D $command, Blob:D :$stdin = Blob.new,
                     Cancellation :$cancel = Cancellation, Bool:D :$check = True --> Promise:D) is single-operation('async') {
    my $deadline = now + $!runtime.timeout-ms / 1000;
    my $input = Blob.new($stdin.list);
    self!operation(-> $deadline {
        my $identity = self!observation($deadline, :$cancel).incarnation;
        $!runtime.execute($command, :incarnation($identity), :stdin($input), :$cancel, :$check, :$deadline)
    }, :$deadline)
}

method !request(&arguments, Cancellation :$cancel = Cancellation --> Promise:D) {
    self!operation(-> $deadline {
        my $command = Invocation.new(:argv(arguments()), :max-bytes($!max-command-bytes));
        my $identity = self!observation($deadline, :$cancel).incarnation;
        $!runtime.execute($command, :incarnation($identity), :$cancel, :$deadline)
    })
}

#| Run literal shell source through tmux. Background acknowledgement is not job completion.
method run-shell(Mu $script, *%options --> Result:D) is single-operation { await self.run-shell-async($script, |%options) }
#| Resolve the bounded tmux job request; cancellation does not undo a server-side job.
method run-shell-async(Mu $script, Mu :$background = False, Mu :$pane = PaneId,
                       Cancellation :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    self!request({
        my $text = literal-format(argument-text($script, 'script'));
        ['run-shell', |(argument-bool($background, 'background') ?? ['-b'] !! []),
            |pane-argument($pane), '--', $text]
    }, :$cancel)
}

#| Execute one of two bounded commands after a shell test, or an explicit FORMAT condition.
method if-shell(Mu $condition, Mu $then, Mu :$otherwise = Invocation,
                Mu :$format = False, Mu :$background = False, Mu :$pane = PaneId,
                Cancellation :$cancel = Cancellation --> Result:D) is single-operation {
    await self!request({
        invalid('then must be one Invocation') unless $then.defined && $then.^isa(Invocation);
        invalid('otherwise must be one Invocation when supplied')
            unless $otherwise === Invocation || ($otherwise.defined && $otherwise.^isa(Invocation));
        my $text = argument-text($condition, 'condition');
        $text = literal-format($text) unless argument-bool($format, 'format');
        ['if-shell', |($format ?? ['-F'] !! []),
            |(argument-bool($background, 'background') ?? ['-b'] !! []),
            |pane-argument($pane), '--', $text, $then.source,
            |($otherwise.defined ?? [$otherwise.source] !! [])]
    }, :$cancel)
}

#| Source one literal local pathname; parse-only validates without running its commands.
method source-file(Mu $path, Mu :$parse-only = False,
                   Cancellation :$cancel = Cancellation --> Result:D) is single-operation {
    await self!request({
        my $literal = argument-text($path, 'path');
        invalid('source-file requires a pathname, not stdin') if $literal eq '-';
        # source-file expands globs even without -F; escape only glob metacharacters.
        $literal = $literal.comb.map({ $_ eq any('\\', '*', '?', '[', ']') ?? '\\' ~ $_ !! $_ }).join;
        ['source-file', |(argument-bool($parse-only, 'parse-only') ?? ['-n'] !! []), '--', $literal]
    }, :$cancel)
}

#| Wait, signal, lock or unlock a named channel; timeout cannot undo server-side effects.
method wait-for(Mu $channel, *%options --> Result:D) is single-operation { await self.wait-for-async($channel, |%options) }
#| Resolve one channel operation within the Server deadline, without readiness polling.
method wait-for-async(Mu $channel, Mu :$action = 'wait',
                     Cancellation :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    self!request({
        my $name = argument-text($channel, 'channel');
        argument-text($action, 'action');
        my %flags = wait => [], signal => ['-S'], lock => ['-L'], unlock => ['-U'];
        invalid('action must be wait, signal, lock or unlock') unless %flags{$action}:exists;
        ['wait-for', |%flags{$action}, '--', $name]
    }, :$cancel)
}

#| Explicitly terminate this observed daemon. Owned callers must still close to join cleanup.
method kill-server(Cancellation :$cancel = Cancellation --> Result:D) is single-operation {
    await self!request({ ['kill-server'] }, :$cancel)
}

method !configuration(Mu $type, Str:D :$scope = 'server', Bool:D :$global = False) {
    await self!operation(-> $deadline {
        $type.new(:endpoint($!endpoint), :incarnation(self!observation($deadline).incarnation),
            :$scope, :$global, :timeout-ms($!runtime.timeout-ms),
            :max-output-bytes($!max-output-bytes), :max-command-bytes($!max-command-bytes))
    })
}

#| Observe daemon identity and return server options or global session/window defaults.
method options(Str:D :$scope = 'server' --> LibTmux::Configuration::Options:D) is single-operation {
    invalid('Server option scope must be server, session or window')
        unless $scope eq any(<server session window>);
    self!configuration(LibTmux::Configuration::Options, :$scope, :global($scope ne 'server'))
}
#| Observe daemon identity and return its global environment facade.
method environment(--> LibTmux::Configuration::Environment:D) is single-operation {
    self!configuration(LibTmux::Configuration::Environment, :scope<session>, :global)
}
#| Observe daemon identity and return its named binary-buffer facade.
method buffers(--> LibTmux::Configuration::Buffers:D) is single-operation {
    self!configuration(LibTmux::Configuration::Buffers)
}
#| Observe daemon identity and return global session/window hooks.
method hooks(Str:D :$scope = 'session' --> LibTmux::Configuration::Hooks:D) is single-operation {
    invalid('Global hook scope must be session or window') unless $scope eq any(<session window>);
    self!configuration(LibTmux::Configuration::Hooks, :$scope, :global)
}
#| Observe daemon identity and return its key-binding facade.
method key-bindings(--> LibTmux::Configuration::KeyBindings:D) is single-operation {
    self!configuration(LibTmux::Configuration::KeyBindings)
}

#| Open a separately owned control connection attached to an explicit session ID.
method open-control(SessionId:D :$session-id!, *%settings --> LibTmux::Control::Connection:D) is single-operation {
    await self.open-control-async(:$session-id, |%settings)
}
#| Resolve a separately owned verified control connection; the caller must close it.
method open-control-async(SessionId:D :$session-id!, :$new-layouts = 'auto',
                          Cancellation :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    self!operation(-> $deadline {
        my $identity = self!observation($deadline, :$cancel).incarnation;
        LibTmux::Control::Connection.connect(:endpoint($!endpoint), :$session-id,
            :incarnation($identity), :$new-layouts, :$cancel,
            :timeout-ms(remaining($deadline)), :max-output-bytes($!max-output-bytes),
            :max-command-bytes($!max-command-bytes))
    })
}

#| Spawn a separately owned interactive client on the caller's explicit terminal.
method attach(SessionId:D :$session!, IO::Handle:D :$terminal!, *%settings --> LibTmux::Attachment:D) is single-operation {
    await self.attach-async(:$session, :$terminal, |%settings)
}
#| Resolve a separately owned terminal client; process creation is not attachment proof.
method attach-async(SessionId:D :$session!, IO::Handle:D :$terminal!,
                    Bool:D :$read-only = False, Bool:D :$detach-others = False,
                    Bool:D :$update-environment = False,
                    Cancellation :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    self!operation(-> $deadline {
        my $identity = self!observation($deadline, :$cancel).incarnation;
        LibTmux::Attachment.spawn(:endpoint($!endpoint), :incarnation($identity),
            :$session, :$terminal, :$read-only, :$detach-others, :$update-environment,
            :$cancel, :timeout-ms(remaining($deadline)))
    })
}

#| Run a declared batch with one observed incarnation and a shared deadline.
method run-batch(LibTmux::Batch::Batch:D $batch, *%options --> LibTmux::Batch::Report:D) is single-operation {
    await self.run-batch-async($batch, |%options)
}
#| Resolve per-operation outcomes with one deadline spanning observation and dispatch.
method run-batch-async(LibTmux::Batch::Batch:D $batch, Cancellation :$cancel = Cancellation,
                       Str:D :$on-error = 'stop' --> Promise:D) is single-operation('async') {
    self!operation(-> $deadline {
        my $identity = self!observation($deadline, :$cancel).incarnation;
        $batch.run(:executor($!runtime), :incarnation($identity), :$cancel, :$on-error,
            :$deadline)
    })
}

#| Start an owned foreground daemon on a fresh private socket and create its first session.
method start(:$name = 'main', :$binary = 'tmux', :$shell-command = Str,
             :$width = 80, :$height = 24, :$environment = %*ENV, :$cwd = $*CWD,
             :$timeout-ms = 10_000, :$max-output-bytes = 8 * 1024 * 1024,
             :$max-command-bytes = 12 * 1024, :$cancel = Cancellation) is single-operation {
    my $command = creation($name, $shell-command, $width, $height);
    limits($timeout-ms, $max-output-bytes, $max-command-bytes);
    $command = Invocation.new(:argv($command.argv), :max-bytes($max-command-bytes));
    invalid('cancel must be a Cancellation') unless $cancel === Cancellation || $cancel ~~ Cancellation:D;
    my $deadline = now + $timeout-ms / 1000;
    my $settings = Endpoint.new(:$binary, :$environment, :$cwd);
    my $executor = Executor.new(:timeout-ms(remaining($deadline)), :$max-output-bytes);
    LEAVE $executor.close if $executor.defined;
    my $version = $executor.execute(($binary, '-V').List,
        :environment($settings.environment), :cwd($settings.cwd), :$cancel).stdout.decode('utf8-c8');
    my $parsed = parse-tmux-version($version);
    X::LibTmux::Unsupported.new(:feature<owned-start>, :state(Unknown),
        :reason('Executable has no declared exact support profile'),
        :message('Cannot start an unqualified tmux executable')).throw
        unless $parsed.stable && support-policy().profile($parsed.release).defined;
    my $host-pidfd = pidfd_open($*PID, 0);
    X::LibTmux::Unsupported.new(:feature<owned-process-identity>,
        :reason('Linux pidfd support is required'),
        :message('Cannot own a daemon without pidfd support')).throw if $host-pidfd < 0;
    native-close($host-pidfd);
    X::LibTmux::Command.new(:kind<cancelled>, :outcome(NotStarted),
        :message('Owned server startup was cancelled')).throw if $cancel.defined && $cancel.cancelled;
    my $directory = temporary-directory;
    my $endpoint = $settings.clone(:socket-path($directory.add('socket').Str), :config-file('/dev/null'));
    my $owner = OwnedDaemon.new(:$endpoint, :$directory);
    my $server; my $failure;
    try {
        $owner.launch;
        $owner.ready($deadline, :$cancel);
        my $runtime = Runtime.new(:$endpoint,
            :timeout-ms(remaining($deadline, :outcome(Indeterminate))),
            :$max-output-bytes, :$max-command-bytes);
        my $observation;
        { LEAVE $runtime.close; $observation = $runtime.observe(:$cancel, :$deadline) }
        $owner.bind($observation);
        $observation.capabilities.require('managed-commands');
        my $creator = Runtime.new(:$endpoint,
            :timeout-ms(remaining($deadline, :outcome(Indeterminate))),
            :$max-output-bytes, :$max-command-bytes);
        { LEAVE $creator.close; created($creator, $observation, $command, :$cancel, :$deadline) }
        remaining($deadline, :outcome(Indeterminate));
        $server = self.bless(:$endpoint, :$owner, :owned-incarnation($observation.incarnation),
            :$max-output-bytes, :$max-command-bytes,
            :runtime(Runtime.new(:$endpoint, :$timeout-ms, :$max-output-bytes, :$max-command-bytes)));
        CATCH { default { $failure = $_ } }
    }
    if $failure.defined {
        my $cleanup;
        try { $owner.stop; CATCH { default { $cleanup = $_ } } }
        X::LibTmux::Command.new(:kind<cleanup>, :outcome(Indeterminate),
            :pid($owner.pid), :!reaped, :cause($failure),
            :message("Owned startup failed; cleanup also failed: {$cleanup.message}")).throw
            if $cleanup.defined;
        $failure.throw;
    }
    $server
}

#| Join idempotent shutdown; borrowed daemons remain running.
method close(--> Nil) { await self.close-async }
#| Join admitted work; owned servers additionally terminate and reap their original daemon.
method close-async(--> Promise:D) {
    my @active;
    my $owner = $!lock.protect({
        if $!closing { False } else { $!closing = True; @active = %!work.values; True }
    });
    if $owner {
        my $worker = start {
            my $failure;
            try { $!runtime.close; CATCH { default { $failure = $_ } } }
            await Promise.allof(@active);
            try { $!owner.stop if $!owner.defined; CATCH { default { $failure //= $_ } } }
            $failure.defined ?? $!closed-vow.break($failure) !! $!closed-vow.keep(True);
        };
    }
    $!closed
}

=begin pod
=head1 Server ownership

C<new> captures a borrowed endpoint without I/O. C<snapshot> and C<capabilities>
acquire daemon state explicitly. C<new-session> requires an existing daemon,
creates a detached session, and returns a SessionRef from tmux's returned ID.
Names are literal Unicode text; controls, backslash, dot and colon are refused
before creation because supported tmux releases normalize them differently.
A shell-command explicitly requests tmux's shell-command interpretation.

C<start> creates a clean foreground daemon on an exclusive temporary socket,
verifies its executable profile before launch, binds its actual process identity,
and creates the initial session. The startup timeout covers all stages. Linux
inotify socket attributes signal listener readiness; pidfds bind termination to
the original process, independently of socket reuse.

Close is idempotent and joins owned work. Borrowed daemons remain running.
Owned daemons receive TERM followed by bounded KILL escalation and are reaped.
Cleanup removes only the original socket and empty original directory; unknown
files and replacement sockets are preserved. References retain values only and
are not clients owned by the Server. A stopped owned daemon invalidates them.

Configuration factories perform one explicit identity observation. The returned
facades retain endpoint and incarnation values, and each subsequent configuration
operation owns its temporary command client. C<open-control> and C<attach> return
separate lifecycle owners: callers must close them. Closing a borrowed Server
does not close those owners; closing an owned daemon causes its attached clients
to disconnect. C<attach> proves process creation, not terminal readiness.

C<command> is an explicit tmux-syntax escape hatch with a daemon fence. It does
not insert an entity target or interpret shell syntax on the caller's behalf.
C<run-batch> reports partial outcomes and never promises rollback.

=head1 Explicit environment and health

C<from-env> is the only factory that interprets C<TMUX>. It parses its final
PID and session components from the right, so commas in the socket path remain
literal. It requires an absolute socket path, validates C<TMUX_PANE> when
present, observes the actual daemon and rejects a different PID. The returned
borrowed facade is bound to that incarnation. Child processes still receive
neither ambient variable. Imported object IDs are observations from the supplied
environment, not evidence that those objects still exist:

    use LibTmux;
    my $server = LibTmux::Server.from-env(:environment(%*ENV));
    LEAVE $server.close;
    my $snapshot = $server.snapshot;
    my $pane = $snapshot.panes.where(%(id => $server.environment-pane-id)).single;
    my $window = $pane.window;
    my $session = $snapshot.sessions
        .where(%(id => $server.environment-session-id)).single;

The selection throws for a vanished object or absent imported ID. A window can
belong to several sessions; the imported session ID supplies that context.
C<capabilities> is the explicit native health observation: success returns
verified daemon evidence, while connection, identity and permission failures
retain their original typed exceptions. C<has-session(:name)> and
C<has-session(:id)> return false only after a successful exact listing finds
no match. C<kill-server> deliberately terminates the observed daemon, including
a borrowed one; C<close> continues to preserve borrowed daemons. An owner must
still close after kill-server to join its process and filesystem cleanup.

=head1 Jobs and channels

C<run-shell> receives literal shell source; tmux FORMAT-looking text is escaped
before dispatch. C<if-shell> follows the same rule for its shell condition and
accepts bounded Invocation values for both branches. Its explicit C<:format>
option instead evaluates a native tmux FORMAT condition. C<source-file> reads
one literal pathname, escaping native glob metacharacters; it does not expand
FORMAT, tilde or a caller shell. Relative paths use the captured command cwd.
C<:parse-only> parses configuration without executing it.

Each request shares one admission, observation and dispatch deadline. A
background job acknowledges scheduling. Foreground completion follows tmux's
job/command queue contract, not an application-specific postcondition; command
output availability also depends on the declared daemon profile. Timing out or
cancelling a client does not undo a job, configuration effect or channel lock
already accepted by the daemon. C<wait-for> offers only wait, signal, lock and
unlock; it does not claim that a signal proves another process's application
work completed.

=head1 Administrative commands

Diagnostics and administrative commands intentionally use the explicit bounded
Invocation surface rather than separate wrappers. These complete calls retain
raw stdout/stderr in Result, enforce the server deadline and throw typed command
errors. C<list-commands>, C<show-messages>, C<lock-server> and C<server-access>
are deliberate replacements for named Python helpers, not claims of identical
typed parameters. C<switch-mode> is also available through Invocation.

    use LibTmux;
    my $server = LibTmux::Server.start(:name<inspection>);
    LEAVE $server.close;
    my $commands = $server.command(Invocation.new(:argv(['list-commands'])));
    my $access = $server.command(Invocation.new(:argv(['server-access', '-l'])));
    my $messages = $server.command(Invocation.new(:argv(['show-messages', '-T'])));
    $server.command(Invocation.new(:argv(['lock-server'])));

Administrative flags keep tmux's native semantics and errors; arbitrary
Invocation values do not acquire a typed catalogue guarantee. Locking may run
configured lock commands on attached clients. Access changes affect other users.
Use only an endpoint whose administration the caller owns or has authorized.
To detach captured clients, iterate C<$snapshot.clients> and call each
C<.ref.detach>. Each target is identity guarded; a changing client set is not
an atomic detach-all operation, and acknowledgement does not prove terminal
rendering or child-process exit.
=end pod
