use v6.d;

unit module LibTmux::Control;

use LibTmux::Types;
use LibTmux::Exceptions;

sub invalid(Str:D $message --> Nil) {
    X::LibTmux::Command.new(:kind<argument>, :outcome(NotStarted), :$message).throw
}

#| One notification, retaining its original bytes without the record terminator.
class Event is export {
    #| Notification name or unframed-output kind, without assuming a known event schema.
    has Str:D $.kind is required;
    #| Original physical record bytes with the terminating LF removed.
    has Blob:D $.raw is required;
    submethod TWEAK() { $!raw = Blob.new($!raw.list) }
    #| Refuse cloning; retain this value or construct a fresh decoder.
    method clone(|) { invalid('Control events cannot be cloned; retain the immutable value') }
}

#| An unrecognized notification remains inspectable without interpreting its body.
class UnknownEvent is Event is export { }

#| Some queued jobs print after their end guard; preserve that unframed line.
class UnframedOutput is Event is export { }

#| Pane output is terminal bytes, not an independently decodable UTF-8 string.
class PaneOutput is Event is export {
    #| Pane identity from the notification, scoped to its owning connection.
    has PaneId:D $.pane-id is required;
    #| Decoded terminal bytes, which may contain NUL or partial UTF-8 sequences.
    has Blob:D $.data is required;
    #| Extended-output age in milliseconds; undefined for ordinary output events.
    has Count $.age-ms;
    submethod TWEAK() { $!data = Blob.new($!data.list) }
}

#| A matched command guard pair acknowledges execution, not asynchronous effects.
class Response is export {
    #| Guard timestamp in Unix seconds, retained for correlation.
    has Count:D $.time is required;
    #| Command number from the matched begin/end or error guard.
    has Count:D $.number is required;
    #| Native guard flags; these are not an operation-completion guarantee.
    has Count:D $.flags is required;
    #| Whether the matching terminal guard was percent-error.
    has Bool:D $.failed = False;
    #| Response bytes between matching guards, retaining their line separators.
    has Blob:D $.payload = Blob.new;
    submethod TWEAK() { $!payload = Blob.new($!payload.list) }
    #| Refuse cloning; retain this value or construct a fresh decoder.
    method clone(|) { invalid('Control responses cannot be cloned') }
}

sub octal-bytes(Blob:D $encoded, Int:D $offset --> Blob:D) {
    my $decoded = Buf.new;
    my $index = 0;
    while $index < $encoded.elems {
        my $byte = $encoded[$index++];
        if $byte == 92 {
            X::LibTmux::Decode.new(:schema<control-output>, :offset($offset + $index - 1),
                :message('Malformed control output octal escape')).throw
                unless $index + 3 <= $encoded.elems && 48 <= $encoded[$index] <= 51
                    && 48 <= $encoded[$index + 1] <= 55 && 48 <= $encoded[$index + 2] <= 55;
            $decoded.push(($encoded[$index] - 48) * 64
                + ($encoded[$index + 1] - 48) * 8 + $encoded[$index + 2] - 48);
            $index += 3;
        } else {
            X::LibTmux::Decode.new(:schema<control-output>, :offset($offset + $index - 1),
                :message('Unescaped control byte in pane output')).throw if $byte < 32;
            $decoded.push($byte);
        }
    }
    Blob.new($decoded.list)
}

my constant KNOWN = set <client-detached client-session-changed config-error continue exit
    layout-change message pane-mode-changed paste-buffer-changed paste-buffer-deleted pause
    session-changed session-renamed session-window-changed sessions-changed subscription-changed
    unlinked-window-add unlinked-window-close unlinked-window-renamed window-add window-close
    window-pane-changed window-renamed>;

sub notification(Blob:D $line, Int:D $offset --> Event:D) {
    # UTF8-C8 only finds the ASCII header. The retained body never passes through text.
    my $text = $line.decode('utf8-c8');
    my $header = $text.match(/^ '%' $<kind>=[<[a..z]>+ [ '-' <[a..z]>+ ]*] [ ' ' | $ ] /);
    X::LibTmux::Decode.new(:schema<control>, :$offset,
        :message('Expected a control notification or response guard')).throw unless $header;
    my $kind = ~$header<kind>;
    if $kind eq any(<output extended-output>) {
        my $prefix = $kind eq 'output'
            ?? $text.match(/^ '%output ' $<pane>=[ '%' <[0..9]>+ ] ' ' /)
            !! $text.match(/^ '%extended-output ' $<pane>=[ '%' <[0..9]>+ ] ' '
                $<age>=[<[0..9]>+] [ ' ' <-[\x00..\x20:]>+ ]* ' : ' /);
        X::LibTmux::Decode.new(:schema<control-output>, :$offset,
            :message('Malformed pane output header')).throw unless $prefix;
        my $size = (~$prefix).encode('utf8-c8').elems;
        my %age = $kind eq 'extended-output' ?? (age-ms => +$prefix<age>) !! ();
        return PaneOutput.new(:$kind, :raw($line), :pane-id(~$prefix<pane>),
            :data(octal-bytes($line.subbuf($size), $offset + $size)), |%age);
    }
    (KNOWN{$kind} ?? Event !! UnknownEvent).new(:$kind, :raw($line))
}

