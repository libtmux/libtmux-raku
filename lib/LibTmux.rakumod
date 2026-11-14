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

=head1 Create a session and split a pane

L<Server|LibTmux::Server> starts and owns a private daemon. This program splits
the first pane and titles both; each runs C<cat>. C<LEAVE> closes the owner on
any exit.

=comment runs: examples/quickstart.raku

=begin code :lang<raku>
use LibTmux;

my $server = Server.start(:name<work>, :shell-command('exec cat'));
LEAVE $server.close if $server.defined;

my $before = $server.snapshot;
my $left = $before.panes.single.ref;
my $right = $left.split(:horizontal, :shell-command('exec cat'));
$left.set-title('editor');
$right.set-title('logs');

my $after = $server.snapshot;
my $editor = $after.panes.filter(*.title eq 'editor').single;
say "{$editor.title}: {$after.panes.elems} panes";
=end code

It prints C<editor: 2 panes>.

=item The earlier snapshot still has one pane: mutation does not change an
observation.
=item C<.ref> builds a command target. C<snapshot> performs I/O; reading a
captured field or relationship stays local.

=head1 Follow the captured graph

A L<Snapshot|LibTmux::Model::Snapshot> holds sessions, session groups, physical
windows, window links, panes, clients and buffer metadata.

=item A physical window can appear at several indexes, even twice in one
session. Its C<WindowLink> owns the session-relative index and active state.
=item C<windows> and C<panes> list each physical identity once; C<window-links>
keeps every placement.
=item A pane's C<window> and a window's C<panes> resolve inside the snapshot.
Field reads, traversal and selection make no tmux calls, even after the
acquisition owner closes. Use C<.ref.inspect> or a new snapshot for fresh data.
=item References carry daemon incarnation evidence, so a replacement daemon that
reuses an ID does not inherit an old pane reference.

=head1 Query captured values

Combine validated query data with native Raku predicates and transformations:

=comment runs: examples/query-panes.raku

=begin code :lang<raku>
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>,
        :width(160), :height(40), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $editor = $server.snapshot.panes.single.ref;
    my $tests = $editor.split(:horizontal, :shell-command('exec cat'));
    my $logs = $tests.split(:shell-command('exec cat'));
    $editor.set-title('editor');
    $tests.set-title('tests');
    $logs.set-title('logs');

    my $snapshot = $server.snapshot;
    my @wide := $snapshot.panes.where(%(width => %(gte => 60)));
    my $selected = @wide.filter(*.title eq 'editor').single;
    say "Wide pane: {$selected.title}";

    my @others = $snapshot.panes.grep(*.id ne $selected.id).map(*.title).sort;
    say 'Other panes: ' ~ @others.join(', ');
}
=end code

It prints C<Wide pane: editor> and
C<Other panes: logs, tests>.

=item Bind with C<:=> to keep a typed selection. Array assignment copies
ordinary Raku values; scalar assignment itemizes the collection.
=item C<where> validates fields and operators even on an empty selection.
=item C<filter> runs its callback eagerly and returns the same selection type.
A C<Failure> returned directly from the callback throws its wrapped exception
before Boolean coercion.
=item C<grep> (including C<:k>, C<:kv> and C<:p>) returns a native C<Seq>.
C<map>, C<sort>, C<first> and junctions keep plain Raku behavior; mapping panes
to titles gives strings, not a selection.
=item C<single> wants exactly one member and C<single-or-nil> allows none.
Several matches throw L<Cardinality|X::LibTmux::Cardinality>. C<one> stays a
junction.

Compile reusable criteria with L<Filter|LibTmux::Query::Filter>:

=item C<ACCEPTS> permits native matching; C<to-json> and C<from-json> keep the
bounded portable data grammar.
=item Closures, regexes and junctions stay local Raku matchers. Data equality
follows field types, not generic smartmatch.
=item Relations use C<some>, C<every>, C<none>, C<is> and C<is-not>. An unloaded
relation raises L<MissingData|X::LibTmux::MissingData> instead of acting like an
empty one.

=head1 Choose where a query runs

C<query-panes> takes C<where> and a C<pushdown> policy:

=item C<auto> has tmux apply the restrictions it can match exactly and checks
the rest locally.
=item C<never> evaluates locally after acquisition.
=item C<require> refuses a query that cannot run exactly in tmux.

C<explain-panes> describes projections, scope, pushed conditions and residual
work. Arbitrary callbacks are never translated to tmux.

=comment runs: examples/explain-query.raku

=begin code :lang<raku>
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    $server.snapshot.panes.single.ref.set-title('editor');

    my %wide = width => %(gte => 60);
    my %titled = AND => [%wide, %(title => %(contains => 'edit'))];

    say 'width: fully pushed = ' ~ $server.explain-panes(:where(%wide)).fully-pushed;
    my $plan = $server.explain-panes(:where(%titled));
    say 'width and title: fully pushed = ' ~ $plan.fully-pushed;
    say 'tmux filter: ' ~ $plan.source-filter;

    say 'Matches: ' ~ $server.query-panes(:where(%titled)).map(*.title).join(', ');
    try {
        $server.query-panes(:where(%titled), :pushdown<require>);
        CATCH { when X::LibTmux::Unsupported { say 'require: refused, title stays local' } }
    }
}
=end code

