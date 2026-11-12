use v6.d;

unit module LibTmux;

need LibTmux::Exceptions;
need LibTmux::Server;
need LibTmux::Control::Connection;
need LibTmux::Attachment;
need LibTmux::Model;
need LibTmux::Selection;
need LibTmux::Query;
need LibTmux::Query::Plan;
need LibTmux::Command;
need LibTmux::Transport;
need LibTmux::Batch;
need LibTmux::Client;
need LibTmux::Capabilities;
need LibTmux::Types;

my constant Server is export = LibTmux::Server;
my constant ControlConnection is export = LibTmux::Control::Connection;
my constant Attachment is export = LibTmux::Attachment;
my constant Snapshot is export = LibTmux::Model::Snapshot;
my constant Session is export = LibTmux::Model::Session;
my constant Window is export = LibTmux::Model::Window;
my constant WindowLink is export = LibTmux::Model::WindowLink;
my constant Pane is export = LibTmux::Model::Pane;
my constant Client is export = LibTmux::Model::Client;
my constant SessionGroup is export = LibTmux::Model::SessionGroup;
my constant Buffer is export = LibTmux::Model::Buffer;
my constant SessionRef is export = LibTmux::Model::SessionRef;
my constant WindowRef is export = LibTmux::Model::WindowRef;
my constant WindowLinkRef is export = LibTmux::Model::WindowLinkRef;
my constant PaneRef is export = LibTmux::Model::PaneRef;
my constant ClientRef is export = LibTmux::Model::ClientRef;
my constant SessionSelection is export = LibTmux::Model::SessionSelection;
my constant WindowSelection is export = LibTmux::Model::WindowSelection;
my constant WindowLinkSelection is export = LibTmux::Model::WindowLinkSelection;
my constant PaneSelection is export = LibTmux::Model::PaneSelection;
my constant ClientSelection is export = LibTmux::Model::ClientSelection;
my constant SessionGroupSelection is export = LibTmux::Model::SessionGroupSelection;
my constant BufferSelection is export = LibTmux::Model::BufferSelection;
my constant Selection is export = LibTmux::Selection::Selection;
my constant Filter is export = LibTmux::Query::Filter;
my constant QueryLimits is export = LibTmux::Query::Limits;
my constant QueryPlan is export = LibTmux::Query::Plan::Plan;
my constant Invocation is export = LibTmux::Command::Invocation;
my constant Cancellation is export = LibTmux::Transport::Cancellation;
my constant CommandResult is export = LibTmux::Transport::Result;
my constant Batch is export = LibTmux::Batch::Batch;
my constant Operation is export = LibTmux::Batch::Operation;
my constant Evidence is export = LibTmux::Batch::Evidence;
my constant BatchReport is export = LibTmux::Batch::Report;
my constant OperationResult is export = LibTmux::Batch::OperationResult;
my constant MenuItem is export = LibTmux::Client::MenuItem;
my constant CommandTemplate is export = LibTmux::Client::CommandTemplate;
my constant Capabilities is export = LibTmux::Capabilities;
my constant SessionId is export = LibTmux::Types::SessionId;
my constant WindowId is export = LibTmux::Types::WindowId;
my constant PaneId is export = LibTmux::Types::PaneId;
my constant Count is export = LibTmux::Types::Count;
my constant Positive is export = LibTmux::Types::Positive;
my constant ValueState is export = LibTmux::Types::ValueState;
my constant SupportState is export = LibTmux::Types::SupportState;
my constant Outcome is export = LibTmux::Types::Outcome;
my constant Present is export = LibTmux::Types::Present;
my constant KnownNull is export = LibTmux::Types::KnownNull;
my constant Unsupported is export = LibTmux::Types::Unsupported;
my constant Unavailable is export = LibTmux::Types::Unavailable;
my constant Unloaded is export = LibTmux::Types::Unloaded;
my constant Supported is export = LibTmux::Types::Supported;
my constant NotSupported is export = LibTmux::Types::NotSupported;
my constant Unknown is export = LibTmux::Types::Unknown;
my constant NotStarted is export = LibTmux::Types::NotStarted;
my constant Complete is export = LibTmux::Types::Complete;
my constant Failed is export = LibTmux::Types::Failed;
my constant Skipped is export = LibTmux::Types::Skipped;
my constant Indeterminate is export = LibTmux::Types::Indeterminate;

=begin pod
=NAME LibTmux
=DESCRIPTION
Typed tmux snapshots, local selections and explicit commands for Raku programs.

=head1 Create an observatory

