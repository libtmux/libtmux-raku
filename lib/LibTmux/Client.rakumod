use v6.d;

#| Explicit client-targeted UI commands and immutable menu/template values.
unit module LibTmux::Client;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Engine;
use LibTmux::Command :DEFAULT, :internals;
use LibTmux::Transport;
use LibTmux::Format;
use LibTmux::Operations;

sub text(Str:D $value --> Str:D) {
    invalid-argument('UI values cannot contain NUL') if $value.contains("\0");
    $value
}

#| Explicit tmux command-template syntax, including percent substitutions.
class CommandTemplate is export {
    #| Unescaped tmux command-template syntax, including native percent placeholders.
    has Str:D $.source is required;
    submethod TWEAK() { text($!source) }
    #| Revalidate replacement source without executing the template.
    method clone(*%changes --> CommandTemplate:D) {
        invalid-argument('Unknown template setting') if %changes.keys.grep(* ne 'source');
        self.WHAT.new(:source(%changes<source>:exists ?? %changes<source> !! $!source))
    }
}

#| A menu entry. Empty labels are separators; labels retain tmux display styles.
class MenuItem is export {
    #| Display text with tmux styles retained; an empty label creates a separator.
    has Str:D $.label is required;
    #| Native tmux key name; empty text leaves the item without a shortcut.
    has Str:D $.key = '';
    #| Command executed on selection; undefined only for a separator.
    has Invocation $.command;
    #| Render an unavailable item whose command cannot be selected.
    has Bool:D $.disabled = False;

    submethod TWEAK() {
        text($!label); text($!key);
        invalid-argument('A nonempty menu entry requires an Invocation')
            if $!label.chars && !$!command.defined;
        invalid-argument('Separators cannot have keys, commands or disabled state')
            if !$!label.chars && ($!key.chars || $!command.defined || $!disabled);
        invalid-argument('Use disabled for a menu label beginning with a minus sign')
            if $!label.starts-with('-') && !$!disabled;
    }

    #| Revalidate a modified entry, including separator and command consistency.
    method clone(*%changes --> MenuItem:D) {
        my %values = label => $!label, key => $!key, command => $!command, disabled => $!disabled;
        for %changes.kv -> $key, $value {
            invalid-argument("Unknown menu setting $key") unless %values{$key}:exists;
            %values{$key} = $value;
        }
        self.WHAT.new(|%values)
    }
}

sub menu-arguments(MenuItem:D $item --> List:D) {
    return ('',).List unless $item.label.chars;
    (($item.disabled && !$item.label.starts-with('-') ?? '-' !! '') ~ literal-format($item.label),
        $item.key, literal-format($item.command.source)).List
}

#| A value-only client target. No subprocess or connection is retained.
class ClientTarget is export {
    #| Socket and executable configuration; no active connection is retained.
    has Endpoint:D $.endpoint is required;
    #| Daemon identity checked before dispatching a client operation.
    has Incarnation:D $.incarnation is required;
    #| Observed client name decoded with utf8-c8 to preserve target bytes.
    has Str:D $.name is required;
    #| Observed client process ID, checked together with name and creation time.
    has Positive:D $.pid is required;
    #| Observed tmux client creation timestamp in Unix seconds.
    has Count:D $.created is required;

    submethod TWEAK() {
        invalid-argument('A client name must be nonempty') unless text($!name).chars;
        X::LibTmux::StaleReference.new(:message('Client endpoint and incarnation disagree')).throw
            unless $!endpoint.key eq $!incarnation.endpoint-key;
    }

    #| Revalidate changed target values; this performs no existence check or I/O.
    method clone(*%changes --> ClientTarget:D) {
        my %values = endpoint => $!endpoint, incarnation => $!incarnation,
            name => $!name, pid => $!pid, created => $!created;
        for %changes.kv -> $key, $value {
            invalid-argument("Unknown client setting $key") unless %values{$key}:exists;
            %values{$key} = $value;
        }
        self.WHAT.new(|%values)
    }

    # cmd_find_client removes one trailing colon before exact name/tty matching.
    method !target(--> Str:D) { $!name ~ ':' }

