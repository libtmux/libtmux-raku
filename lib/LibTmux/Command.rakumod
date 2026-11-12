use v6.d;

unit module LibTmux::Command;

use LibTmux::Types;
use LibTmux::Exceptions;

sub invalid(Str:D $message --> Nil) {
    X::LibTmux::Command.new(:$message, :kind<argument>, :outcome(NotStarted)).throw
}

# Internal admission for role protos, which must specialize before typed dispatch.
sub admit-operation(Capture:D $capture, :%named = {}, Bool:D :$forwarded = False --> Nil)
        is export(:internals) {
    for $capture.list -> Mu $value {
        invalid('An operation argument must be one value, not a Junction')
            if $value.^isa(Junction);
    }
    for $capture.hash.kv -> $name, Mu $value {
        invalid('An operation argument must be one value, not a Junction')
            if $value.^isa(Junction);
        invalid("Unknown operation argument $name")
            unless $forwarded || (%named{$name}:exists);
    }
}

#| Reject implicit operation fan-out and misspelled settings before native binding.
multi sub trait_mod:<is>(Routine:D $routine, Mu :$single-operation!) is export(:internals) {
    my Bool $async = $single-operation ~~ Str:D && $single-operation eq 'async';
    invalid('single-operation accepts only its default or async mode')
        unless $single-operation === True || $async;
    my $parameters = $routine.signature.params;
    my Bool $forwarded = $parameters.first({ .slurpy && .named && .name ne '%_' }).defined;
    my %named = $parameters.grep(*.named).map(*.named_names).flat.map({ $_ => True });
    $routine.wrap(sub (|capture) {
        my Exception $failure;
        try {
            admit-operation(capture, :%named, :$forwarded);
            CATCH { default { $failure = $_ } }
        }
        if $failure.defined { return $async ?? Promise.broken($failure) !! $failure.throw }
        if $async {
            my $value;
            try { $value = callsame; CATCH { default { $failure = $_ } } }
            return $failure.defined ?? Promise.broken($failure) !! $value;
        }
        callsame
    });
}

sub quote(Str:D $value --> Str:D) {
    my @pieces;
    for $value.encode('utf8-c8').list -> $byte {
        @pieces.push(32 <= $byte <= 126 && $byte != any(34, 92, 36, 126)
            ?? $byte.chr !! '\\' ~ $byte.fmt('%03o'));
    }
    '"' ~ @pieces.join ~ '"'
}

#| One copied tmux command with distinct argv and command-language encodings.
class Invocation is export {
    has List:D $!argv = ().List;
    has Str:D $!source = '';

    submethod BUILD(Mu :$argv!, Mu :$max-bytes = 12 * 1024, *%unknown) {
        invalid('Unknown command setting ' ~ %unknown.keys.sort.join(', ')) if %unknown;
        invalid('Command size limit must be a positive integer')
            if $max-bytes.^isa(Junction) || $max-bytes !~~ Positive:D;
        invalid('A command needs a nonempty argument vector')
            if $argv.^isa(Junction) || $argv !~~ Positional:D || !$argv.elems;
        my @copied;
        for $argv.list -> Mu $argument {
            invalid('Command arguments must be defined strings')
                if $argument.^isa(Junction) || $argument !~~ Str:D;
            invalid('Command arguments cannot contain NUL') if $argument.contains("\0");
            @copied.push($argument.Str);
        }
        invalid('Command name cannot be empty') unless @copied[0].chars;
        $!argv = @copied.map(-> $value { $value }).eager.List;
        $!source = $!argv.map(&quote).join(' ');
        invalid('Encoded command exceeds its byte limit')
            if $!source.encode('utf8-c8').elems > $max-bytes;
    }

    #| Original literal values, detached from the caller's membership containers.
    method argv(--> List:D) { $!argv }

    #| Protect literal final semicolons from tmux's OS-argv command separator.
    method as-argv(--> List:D) {
        $!argv.map({ .ends-with(';') ?? .substr(0, .chars - 1) ~ '\;' !! $_ }).List
    }

    #| A bounded tmux command string, with no shell expansion or Raku evaluation.
    method source(--> Str:D) { $!source }
}

=begin pod
=head1 Interpretation boundaries

Invocation encodes a tmux command, not a shell command or a FORMAT literal.
Double quoting alone does not suppress tmux tilde expansion. Exact octal
escapes preserve quotes, backslashes, dollars, tildes, controls and high bytes.
The encoded size limit applies after expansion and before dispatch.

Engine code inserts command separators deliberately between Invocation values;
literal semicolons inside their argument values remain data. Commands which
interpret FORMAT syntax require an additional command-specific policy.

=head1 Single-operation admission

Effectful entry points use C<is single-operation> to reject Junction arguments
before Raku can autothread a typed method into several operations. Unknown named
arguments are rejected unless the method explicitly forwards a slurpy options
hash; the receiving operation validates those forwarded names. Nested command
operands remain the responsibility of Invocation and the command's validators.
Native signatures, defaults and constraints retain their normal binding rules.
An effectful multi must guard its explicit proto, since candidate dispatch can
autothread before a wrapper on an individual candidate runs.
Role methods use capture admission in the proto body before typed candidate
dispatch. Wrapping an unspecialized role method loses its private-method context
after precompilation on the pinned compiler.

C<is single-operation('async')> returns one broken Promise for rejected input or
a synchronous exception from the method. Junctions and unknown names produce
C<X::LibTmux::Command> with C<kind> argument and C<outcome> NotStarted. Native
binding errors and exceptions from the body retain their types. An accepted
method's Promise passes through unchanged. Portable query validation keeps its
own C<InvalidFilter> policy, while local selections retain native Junction
matching.
=end pod
