use v6.d;

unit module LibTmux::Model;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Catalogue;
use LibTmux::Capabilities;
use LibTmux::Engine;
use LibTmux::Command :DEFAULT, :internals;
use LibTmux::Format;
use LibTmux::Layout;
use LibTmux::Selection;
use LibTmux::Fields;
use LibTmux::Operations;
use LibTmux::Transport;
use LibTmux::Configuration;
use LibTmux::Client;

class Snapshot { ... }
class View { ... }
class WindowLink { ... }
class Window { ... }
class Pane { ... }
class Client { ... }
class SessionGroup { ... }
class SessionSelection { ... }
class WindowLinkSelection { ... }
class WindowSelection { ... }
class PaneSelection { ... }
class ClientSelection { ... }
class SessionGroupSelection { ... }
class BufferSelection { ... }
class SessionRef { ... }
class WindowRef { ... }
class WindowLinkRef { ... }
class PaneRef { ... }
my %view-types;
my %selection-types;

sub inconsistent(Str:D $entity, Str:D $field, Str:D $message --> Nil) {
    X::LibTmux::InconsistentSnapshot.new(:$entity, :$field, :$message).throw
}

sub missing(Str:D $name, ValueState:D $state --> Nil) {
    X::LibTmux::MissingData.new(:field($name), :$state,
        :message("$name is $state in this observation")).throw
}

sub bytes-key(Blob:D $bytes --> Str:D) { $bytes.list.map(*.fmt('%02x')).join }

sub row-key(Str:D $entity, DecodedRow:D $row --> Str:D) {
    given $entity {
        when 'window-link' { $row.value('session-id') ~ ':' ~ $row.value('index') }
        when 'client' {
            bytes-key($row.bytes('name')) ~ ':' ~ $row.value('pid') ~ ':' ~ $row.value('created')
        }
        when any(<session-group buffer>) { bytes-key($row.bytes('name')) }
        default { $row.value('id') }
    }
}

role Reference[::ID, Str:D $entity] {
    #| Captured connection settings; retaining them owns no process.
    has Endpoint:D $.endpoint is required;
    #| Captured daemon identity used to reject references after replacement.
    has Incarnation:D $.incarnation is required;
    has ID:D $.id is required;

    #| Return the registered entity schema without I/O.
    method entity(--> Str:D) { $entity }

    #| Construct a value-only option facade scoped to this captured identity.
    method options(--> Options:D) {
        Options.new(:endpoint($!endpoint), :incarnation($!incarnation), :scope($entity), :target($!id))
    }

    #| Construct a value-only hook facade; its reads and writes are explicit operations.
    method hooks(--> Hooks:D) {
        Hooks.new(:endpoint($!endpoint), :incarnation($!incarnation), :scope($entity), :target($!id))
    }

    method !with-runtime(&body) {
        my $runtime = Runtime.new(:endpoint($!endpoint));
        LEAVE $runtime.close if $runtime.defined;
        body($runtime)
    }

    #| A bounded, identity-guarded explicit command. Arguments keep tmux semantics.
    proto method command(|operation) {
        admit-operation(operation, :named{stdin => True});
        {*}
    }
    multi method command(Invocation:D $command, Blob:D :$stdin = Blob.new --> Result:D) {
        self!with-runtime(-> $runtime {
            $runtime.execute($command, :incarnation($!incarnation), :$stdin)
        })
    }

    #| Acquire a fresh graph and require exactly one observed entity with this ID.
    proto method inspect(|operation) {
        admit-operation(operation);
        {*}
    }
    multi method inspect(--> View:D) {
        self!with-runtime(-> $runtime {
            my $snapshot = capture($runtime, :required-incarnation($!incarnation));
            my $view = $snapshot.selection($entity).List.first(*.identity-key eq $!id);
            X::LibTmux::Cardinality.new(:entity($entity), :count(0),
                :message("$entity reference no longer exists")).throw unless $view.defined;
            $view
        })
    }

    #| Compare scoped identity without acquiring current state.
    method same-entity($other --> Bool:D) {
        $other ~~ Reference[ID, $entity] && $!id eq $other.id
            && $!incarnation.key eq $other.incarnation.key
    }
}