#| Incremental LF framing with exact response guards and bounded retained data.
class Decoder is export {
    #| Maximum incomplete or complete physical control line length in bytes.
    has Positive:D $.max-line-bytes = 1024 * 1024;
    #| Maximum payload bytes retained inside one response block.
    has Positive:D $.max-response-bytes = 8 * 1024 * 1024;
    #| Maximum bytes accepted in one feed call.
    has Positive:D $.max-chunk-bytes = 8 * 1024 * 1024;
    #| Maximum completed frames emitted by one feed call.
    has Positive:D $.max-frames = 4096;
    has Buf $!line = Buf.new;
    has Buf $!payload = Buf.new;
    has List $!guard;
    has Count $!offset = 0;
    has Count $!line-start = 0;
    has Bool $!closed = False;
    has Bool $!failed = False;

    #| Refuse cloning; retain this value or construct a fresh decoder.
    method clone(|) { invalid('A control decoder cannot be cloned') }
    method !error(Str:D $message --> Nil) {
        $!failed = True;
        X::LibTmux::Decode.new(:schema<control>, :offset($!line-start), :$message).throw
    }
    method !record(Blob:D $line) {
        my $text = $line.decode('utf8-c8');
        my $guard = $text.match(/^ '%' $<kind>=[ 'begin' | 'end' | 'error' ] ' '
            $<time>=[<[0..9]> ** 1..20] ' ' $<number>=[<[0..9]> ** 1..20] ' '
            $<flags>=[<[0..9]> ** 1..20] $/);
        if $!guard.defined {
            if $guard && ~$guard<kind> ne 'begin'
                && (+$guard<time>, +$guard<number>, +$guard<flags>) eqv $!guard {
                my $response = Response.new(:time($!guard[0]), :number($!guard[1]),
                    :flags($!guard[2]), :failed(~$guard<kind> eq 'error'),
                    :payload(Blob.new($!payload.list)));
                $!guard = List;
                $!payload = Buf.new;
                return $response;
            }
            self!error('Control response exceeds its byte limit')
                if $!payload.elems + $line.elems + 1 > $!max-response-bytes;
            $!payload.append($line);
            $!payload.push(10);
            return Nil;
        }
        if $guard {
            self!error('Response ended without a matching begin') unless ~$guard<kind> eq 'begin';
            $!guard = (+$guard<time>, +$guard<number>, +$guard<flags>).List;
            return Nil;
        }
        self!error('Malformed response guard')
            if $text eq any(<%begin %end %error>)
                || $text.starts-with('%begin ') || $text.starts-with('%end ')
                || $text.starts-with('%error ');
        return UnframedOutput.new(:kind<command-output>, :raw($line))
            unless $text.starts-with('%');
        notification($line, $!line-start)
    }

    #| Return complete events/responses in arrival order; partial records stay bounded.
    method feed(Blob:D $chunk --> List:D) {
        self!error('Control decoder is closed or failed') if $!closed || $!failed;
        self!error('Control chunk exceeds its byte limit') if $chunk.elems > $!max-chunk-bytes;
        my @frames;
        try {
            for $chunk.list -> $byte {
                ++$!offset;
                if $byte == 10 {
                    my $frame = self!record(Blob.new($!line.list));
                    @frames.push($frame) if $frame.defined;
                    self!error('Too many frames in one input chunk') if @frames.elems > $!max-frames;
                    $!line = Buf.new;
                    $!line-start = $!offset;
                } else {
                    self!error('Control line exceeds its byte limit')
                        if $!line.elems >= $!max-line-bytes;
                    $!line.push($byte);
                }
            }
            CATCH { default { $!failed = True; .rethrow } }
        }
        @frames.List
    }

    #| EOF is valid only between complete notifications and command blocks.
    method finish(--> Nil) {
        return if $!closed && !$!failed;
        self!error('Control decoder already failed') if $!failed;
        $!closed = True;
        self!error('Truncated control input') if $!line.elems || $!guard.defined;
    }
}

my class Delivery {
    has $.value;
    has Int:D $.bytes = 0;
    #| Notification name or unframed-output kind, without assuming a known event schema.
    has Str:D $.kind = 'event';
}

