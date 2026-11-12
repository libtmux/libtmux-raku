use v6.d;
unit module Test::LibTmux::Terminal;

use Test::LibTmux::Fixture;

#| An outer-test PTY broker. Python owns its descriptors and blocks on selector events.
class Terminal is export {
    has IO::Handle $.handle;
    has Str $.path;
    has Proc::Async $!broker;
    has Promise $!done;
    has @!taps;
    has Lock $!lock .= new;
    has Str $!output = '';
    has @!waiting;
    has Bool $!closed = False;

    submethod TWEAK() {
        my $program = q:to/PYTHON/;
import fcntl, os, pty, selectors, struct, sys, termios
master, slave = pty.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
os.write(1, os.ttyname(slave).encode() + b'\n')
selector = selectors.DefaultSelector()
selector.register(0, selectors.EVENT_READ)
selector.register(master, selectors.EVENT_READ)
try:
    running = True
    while running:
        for key, _ in selector.select():
            data = os.read(key.fd, 4096)
            if not data:
                running = False
                break
            destination = master if key.fd == 0 else 1
            while data:
                data = data[os.write(destination, data):]
finally:
    selector.close()
    os.close(master)
    os.close(slave)
PYTHON
        $!broker = Proc::Async.new(:w, 'python3', '-u', '-c', $program);
        my $ready = Promise.new;
        my $vow = $ready.vow;
        my $prefix = '';
        @!taps.push($!broker.stdout(:bin).tap(-> Blob:D $bytes {
            my $text = $bytes.decode('utf8-c8');
            $!lock.protect({
                if !$!path.defined {
                    $prefix ~= $text;
                    my $end = $prefix.index("\n");
                    if $end.defined {
                        $!path = $prefix.substr(0, $end);
                        $text = $prefix.substr($end + 1);
                        $vow.keep(True);
                    } else { $text = '' }
                }
                $!output ~= $text;
                $!output = $!output.substr(* - 65536) if $!output.chars > 65536;
                my @remaining;
                for @!waiting -> $entry {
                    if $!output.contains($entry[0]) { $entry[1].keep(True) }
                    else { @remaining.push($entry) }
                }
                @!waiting = @remaining;
            });
        }, :quit(-> $error { $vow.break($error) if $ready.status == Planned })));
        @!taps.push($!broker.stderr(:bin).tap(-> $bytes { note $bytes.decode('utf8-c8') },
            :quit(-> $error { $vow.break($error) if $ready.status == Planned })));
        $!done = $!broker.start;
        my $wait = try await Promise.anyof($ready, $!done, Promise.in(0.9));
        unless $ready.status == Kept {
            self.close;
            die FixtureError.new(:message('PTY broker did not supply a terminal'));
        }
        $!handle = $!path.IO.open(:rw, :bin);
    }

    method when-text(Str:D $text --> Promise:D) {
        $!lock.protect({
            return Promise.kept(True) if $!output.contains($text);
            my $seen = Promise.new;
            @!waiting.push([$text, $seen.vow]);
            $seen
        })
    }

    method send(Str:D $text --> Nil) { await $!broker.write($text.encode('utf8')) }

    method close(--> Nil) {
        return if $!closed;
        $!closed = True;
        $!handle.close if $!handle.defined;
        if $!done.defined {
            try $!broker.close-stdin;
            my $wait = try await Promise.anyof($!done, Promise.in(0.9));
            if $!done.status == Planned {
                $!broker.kill(9);
                $wait = try await Promise.anyof($!done, Promise.in(0.9));
            }
            die FixtureError.new(:message('PTY broker survived cleanup')) if $!done.status == Planned;
            my $reaped = try await $!done;
        }
        .close for @!taps;
    }
}
