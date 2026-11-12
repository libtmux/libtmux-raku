use v6.d;

unit module LibTmux::Types;

#| A session identifier's spelling; existence and daemon ownership are separate.
subset SessionId of Str:D is export where /^ '$' <[0..9]>+ $/;
#| A physical window identifier. An index in a session is a different value.
subset WindowId of Str:D is export where /^ '@' <[0..9]>+ $/;
#| A pane identifier scoped to a captured daemon incarnation.
subset PaneId of Str:D is export where /^ '%' <[0..9]>+ $/;
#| A nonnegative count or dimension. Bool is deliberately not a number here.
subset Count of Int:D is export where { $_ !~~ Bool && $_ >= 0 };
#| A positive dimension or resource limit.
subset Positive of Int:D is export where { $_ !~~ Bool && $_ > 0 };

#| Availability states preserve absence without conflating false, zero or empty text.
enum ValueState is export <Present KnownNull Unsupported Unavailable Unloaded>;
#| Capability evidence never treats an unprobed feature as supported.
enum SupportState is export <Supported NotSupported Unknown>;
#| What the caller knows about an operation's effects.
enum Outcome is export <NotStarted Complete Failed Skipped Indeterminate>;

=begin pod
=head1 Identifiers and states

IDs validate ASCII spelling only. Store daemon identity separately and check
it before operations. WindowLink identity additionally includes session/index;
an observed index is not a permanent link identifier.

ValueState describes field availability. KnownNull is domain absence;
Unloaded means acquisition omitted data, and Unavailable means the selected
acquisition context cannot supply it. Unsupported is a capability refusal.
None of these states is encoded as an empty string or numeric zero.
=end pod