    method !run(Invocation:D $command, Positive:D :$timeout-ms = 10_000,
                Cancellation :$cancel = Cancellation, PaneId :$pane = PaneId,
                Bool:D :$check = True, Bool:D :$retain-session = False --> Promise:D) is single-operation('async') {
        my $deadline = now + $timeout-ms / 1000;
        start {
            my $runtime = Runtime.new(:endpoint($!endpoint), :$timeout-ms);
            LEAVE $runtime.close if $runtime.defined;
            my $caps = operation-capabilities($!incarnation);
            my $projection = Projection.new(:entity<client>,
                :fields(<name pid created session-id>), :capabilities($caps));
            my @clients = $runtime.read($projection, Invocation.new(:argv(['list-clients'])),
                :incarnation($!incarnation), :$cancel, :$deadline);
            my $name = Blob.new($!name.encode('utf8-c8').list);
            my @matching = @clients.grep({ .bytes('name') eqv $name
                && .value('pid') == $!pid && .value('created') == $!created });
            X::LibTmux::StaleReference.new(:message('Observed client is no longer attached')).throw
                unless @matching.elems == 1;
            if $pane.defined {
                my $panes = Projection.new(:entity<pane>, :fields(['id']), :capabilities($caps));
                my @rows = $runtime.read($panes, Invocation.new(:argv([
                    'list-panes', '-s', '-t', @matching[0].value('session-id'),
                ])), :incarnation($!incarnation), :$cancel, :$deadline);
                X::LibTmux::StaleReference.new(
                    :message('UI pane is absent from the client session')).throw
                    unless @rows.first(*.value('id') eq $pane).defined;
            }
            my $dispatch = $retain-session ?? Invocation.new(:argv([
                |$command.argv, '-t', @matching[0].value('session-id'),
            ])) !! $command;
            $runtime.execute($dispatch, :incarnation($!incarnation), :$cancel, :$deadline, :$check)
        }
    }

    #| Display literal FORMAT/time text; tmux still interprets display styles.
    method display-message(Str:D $message, PaneId:D :$pane!, Count :$duration-ms = Count,
                           Bool:D :$print = False, *%operation --> Result:D) is single-operation {
        my @argv = 'display-message', '-c', self!target, '-t', $pane;
        @argv.append('-d', $duration-ms.Str) if $duration-ms.defined;
        @argv.push('-p') if $print;
        @argv.append('--', literal-format(text($message)).subst('%', '#{a:37}', :g));
        await self!run(Invocation.new(:argv(@argv)), :$pane, |%operation)
    }

    #| Evaluate explicit FORMAT and strftime syntax in an existing pane context.
    method display-format(Str:D $format, PaneId:D :$pane!, Bool:D :$print = True,
                          *%operation --> Result:D) is single-operation {
        my @argv = 'display-message', '-c', self!target, '-t', $pane;
        @argv.push('-p') if $print;
        @argv.append('-F', text($format));
        await self!run(Invocation.new(:argv(@argv)), :$pane, |%operation)
    }

    #| Show a menu. Completion follows tmux's command lifecycle, not rendering proof.
    method menu-async(Positional:D $items, PaneId:D :$pane!, Positive:D :$timeout-ms!,
                      Str:D :$title = '', Str:D :$x = 'C', Str:D :$y = 'C',
                      Bool:D :$stay-open = False, Bool:D :$mouse = False,
                      Str :$style = Str, Str :$border-style = Str,
                      Str :$selected-style = Str, Str :$border-lines = Str,
                      Count :$starting-choice = Count, *%operation --> Promise:D) is single-operation('async') {
        invalid-argument('A menu requires one or more finite entries')
            if $items.iterator.is-lazy;
        my @argv = 'display-menu', '-c', self!target, '-t', $pane,
            '-T', literal-format(text($title)), '-x', text($x), '-y', text($y);
        my $caps = operation-capabilities($!incarnation);
        $caps.require('menu-appearance') if $style.defined || $border-style.defined
            || $selected-style.defined || $border-lines.defined || $starting-choice.defined;
        $caps.require('menu-mouse') if $mouse;
        @argv.append('-s', text($style)) if $style.defined;
        @argv.append('-S', text($border-style)) if $border-style.defined;
        @argv.append('-H', text($selected-style)) if $selected-style.defined;
        @argv.append('-b', text($border-lines)) if $border-lines.defined;
        @argv.append('-C', $starting-choice.Str) if $starting-choice.defined;
        @argv.push('-M') if $mouse;
        @argv.push('-O') if $stay-open;
        @argv.push('--');
        my $count = 0;
        for $items -> $item {
            invalid-argument('A menu accepts at most 256 MenuItem values')
                unless ++$count <= 256 && $item.^isa(MenuItem) && $item.defined;
            @argv.append(menu-arguments($item));
        }
        invalid-argument('A menu requires one or more entries') unless $count;
        self!run(Invocation.new(:argv(@argv)), :$pane, :$timeout-ms, |%operation)
    }

