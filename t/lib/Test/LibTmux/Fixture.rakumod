use v6.d;
unit module Test::LibTmux::Fixture;

use NativeCall;

class FixtureError is Exception is export {
    has Str $.message is required;
}
class FixtureCancelled is FixtureError is export { }

class PollEvent is repr('CStruct') {
    has int32 $.fd is rw;
    has int16 $.events is rw = 1;
    has int16 $.revents is rw;
}
sub mkdtemp(CArray[uint8] --> Pointer) is native { * }
sub pidfd_open(int32, uint32 --> int32) is native { * }
sub pidfd_send_signal(int32, int32, Pointer, uint32 --> int32) is native { * }
sub poll(PollEvent, size_t, int32 --> int32) is native { * }
sub close(int32 --> int32) is native { * }

class Fixture is export {
    has Str $.binary is required;
    has IO::Path $.directory is required;
    has IO::Path $.socket-path is required;
    has Int $.pid = 0;
    has Bool $.exited = False;
    has int32 $!pidfd = -1;
    has Lock $!lock .= new;
    has Str $!state = 'open';
    has %!clients;
    has Promise $!closed .= new;

    method start(--> Nil) {
        my $pid = self.cmd('new-session', '-d', '-P', '-F', '#{pid}',
            '-s', 'fixture', 'exec cat').trim;
        die FixtureError.new(:message('fixture returned an invalid daemon PID'))
            unless $pid ~~ /^ <[0..9]>+ $/ && $pid.Int > 1;
        $!pid = $pid.Int;
        $!pidfd = pidfd_open($!pid, 0);
        die FixtureError.new(:message('Linux pidfd_open failed for owned daemon'))
            if $!pidfd < 0;
    }

    method !run(@arguments, Bool :$during-close = False --> Blob:D) {
        my @argv = $!binary, '-u', '-S', $!socket-path.Str, '-f', '/dev/null',
            |@arguments;
        my $proc = Proc::Async.new(:w, |@argv);
        my $out = Buf.new;
        my $err = Buf.new;
        my $output-lock = Lock.new;
        my Bool $overflow = False;
        my &collect = -> $buffer, Blob:D $chunk {
            $output-lock.protect({
                if $out.elems + $err.elems + $chunk.elems > 1024 * 1024 {
                    $overflow = True;
                    try $proc.kill(9);
                } else {
                    $buffer.append($chunk);
                }
            });
        };
        my $out-tap = $proc.stdout(:bin).tap(-> $chunk { collect($out, $chunk) });
        my $err-tap = $proc.stderr(:bin).tap(-> $chunk { collect($err, $chunk) });
        LEAVE { $out-tap.close; $err-tap.close }
        my %environment = %*ENV;
        %environment<TMUX>:delete;
        %environment<TMUX_PANE>:delete;
        my $key = $proc.WHICH.Str;
        my $done = $!lock.protect({
            die FixtureError.new(:message('fixture is closing or closed'))
                unless $!state eq 'open' || $during-close;
            my $completion = $proc.start(:ENV(%environment));
            $proc.close-stdin;
            %!clients{$key} = [$proc, $completion];
            $completion
        });
        LEAVE $!lock.protect({ %!clients{$key}:delete });
        my $wait-result = try await Promise.anyof($done, Promise.in(3));
        if $done.status == Planned {
            try $proc.kill(9);
            my $wait-result = try await Promise.anyof($done, Promise.in(3));
            die FixtureError.new(:message('owned command did not exit after kill'))
                if $done.status == Planned;
            my $reaped = try await $done;
            die FixtureError.new(:message('owned fixture command timed out'));
        }
        my $result = await $done;
        die FixtureError.new(:message('owned fixture command exceeded output limit'))
            if $overflow;
        die FixtureError.new(:message(
            "owned tmux command failed ({$result.exitcode}): " ~
            $err.decode('utf8-c8')))
            if $result.exitcode != 0;
        Blob.new($out.list)
    }

    method cmd(*@arguments, Bool :$bin = False) {
        my $bytes = self!run(@arguments);
        $bin ?? $bytes !! $bytes.decode('utf8')
    }

