use v6.d;

#| Private native process lease. Load through the Program facade.
unit module LibTmux::Program::Owner;

use LibTmux::Engine :internals;
use NativeCall;
use JSON::Fast;

class PollEvent is repr('CStruct') {
    has int32 $.fd is rw;
    has int16 $.events is rw = 1;
    has int16 $.revents is rw;
}
sub mkdtemp(CArray[uint8] --> Pointer) is native { * }
sub mkfifo(Str, uint32 --> int32) is native { * }
sub native-open(Str, int32 --> int32) is native is symbol('open') { * }
sub pidfd_open(int32, uint32 --> int32) is native { * }
sub pidfd_send_signal(int32, int32, Pointer, uint32 --> int32) is native { * }
sub poll(PollEvent, size_t, int32 --> int32) is native { * }
sub native-close(int32 --> int32) is native is symbol('close') { * }
sub errno-location(--> CArray[int32]) is native is symbol('__errno_location') { * }
sub native-signal(int32, Pointer --> Pointer) is native is symbol('signal') { * }
sub native-read(int32, CArray[uint8], size_t --> ssize_t) is native is symbol('read') { * }
sub native-chdir(CArray[uint8] --> int32) is native is symbol('chdir') { * }
sub execvp(CArray[uint8], CArray[Pointer] --> int32) is native { * }
sub native-setenv(CArray[uint8], CArray[uint8], int32 --> int32)
    is native is symbol('setenv') { * }

