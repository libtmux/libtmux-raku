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
Typed tmux snapshots, local selections and explicit lifecycle owners.

=head1 Start with an owned daemon

Run C<examples/observatory.raku> for a complete checked lifecycle, control-output,
screen-capture and query example. C<examples/batch-recovery.raku> checks partial
command outcomes and explicit recovery. Both examples own and verify cleanup of
their clients, daemon and socket directory.

C<Server.start> owns a new daemon; C<Server.new> captures a borrowed endpoint
without starting one. Both require explicit close. A L<Snapshot|LibTmux::Model::Snapshot>
is captured data: its properties, relations and selections perform no I/O.
References perform explicit commands and leave earlier observations unchanged.

=head1 Query captured values

Binding preserves the typed selection. Array assignment materializes ordinary
Raku values; scalar assignment itemizes the collection. C<where> accepts query
data or a L<Filter|LibTmux::Query::Filter>; C<filter> preserves selection type.
C<grep>, C<map>, C<sort>, C<first> and junction operations retain native Raku
behavior. Use C<single> or C<single-or-nil> for cardinality.

=head1 Effects and ownership

L<ControlConnection|LibTmux::Control::Connection> and
L<Attachment|LibTmux::Attachment> are separate explicit owners. A control
Supply shares its connection; opening another tap does not start another
process. L<Batch|LibTmux::Batch::Batch> reports per-operation completion scope
and partial outcomes. Command acknowledgement alone is not effect evidence.

Literal pane text does not append Enter. Shell commands, tmux command templates
and FORMAT expressions use separately named entry points. Exceptions preserve
operational failures; optional absence never hides a command error.
=end pod