#| Value-only command target for a session in one daemon incarnation.
class SessionRef does Reference[SessionId, 'session'] is export {
    #| Construct a session environment facade without acquiring current values.
    method environment(--> Environment:D) {
        Environment.new(:endpoint(self.endpoint), :incarnation(self.incarnation),
            :scope<session>, :target(self.id))
    }
    #| Store the exact name; refuse characters or separators the daemon would change.
    method rename(Str:D $name --> Result:D) is single-operation {
        my $literal = operation-name($name, :domain<session>, :incarnation(self.incarnation));
        self.command(Invocation.new(:argv(['rename-session', '-t', self.id, '--', literal-format($literal)])))
    }
    #| Create a window and return its reported identity without refreshing observations.
    method new-window(Str :$name, :$index = Count, Bool :$select = False,
                      Bool :$replace = False, Str :$directory, Str :$shell-command,
                      Bool :$empty = False, Associative:D :$environment = Map.new --> WindowRef:D) is single-operation {
        my @spawn = spawn-arguments(:$directory, :$shell-command, :$empty, :$environment, :empty-flag);
        operation-capabilities(self.incarnation).require('window-empty') if $empty;
        invalid-argument('Window index must be a nonnegative integer')
            if $index.defined && $index !~~ Count;
        my @argv = 'new-window', '-P', '-F', creation-format('window'),
            '-t', self.id ~ ':' ~ ($index.defined ?? $index.Str !! '');
        @argv.push('-d') unless $select;
        @argv.push('-k') if $replace;
        @argv.append('-n', literal-format(operation-name($name, :domain<window>,
            :incarnation(self.incarnation)))) if $name.defined;
        @argv.append(@spawn);
        my $id = created-id(self.command(Invocation.new(:@argv)).stdout, 'window');
        WindowRef.new(:endpoint(self.endpoint), :incarnation(self.incarnation), :$id)
    }
    #| Select the next session window, optionally restricting to activity alerts.
    method next-window(Bool :$activity = False --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['next-window', '-t', self.id, |($activity ?? ['-a'] !! [])])))
    }
    #| Select the previous session window, optionally restricting to activity alerts.
    method previous-window(Bool :$activity = False --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['previous-window', '-t', self.id, |($activity ?? ['-a'] !! [])])))
    }
    #| Select the session's previous current window.
    method last-window(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['last-window', '-t', self.id]))) }
    #| Renumber this session's links; previously captured indices may become stale.
    method renumber-windows(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['move-window', '-r', '-t', self.id]))) }
    #| Ask tmux to lock clients attached to this session.
    method lock(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['lock-session', '-t', self.id]))) }
    #| Request detachment of clients in this session; acknowledgement is not client exit.
    method detach-clients(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['detach-client', '-s', self.id]))) }
    #| Destroy the addressed entity; retained observations remain unchanged.
    method kill(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['kill-session', '-t', self.id]))) }
}
#| Value-only command target for a physical window, independent of its links.
class WindowRef does Reference[WindowId, 'window'] is export {
    #| Store the exact name; refuse characters or separators the daemon would change.
    method rename(Str:D $name --> Result:D) is single-operation {
        my $literal = operation-name($name, :domain<window>, :incarnation(self.incarnation));
        self.command(Invocation.new(:argv(['rename-window', '-t', self.id, '--', literal-format($literal)])))
    }
    #| Set absolute dimensions or adjust one direction; these forms cannot be mixed.
    method resize(:$width = Positive, :$height = Positive, Str :$direction, :$amount = Positive --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['resize-window', '-t', self.id,
            |resize-arguments(:$width, :$height, :$direction, :$amount)])))
    }
    #| Select a named layout. Serialized layouts use restore-layout instead.
    method select-layout(Str:D $name --> Result:D) is single-operation {
        invalid-argument('Unknown named window layout') unless $name eq any(
            <even-horizontal even-vertical main-horizontal main-vertical tiled
             main-horizontal-mirrored main-vertical-mirrored>);
        operation-capabilities(self.incarnation).require('layout-mirrored-main')
            if $name.ends-with('-mirrored');
        self.command(Invocation.new(:argv(['select-layout', '-t', self.id, $name])))
    }
    #| Validate and apply serialized layout bytes in the daemon's declared dialect.
    method restore-layout(Blob:D $layout --> Result:D) is single-operation {
        my $profile = operation-capabilities(self.incarnation).layout-profile;
        my $parsed = decode-layout($layout, :$profile);
        invalid-argument('Unknown layouts cannot be applied') unless $parsed.known;
        self.command(Invocation.new(:argv(['select-layout', '-t', self.id, $layout.decode('utf8')])))
    }
    #| Apply the next tmux layout to this physical window.
    method next-layout(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['next-layout', '-t', self.id]))) }
    #| Apply the previous tmux layout to this physical window.
    method previous-layout(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['previous-layout', '-t', self.id]))) }
    #| Distribute space evenly around the active pane using select-layout -E.
    method spread-layout(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['select-layout', '-E', '-t', self.id]))) }
    #| Select the previous active pane in this physical window.
    method last-pane(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['last-pane', '-t', self.id]))) }
    #| Rotate panes in the layout; reverse changes the rotation direction.
    method rotate(Bool :$reverse = False, Bool :$preserve-zoom = False --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['rotate-window', '-t', self.id,
            $reverse ?? '-U' !! '-D', |($preserve-zoom ?? ['-Z'] !! [])])))
    }
    #| Restart the target's process; kill must be explicit when replacing a running process.
    method respawn(Str :$shell-command, Str :$directory, Bool :$kill = False,
                   Associative:D :$environment = Map.new --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['respawn-window', '-t', self.id,
            |($kill ?? ['-k'] !! []), |spawn-arguments(:$shell-command, :$directory, :$environment)])))
    }
    #| Add a destination placement. tmux synchronizes placements across session groups.
    method link(SessionRef:D $session, Count:D :$index!, Bool :$select = False,
                Bool :$replace = False --> WindowLinkRef:D) is single-operation {
        require-same-incarnation(self, $session);
        my $runtime = Runtime.new(:endpoint(self.endpoint));
        LEAVE $runtime.close if $runtime.defined;
        my $deadline = now + $runtime.timeout-ms / 1000;
        my $projection = Projection.new(:entity<window-link>, :fields<session-id window-id>,
            :capabilities(operation-capabilities(self.incarnation)));
        my @links = $runtime.read($projection, Invocation.new(:argv(['list-windows', '-a'])),
            :incarnation(self.incarnation), :$deadline).grep({ .value('window-id') eq self.id });
        X::LibTmux::StaleReference.new(:message('Window no longer has a session placement')).throw
            unless @links;
        my $source = @links.first({ .value('session-id') eq $session.id }) // @links[0];
        $runtime.execute(Invocation.new(:argv(['link-window', '-s', $source.value('session-id') ~ ':' ~ self.id,
            '-t', $session.id ~ ':' ~ $index, |($select ?? [] !! ['-d']),
            |($replace ?? ['-k'] !! [])])), :incarnation(self.incarnation), :$deadline);
        WindowLinkRef.new(:endpoint(self.endpoint), :incarnation(self.incarnation),
            :session-id($session.id), :window-id(self.id), :$index)
    }
    #| Destroy the addressed entity; retained observations remain unchanged.
    method kill(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['kill-window', '-t', self.id]))) }
}
#| Value-only command target for a physical pane in one daemon incarnation.
class PaneRef does Reference[PaneId, 'pane'] is export {
    #| Send literal bytes as text without appending Enter.
    method send-text(Str:D $text --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['send-keys', '-l', '-t', self.id, '--', $text])))
    }
    #| Send native key names, repeating them the requested number of times.
    method send-keys(*@keys, Positive:D :$repeat = 1 --> Result:D) is single-operation {
        invalid-argument('At least one key is required') unless @keys;
        self.command(Invocation.new(:argv(['send-keys', '-t', self.id, '-N', $repeat.Str, '--', |@keys])))
    }
    #| Send the configured primary or secondary prefix key to this pane.
    method send-prefix(Bool :$secondary = False --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['send-prefix', '-t', self.id, |($secondary ?? ['-2'] !! [])])))
    }
    #| Acquire screen/history bytes with explicit bounds and whitespace options.
    method capture(Int :$start, Int :$end, Bool :$history = False,
                   Bool :$join-wrapped = False, Bool :$escape-sequences = False,
                   Bool :$escape-controls = False, Bool :$alternate = False,
                   Bool :$trailing-spaces = False --> Blob:D) is single-operation {
        invalid-argument('history and start cannot be combined') if $history && $start.defined;
        my @argv = 'capture-pane', '-p', '-t', self.id;
        @argv.append('-S', '-') if $history;
        @argv.append('-S', $start.Str) if $start.defined;
        @argv.append('-E', $end.Str) if $end.defined;
        @argv.push('-J') if $join-wrapped;
        @argv.push('-e') if $escape-sequences;
        @argv.push('-C') if $escape-controls;
        @argv.push('-a') if $alternate;
        @argv.push('-N') if $trailing-spaces;
        self.command(Invocation.new(:@argv)).stdout
    }
    #| Acquire incomplete terminal escape input as bytes, separate from screen capture.
    method capture-pending(Bool :$escape-controls = False --> Blob:D) is single-operation {
        self.command(Invocation.new(:argv(['capture-pane', '-p', '-P', '-t', self.id,
            |($escape-controls ?? ['-C'] !! [])]))).stdout
    }
    #| Create a detached split by default, returning the reported pane ID.
    method split(Bool :$horizontal = False, Bool :$before = False,
                 Bool :$full = False, Bool :$select = False, Bool :$preserve-zoom = False,
                 :$size = Positive, :$percent = Positive, Str :$directory,
                 Str :$shell-command, Bool :$empty = False,
                 Associative:D :$environment = Map.new --> PaneRef:D) is single-operation {
        my @size = split-size(:$size, :$percent);
        my @spawn = spawn-arguments(:$directory, :$shell-command, :$empty, :$environment,
            :empty-flag(operation-capabilities(self.incarnation).status('pane-empty-flag').supported));
        my @argv = 'split-window', '-P', '-F', creation-format('pane'), '-t', self.id;
        @argv.push('-h') if $horizontal;
        @argv.push('-b') if $before;
        @argv.push('-f') if $full;
        @argv.push('-d') unless $select;
        @argv.push('-Z') if $preserve-zoom;
        @argv.append(|@size, |@spawn);
        my $id = created-id(self.command(Invocation.new(:@argv)).stdout, 'pane');
        PaneRef.new(:endpoint(self.endpoint), :incarnation(self.incarnation), :$id)
    }
    #| Create a floating pane. Modal input ownership requires the modal capability.
    method new-floating(Positive:D :$width!, Positive:D :$height!, Int :$x, Int :$y,
                        Bool :$modal = False, Bool :$select = False,
                        Str :$directory, Str :$shell-command, Bool :$empty = False,
                        Associative:D :$environment = Map.new --> PaneRef:D) is single-operation {
        my $caps = operation-capabilities(self.incarnation);
        $caps.require('pane-floating');
        $caps.require('pane-modal') if $modal;
        my @argv = 'new-pane', '-P', '-F', creation-format('pane'), '-t', self.id,
            '-x', $width.Str, '-y', $height.Str;
        @argv.append('-X', $x.Str) if $x.defined;
        @argv.append('-Y', $y.Str) if $y.defined;
        @argv.push('-O') if $modal;
        @argv.push('-d') unless $select;
        @argv.append(spawn-arguments(:$directory, :$shell-command, :$empty, :$environment, :empty-flag));
        my $id = created-id(self.command(Invocation.new(:@argv)).stdout, 'pane');
        PaneRef.new(:endpoint(self.endpoint), :incarnation(self.incarnation), :$id)
    }
    #| Set absolute dimensions or adjust one direction; these forms cannot be mixed.
    method resize(:$width = Positive, :$height = Positive, Str :$direction, :$amount = Positive --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['resize-pane', '-t', self.id,
            |resize-arguments(:$width, :$height, :$direction, :$amount)])))
    }
    #| Toggle this pane's window zoom state.
    method toggle-zoom(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['resize-pane', '-Z', '-t', self.id]))) }
    #| Select the exact pane or verified session-relative window placement.
    method select(Bool :$preserve-zoom = False --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['select-pane', '-t', self.id, |($preserve-zoom ?? ['-Z'] !! [])])))
    }
    #| Set title text through one literal FORMAT expansion; tmux title rules still apply.
    method set-title(Str:D $title --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['select-pane', '-t', self.id, '-T', literal-format($title)])))
    }
    #| Enable or disable delivery of keyboard input to this pane.
    method set-input(Bool:D $enabled --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['select-pane', '-t', self.id, $enabled ?? '-e' !! '-d'])))
    }
    #| Toggle the global marked-pane target using this pane.
    method toggle-mark(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['select-pane', '-m', '-t', self.id]))) }
    #| Clear the server's marked pane.
    method unmark(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['select-pane', '-M', '-t', self.id]))) }
    #| Restart the target's process; kill must be explicit when replacing a running process.
    method respawn(Str :$shell-command, Str :$directory, Bool :$kill = False,
                   Associative:D :$environment = Map.new --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['respawn-pane', '-t', self.id,
            |($kill ?? ['-k'] !! []), |spawn-arguments(:$shell-command, :$directory, :$environment)])))
    }
    method !transfer(Str:D $command, PaneRef:D $target, Bool :$horizontal = False,
                     Bool :$before = False, Bool :$full = False, Bool :$select = False,
                     :$size = Positive, :$percent = Positive) {
        require-same-incarnation(self, $target);
        invalid-argument('Source and target pane must differ') if self.id eq $target.id;
        self.command(Invocation.new(:argv([$command, '-s', self.id, '-t', $target.id,
            |($horizontal ?? ['-h'] !! []), |($before ?? ['-b'] !! []),
            |($full ?? ['-f'] !! []), |($select ?? [] !! ['-d']), |split-size(:$size, :$percent)])))
    }
    #| Move this pane into the target's split tree; its scoped ID remains unchanged.
    method join(PaneRef:D $target, Bool :$horizontal = False, Bool :$before = False,
                Bool :$full = False, Bool :$select = False,
                :$size = Positive, :$percent = Positive --> Result:D) is single-operation {
        self!transfer('join-pane', $target, :$horizontal, :$before, :$full, :$select, :$size, :$percent)
    }
    #| Move this pane beside an explicit pane target without changing its ID.
    method move(PaneRef:D $target, Bool :$horizontal = False, Bool :$before = False,
                Bool :$full = False, Bool :$select = False,
                :$size = Positive, :$percent = Positive --> Result:D) is single-operation {
        self!transfer('move-pane', $target, :$horizontal, :$before, :$full, :$select, :$size, :$percent)
    }
    #| Move a floating pane to explicit coordinates in the supported profile.
    method move-floating(Int :$x, Int :$y --> Result:D) is single-operation {
        invalid-argument('Specify at least one floating coordinate') unless $x.defined || $y.defined;
        operation-capabilities(self.incarnation).require('pane-floating-move');
        self.command(Invocation.new(:argv(['move-pane', '-t', self.id,
            |($x.defined ?? ['-X', $x.Str] !! []), |($y.defined ?? ['-Y', $y.Str] !! [])])))
    }
    #| Change a floating pane's relative stacking order using a closed placement name.
    method stack(Str:D $placement --> Result:D) is single-operation {
        invalid-argument('Stack placement must be front, back, forward, backward, forward-loop, or backward-loop')
            unless $placement eq any(<front back forward backward forward-loop backward-loop>);
        operation-capabilities(self.incarnation).require('pane-floating-move');
        self.command(Invocation.new(:argv(['move-pane', '-t', self.id, '-P', $placement])))
    }
    #| Set a floating pane's nonnegative stacking index.
    method set-z-index(Count:D $index --> Result:D) is single-operation {
        operation-capabilities(self.incarnation).require('pane-floating-move');
        self.command(Invocation.new(:argv(['move-pane', '-t', self.id, '-z', $index.Str])))
    }
    #| Convert this floating pane into a tile while preserving its ID.
    method tile(Bool :$select = False --> Result:D) is single-operation {
        operation-capabilities(self.incarnation).require('pane-floating-move');
        self.command(Invocation.new(:argv(['move-pane', '-s', self.id, '-t', self.id,
            |($select ?? [] !! ['-d'])])))
    }
    #| Convert this tile into a floating pane with explicit dimensions.
    method float(Positive:D :$width!, Positive:D :$height!, Int :$x, Int :$y,
                 Bool :$select = False --> Result:D) is single-operation {
        operation-capabilities(self.incarnation).require('pane-floating-move');
        self.command(Invocation.new(:argv(['break-pane', '-W', '-s', self.id,
            '-x', $width.Str, '-y', $height.Str, |($select ?? [] !! ['-d']),
            |($x.defined ?? ['-X', $x.Str] !! []), |($y.defined ?? ['-Y', $y.Str] !! [])])))
    }
    #| Swap the two verified pane identities or session-relative window placements.
    method swap(PaneRef:D $target, Bool :$select = False, Bool :$preserve-zoom = False --> Result:D) is single-operation {
        require-same-incarnation(self, $target);
        invalid-argument('Source and target pane must differ') if self.id eq $target.id;
        self.command(Invocation.new(:argv(['swap-pane', '-s', self.id, '-t', $target.id,
            |($select ?? [] !! ['-d']), |($preserve-zoom ?? ['-Z'] !! [])])))
    }
    #| Move this pane to a new window in an explicit session, returning the reported window ID.
    method break(SessionRef:D $session, :$index = Count, Str :$name,
                 WindowLinkRef :$from, Bool :$select = False --> WindowRef:D) is single-operation {
        require-same-incarnation(self, $session);
        require-same-incarnation(self, $from) if $from.defined;
        invalid-argument('Window index must be a nonnegative integer')
            if $index.defined && $index !~~ Count;
        my $caps = operation-capabilities(self.incarnation);
        my $defect = $caps.workaround('break-pane-name-defect');
        X::LibTmux::Unsupported.new(:feature<break-pane-name-defect>, :state(NotSupported),
            :reason($defect.reason), :message('break-pane is unsafe for this daemon profile')).throw
            if $defect.applies;
        my @argv = 'break-pane', '-P', '-F', creation-format('window'),
            '-t', $session.id ~ ':' ~ ($index.defined ?? $index.Str !! '');
        @argv.push('-d') unless $select;
        if $name.defined {
            @argv.append('-n', operation-name($name, :domain<window>, :incarnation(self.incarnation)));
        }
        my $runtime = Runtime.new(:endpoint(self.endpoint));
        LEAVE $runtime.close if $runtime.defined;
        my $deadline = now + $runtime.timeout-ms / 1000;
        my $pane-projection = Projection.new(:entity<pane>, :fields<id window-id>, :capabilities($caps));
        my @current = $runtime.read($pane-projection, Invocation.new(:argv(['list-panes', '-a'])),
            :incarnation(self.incarnation), :$deadline).grep({ .value('id') eq self.id });
        my @windows = @current.map({ .value('window-id') }).unique;
        X::LibTmux::Cardinality.new(:entity<pane>, :count(@windows.elems),
            :message('The pane must have one current physical window')).throw unless @windows.elems == 1;
        my $link-projection = Projection.new(:entity<window-link>,
            :fields<session-id window-id index>, :capabilities($caps));
        my @links = $runtime.read($link-projection, Invocation.new(:argv(['list-windows', '-a'])),
            :incarnation(self.incarnation), :$deadline).grep({ .value('window-id') eq @windows[0] });
        if $from.defined {
            @links = @links.grep({ .value('session-id') eq $from.session-id
                && .value('index') == $from.index && .value('window-id') eq $from.window-id });
            X::LibTmux::StaleReference.new(:message('The source link no longer contains this pane')).throw
                unless @links.elems == 1;
        } else {
            X::LibTmux::Cardinality.new(:entity<window-link>, :count(@links.elems),
                :message('A linked window requires an explicit :from WindowLinkRef for break')).throw
                unless @links.elems == 1;
        }
        @argv.append('-s', @links[0].value('session-id') ~ ':' ~ @links[0].value('index') ~ '.' ~ self.id);
        my $output = $runtime.execute(Invocation.new(:@argv),
            :incarnation(self.incarnation), :$deadline).stdout;
        my $id;
        if !$output.elems && !$caps.status('break-pane-single-print').supported {
            # Older break-pane omits -P for an already single-pane window.
            my $projection = Projection.new(:entity<pane>, :fields<id window-id>, :capabilities($caps));
            my @rows = $runtime.read($projection, Invocation.new(:argv(['list-panes', '-a'])),
                :incarnation(self.incarnation), :$deadline).grep({ .value('id') eq self.id });
            my @ids = @rows.map({ .value('window-id') }).unique;
            X::LibTmux::Decode.new(:schema<creation:window>,
                :message('Cannot resolve the moved pane after legacy break-pane')).throw unless @ids.elems == 1;
            $id = @ids[0];
        } else {
            $id = created-id($output, 'window');
        }
        WindowRef.new(:endpoint(self.endpoint), :incarnation(self.incarnation), :$id)
    }
    #| Discard scrollback; visible screen contents and application state are unaffected.
    method clear-history(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['clear-history', '-t', self.id]))) }
    #| Reset tmux's terminal state for this pane; this does not restart its process.
    method reset-terminal(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['send-keys', '-R', '-t', self.id]))) }
    #| Reset terminal state and clear history in one tmux queue; failure can leave partial effects.
    method reset(--> Result:D) is single-operation {
        my $reset = Invocation.new(:argv(['send-keys', '-R', '-t', self.id]));
        my $history = Invocation.new(:argv(['clear-history', '-t', self.id]));
        self.command(Invocation.new(:argv(['if-shell', '-F', '1',
            $reset.source ~ ' ; ' ~ $history.source])))
    }
    #| Enter copy mode, optionally paging upward or exiting when scrolling to the bottom.
    method copy-mode(Bool :$page-up = False, Bool :$exit-at-bottom = False --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['copy-mode', '-t', self.id,
            |($page-up ?? ['-u'] !! []), |($exit-at-bottom ?? ['-e'] !! [])])))
    }
    #| Dispatch a native copy-mode command with separate argument values.
    method copy-command(Str:D $command, *@arguments --> Result:D) is single-operation {
        self.command(Invocation.new(:argv(['send-keys', '-X', '-t', self.id, '--', $command, |@arguments])))
    }
    #| Enter tmux's clock mode for this pane.
    method clock-mode(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['clock-mode', '-t', self.id]))) }
    #| The pipe command deliberately uses tmux's FORMAT and strftime shell-command syntax.
    method pipe(Str :$shell-command, Bool :$input = False, Bool :$output = True,
                Bool :$toggle = False --> Result:D) is single-operation {
        invalid-argument('A pipe must accept input or output') unless $input || $output;
        self.command(Invocation.new(:argv(['pipe-pane', '-t', self.id,
            |($input ?? ['-I'] !! []), |($output ?? ['-O'] !! []),
            |($toggle ?? ['-o'] !! []), |($shell-command.defined ?? ['--', $shell-command] !! [])])))
    }
    #| Destroy the addressed entity; retained observations remain unchanged.
    method kill(--> Result:D) is single-operation { self.command(Invocation.new(:argv(['kill-pane', '-t', self.id]))) }
}