    #| Start an explicitly supplied shell command in a popup; wait asynchronously.
    method popup-async(Str:D :$shell-command!, PaneId:D :$pane!, Positive:D :$timeout-ms!,
                       Str:D :$title = '', Str :$directory = Str,
                       Positive :$width = Positive, Positive :$height = Positive,
                       Str:D :$x = 'C', Str:D :$y = 'C',
                       Str:D :$close = 'exit', Bool:D :$border = True,
                       Bool:D :$close-on-key = False, Bool:D :$reset-flags = False,
                       *%operation --> Promise:D) is single-operation('async') {
        invalid-argument('Popup close must be exit, success or manual')
            unless $close eq any(<exit success manual>);
        my @argv = 'display-popup', '-c', self!target, '-t', $pane,
            '-T', literal-format(text($title)), '-x', text($x), '-y', text($y);
        @argv.append('-w', $width.Str) if $width.defined;
        @argv.append('-h', $height.Str) if $height.defined;
        @argv.append('-d', literal-format(text($directory))) if $directory.defined;
        @argv.push('-B') unless $border;
        my $caps = operation-capabilities($!incarnation);
        if $close-on-key { $caps.require('popup-close-on-key'); @argv.push('-k') }
        if $reset-flags { $caps.require('popup-reset-flags'); @argv.push('-N') }
        @argv.append(('-E') xx ($close eq 'success' ?? 2 !! 1)) unless $close eq 'manual';
        @argv.append('--', text($shell-command));
        self!run(Invocation.new(:argv(@argv)), :$pane, :$timeout-ms, |%operation)
    }

    #| Explicitly remove the current popup/overlay, including one left after timeout.
    method close-popup(*%operation --> Result:D) is single-operation {
        await self!run(Invocation.new(:argv(['display-popup', '-C', '-c', self!target])), |%operation)
    }

    #| Prompt with explicit tmux template syntax. Commas separate prompts and inputs.
    method prompt-async(CommandTemplate:D $template, Positive:D :$timeout-ms!,
                        Str:D :$prompts = ':', Str:D :$inputs = '',
                        Str:D :$mode = 'text', Str:D :$type = 'command',
                        Bool:D :$literal-commas = False,
                        *%operation --> Promise:D) is single-operation('async') {
        my %modes = text => '', single => '-1', numeric => '-N', key => '-k';
        invalid-argument('Prompt mode must be text, single, numeric or key')
            unless %modes{$mode}:exists;
        my @argv = 'command-prompt', '-t', self!target, '-p', literal-format(text($prompts)),
            '-I', literal-format(text($inputs)), '-T', text($type);
        @argv.push(%modes{$mode}) if %modes{$mode}.chars;
        if $literal-commas {
            operation-capabilities($!incarnation).require('prompt-literal-commas');
            @argv.push('-l');
        }
        @argv.append('--', $template.source);
        self!run(Invocation.new(:argv(@argv)), :$timeout-ms, |%operation)
    }

    #| Ask confirmation before one Invocation. A refusal is returned as a Result.
    method confirm-async(Invocation:D $command, Positive:D :$timeout-ms!,
                         Str:D :$prompt = 'Confirm? (y/n)', *%operation --> Promise:D) is single-operation('async') {
        self!run(Invocation.new(:argv(['confirm-before', '-t', self!target,
            '-p', literal-format(text($prompt)), '--', $command.source])),
            :$timeout-ms, :!check, |%operation)
    }