#| Enter one isolated watchdog or gated bootstrap process.
sub run-owner(*@arguments --> Nil) is export(:internals) {
    my int32 $daemon-fd = -1;
    LEAVE native-close($daemon-fd) if $daemon-fd >= 0;
    if (@arguments[0] // '') eq '--bootstrap' {
        my ($mode, $path, $token, $cwd, $environment-count, *@argv) = @arguments;
        sub startup-failed(Int:D $status, Str:D $stage --> Nil) {
            my $error = errno-location()[0].Int;
            my $record = $path.IO.parent.add('startup-error');
            $record.spurt(to-json(%(:$token, :$stage, :$error), :!pretty));
            $record.chmod(0o600);
            exit $status;
        }
        exit 125 unless $environment-count ~~ /^ <[0..9]>+ $/
            && $environment-count.Int <= 256 && @argv.elems > 2 * $environment-count.Int;
        my @environment = @argv.splice(0, 2 * $environment-count.Int);
        my $fd = native-open($path, 0o4000 +| 0o2000000 +| 0o400000);
        exit 125 if $fd < 0;
        my $pending = $path.IO.parent.add('bootstrap-ready.tmp');
        $pending.spurt(to-json(%(:$token, pid => $*PID), :!pretty));
        $pending.chmod(0o600);
        $pending.rename($path.IO.parent.add('bootstrap-ready'));
        my $bytes = CArray[uint8].new; $bytes[63] = 0;
        my $message = Buf.new;
        loop {
            my $count = native-read($fd, $bytes, 64);
            if $count > 0 {
                $message.append((^$count).map({ $bytes[$_] }));
                exit 125 if $message.elems > 64;
                last if $message.list.first(* == 10).defined;
            } elsif $count == 0 { exit 125 }
            else {
                my $error = errno-location()[0];
                next if $error == 4;
                exit 125 unless $error == 11;
            }
            my $event = PollEvent.new(:$fd);
            my $ready = poll($event, 1, -1);
            exit 125 if $ready < 0 && errno-location()[0] != 4;
        }
        native-close($fd);
        exit 125 unless $message.decode('utf8') eq $token ~ "\n";
        startup-failed(126, 'directory')
            if native-chdir(CArray[uint8].new(|$cwd.encode('utf8-c8').list, 0)) != 0;
        for @environment.rotor(2) -> @entry {
            startup-failed(126, 'environment') if native-setenv(
                CArray[uint8].new(|@entry[0].encode('utf8-c8').list, 0),
                CArray[uint8].new(|@entry[1].encode('utf8-c8').list, 0), 1) != 0;
        }
        my @storage = @argv.map({ CArray[uint8].new(|.encode('utf8-c8').list, 0) });
        my $arguments = CArray[Pointer].new(|@storage.map({ nativecast(Pointer, $_) }), Pointer);
        execvp(@storage[0], $arguments);
        startup-failed(127, 'exec');
    }

    die 'Unexpected owner mode arguments' if @arguments;

    native-signal(13, Pointer.new(1));
    $*OUT.out-buffer = False;
    my $line = $*IN.get;
    exit 2 unless $line.defined && $line.encode.elems <= 65536;
    my %settings = from-json($line);
    die 'Missing daemon identity' unless %settings<daemon> ~~ Associative:D;
    my %daemon = %settings<daemon>.Hash;
    $daemon-fd = pidfd_open(%daemon<pid>.Int, 0);
    die 'Cannot retain observed daemon' if $daemon-fd < 0;
    my $identity = process-evidence(%daemon<pid>.Int);
    die 'Daemon identity changed during handoff'
        unless $identity<boot-id> eq %daemon<boot-id>
            && $identity<start-ticks> == %daemon<start-ticks>
            && pidfd_send_signal($daemon-fd, 0, Pointer, 0) == 0;
    my $template = (%settings<root> // $*TMPDIR.Str).IO.add('libtmux-program-XXXXXX').Str.encode('utf8-c8');
    my $bytes = CArray[uint8].new(|$template.list, 0);
    die 'Cannot create program directory' unless mkdtemp($bytes);
    my $directory = Blob.new((^$template.elems).map({ $bytes[$_] })).decode('utf8-c8').IO;
    my $directory-inode = $directory.inode;
    my $directory-device = $directory.dev;
    my $gate = $directory.add('gate');
    die 'Cannot create program gate' if mkfifo($gate.Str, 0o600) != 0;
    my $gate-inode = $gate.inode;
    my $gate-device = $gate.dev;
    my $gate-owner = native-open($gate.Str, 2 +| 0o4000 +| 0o2000000);
    die 'Cannot retain program gate' if $gate-owner < 0;
    my int32 $group = -1;
    my Proc::Async $observer;
    my Promise $observed;
    my @taps;
    my $lock = Lock.new;
    my $failed = False;
    my $root-watcher;
    my %watchers;
    my %cleanup;
    my Bool $may-have-pane = False;
    my Bool $gate-closed = False;
    my Bool $group-gone = False;
    my Bool $pane-cleaned = False;
    my Bool $removed = False;
    my Promise $finishing;
    my $finish-lock = Lock.new;
    my $dispatch-lock = Lock.new;
    my %responders;
    my $stop-lock = Lock.new;
    my Promise $stopped;
    my $signals-sent = False;

    sub report(%data) {
        my $line = to-json(%data, :!pretty);
        # The lifetime pipe, rather than reply delivery, owns cleanup after VM loss.
        try $lock.protect({ say $line });
    }
    sub signal-group(Int:D $signal --> Nil) {
        return if $group < 0;
        if pidfd_send_signal($group, $signal, Pointer, 4) != 0 {
            die 'Cannot signal owned process group' unless errno-location()[0] == 3;
        }
    }
    sub group-empty(--> Bool:D) {
        return True if $group < 0;
        return False if pidfd_send_signal($group, 0, Pointer, 4) == 0;
        die 'Cannot observe owned process group' unless errno-location()[0] == 3;
        True
    }
    sub terminate-group(--> Promise:D) {
        $stop-lock.protect({
            if !$stopped.defined || $stopped.status == Broken {
                $stopped = start {
                    unless group-empty() {
                        unless $signals-sent {
                            signal-group(15);
                            await Promise.in(0.2);
                            $signals-sent = True;
                        }
                        signal-group(9);
                        await $root-watcher if $root-watcher.defined;
                        my $deadline = now + 0.5;
                        until group-empty() {
                            die 'Owned process group remains nonempty' if now >= $deadline;
                            # Linux has no group-empty readiness event. Yield while rechecking
                            # the retained group; never reacquire a numeric process group.
                            await Promise.in(0.01);
                        }
                    }
                    True
                };
            }
            $stopped
        })
    }
    sub cleanup-command(@argv --> Map:D) {
        my $process = Proc::Async.new(:w, |@argv);
        my $size = 0;
        my $overflow = False;
        my $output = Buf.new;
        my $errors = Buf.new;
        my $output-lock = Lock.new;
        my &collect = -> $buffer, $chunk {
            $output-lock.protect({
                $size += $chunk.elems;
                if $size > 4096 { $overflow = True; try $process.kill(9) }
                else { $buffer.append($chunk) }
            });
        };
        my @watch = ($process.stdout(:bin).tap(-> $chunk { collect($output, $chunk) }),
            $process.stderr(:bin).tap(-> $chunk { collect($errors, $chunk) }));
        LEAVE .close for @watch;
        my $done = $process.start;
        $process.close-stdin;
        my $settled = await Promise.anyof($done, Promise.in(0.5));
        if $done.status == Planned {
            try $process.kill(9);
            my $reaped = await $done;
            return %(success => False, timeout => True).Map;
        }
        my $result = await $done;
        %(success => so (!$overflow && $result.exitcode == 0 && !$result.signal),
            :$overflow, timeout => False, exitcode => $result.exitcode,
            signal => $result.signal, stdout => Blob.new($output.list),
            stderr => Blob.new($errors.list)).Map
    }

    sub watch(%request --> Nil) {
        for %watchers.keys -> $key {
            if %watchers{$key}<done>.status != Planned {
                .close for %watchers{$key}<taps>.list;
                %watchers{$key}:delete;
            }
        }
        die 'Too many retained generation observers' if %watchers.elems >= 3;
        my $process = Proc::Async.new(:w, |%request<argv>);
        my $size = 0;
        my @taps = $process.stdout(:bin).tap(-> $chunk {
            $size += $chunk.elems;
            try $process.kill(9) if $size > 4096;
        }), $process.stderr(:bin).tap(-> $chunk {
            $size += $chunk.elems;
            try $process.kill(9) if $size > 4096;
        });
        my $done = $process.start;
        $process.close-stdin;
        my $pid = await $process.pid;
        %watchers{%request<id>} = %(process => $process, :$done, :$pid, taps => @taps.List);
        report(%(kind => 'watched', id => %request<id>, :$pid));
    }

    sub retire(Int:D $pid --> Nil) {
        my $key = %watchers.keys.first({ %watchers{$_}<pid> == $pid });
        return unless $key.defined;
        my $entry = %watchers{$key};
        my $settled = await Promise.anyof($entry<done>, Promise.in(0.5));
        die 'Consumed observer did not retire' if $entry<done>.status == Planned;
        my $result = await $entry<done>;
        die 'Consumed event client failed' if $result.exitcode || $result.signal;
        .close for $entry<taps>.list;
        %watchers{$key}:delete;
    }

    sub daemon-gone(--> Bool:D) {
        my $event = PollEvent.new(:fd($daemon-fd));
        my $ready = poll($event, 1, 0);
        die 'Cannot observe retained daemon' if $ready < 0;
        so ($ready == 1 && $event.revents +& 1)
    }
    sub directory-original(--> Bool:D) {
        so ($directory.e && !$directory.l && $directory.d
            && $directory.inode == $directory-inode && $directory.dev == $directory-device)
    }
    sub close-gate(--> Nil) {
        return if $gate-closed;
        LEAVE {
            native-close($gate-owner) if $gate-owner >= 0;
            $gate-owner = -1;
            $gate-closed = True;
        }
        die 'Program lease directory was replaced' unless directory-original();
        if $gate.e || $gate.l {
            die 'Program gate was replaced' if $gate.l
                || $gate.inode != $gate-inode || $gate.dev != $gate-device;
            $gate.unlink;
        }
    }
    sub await-bootstrap-exit(--> Nil) {
        return if $group >= 0 || !(%cleanup<pid> // 0);
        # This read-only watch proves exit after deletion; it never signals a PID.
        # Reuse can make the proof conservative, but cannot make the old PID live.
        my $fd = pidfd_open(%cleanup<pid>.Int, 0);
        return if $fd < 0 && errno-location()[0] == 3;
        die 'Cannot observe cancelled bootstrap exit' if $fd < 0;
        LEAVE native-close($fd) if $fd.defined && $fd >= 0;
        my $event = PollEvent.new(:$fd);
        die 'Cancelled bootstrap has not exited'
            unless poll($event, 1, 500) == 1 && $event.revents +& 1;
    }
    sub remove-pane(--> Bool:D) {
        return False if !$may-have-pane || daemon-gone();
        die 'Startup pane identity is unavailable; recovery owner is retained'
            unless (%cleanup<pane> // '').chars;
        my $result = cleanup-command(%cleanup<argv>.List);
        return True if $result<success>;
        return False if daemon-gone();
        my $probe = cleanup-command(%cleanup<probe>.List);
        die 'Cannot confirm original pane cleanup' unless $probe<success>;
        return False unless $probe<stdout>.decode('utf8-c8').lines
            .first(* eq %cleanup<pane>).defined;
        my $refused = !($result<timeout> // False) && !($result<overflow> // False)
            && $result<exitcode> == 1 && !$result<signal>
            && %cleanup<refusals>.first(* eq $result<stderr>.decode('utf8-c8')).defined;
        if $refused {
            return False if $group >= 0;
            my $current = cleanup-command(%cleanup<inspect>.List);
            if $current<success> {
                my @identity = $current<stdout>.decode('utf8-c8').lines[0].split('|');
                return False if @identity.elems == 2 && @identity[0] eq %cleanup<pane>
                    && @identity[1] ~~ /^ <[0..9]>+ $/
                    && @identity[1].Int != %cleanup<pid>;
            }
        }
        die 'Original pane deletion was not confirmed; recovery owner is retained';
    }
    sub release-clients(--> Nil) {
        my @failures;
        for %watchers.keys -> $key {
            my $entry = %watchers{$key};
            try {
                try $entry<process>.kill(9) if $entry<done>.status == Planned;
                my $settled = await Promise.anyof($entry<done>, Promise.in(0.5));
                die 'Generation client did not exit' if $entry<done>.status == Planned;
                my $reaped = await $entry<done>;
                .close for $entry<taps>.list;
                %watchers{$key}:delete;
                CATCH { default { @failures.push($_) } }
            }
        }
        if $observer.defined && $observed.defined {
            try {
                try $observer.kill(9) if $observed.status == Planned;
                my $settled = await Promise.anyof($observed, Promise.in(0.5));
                die 'Exit client did not exit' if $observed.status == Planned;
                my $reaped = await $observed;
                .close for @taps;
                @taps = ();
                CATCH { default { @failures.push($_) } }
            }
        }
        die @failures[0] if @failures;
    }
    sub finish-owner(--> Promise:D) {
        $finish-lock.protect({
            if !$finishing.defined || $finishing.status == Broken {
                $finishing = start {
                    close-gate();
                    await terminate-group();
                    $group-gone = True;
                    unless $pane-cleaned {
                        $removed = remove-pane();
                        await-bootstrap-exit();
                        $pane-cleaned = True;
                    }
                    release-clients();
                    await $root-watcher if $root-watcher.defined;
                    native-close($group) if $group >= 0;
                    $group = -1;
                    die 'Program lease directory was replaced' unless directory-original();
                    for <startup-error bootstrap-ready bootstrap-ready.tmp> -> $name {
                        my $record = $directory.add($name);
                        if $record.e || $record.l {
                            die 'Program bootstrap report was replaced' if $record.l || !$record.f;
                            my $handle = $record.open(:r, :bin);
                            my $bytes = $handle.read(513); $handle.close;
                            die 'Invalid program bootstrap report' if $bytes.elems > 512;
                            my %report = from-json($bytes.decode('utf8'));
                            die 'Program bootstrap report has another owner'
                                unless %report<token> eq %settings<token>;
                            $record.unlink;
                        }
                    }
                    $directory.rmdir;
                    True
                };
            }
            $finishing
        })
    }
    sub respond(Str:D $kind, Str:D $id, Promise:D $pending --> Nil) {
        my $accepted = $dispatch-lock.protect({
            if %responders{$kind} { False }
            else { %responders{$kind} = True; True }
        });
        unless $accepted {
            report(%(kind => 'termination-error', :$id,
                message => 'Owned cleanup is still pending'));
            return;
        }
        start {
            my Exception $error;
            try {
                await $pending;
                CATCH { default { $error = $_ } }
            }
            $dispatch-lock.protect({ %responders{$kind}:delete });
            $error.defined
                ?? report(%(kind => 'termination-error', :$id, message => $error.message))
                !! report(%(kind => 'ack', :$id));
        };
    }

    report(%(kind => 'ready', directory => $directory.Str,
        gate-inode => $gate-inode, gate-device => $gate-device));
    try {
        while (my $command = $*IN.get).defined {
            die 'Oversized owner command' if $command.encode.elems > 65536;
            my %request = from-json($command);
            if %request<kind> eq 'watch' {
                if $gate-closed {
                    report(%(kind => 'termination-error', id => %request<id>,
                        message => 'Program cleanup has started'));
                } else { watch(%request) }
                next;
            }
            if %request<kind> eq 'status' {
                my $entry = %watchers.values.first({ .<pid> == %request<pid> });
                report(%(kind => 'ack', id => %request<id>,
                    value => so ($entry.defined && $entry<done>.status == Planned)));
                next;
            }
            if %request<kind> eq 'retire' {
                retire(%request<pid>.Int);
                report(%(kind => 'ack', id => %request<id>));
                next;
            }
            if %request<kind> eq 'terminate' {
                respond('terminate', %request<id>, terminate-group());
                next;
            }
            if %request<kind> eq 'cleanup' {
                %cleanup = %request<command>.Hash;
                report(%(kind => 'ack', id => %request<id>));
                next;
            }
            if %request<kind> eq 'creating' {
                $may-have-pane = True;
                report(%(kind => 'ack', id => %request<id>));
                next;
            }
            if %request<kind> eq 'finish' {
                $may-have-pane = so %request<created> if $group < 0 && !$pane-cleaned;
                %cleanup = %request<command>.Hash
                    if %request<command>.defined && $group < 0 && !$pane-cleaned;
                respond('finish', %request<id>, finish-owner());
                next;
            }
            die 'Unexpected owner request'
                unless %request<kind> eq 'arm' && $group < 0 && !$gate-closed;
            try {
                my $pid = %request<pid>.Int;
                my $candidate = pidfd_open($pid, 0);
                die 'Cannot acquire candidate bootstrap pidfd' if $candidate < 0;
                my $accepted = False;
                try {
                    my $environment = "/proc/$pid/environ".IO.slurp(:bin).decode('utf8-c8');
                    die 'Bootstrap ownership nonce changed' unless $environment.split("\0")
                        .first(* eq 'LIBTMUX_PROGRAM_TOKEN=' ~ %request<token>).defined;
                    # The post-read liveness check rules out numeric PID reuse during procfs access.
                    die 'Bootstrap exited during identity handoff'
                        if pidfd_send_signal($candidate, 0, Pointer, 0) != 0;
                    die 'Bootstrap is not a live process-group leader'
                        if pidfd_send_signal($candidate, 0, Pointer, 4) != 0;
                    # Claim the pending tmux generation only after identity validation. A respawn
                    # before acquisition cannot transfer ownership to its replacement process.
                    die 'Bootstrap generation changed'
                        unless cleanup-command(%request<admit>.List)<success>;
                    $accepted = True;
                    CATCH { default { native-close($candidate); .rethrow } }
                }
                die 'Bootstrap ownership was not accepted' unless $accepted;
                $group = $candidate;
                %cleanup = %request<cleanup>.Hash;
                $may-have-pane = True;
                $observer = Proc::Async.new(:w, |%request<observer>);
                my $output = 0;
                @taps = ($observer.stdout(:bin).tap(-> $chunk {
                    $output += $chunk.elems;
                    if $output > 4096 { $failed = True; try $observer.kill(9) }
                }), $observer.stderr(:bin).tap(-> $chunk {
                    $output += $chunk.elems;
                    if $output > 4096 { $failed = True; try $observer.kill(9) }
                }));
                $observed = $observer.start;
                $observer.close-stdin;
                my $observer-pid = await $observer.pid;
                $root-watcher = start {
                    my $event = PollEvent.new(:fd($group));
                    my $ready;
                    repeat { $ready = poll($event, 1, -1) } while $ready < 0;
                    report(%(kind => 'root-exit'));
                };
                start {
                    my $result;
                    try {
                        $result = await $observed;
                        report(%(kind => (!$failed && $result.exitcode == 0 && !$result.signal
                            ?? 'exited' !! 'observer-error')));
                        CATCH { default { report(%(kind => 'observer-error')) } }
                    }
                };
                report(%(kind => 'armed', observer => $observer-pid));
                CATCH { default { report(%(kind => 'arm-error', message => .message)) } }
            }
        }
        CATCH { default { $failed = True; report(%(kind => 'owner-error', message => .message)) } }
    }

    loop {
        my Exception $failure;
        try { await finish-owner(); CATCH { default { $failure = $_ } } }
        unless $failure.defined {
            report(%(kind => 'closed', pane-removed => $removed, group-empty => $group-gone));
            exit 0;
        }
        report(%(kind => 'cleanup-incomplete', message => $failure.message));
        if !$group-gone {
            until group-empty() { await Promise.in(0.1) }
        } elsif !$pane-cleaned && !daemon-gone() {
            # Without a caller or pane authority, retain the lease until this
            # exact daemon exits rather than deleting through a replacement path.
            my $event = PollEvent.new(:fd($daemon-fd));
            my $ready;
            repeat { $ready = poll($event, 1, -1) } while $ready < 0;
        } else {
            report(%(kind => 'cleanup-error', message => $failure.message));
            exit 1;
        }
    }

}