#| A session/index target with an expected window. Renumbering checks are not atomic.
class WindowLinkRef is export {
    #| Captured connection settings; retaining them owns no process.
    has Endpoint:D $.endpoint is required;
    #| Captured daemon identity used to reject references after replacement.
    has Incarnation:D $.incarnation is required;
    #| Captured session identity for this observed window placement.
    has SessionId:D $.session-id is required;
    #| Expected physical window identity at the captured session index.
    has WindowId:D $.window-id is required;
    #| Captured session-relative index; it can change after renumbering.
    has Count:D $.index is required;

    #| Return the observed session:index target without checking whether it remains current.
    method target(--> Str:D) { $!session-id ~ ':' ~ $!index }

    method !with-link(&body, Instant :$deadline) {
        my $runtime = Runtime.new(:endpoint($!endpoint));
        LEAVE $runtime.close if $runtime.defined;
        my $until = $deadline // now + $runtime.timeout-ms / 1000;
        my $caps = LibTmux::Capabilities.new(:daemon-version($!incarnation.daemon-version),
            :incarnation($!incarnation.key));
        my $projection = Projection.new(:entity<window-link>,
            :fields<session-id window-id index>, :capabilities($caps));
        my @rows = $runtime.read($projection,
            Invocation.new(:argv(['list-windows', '-t', $!session-id])),
            :incarnation($!incarnation), :deadline($until));
        my $row = @rows.first({ .value('index') == $!index });
        X::LibTmux::StaleReference.new(:message('Window link was removed or renumbered')).throw
            unless $row.defined && $row.value('window-id') eq $!window-id;
        body($runtime, $until)
    }
    #| Select the exact pane or verified session-relative window placement.
    method select(--> Result:D) is single-operation {
        self!with-link(-> $runtime, $deadline {
            $runtime.execute(Invocation.new(:argv(['select-window', '-t', self.target])),
                :incarnation($!incarnation), :$deadline)
        })
    }
    #| Remove this placement and its grouped-session peers; kill-last permits the last link.
    method unlink(Bool :$kill-last = False --> Result:D) is single-operation {
        self!with-link(-> $runtime, $deadline {
            $runtime.execute(Invocation.new(:argv(['unlink-window', '-t', self.target,
                |($kill-last ?? ['-k'] !! [])])), :incarnation($!incarnation), :$deadline)
        })
    }
    #| Move this association; tmux also synchronizes the affected session groups.
    method move(SessionRef:D $session, Count:D :$index!, Bool :$select = False,
                Bool :$replace = False --> WindowLinkRef:D) is single-operation {
        require-same-incarnation(self, $session);
        self!with-link(-> $runtime, $deadline {
            $runtime.execute(Invocation.new(:argv(['move-window', '-s', self.target,
                '-t', $session.id ~ ':' ~ $index, |($select ?? [] !! ['-d']),
                |($replace ?? ['-k'] !! [])])), :incarnation($!incarnation), :$deadline)
        });
        WindowLinkRef.new(:$!endpoint, :$!incarnation, :session-id($session.id),
            :window-id($!window-id), :$index)
    }
    #| Swap the two verified pane identities or session-relative window placements.
    method swap(WindowLinkRef:D $other, Bool :$select = False --> Result:D) is single-operation {
        require-same-incarnation(self, $other);
        self!with-link(-> $runtime, $deadline {
            $other!with-link(-> $checked, $other-deadline {
                $runtime.execute(Invocation.new(:argv(['swap-window', '-s', self.target,
                    '-t', $other.target, |($select ?? [] !! ['-d'])])), :incarnation($!incarnation), :$deadline)
            }, :$deadline)
        })
    }
}