L<Server|LibTmux::Server> starts and owns a private daemon. Split the first pane,
label the instruments, then capture the new state. C<LEAVE> closes the owner on
normal or exceptional exit.

=comment runs: examples/quickstart.raku

=begin code :lang<raku>
use LibTmux;

my $server = Server.start(:name<observatory>, :shell-command('exec cat'));
LEAVE $server.close if $server.defined;

my $before = $server.snapshot;
my $left = $before.panes.single.ref;
my $right = $left.split(:horizontal, :shell-command('exec cat'));
$left.set-title('Starlight telescope');
$right.set-title('Orion weather');

my $after = $server.snapshot;
my $telescope = $after.panes.filter(*.title.starts-with('Starlight')).single;
say "{$telescope.title}: {$after.panes.elems} panes";
=end code

The program prints C<Starlight telescope: 2 panes>. The earlier snapshot retains
one pane. C<.ref> constructs an explicit command target; mutation does not change
an earlier observation. C<snapshot> performs I/O, while reading a captured field
or relationship stays local.

=head1 Follow the captured graph

A L<Snapshot|LibTmux::Model::Snapshot> contains sessions, session groups, physical
windows, window links, panes, clients and buffer metadata. A physical window can
appear at several indexes, including twice in the same session. Its
C<WindowLink> owns the session-relative index and active state. C<windows> and
C<panes> enumerate physical identities once; C<window-links> preserves placements.

A pane's C<window> and a window's C<panes> resolve against the retained graph.
Keeping an observation after closing its acquisition owner remains useful:
field reads, relationship traversal and selection operations make no tmux calls.
Use C<.ref.inspect> or a new snapshot when fresh information is needed.
References include daemon incarnation evidence, so a replacement daemon does
not inherit an old pane reference merely by reusing its ID.

=head1 Query captured values

Combine validated query data with native Raku predicates and transformations:

=comment runs: examples/query-panes.raku

=begin code :lang<raku>
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<instruments>,
        :width(160), :height(40), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $telescope = $server.snapshot.panes.single.ref;
    my $weather = $telescope.split(:horizontal, :shell-command('exec cat'));
    my $recorder = $weather.split(:shell-command('exec cat'));
    $telescope.set-title('Starlight telescope');
    $weather.set-title('Orion weather');
    $recorder.set-title('Spectrum recorder');

    my $snapshot = $server.snapshot;
    my @wide := $snapshot.panes.where(%(width => %(gte => 60)));
    my $selected = @wide.filter(*.title.ends-with('telescope')).single;
    say "Wide telescope: {$selected.title}";

    my @others = $snapshot.panes.grep(*.id ne $selected.id).map(*.title).sort;
    say 'Other instruments: ' ~ @others.join(', ');
}
=end code

It prints C<Wide telescope: Starlight telescope> and
C<Other instruments: Orion weather, Spectrum recorder>.

Binding with C<:=> preserves a typed selection. Array assignment materializes
ordinary Raku values; scalar assignment itemizes the collection. C<where>
validates fields and operators even on an empty selection. C<filter> evaluates a
callback eagerly and returns the same entity selection type. C<grep>, including
C<:k>, C<:kv> and C<:p>, retains its native C<Seq> contract. C<map>, C<sort>,
C<first> and junction operations also retain ordinary Raku behavior. Mapping
panes to titles does not produce a pane selection of strings.

Use C<single> for exactly one member and C<single-or-nil> for zero or one;
multiple matches throw L<Cardinality|X::LibTmux::Cardinality>. C<one> remains a
junction. A directly returned C<Failure> from a C<filter> callback throws its
wrapped exception before Boolean coercion.

Compile reusable criteria with L<Filter|LibTmux::Query::Filter>. Its C<ACCEPTS>
method permits native matching, and C<to-json>/C<from-json> preserve the bounded
portable data grammar. Closures, regexes and junctions remain local Raku
matchers. Data equality follows field types; it does not use generic smartmatch.
Relations use C<some>, C<every>, C<none>, C<is> and C<is-not>. An unloaded
relation raises L<MissingData|X::LibTmux::MissingData> instead of behaving like
an empty relation.

For explicit live acquisition, C<query-panes> accepts C<where> and a pushdown
policy. C<auto> pushes proven exact restrictions and evaluates residual work
locally; C<never> evaluates locally after acquisition; C<require> refuses an
inexact translation. C<explain-panes> describes projections, scope, pushed
conditions and residual work. Arbitrary callbacks are not translated to tmux.

=head1 Choose an operation from capabilities

Capabilities describe the observed daemon separately from the client executable.
Ask C<supports> before offering a newer operation, or use C<require> to obtain a
typed refusal with its reason. This program gives Aurora telemetry a floating
pane when supported and a tiled split otherwise:

