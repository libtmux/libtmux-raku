use v6.d;
unit module Test::LibTmux::Terminal;

use NativeCall;
use Test::LibTmux::Fixture;

sub posix_openpt(int32 --> int32) is native { * }
sub grantpt(int32 --> int32) is native { * }
sub unlockpt(int32 --> int32) is native { * }
sub ptsname(int32 --> Str) is native { * }
sub eventfd(uint32, int32 --> int32) is native { * }
sub pty-ioctl(int32, ulong, CArray[uint16] --> int32) is native is symbol('ioctl') { * }
# `poll` takes struct pollfd entries: int fd, then short events and short revents.
# Two int32 per entry carry those layouts on the little-endian Linux targets.
sub pty-poll(CArray[int32], ulong, int32 --> int32) is native is symbol('poll') { * }
sub pty-read(int32, CArray[uint8], size_t --> ssize_t) is native is symbol('read') { * }
sub pty-write(int32, CArray[uint8], size_t --> ssize_t) is native is symbol('write') { * }
sub pty-close(int32 --> int32) is native is symbol('close') { * }

constant O_RDWR = 2;
constant O_NOCTTY = 0o400;
constant TIOCSWINSZ = 0x5414;
constant POLLIN = 1;
# Entries of the poll set built in `pump`.
constant MASTER-ENTRY = 0;
constant WAKE-ENTRY = 1;

#| The `revents` field of a poll entry: the high half of its second int32.
sub revents(CArray[int32] $fds, Int:D $entry --> Int:D) { $fds[2 * $entry + 1] +> 16 }

# The constants and the pollfd layout above are those of Linux on a
# little-endian CPU. Refuse anywhere else rather than misread descriptors.
BEGIN {
    my $little-endian = buf8.new(1, 0).read-uint16(0, NativeEndian) == 1;
    die 'Test::LibTmux::Terminal needs Linux on a little-endian CPU'
        unless $*KERNEL.name eq 'linux' && $little-endian;
}

#| An outer-test PTY. The test owns the master descriptor, and a reader thread
#| blocks in poll(2) until output arrives or `close` wakes it.
class Terminal is export {
    has IO::Handle $.handle;
    has Str $.path;
    has int32 $!master = -1;
    has int32 $!wake = -1;
    has Thread $!reader;
    has Lock $!lock .= new;
    has Str $!output = '';
    has @!waiting;
    has Bool $!closed = False;

    submethod TWEAK() {
        try {
            $!master = posix_openpt(O_RDWR +| O_NOCTTY);
            die FixtureError.new(:message('posix_openpt failed')) if $!master < 0;
            die FixtureError.new(:message('grantpt or unlockpt failed'))
                if grantpt($!master) || unlockpt($!master);
            $!path = ptsname($!master) // die FixtureError.new(:message('ptsname failed'));
            my $size = CArray[uint16].new(24, 80, 0, 0);
            die FixtureError.new(:message('could not set the terminal size'))
                if pty-ioctl($!master, TIOCSWINSZ, $size);
            $!wake = eventfd(0, 0);
            die FixtureError.new(:message('eventfd failed')) if $!wake < 0;
            $!handle = $!path.IO.open(:rw, :bin);
            $!reader = Thread.start({ self!pump }, :app_lifetime);
            CATCH { default { my $failure = $_; try self.close; die $failure } }
        }
    }

    method !pump(--> Nil) {
        my $fds = CArray[int32].new($!master, POLLIN, $!wake, POLLIN);
        my $buffer = CArray[uint8].new(0 xx 4096);
        my $failures = 0;
        loop {
            if pty-poll($fds, 2, -1) < 0 {
                # A signal interrupts poll; give up only on a persistent error.
                last if ++$failures > 100;
                next;
            }
            $failures = 0;
            last if revents($fds, WAKE-ENTRY);
            next unless revents($fds, MASTER-ENTRY);
            my $count = pty-read($!master, $buffer, 4096);
            last if $count <= 0;
            self!received(Blob.new((^$count).map({ $buffer[$_] })));
        }
    }

    method !received(Blob:D $bytes --> Nil) {
        my $text = $bytes.decode('utf8-c8');
        $!lock.protect({
            $!output ~= $text;
            $!output = $!output.substr(* - 65536) if $!output.chars > 65536;
            my @remaining;
            for @!waiting -> $entry {
                if $!output.contains($entry[0]) { $entry[1].keep(True) }
                else { @remaining.push($entry) }
            }
            @!waiting = @remaining;
        });
    }

    method when-text(Str:D $text --> Promise:D) {
        $!lock.protect({
            return Promise.kept(True) if $!output.contains($text);
            my $seen = Promise.new;
            @!waiting.push([$text, $seen.vow]);
            $seen
        })
    }

    method send(Str:D $text --> Nil) {
        my @remaining = $text.encode('utf8').list;
        while @remaining {
            my $count = pty-write($!master, CArray[uint8].new(@remaining), @remaining.elems);
            die FixtureError.new(:message('could not write to the terminal')) if $count < 0;
            @remaining = @remaining.skip($count);
        }
    }

    method close(--> Nil) {
        return if $!closed;
        $!closed = True;
        $!handle.close if $!handle.defined;
        if $!reader.defined {
            # An eventfd takes an 8-byte counter. Without the wake the reader
            # would block in poll forever, so a failed write must not reach `finish`.
            die FixtureError.new(:message('could not wake the terminal reader'))
                unless pty-write($!wake, CArray[uint8].new(1, 0, 0, 0, 0, 0, 0, 0), 8) == 8;
            $!reader.finish;
        }
        pty-close($!master) if $!master >= 0;
        pty-close($!wake) if $!wake >= 0;
        $!master = $!wake = -1;
    }
}