#| A captured client identity with explicit inspection and inherited client commands.
class ClientRef is ClientTarget is export {
    #| Return the registered client schema without I/O.
    method entity(--> Str:D) { 'client' }

    #| Acquire a fresh graph and require the observed name, process and creation time.
    method inspect(--> Client:D) is single-operation {
        my $runtime = Runtime.new(:endpoint(self.endpoint));
        LEAVE $runtime.close if $runtime.defined;
        my $snapshot = capture($runtime, :required-incarnation(self.incarnation));
        my $name = Blob.new(self.name.encode('utf8-c8').list);
        my $client = $snapshot.clients.List.first({ .bytes('name') eqv $name
            && .pid == self.pid && .created == self.created });
        X::LibTmux::StaleReference.new(:message('Observed client is no longer attached')).throw
            unless $client.defined;
        $client
    }

    #| Compare captured identities without checking whether the client remains attached.
    method same-entity($other --> Bool:D) {
        $other ~~ ClientTarget && self.incarnation.key eq $other.incarnation.key
            && self.name.encode('utf8-c8') eqv $other.name.encode('utf8-c8')
            && self.pid == $other.pid && self.created == $other.created
    }
}

#| Captured records and indexed relations; it retains no transport or live owner.
class Snapshot is export {
    trusts View;
    #| Captured connection settings; retaining them owns no process.
    has Endpoint:D $.endpoint is required;
    #| Immutable daemon identity and capabilities used during acquisition.
    has Observation:D $.observation is required;
    #| Start of the acquisition interval; the graph is not an atomic instant.
    has Instant:D $.started is required;
    #| End of the acquisition interval after declared records were captured.
    has Instant:D $.ended is required;
    has %!rows;
    has %!views;
    has %!lookup;
    has %!complete;
    has %!relations;
    has %!ready;

