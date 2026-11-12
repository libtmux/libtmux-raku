use v6.d;

unit module LibTmux::Operations;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Capabilities;
use LibTmux::Engine;
use LibTmux::Command;
use LibTmux::Transport;

sub invalid-argument(Str:D $message --> Nil) is export {
    X::LibTmux::Command.new(:$message, :kind<argument>, :outcome(NotStarted)).throw
}

#| Quote literal data for exactly one tmux FORMAT expansion, including #[style].
sub literal-format(Str:D $text --> Str:D) is export {
    invalid-argument('Literal text cannot contain NUL') if $text.contains("\0");
    $text.subst('#', '#{a:35}', :g)
}

sub operation-capabilities(Incarnation:D $incarnation --> LibTmux::Capabilities:D) is export {
    LibTmux::Capabilities.new(:daemon-version($incarnation.daemon-version),
        :incarnation($incarnation.key))
}

#| Validate an exact stored name before choosing a command's FORMAT policy.
sub operation-name(Str:D $name, Str:D :$domain!, Incarnation:D :$incarnation! --> Str:D) is export {
    invalid-argument('Name domain must be session or window')
        unless $domain eq any(<session window>);
    invalid-argument('Names cannot be empty, contain controls, or contain backslashes')
        unless $name.chars && !$name.contains('\\') && $name !~~ /<:Cc>/;
    my $unicode = try $name.encode('utf8-c8').decode('utf8');
    invalid-argument('Names require valid Unicode') unless $unicode.defined;
    operation-capabilities($incarnation).require("{$domain}-name-separators")
        if $name.contains('.') || $name.contains(':');
    $name
}

#| Run one command with a temporary owner; no subprocess survives successful return.
sub execute-operation(Endpoint:D $endpoint, Incarnation:D $incarnation,
                      Invocation:D $command, Blob:D :$stdin = Blob.new,
                      Bool:D :$check = True --> Result:D) is export {
    my $runtime = Runtime.new(:$endpoint);
    LEAVE $runtime.close if $runtime.defined;
    $runtime.execute($command, :$incarnation, :$stdin, :$check)
}

sub require-same-incarnation($left, $right --> Nil) is export {
    X::LibTmux::StaleReference.new(
        :message('Both command targets must belong to the same daemon incarnation')).throw
        unless $left.endpoint.key eq $right.endpoint.key
            && $left.incarnation.key eq $right.incarnation.key;
}

sub creation-format(Str:D $entity --> Str:D) is export {
    invalid-argument('Creation must return a session, window, or pane identity')
        unless $entity eq any(<session window pane>);
    'LTM1-' ~ $entity ~ '-#{' ~ $entity ~ '_id}'
}

#| Require one complete ASCII identity record; never infer a new object from indices.
sub created-id(Blob:D $output, Str:D $entity --> Str:D) is export {
    my $prefix = 'LTM1-' ~ $entity ~ '-';
    my $text = try $output.decode('ascii');
    my $id = $text.defined && $text.starts-with($prefix) && $text.ends-with("\n")
        ?? $text.substr($prefix.chars, $text.chars - $prefix.chars - 1) !! '';
    my $valid = do given $entity {
        when 'session' { $id ~~ SessionId }
        when 'window' { $id ~~ WindowId }
        when 'pane' { $id ~~ PaneId }
        default { False }
    };
    X::LibTmux::Decode.new(:schema("creation:$entity"),
        :message('Creation did not return exactly one declared identity')).throw unless $valid;
    $id.Str
}

sub split-size(:$size = Positive, :$percent = Positive --> List:D) is export {
    invalid-argument('Specify size or percent, not both') if $size.defined && $percent.defined;
    invalid-argument('Size must be a positive integer') if $size.defined && $size !~~ Positive;
    invalid-argument('Percent must be an integer from 1 through 100')
        if $percent.defined && ($percent !~~ Positive || $percent > 100);
    return ('-l', $size.Str).List if $size.defined;
    # The size form also avoids the split-window -p defect in the declared profiles.
    return ('-l', $percent ~ '%').List if $percent.defined;
    ().List
}

sub spawn-arguments(Str :$directory, Str :$shell-command, Bool :$empty = False,
                    Bool :$empty-flag = False,
                    Associative:D :$environment = Map.new --> List:D) is export {
    invalid-argument('An empty pane cannot also run a shell command')
        if $empty && $shell-command.defined;
    my @arguments;
    @arguments.append('-c', literal-format($directory)) if $directory.defined;
    for $environment.kv -> Mu $name, Mu $value {
        invalid-argument('Child environment names must be nonempty and contain neither equals nor NUL')
            unless $name.^isa(Str) && $name.defined && $name.chars
                && !$name.contains('=') && !$name.contains("\0");
        invalid-argument('Child environment values must be defined strings without NUL')
            unless $value.^isa(Str) && $value.defined && !$value.contains("\0");
        @arguments.append('-e', "$name=$value");
    }
    if $empty && $empty-flag { @arguments.push('-E') }
    elsif $empty || $shell-command.defined {
        @arguments.append('--', $empty ?? '' !! $shell-command);
    }
    @arguments.List
}

sub resize-arguments(:$width = Positive, :$height = Positive, Str :$direction,
                     :$amount = Positive --> List:D) is export {
    invalid-argument('Absolute dimensions and relative direction cannot be combined')
        if ($width.defined || $height.defined) && ($direction.defined || $amount.defined);
    invalid-argument('A relative amount requires a direction') if $amount.defined && !$direction.defined;
    invalid-argument('Specify dimensions or a direction')
        unless $width.defined || $height.defined || $direction.defined;
    for $width, $height, $amount -> $number {
        invalid-argument('Dimensions and adjustment must be positive integers')
            if $number.defined && $number !~~ Positive;
    }
    my @arguments;
    @arguments.append('-x', $width.Str) if $width.defined;
    @arguments.append('-y', $height.Str) if $height.defined;
    if $direction.defined {
        my %directions = left => '-L', right => '-R', up => '-U', down => '-D';
        invalid-argument('Direction must be left, right, up, or down')
            unless %directions{$direction}:exists;
        @arguments.append(%directions{$direction}, ($amount // 1).Str);
    }
    @arguments.List
}

=begin pod
=head1 Command values

This internal module shares command validation and encoding between the public
facades. Literal names and paths are encoded for the specific commands that
expand FORMAT. Shell commands, FORMAT templates, key names and tmux command
lists retain their separately documented syntax. A Result confirms child
completion; it does not assert that a pane program processed input or rendered.
=end pod