=comment runs: examples/floating-panes.raku

=begin code :lang<raku>
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<flight-deck>,
        :width(120), :height(36), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $snapshot = $server.snapshot;
    my $main = $snapshot.panes.single.ref;
    my $floating = $snapshot.capabilities.supports('pane-floating');
    my $auxiliary = $floating
        ?? $main.new-floating(:width(40), :height(12), :x(2), :y(2), :empty)
        !! $main.split(:horizontal, :empty);
    $auxiliary.set-title('Aurora telemetry');

    my $after = $server.snapshot;
    die 'The auxiliary pane was not captured' unless $after.panes.elems == 2;
    say 'Telemetry placement: ' ~ ($floating ?? 'floating' !! 'tiled');
    say $after.panes.where(%(id => $auxiliary.id)).single.title;
}
=end code

The selected placement and C<Aurora telemetry> are printed. An empty pane can
have no child PID; its C<pid> is then null rather than a fabricated integer.
C<state('pid')> distinguishes known null from a field that was not acquired.
Unknown release profiles are refused conservatively. Field, codec, layout and
command decisions come from the same packaged catalogue.

=head1 React to terminal output

Synchronous acquisition returns a snapshot or selection. An C<-async> method
returns a C<Promise> resolving to that result. A
L<ControlConnection|LibTmux::Control::Connection> owns one persistent client;
its event C<Supply> is shared by its subscribers. Native C<react> and C<whenever>
can consume the output without polling:

=comment runs: examples/watch-output.raku

=begin code :lang<raku>
use v6.d;
use LibTmux;
use LibTmux::Control;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<downlink>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $snapshot = await $server.snapshot-async;
    my $pane = $snapshot.panes.single.ref;
    my $connection = await $server.open-control-async(:session-id($snapshot.sessions.single.id));
    LEAVE $connection.close if $connection.defined;

    my $message = 'Starlight downlink: 42 stars catalogued';
    my $received = '';
    react {
        whenever $connection.events.grep(PaneOutput) -> $event {
            if $event.pane-id eq $pane.id {
                $received ~= $event.data.decode('utf8-c8');
                die 'Downlink output exceeded its bound' if $received.chars > 65536;
                done if $received.contains($message);
            }
        }
        whenever start { $pane.send-text($message); $pane.send-keys('Enter') } { }
        whenever Promise.in(2) { die 'Downlink timed out' }
    }

    die 'The captured screen did not contain the downlink'
        unless $pane.capture.decode('utf8').contains($message);
    say $message;
    say 'Screen capture confirmed';
}
=end code

It prints C<Starlight downlink: 42 stars catalogued> and C<Screen capture confirmed>.
Subscribing precedes input. Received pane bytes establish the screen-capture
precondition; the deadline bounds the wait. C<send-text> never appends Enter.
Output remains bytes until an explicit decoder is selected, so fragmented and
invalid UTF-8 remains available. Unknown notification types retain their raw
representation.

Connections need explicit close. Cancellation terminates and joins owned client
work, but does not undo commands that the daemon already executed. Reconnection
requires a fresh observation; event delivery does not imply a complete current
graph. L<Attachment|LibTmux::Attachment> is a separate terminal client owner.

=head1 Recover from partial completion

L<Batch|LibTmux::Batch::Batch> reports each operation's completion scope and
outcome. The
L<batch recovery program|https://github.com/libtmux/libtmux-raku/blob/master/examples/batch-recovery.raku>
checks C<Complete>, C<Failed> and C<Skipped>, verifies the successful first
effect, then removes it explicitly. Acknowledgement alone does not prove an
application effect. A failed batch offers no rollback guarantee.

The
L<observatory program|https://github.com/libtmux/libtmux-raku/blob/master/examples/observatory.raku>
combines creation, a control-output subscription, screen capture, local
filtering and an explained source query in one checked lifecycle.

=head1 Ownership and operational errors

C<Server.start> owns its private daemon. C<Server.new> configures a borrowed
endpoint; closing that facade leaves the daemon running. Both need explicit
close. A connection or terminal attachment has its own lifetime and must also
be closed. An observation retains values and the captured graph, not a live
acquisition process.

Commands pass an argument vector. Literal pane text, explicit key presses,
FORMAT expressions, tmux command templates and deliberate shell commands have
separate entry points. Operational errors retain typed context and captured
bytes. Optional lookup absence never disguises a failed command. Fields retain
known null, false, zero, empty text, unsupported, unavailable and unloaded data
as distinct states.
=end pod