It prints whether each query is fully pushed to tmux, the filter tmux gets, the
match, and the refusal.

=head1 Choose an operation from capabilities

Capabilities describe the daemon, not the client executable. Ask C<supports>
before offering a newer operation, or call C<require> for a typed refusal with
its reason. This program creates an empty C<status> pane, floating when
supported and tiled otherwise:

=comment runs: examples/floating-panes.raku

=begin code :lang<raku>
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>,
        :width(120), :height(36), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $snapshot = $server.snapshot;
    my $main = $snapshot.panes.single.ref;
    my $floating = $snapshot.capabilities.supports('pane-floating');
    my $auxiliary = $floating
        ?? $main.new-floating(:width(40), :height(12), :x(2), :y(2), :empty)
        !! $main.split(:horizontal, :empty);
    $auxiliary.set-title('status');

    my $after = $server.snapshot;
    die 'The auxiliary pane was not captured' unless $after.panes.elems == 2;
    say 'Status pane: ' ~ ($floating ?? 'floating' !! 'tiled');
    say $after.panes.where(%(id => $auxiliary.id)).single.title;
}
=end code

It prints the placement, then C<status>.

=item An empty pane can have no child PID. Its C<pid> is then null, not a made-up
integer; C<state('pid')> tells known null from a field that was not acquired.
=item Unknown tmux releases are refused. Field, codec, layout and command
decisions come from one packaged catalogue.

=head1 React to terminal output

An C<-async> method returns a C<Promise> of the same result. A
L<ControlConnection|LibTmux::Control::Connection> owns one persistent client;
its event C<Supply> is shared by subscribers. Native C<react> and C<whenever>
consume output without polling:

=comment runs: examples/watch-output.raku

=begin code :lang<raku>
use v6.d;
use LibTmux;
use LibTmux::Control;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<output>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $snapshot = await $server.snapshot-async;
    my $pane = $snapshot.panes.single.ref;
    my $connection = await $server.open-control-async(:session-id($snapshot.sessions.single.id));
    LEAVE $connection.close if $connection.defined;

    my $message = 'hello from Raku';
    my $received = '';
    react {
        whenever $connection.events.grep(PaneOutput) -> $event {
            if $event.pane-id eq $pane.id {
                $received ~= $event.data.decode('utf8-c8');
                die 'Pane output exceeded its bound' if $received.chars > 65536;
                done if $received.contains($message);
            }
        }
        whenever start { $pane.send-text($message); $pane.send-keys('Enter') } { }
        whenever Promise.in(2) { die 'Pane output timed out' }
    }

    die 'The captured screen did not contain the message'
        unless $pane.capture.decode('utf8').contains($message);
    say $message;
    say 'Screen capture confirmed';
}
=end code

It prints C<hello from Raku> and C<Screen capture confirmed>.

=item Subscribe before sending input; the deadline bounds the wait.
=item C<send-text> never appends Enter.
=item Output stays bytes until you pick a decoder, so fragmented or invalid
UTF-8 survives. Unknown notification types keep their raw form.

Close each connection:

=item Cancellation stops and joins owned client work. It does not undo commands
the daemon already ran.
=item After reconnecting, take a fresh observation; events do not add up to a
complete current graph.
=item L<Attachment|LibTmux::Attachment> is a separate terminal client owner.

=head1 Recover from partial completion

L<Batch|LibTmux::Batch::Batch> reports each operation's completion scope and
outcome. The
L<batch recovery program|https://github.com/libtmux/libtmux-raku/blob/master/examples/batch-recovery.raku>
shows C<Complete>, C<Failed> and C<Skipped>, then removes the first effect
itself. Acknowledgement alone does not prove an application effect, and a failed
batch is not rolled back.

The
L<session workflow program|https://github.com/libtmux/libtmux-raku/blob/master/examples/session-workflow.raku>
combines creation, control output, capture, local filtering and an explained
source query.

=head1 Ownership and operational errors

=item C<Server.start> owns its private daemon. C<Server.new> configures a
borrowed endpoint; closing that facade leaves the daemon running. Close both.
=item A connection or terminal attachment has its own lifetime; close it too.
=item An observation keeps values and the captured graph, not a live
acquisition process.
=item Commands pass an argument vector. Literal pane text, key presses, FORMAT
expressions, tmux command templates and deliberate shell commands have separate
entry points.
=item Errors keep typed context and captured bytes. A missing optional lookup
never disguises a failed command.
=item Fields keep known null, false, zero, empty text, unsupported, unavailable
and unloaded data as distinct states.
=end pod