    #| Enter a pane mode shared by every client viewing that pane.
    method choose(Str:D $kind, PaneId:D :$pane!, Str :$format = Str,
                  Str :$filter = Str, Str :$key-format = Str, Str :$sort = Str,
                  Bool:D :$reverse = False, Bool:D :$zoom = False,
                  Bool:D :$preview = True, CommandTemplate :$template = CommandTemplate,
                  *%operation --> Result:D) is single-operation {
        my %commands = tree => 'choose-tree', client => 'choose-client',
            buffer => 'choose-buffer', customize => 'customize-mode';
        invalid-argument('Choose kind must be tree, client, buffer or customize')
            unless %commands{$kind}:exists;
        invalid-argument('Customize mode has no key format, sort or command template')
            if $kind eq 'customize' && ($key-format.defined || $sort.defined || $reverse || $template.defined);
        my @argv = %commands{$kind}, '-t', $pane;
        @argv.append('-F', text($format)) if $format.defined;
        @argv.append('-f', text($filter)) if $filter.defined;
        @argv.append('-K', text($key-format)) if $key-format.defined;
        @argv.append('-O', text($sort)) if $sort.defined;
        @argv.push('-r') if $reverse;
        @argv.push('-Z') if $zoom;
        @argv.push('-N') unless $preview;
        @argv.append('--', $template.source) if $template.defined;
        await self!run(Invocation.new(:argv(@argv)), :$pane, |%operation)
    }

    #| Open the native finder using tmux match/FORMAT syntax, not literal substring data.
    method find-window(Str:D $pattern, PaneId:D :$pane!, Bool:D :$content = True,
                       Bool:D :$names = True, Bool:D :$titles = True,
                       Bool:D :$regex = False, Bool:D :$ignore-case = False,
                       Bool:D :$zoom = False, *%operation --> Result:D) is single-operation {
        invalid-argument('Find-window requires at least one search area')
            unless $content || $names || $titles;
        my @argv = 'find-window', '-t', $pane;
        @argv.push('-C') if $content;
        @argv.push('-N') if $names;
        @argv.push('-T') if $titles;
        @argv.push('-r') if $regex;
        @argv.push('-i') if $ignore-case;
        @argv.push('-Z') if $zoom;
        @argv.append('--', text($pattern));
        await self!run(Invocation.new(:argv(@argv)), :$pane, |%operation)
    }

    #| Display pane numbers, with an optional explicit tmux selection template.
    method display-panes-async(Positive:D :$timeout-ms!, Count :$duration-ms = Count,
                               Bool:D :$select = True,
                               CommandTemplate :$template = CommandTemplate,
                               *%operation --> Promise:D) is single-operation('async') {
        my @argv = 'display-panes', '-t', self!target;
        @argv.append('-d', $duration-ms.Str) if $duration-ms.defined;
        @argv.push('-N') unless $select;
        @argv.append('--', $template.source) if $template.defined;
        self!run(Invocation.new(:argv(@argv)), :$timeout-ms, |%operation)
    }

    #| Refresh the display, status, or viewport using one explicit action.
    method refresh(Str:D :$part = 'all', Positive :$amount = Positive,
                   *%operation --> Result:D) is single-operation {
        my %flags = all => '', status => '-S', reset => '-c',
            left => '-L', right => '-R', up => '-U', down => '-D';
        invalid-argument('Unknown refresh action') unless %flags{$part}:exists;
        invalid-argument('An adjustment requires a viewport direction')
            if $amount.defined && $part ne any(<left right up down>);
        my @argv = 'refresh-client', '-t', self!target;
        @argv.push(%flags{$part}) if %flags{$part}.chars;
        @argv.push($amount.Str) if $amount.defined;
        await self!run(Invocation.new(:argv(@argv)), |%operation)
    }