    submethod BUILD(:$!endpoint!, :$!observation!, :$!started = now, :$!ended = now,
                    :%rows!, :$complete = ()) {
        X::LibTmux::Decode.new(:schema<snapshot>,
            :message('Capture timestamps are reversed')).throw if $!ended < $!started;
        X::LibTmux::StaleReference.new(:message('Snapshot endpoint does not match its identity')).throw
            unless $!endpoint.key eq self.incarnation.endpoint-key;
        for $complete.list -> $entity {
            X::LibTmux::Decode.new(:schema<snapshot>,
                :message('Unknown complete entity collection')).throw
                unless $entity ~~ Str:D && (%view-types{$entity}:exists);
            %!complete{$entity} = True;
        }
        for %rows.keys -> $entity {
            X::LibTmux::Decode.new(:schema<snapshot>,
                :message("Unknown snapshot entity $entity")).throw
                unless %view-types{$entity}:exists;
        }
        for %view-types.keys -> $entity {
            my @rows = %rows{$entity}:exists ?? %rows{$entity}.list !! ();
            my %indexed;
            my @views;
            for @rows -> $row {
                X::LibTmux::Decode.new(:schema<snapshot>,
                    :message("Expected a declared $entity row")).throw
                    unless $row ~~ DecodedRow:D
                        && $row.schema.starts-with("libtmux.format/v1:$entity:");
                X::LibTmux::StaleReference.new(
                    :message('Captured row belongs to another daemon')).throw
                    unless $row.incarnation eq self.incarnation.key;
                my $key = row-key($entity, $row);
                if %indexed{$key}:exists {
                    inconsistent($entity, '', "Contextual rows disagree about $entity")
                        unless %indexed{$key}<row>.raw eqv $row.raw;
                    next;
                }
                my $view = %view-types{$entity}.bless(:snapshot(self), :record($row),
                    :$entity, :identity-key($key));
                %indexed{$key} = Map.new(row => $row, view => $view);
                @views.push($view);
            }
            %!rows{$entity} = @rows.map({ $_<> }).List;
            %!views{$entity} = @views.map({ $_<> }).List;
            %!lookup{$entity} = %indexed.Map;
        }
        self!index-relations;
    }