# Each tap has a bounded queue and one serial worker. User callbacks never run
# on the process reader or another subscriber's worker.
my class Subscriber {
    has Positive:D $.max-events is required;
    has Positive:D $.max-bytes is required;
    has &.emit is required;
    has &.done is required;
    has &.quit is required;
    has &.remove is required;
    has Channel $!queue .= new;
    has Lock $!lock .= new;
    has Int $!events = 0;
    has Int $!bytes = 0;
    has Bool $!closed = False;
    has Bool $!discard = False;
    has Bool $!muted = False;
    has Bool $!finished = False;

    method enqueue(Event:D $event --> Nil) {
        $!lock.protect({
            return if $!closed;
            my $bytes = $event.raw.elems + ($event ~~ PaneOutput ?? $event.data.elems !! 0);
            if $!events >= $!max-events || $!bytes + $bytes > $!max-bytes {
                $!closed = True;
                $!discard = True;
                $!queue.send(Delivery.new(:kind<quit>, :value(X::LibTmux::Command.new(
                    :kind<overflow>, :message('Control event subscriber exceeded its queue limit')))));
            } else {
                ++$!events;
                $!bytes += $bytes;
                $!queue.send(Delivery.new(:value($event), :$bytes));
            }
        });
    }
    method stop(:$error = Exception, Bool :$discard = False --> Nil) {
        $!lock.protect({
            return if $!closed;
            $!closed = True;
            $!discard = $discard;
            $!queue.send(Delivery.new(:kind($error.defined ?? 'quit' !! 'done'), :value($error)));
        });
    }
    method close(--> Nil) {
        $!lock.protect({
            $!muted = True;
            $!discard = True;
            $!closed = True;
            while $!queue.poll.defined { }
            $!events = 0;
            $!bytes = 0;
            $!queue.send(Delivery.new(:kind<done>)) unless $!finished;
        });
        self.remove.();
    }
    method start(--> Nil) {
        my $worker = start {
            LEAVE {
                $!lock.protect({
                    $!finished = True;
                    $!closed = True;
                    while $!queue.poll.defined { }
                    $!events = 0;
                    $!bytes = 0;
                });
                self.remove.();
            }
            loop {
                my $delivery = $!queue.receive;
                my ($discard, $muted) = $!lock.protect({
                    if $delivery.kind eq 'event' && !$!closed {
                        --$!events;
                        $!bytes -= $delivery.bytes;
                    }
                    ($!discard, $!muted)
                });
                my $error;
                try {
                    given $delivery.kind {
                        when 'event' { self.emit.($delivery.value) unless $discard }
                        when 'done' { self.done.() unless $discard }
                        when 'quit' { self.quit.($delivery.value) unless $muted }
                    }
                    CATCH { default { $error = $_ } }
                }
                if $error.defined {
                    self.stop(:error($error), :discard);
                    my $muted-now = $!lock.protect({ $!muted });
                    try self.quit.($error) if $delivery.kind eq 'event' && !$muted-now;
                    last;
                }
                last unless $delivery.kind eq 'event';
            }
        };
    }
}

#| A shared live Supply with bounded, isolated delivery for each subscription.
class EventStream does Tappable is export(:internal) {
    has Positive:D $.max-events = 256;
    has Positive:D $.max-bytes = 1024 * 1024;
    has Lock $!lock .= new;
    has %!subscribers;
    has Int $!next = 0;
    has Bool $!closed = False;
    has Exception $!error;

    method live(--> Bool:D) { True }
    method serial(--> Bool:D) { True }
    method sane(--> Bool:D) { True }
    #| Refuse cloning; retain this value or construct a fresh decoder.
    method clone(|) { invalid('An event stream cannot be cloned') }
    method Supply(--> Supply:D) { Supply.new(self) }
    method tap(&emit, &done, &quit, &tap) {
        my $id;
        my $subscriber;
        $!lock.protect({
            $id = ++$!next;
            $subscriber = Subscriber.new(:$!max-events, :$!max-bytes, :&emit, :&done, :&quit,
                :remove({ $!lock.protect({ %!subscribers{$id}:delete }) }));
            if $!closed { $subscriber.stop(:error($!error)) }
            else { %!subscribers{$id} = $subscriber }
        });
        my $handle = Tap.new({ $subscriber.close });
        try {
            tap($handle);
            CATCH { default { $subscriber.close; .rethrow } }
        }
        $subscriber.start;
        $handle
    }
    method emit(Event:D $event --> Nil) {
        $!lock.protect({ unless $!closed { .enqueue($event) for %!subscribers.values } });
    }
    method finish(Exception :$error = Exception --> Nil) {
        $!lock.protect({
            return if $!closed;
            $!closed = True;
            $!error = $error;
            .stop(:$error) for %!subscribers.values;
            %!subscribers = ();
        });
    }
}

=begin pod
=head1 Control framing and delivery

Decoder frames bytes on LF and correlates all three numeric guard fields.
Notification-shaped lines within a response remain payload. PaneOutput keeps
octal-decoded bytes, including NUL and incomplete UTF-8; text decoding belongs
to a separate incremental consumer. UnknownEvent preserves future notifications.

The tmux wire protocol does not escape arbitrary command payloads from matching
their own terminal guard. Managed reads must use declared, prefixed projections;
raw command output cannot promise lossless framing for guard-shaped payloads.
A Response acknowledges dispatch. Its end guard does not establish completion
of a launched job, popup, detach, or other asynchronous effect.
Some queued jobs print outside response blocks. UnframedOutput preserves such
lines, but the protocol cannot distinguish arbitrary job text from notifications.

Event delivery is live, without replay. A late tap misses earlier events.
Each subscriber has an independently bounded queue and serial worker. A slow
subscriber overflows explicitly; a throwing callback terminates only its own
subscription. Closing a tap discards queued values. Owner completion drains
already accepted values before done; failure drains before quit. User callbacks
already executing cannot be cancelled, and owner teardown does not wait for them.
=end pod