    #| Request detachment of this exact observed client. Completion is not exit proof.
    method detach(*%operation --> Result:D) is single-operation {
        await self!run(Invocation.new(:argv(['detach-client', '-t', self!target])), |%operation)
    }

    #| Suspend the client's terminal process through tmux.
    method suspend(*%operation --> Result:D) is single-operation {
        await self!run(Invocation.new(:argv(['suspend-client', '-t', self!target])), |%operation)
    }

    #| Invoke the configured lock command for this client.
    method lock(*%operation --> Result:D) is single-operation {
        await self!run(Invocation.new(:argv(['lock-client', '-t', self!target])), |%operation)
    }

    #| Switch session by ID. Updating the session environment is opt-in.
    method switch(SessionId:D $session, Bool:D :$update-environment = False,
                  Bool:D :$keep-zoom = False, *%operation --> Result:D) is single-operation {
        my @argv = 'switch-client', '-c', self!target, '-t', $session;
        @argv.push('-E') unless $update-environment;
        @argv.push('-Z') if $keep-zoom;
        await self!run(Invocation.new(:argv(@argv)), |%operation)
    }

    #| Select an existing key table; its name is passed without FORMAT expansion.
    method key-table(Str:D $table, *%operation --> Result:D) is single-operation {
        invalid-argument('A key table name cannot be empty') unless text($table).chars;
        await self!run(Invocation.new(:argv(['switch-client', '-c', self!target,
            '-T', $table])), |%operation)
    }

    #| Switch relative to this client's current/previous session.
    method switch-relative(Str:D $direction, *%operation --> Result:D) is single-operation {
        my %flags = next => '-n', previous => '-p', last => '-l';
        invalid-argument('Relative session must be next, previous or last')
            unless %flags{$direction}:exists;
        await self!run(Invocation.new(:argv(['switch-client', '-c', self!target,
            '-E', %flags{$direction}])), |%operation)
    }

    #| Toggle read-only and ignore-size flags while retaining the observed session.
    method toggle-read-only(*%operation --> Result:D) is single-operation {
        await self!run(Invocation.new(:argv(['switch-client', '-c', self!target, '-r', '-E', '-Z'])),
            :retain-session, |%operation)
    }

    #| Return raw prompt-history output, without claiming newline-safe entry framing.
    method prompt-history(Str :$type = Str, *%operation --> Blob:D) is single-operation {
        my @argv = 'show-prompt-history';
        @argv.append('-T', text($type)) if $type.defined;
        (await self!run(Invocation.new(:argv(@argv)), |%operation)).stdout
    }

    #| Clear the daemon's selected prompt history; it is shared across clients.
    method clear-prompt-history(Str :$type = Str, *%operation --> Result:D) is single-operation {
        my @argv = 'clear-prompt-history';
        @argv.append('-T', text($type)) if $type.defined;
        await self!run(Invocation.new(:argv(@argv)), |%operation)
    }
}

=begin pod
=head1 Client commands

ClientTarget retains endpoint and daemon identity values only. Each operation
lists clients and checks the observed name, process ID and creation time before
dispatch. tmux exposes no permanent client ID: disconnect and name reuse between
this check and the command remain possible. The daemon fence does not make that
check atomic. A client target never silently selects a current client.
The read-only toggle follows tmux's paired read-only/ignore-size flag behavior;
it retains the observed session and suppresses environment updates.

Pane-context UI methods require an explicit pane belonging to the client's
current session. This avoids display-message's missing-target fallback. Pane
modes are shared by every client viewing that pane, not private UI state.

Menu, prompt, popup and pane-number methods return Promises and require an
explicit timeout in milliseconds. Human interaction may outlast that budget.
Cancellation or timeout stops the command client; it does not retract an overlay
or command already submitted. Use close-popup explicitly when appropriate.
Results describe command completion, not rendered pixels or a human response.

Literal messages disable FORMAT and strftime interpolation. tmux display styles
still apply. Menu labels retain display styles and leading-minus disabled-entry
semantics. CommandTemplate deliberately exposes tmux template syntax and percent
substitutions; it is never compiled as Raku. Popup shell-command deliberately
requests shell execution. Other commands use argv and the shared tmux encoder.
=end pod