    #| Return the captured daemon identity without refreshing it.
    method incarnation(--> Incarnation:D) { $!observation.incarnation }
    #| Return the immutable capability observation used to acquire this graph.
    method capabilities(--> LibTmux::Capabilities:D) { $!observation.capabilities }
    #| Whether the named entity collection was acquired without source restriction.
    method complete(Str:D $entity --> Bool:D) { so (%!complete{$entity} // False) }

    #| Return raw contextual rows, retaining repeated physical-entity observations.
    method rows(Str:D $entity --> List:D) {
        catalogue().fields($entity);
        %!rows{$entity}.list
    }

    #| Return the captured typed selection for a validated entity schema.
    method selection(Str:D $entity) {
        catalogue().fields($entity);
        %selection-types{$entity}.new(:items(%!views{$entity}))
    }

    #| Captured sessions in acquisition order; reading performs no I/O.
    method sessions(--> SessionSelection:D) { self.selection('session') }
    #| Captured session/index associations, including repeated links to one physical window.
    method window-links(--> WindowLinkSelection:D) { self.selection('window-link') }
    #| Captured physical windows, unique by daemon-scoped identity.
    method windows(--> WindowSelection:D) { self.selection('window') }
    #| Captured physical panes; relation traversal never acquires newer data.
    method panes(--> PaneSelection:D) { self.selection('pane') }
    #| Captured attached clients with their observed process and creation identity.
    method clients(--> ClientSelection:D) { self.selection('client') }
    #| Captured session groups and their observed membership.
    method session-groups(--> SessionGroupSelection:D) { self.selection('session-group') }
    #| Captured buffer metadata; content requires a separate explicit operation.
    method buffers(--> BufferSelection:D) { self.selection('buffer') }

    method !relation-key(View:D $view, Str:D $name --> Str:D) {
        $view.entity ~ "\0" ~ $view.identity-key ~ "\0" ~ $name
    }

    method !ready(Str:D $entity, *@fields --> Bool:D) {
        my $key = ($entity, |@fields).join("\0");
        return %!ready{$key} if %!ready{$key}:exists;
        %!ready{$key} = self.complete($entity) && so %!rows{$entity}.list.map(-> $row {
            so @fields.map({ $row.raw{$_}:exists }).all
        }).all
    }

    method !put(View:D $view, Str:D $name, ValueState:D $state, *@keys --> Nil) {
        my $spec = catalogue().relation($view.entity, $name);
        if $state == Present {
            inconsistent($view.entity, $name, "Missing target for {$view.entity}.$name")
                if @keys.first({ !(%!lookup{$spec.target}{$_}:exists) }).defined;
            inconsistent($view.entity, $name, "Expected one target for {$view.entity}.$name")
                if $spec.cardinality eq 'one' && @keys.elems != 1;
        }
        %!relations{self!relation-key($view, $name)} = Map.new(:$state,
            :keys(@keys.map({ $_<> }).List));
    }

    method !foreign(View:D $view, Str:D $relation, Str:D $field,
                    Str:D $target --> Nil) {
        my $state = $view.state($field);
        if $state == KnownNull { self!put($view, $relation, KnownNull); return }
        unless $state == Present && self.complete($target) {
            self!put($view, $relation, Unloaded);
            return;
        }
        my $key = $target eq 'session-group'
            ?? bytes-key($view.bytes($field)) !! $view.value($field);
        self!put($view, $relation, Present, $key);
    }

    method !index-relations(--> Nil) {
        my %session-links;
        my %window-links;
        my %window-panes;
        my %group-sessions;
        for %!views<window-link>.list -> $link {
            (%session-links{$link.value('session-id')} //= []).push($link);
            (%window-links{$link.value('window-id')} //= []).push($link)
                if $link.state('window-id') == Present;
        }
        for %!views<pane>.list -> $pane {
            (%window-panes{$pane.value('window-id')} //= []).push($pane)
                if $pane.state('window-id') == Present;
        }
        for %!views<session>.list -> $session {
            (%group-sessions{bytes-key($session.bytes('group-name'))} //= []).push($session)
                if $session.state('group-name') == Present;
        }
        for %!views<session>.list -> $session {
            my @links = (%session-links{$session.identity-key} // []).list;
            my $ready = self!ready('window-link', 'session-id');
            self!put($session, 'window-links', $ready ?? Present !! Unloaded,
                |@links.map(*.identity-key));
            $ready = self!ready('window-link', 'session-id', 'active');
            self!put($session, 'current-link', $ready ?? Present !! Unloaded,
                |($ready ?? @links.grep(*.value('active')).map(*.identity-key) !! ()));
            self!foreign($session, 'group', 'group-name', 'session-group');
        }
        for %!views<window-link>.list -> $link {
            self!foreign($link, 'session', 'session-id', 'session');
            self!foreign($link, 'window', 'window-id', 'window');
        }
        for %!views<window>.list -> $window {
            my @panes = (%window-panes{$window.identity-key} // []).list;
            my @links = (%window-links{$window.identity-key} // []).list;
            self!put($window, 'panes', self!ready('pane', 'window-id') ?? Present !! Unloaded,
                |@panes.map(*.identity-key));
            self!put($window, 'links', self!ready('window-link', 'window-id') ?? Present !! Unloaded,
                |@links.map(*.identity-key));
            my $ready = self!ready('pane', 'window-id', 'active');
            self!put($window, 'active-pane', $ready ?? Present !! Unloaded,
                |($ready ?? @panes.grep(*.value('active')).map(*.identity-key) !! ()));
        }
        for %!views<pane>.list -> $pane {
            self!foreign($pane, 'window', 'window-id', 'window');
        }
        for %!views<client>.list -> $client {
            self!foreign($client, 'session', 'session-id', 'session');
        }
        for %!views<session-group>.list -> $group {
            my @sessions = (%group-sessions{$group.identity-key} // []).list;
            self!put($group, 'sessions', self!ready('session', 'group-name') ?? Present !! Unloaded,
                |@sessions.map(*.identity-key));
        }
    }

    method !relation-state(View:D $view, Str:D $name --> ValueState:D) {
        (%!relations{self!relation-key($view, $name)} // Map.new(state => Unloaded))<state>
    }

    method !resolve(View:D $view, Str:D $name) {
        my $spec = catalogue().relation($view.entity, $name);
        X::LibTmux::InvalidFilter.new(:path($name),
            :message("Unknown {$view.entity} relation $name")).throw unless $spec.defined;
        my $state = self!relation-state($view, $name);
        return Nil if $state == KnownNull;
        missing($name, $state) unless $state == Present;
        my @values = %!relations{self!relation-key($view, $name)}<keys>.map({
            %!lookup{$spec.target}{$_}<view>
        });
        $spec.cardinality eq 'one' ?? @values[0]
            !! %selection-types{$spec.target}.new(:items(@values))
    }

    #| Copy this captured value without changing its records or acquiring new data.
    method clone(*%changes) {
        X::LibTmux::Command.new(:kind<argument>, :outcome(NotStarted),
            :message('Captured graph membership cannot be replaced')).throw if %changes;
        self.WHAT.new(:$!endpoint, :$!observation, :$!started, :$!ended,
            :rows(%!rows), :complete(%!complete.keys.List))
    }
}

#| A local view of one captured record. Accessors and relations never perform I/O.
class View {
    has Snapshot:D $!snapshot is required;
    has DecodedRow:D $!record is required;
    #| Catalogue entity schema for this view or reference.
    has Str:D $.entity is required;
    #| Snapshot lookup key; window-link keys are not stable across captures.
    has Str:D $.identity-key is required;

    submethod BUILD(:$!snapshot!, :$!record!, :$!entity!, :$!identity-key!) { }

    #| Refuse direct view construction; obtain this value from a Snapshot.
    method new(| --> Nil) {
        X::LibTmux::Command.new(:kind<argument>, :outcome(NotStarted),
            :message('Obtain captured views from a Snapshot')).throw
    }

    #| Report availability of a declared field or relation without conflating null and unloaded data.
    method state(Str:D $name --> ValueState:D) {
        my $field = catalogue().field($!entity, $name);
        if $field.defined {
            return $!record.state($name) if $!record.raw{$name}:exists;
            return Unsupported unless $!snapshot.capabilities.supports-field($!entity, $name);
            return Unavailable if $field.context ne $!record.schema.split(':')[2];
            return Unloaded;
        }
        my $relation = catalogue().relation($!entity, $name);
        return $!snapshot!Snapshot::relation-state(self, $name) if $relation.defined;
        X::LibTmux::InvalidFilter.new(:path($name),
            :message("Unknown $!entity field or relation $name")).throw
    }

    #| Return a decoded local field, Nil for known null, or throw MissingData for unavailable data.
    method value(Str:D $name) {
        my $state = self.state($name);
        return Nil if $state == KnownNull;
        missing($name, $state) unless $state == Present;
        $!record.value($name)
    }

    #| Exact captured bytes, before strict text conversion or normalization.
    method bytes(Str:D $name --> Blob:D) {
        my $state = self.state($name);
        missing($name, $state) unless $state == Present || $state == KnownNull;
        $!record.bytes($name)
    }

    #| Resolve one declared relation locally; incomplete required data raises MissingData.
    method relation(Str:D $name) { $!snapshot!Snapshot::resolve(self, $name) }

    #| Compare scoped entity identity; window links additionally require the same snapshot.
    method same-entity(View:D $other --> Bool:D) {
        return False unless $!entity eq $other.entity;
        return False unless $!snapshot.incarnation.key eq $other.incarnation.key;
        return False if $!entity eq 'window-link' && $!snapshot !=== $other.snapshot;
        $!identity-key eq $other.identity-key
    }

    #| Return the retained captured graph; it owns no live transport.
    method snapshot(--> Snapshot:D) { $!snapshot }
    #| Return the captured daemon identity without refreshing it.
    method incarnation(--> Incarnation:D) { $!snapshot.incarnation }

    #| Construct a value-only command target without observing current daemon state.
    method ref() {
        my %arguments = endpoint => $!snapshot.endpoint, incarnation => self.incarnation;
        given $!entity {
            when 'session' { SessionRef.new(:id(self.value('id')), |%arguments) }
            when 'window' { WindowRef.new(:id(self.value('id')), |%arguments) }
            when 'pane' { PaneRef.new(:id(self.value('id')), |%arguments) }
            when 'client' {
                ClientRef.new(:name(self.bytes('name').decode('utf8-c8')),
                    :pid(self.value('pid')), :created(self.value('created')), |%arguments)
            }
            when 'window-link' {
                WindowLinkRef.new(:session-id(self.value('session-id')),
                    :window-id(self.value('window-id')), :index(self.value('index')),
                    |%arguments)
            }
            default {
                X::LibTmux::Unsupported.new(:feature("{$!entity}-reference"),
                    :reason('This observation has no command reference'),
                    :message("$!entity has no command reference")).throw
            }
        }
    }

    #| Copy this captured value without changing its records or acquiring new data.
    method clone(*%changes) {
        X::LibTmux::Command.new(:kind<argument>, :outcome(NotStarted),
            :message('Captured views cannot replace their records')).throw if %changes;
        self.WHAT.bless(:snapshot($!snapshot), :record($!record),
            :$!entity, :$!identity-key)
    }
}

#| Captured session with local window-link and group relationships.
class Session is View does SessionFields is export {
    #| Captured session/index associations, including repeated links to one physical window.
    method window-links(--> WindowLinkSelection:D) { self.relation('window-links') }
    #| The session-relative active window placement in this observation.
    method current-link(--> WindowLink:D) { self.relation('current-link') }
    #| Observed session group, or Nil when the session is known to be ungrouped.
    method group(--> SessionGroup) { self.relation('group') }
}
#| One captured session/index association with an expected physical window.
class WindowLink is View does WindowLinkFields is export {
    #| The observed associated session, resolved without I/O.
    method session(--> Session:D) { self.relation('session') }
    #| The observed physical window, resolved without I/O.
    method window(--> Window:D) { self.relation('window') }
}
#| Captured physical window; session-relative indices belong to WindowLink.
class Window is View does WindowFields is export {
    #| Captured physical panes; relation traversal never acquires newer data.
    method panes(--> PaneSelection:D) { self.relation('panes') }
    #| All captured placements of this physical window, preserving repeated associations.
    method links(--> WindowLinkSelection:D) { self.relation('links') }
    #| The physical window's observed active pane.
    method active-pane(--> Pane:D) { self.relation('active-pane') }
    #| Decode retained layout bytes locally, preserving unknown layout versions.
    method decoded-layout(--> Layout:D) {
        my %options = profile => self.snapshot.capabilities.layout-profile;
        %options<modal-pane-id> = self.value('modal-pane-id')
            if self.state('modal-pane-id') == Present;
        decode-layout(self.bytes('layout'), |%options)
    }
}
#| Captured pane fields and its local physical-window relationship.
class Pane is View does PaneFields is export {
    #| The observed physical window, resolved without I/O.
    method window(--> Window:D) { self.relation('window') }
}
#| Captured attached-client fields; commands use its separate reference.
class Client is View does ClientFields is export {
    #| The observed associated session, resolved without I/O.
    method session(--> Session:D) { self.relation('session') }
}
#| Captured session group whose members are resolved within this graph.
class SessionGroup is View does SessionGroupFields is export {
    #| Captured sessions in acquisition order; reading performs no I/O.
    method sessions(--> SessionSelection:D) { self.relation('sessions') }
}
#| Captured buffer metadata; it does not retain or implicitly load buffer content.
class Buffer is View does BufferFields is export { }

#| Replayable typed session membership with local filtering.
class SessionSelection does Selection[Session, 'session'] is export { }
#| Replayable typed window-link membership with local filtering.
class WindowLinkSelection does Selection[WindowLink, 'window-link'] is export { }
#| Replayable typed window membership with local filtering.
class WindowSelection does Selection[Window, 'window'] is export { }
#| Replayable typed pane membership with local filtering.
class PaneSelection does Selection[Pane, 'pane'] is export { }
#| Replayable typed client membership with local filtering.
class ClientSelection does Selection[Client, 'client'] is export { }
#| Replayable typed sessiongroup membership with local filtering.
class SessionGroupSelection does Selection[SessionGroup, 'session-group'] is export { }
#| Replayable typed buffer membership with local filtering.
class BufferSelection does Selection[Buffer, 'buffer'] is export { }


%view-types = session => Session, window-link => WindowLink, window => Window,
    pane => Pane, client => Client, session-group => SessionGroup, buffer => Buffer;
%selection-types = session => SessionSelection, window-link => WindowLinkSelection,
    window => WindowSelection, pane => PaneSelection, client => ClientSelection,
    session-group => SessionGroupSelection, buffer => BufferSelection;

#| Acquire all graph collections explicitly. Multiple commands observe an interval.
sub capture(Acquirer:D $runtime, Incarnation :$required-incarnation,
            Cancellation :$cancel = Cancellation,
            Instant:D :$deadline = now + $runtime.timeout-ms / 1000 --> Snapshot:D) is export {
    my $started = now;
    my $observation = $runtime.observe(:$deadline, :$cancel);
    X::LibTmux::StaleReference.new(:message('Reference belongs to a replaced daemon')).throw
        if $required-incarnation.defined
            && $required-incarnation.key ne $observation.incarnation.key;
    $observation.capabilities.require('managed-commands');
    my %commands = session => ['list-sessions'], window-link => ['list-windows', '-a'],
        window => ['list-windows', '-a'], pane => ['list-panes', '-a'],
        client => ['list-clients'], buffer => ['list-buffers'],
        session-group => ['list-sessions', '-f', '#{session_grouped}'];
    my %contexts = session-group => 'grouped-session';
    my %rows;
    for <session window-link window pane client session-group buffer> -> $entity {
        my $context = %contexts{$entity} // $entity;
        my @fields = catalogue().fields($entity).grep({
            .context eq $context && $observation.capabilities.supports-field($entity, .name)
        }).map(*.name);
        my $projection = Projection.new(:$entity, :fields(@fields), :$context,
            :capabilities($observation.capabilities));
        %rows{$entity} = $runtime.read($projection,
            Invocation.new(:argv(%commands{$entity})), :incarnation($observation.incarnation), :$deadline, :$cancel);
    }
    my $after = $runtime.observe(:$deadline, :$cancel);
    X::LibTmux::StaleReference.new(:message('Daemon changed during snapshot acquisition')).throw
        unless $after.incarnation.key eq $observation.incarnation.key;
    my $snapshot = Snapshot.new(:endpoint($runtime.endpoint), :$observation, :$started, :ended(now),
        :%rows, :complete(%commands.keys.List));
    X::LibTmux::Command.new(:kind<timeout>, :outcome(Complete),
        :message('Snapshot deadline expired after acquisition')).throw if now >= $deadline;
    $snapshot
}

=begin pod
=head1 Captured graph

Snapshot captures observations over an interval. Its field accessors, raw bytes,
relations and typed selections perform no I/O. It retains endpoint settings and
incarnation values, never the Runtime that acquired it. Reference construction
is local; reference commands create and close a fresh bounded client executor.

Physical windows and panes are unique by scoped ID. WindowLink represents one
session/index association, including repeated links to the same physical window.
Raw contextual rows preserve their multiplicity. Contradictory duplicate records
and missing targets in complete collections raise InconsistentSnapshot.
An incomplete relation raises MissingData rather than appearing empty.

same-entity compares daemon-scoped identity. WindowLink has no stable identity
between captures, so its comparison is confined to one captured graph. A link
reference checks its expected physical window before selecting or unlinking;
renumbering between that check and the operation remains a documented race.

Window.decoded-layout parses captured layout bytes locally. Strict text access
can fail for invalid UTF-8 while bytes remains available.

=head1 Explicit commands

SessionRef.new-window and PaneRef.split/new-floating return references from the
command's declared identity projection. PaneRef.break returns the resulting
WindowRef; older profiles that omit the identity for a single-pane break use
an ID-filtered observation afterward. A new observation is acquired only by
inspect. If the source window has several placements, break requires an
explicit :from(WindowLinkRef) so tmux cannot choose which association to move.
Other mutations return a command Result. Completion means the tmux
client completed; pane input processing, rendering and child programs may
continue afterward.

WindowRef.link and WindowLinkRef.move require a destination session and index.
They return a WindowLinkRef for that placement. Moving, swapping or unlinking a
placement is separate from WindowRef.kill, which destroys the physical window
and all its links. tmux synchronizes placement changes across grouped sessions;
unlinking a placement also removes its corresponding peer placements. Physical
window linking prefers the destination session's existing source context when
the window is already present there. Link checks and mutations are separate operations;
concurrent renumbering can race between them. Cross-daemon targets are rejected.

References expose value-only options and hooks facades; SessionRef also exposes
environment. Creating these facades performs no I/O. Their get, set and other
methods explicitly acquire or mutate current configuration. See
L<LibTmux::Configuration> for typed option, environment and command-value rules.

Client.ref creates a ClientRef with the observed name bytes, PID and creation
time. inspect requires that identity to remain attached. Client commands are
inherited from L<LibTmux::Client>; client disconnection and name reuse can still
race between the identity check and the command.

Names and start directories are literal. Names that tmux would silently change
are refused, and separator support follows the daemon's capability profile.
PaneRef.set-title quotes one FORMAT expansion; tmux's title validation still
applies. The low-level command method keeps native tmux argument semantics.
Shell commands passed to creation and respawn run through tmux's shell-command
contract. PaneRef.pipe deliberately accepts tmux FORMAT and strftime syntax as
well as shell syntax. It closes an existing pipe when called without a command;
:toggle follows pipe-pane -o, which closes an already open pipe.

Literal pane input uses send-text and never appends Enter. send-keys accepts
key names and a positive :repeat. capture and capture-pending return Blob data
without text conversion or whitespace removal. copy-command sends an explicit
copy-mode command; it does not interpret arbitrary text as a key sequence.
reset queues terminal-state reset followed by history clearing without a client
roundtrip between them. It is not transactional: failure can leave partial
effects. reset-terminal only resets terminal state. Running a shell's C<reset>
program is a separate application action: send-text('reset') followed by
send-keys('Enter') requests it without promising what the pane application does.

Split dimensions use :size or :percent exclusively. Percentage splits use the
size syntax across profiles, avoiding the known percentage-flag defect. Empty
pane creation selects its documented profile encoding; empty windows require
the corresponding capability. Floating creation, movement, stacking, modal
panes and layout variants have independent capability checks. The defective
break-pane profile is refused before either named or unnamed operations.

See L<LibTmux::Server> for endpoint ownership and acquisition,
L<LibTmux::Selection> for captured collection operations, and
L<LibTmux::Transport> for Result and process cancellation contracts.
=end pod