    method client-pids(--> List:D) {
        my @pids = $!lock.protect({ %!clients.values.map({ $_[0].pid }).List });
        @pids.grep(*.status == Kept).map(*.result).List
    }

    method close(--> Nil) {
        my Bool $owner = $!lock.protect({
            if $!state eq 'open' { $!state = 'closing'; True } else { False }
        });
        unless $owner { await $!closed; return }
        my @failures;
        my &attempt = -> &release {
            try {
                my $released = release();
                CATCH { default { @failures.push($_) } }
            }
        };
        my @clients = $!lock.protect({ %!clients.values.List });
        for @clients -> $client {
            attempt({ $client[0].kill(9) }) if $client[1].status == Planned;
        }
        for @clients -> $client {
            attempt({
                my $wait-result = try await Promise.anyof($client[1], Promise.in(3));
                die FixtureError.new(:message('owned client survived cleanup'))
                    if $client[1].status == Planned;
                my $reaped = try await $client[1];
            });
        }
        # A failed client release must not prevent the independent daemon cleanup.
        my $stopped = try self!run(['kill-server'], :during-close);
        attempt({
            if $!pidfd >= 0 {
                my $event = PollEvent.new(:fd($!pidfd));
                unless poll($event, 1, 1000) == 1 && $event.revents +& 1 {
                    pidfd_send_signal($!pidfd, 9, Pointer, 0);
                    die FixtureError.new(:message('owned daemon survived cleanup'))
                        unless poll($event, 1, 1000) == 1 && $event.revents +& 1;
                }
                $!exited = True;
            }
        });
        if $!pidfd >= 0 {
            close($!pidfd);
            $!pidfd = -1;
        }
        attempt({ $!socket-path.unlink if $!socket-path.e });
        attempt({ $!directory.rmdir });
        $!lock.protect({ $!state = 'closed' });
        if @failures {
            $!closed.break(@failures[0]);
            die @failures[0];
        }
        $!closed.keep(True);
    }
}

sub make-fixture(--> Fixture:D) {
    my $binary = %*ENV<LIBTMUX_TMUX> // '';
    die FixtureError.new(:message('LIBTMUX_TMUX must name the live-test tmux executable'))
        unless $binary.chars && $binary.IO.f && $binary.IO.x;
    my $template = $*TMPDIR.add('libtmux-raku-XXXXXX').Str.encode('utf8');
    my $bytes = CArray[uint8].new(|$template.list, 0);
    die FixtureError.new(:message('could not create owned fixture directory'))
        unless mkdtemp($bytes);
    my $directory = Blob.new((^$template.elems).map({ $bytes[$_] })).decode('utf8').IO;
    my $fixture = Fixture.new(:$binary, :$directory,
        :socket-path($directory.add('socket')));
    try {
        $fixture.start;
        CATCH { default { my $failure = $_; try $fixture.close; die $failure } }
    }
    $fixture
}

sub with-tmux(&body, Promise :$cancel) is export {
    die FixtureCancelled.new(:message('owned fixture cancelled before setup'))
        if $cancel.defined && $cancel.status != Planned;
    my $fixture = make-fixture;
    my $result;
    my $failure;
    try {
        if $cancel.defined {
            die FixtureCancelled.new(:message('owned fixture cancelled during setup'))
                if $cancel.status != Planned;
            my $running = start {
                my $value = body($fixture);
                $value ~~ Promise ?? (await $value) !! $value
            };
            my $wait-result = try await Promise.anyof($running, $cancel);
            die FixtureCancelled.new(:message('owned fixture cancelled'))
                if $cancel.status != Planned;
            $result = await $running;
        } else {
            $result = body($fixture);
            $result = await $result if $result ~~ Promise;
        }
        $result.exception.throw if $result ~~ Failure;
        CATCH { default { $failure = $_ } }
    }
    my $cleanup-failure;
    try {
        $fixture.close;
        CATCH { default { $cleanup-failure = $_ } }
    }
    die $failure if $failure.defined;
    die $cleanup-failure if $cleanup-failure.defined;
    $result
}
