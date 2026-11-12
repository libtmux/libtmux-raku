use v6.d;

#| Immutable daemon evidence and catalogue policy; construction performs no I/O.
unit class LibTmux::Capabilities;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Catalogue;

#| Evidence and required handling; a repair policy never means repair ran.
class Decision {
    #| Catalogue feature, field or defect identifier used by this decision.
    has Str:D $.id is required;
    #| Whether the decision concerns a feature, field or known upstream defect.
    has Str:D $.kind = 'feature';
    #| Qualified support state; Unknown is distinct from an unsupported release.
    has SupportState:D $.state is required;
    #| Refusal, fallback or repair policy; it does not record an executed action.
    has Str:D $.handling = 'refuse';
    #| Explanation of availability, missing evidence or a blocking defect.
    has Str:D $.reason is required;
    #| Pinned upstream source supporting the policy, or empty when no rule exists.
    has Str:D $.source = '';
    #| Provenance label from the immutable daemon capability observation.
    has Str:D $.evidence = '';
    #| Explicit alternative capability identifier; empty when no fallback is declared.
    has Str:D $.fallback = '';

    #| True only for a supported feature or field, never for a known defect.
    method supported(--> Bool:D) { $!kind ne 'defect' && $!state == Supported }
    #| Whether this defect needs handling; True does not mean a repair has run.
    method applies(--> Bool:D) { $!kind eq 'defect' && $!state == Supported }
}

#| Version observed from the daemon; client version does not establish support.
has Str:D $.daemon-version = '';
#| Independently observed executable version, retained for diagnostics.
has Str:D $.client-version = '';
#| Opaque immutable identity supplied by the engine's explicit identity probe.
has Str:D $.incarnation = '';
#| How the caller acquired the daemon observation.
has Str:D $.source = 'explicit observation';
#| Flags already negotiated by an explicitly owned connection.
has List:D $.negotiated-features = ().List;

has TmuxVersion $!parsed-daemon-version;
has TmuxVersion $!parsed-client-version;
has $!catalogue;
has $!support;

submethod TWEAK() {
    $!parsed-daemon-version = parse-tmux-version($!daemon-version);
    $!parsed-client-version = parse-tmux-version($!client-version);
    $!negotiated-features = $!negotiated-features.map({ .Str }).eager.List;
    $!catalogue = catalogue();
    $!support = support-policy();
}

#| Reconstruct copies so changed observations cannot retain stale parsed evidence.
method clone(*%changes --> LibTmux::Capabilities:D) {
    my %arguments = daemon-version => $!daemon-version, client-version => $!client-version,
        incarnation => $!incarnation, source => $!source,
        negotiated-features => $!negotiated-features;
    for %changes.kv -> $name, $value {
        X::LibTmux::Decode.new(:schema<capabilities>,
            :message("Unknown capability observation field $name")).throw
            unless %arguments{$name}:exists;
        %arguments{$name} = $value;
    }
    self.WHAT.new(|%arguments)
}

#| Parsed daemon release; syntactic stability does not establish a support profile.
method parsed-daemon-version(--> TmuxVersion:D) { $!parsed-daemon-version }
#| Parsed executable release retained for diagnostics, not daemon feature decisions.
method parsed-client-version(--> TmuxVersion:D) { $!parsed-client-version }

method !profile-state(--> SupportState:D) {
    return Unknown unless $!parsed-daemon-version.stable;
    return Supported if $!support.profile($!parsed-daemon-version.release).defined;
    return NotSupported unless $!parsed-daemon-version.at-least(
        parse-tmux-version($!support.minimum));
    Unknown
}

method !profile-reason(--> Str:D) {
    return 'No daemon version was observed' unless $!daemon-version.chars;
    return "Daemon release $!daemon-version is below the declared floor {$!support.minimum}"
        if self!profile-state == NotSupported;
    "Daemon release $!daemon-version has no exact declared support profile"
}

method !decision($spec --> Decision:D) {
    my $profile-state = self!profile-state;
    return Decision.new(:id($spec.id), :kind($spec.kind), :state($profile-state),
        :handling($spec.handling), :reason(self!profile-reason),
        :source($spec.source), :evidence($!source), :fallback($spec.fallback))
        unless $profile-state == Supported;
    my $available = $spec.releases.elems
        ?? so $spec.releases.first(* eq $!parsed-daemon-version.release).defined
        !! $!parsed-daemon-version.at-least(parse-tmux-version($spec.since));
    if $available {
        for $spec.blocked-by.List -> $id {
            my $blocker = self.workaround($id);
            return Decision.new(:id($spec.id), :kind($spec.kind), :state(NotSupported),
                :handling<refuse>, :reason("Blocked by $id: {$blocker.reason}"),
                :source($blocker.source), :evidence($!source), :fallback($spec.fallback))
                if $blocker.applies;
        }
    }
    Decision.new(:id($spec.id), :kind($spec.kind),
        :state($available ?? Supported !! NotSupported),
        :handling($spec.handling), :reason($spec.reason), :source($spec.source),
        :evidence($!source), :fallback($spec.fallback))
}

#| Inspect one feature without I/O. Unknown names remain explicitly unknown.
method status(Str:D $id --> Decision:D) {
    my $spec = $!catalogue.capability($id);
    return Decision.new(:$id, :state(Unknown),
        :reason("Unknown feature $id"), :evidence($!source)) unless $spec.defined;
    self!decision($spec)
}

#| Native support only; an available fallback does not make the feature native.
method supports(Str:D $id --> Bool:D) { self.status($id).supported }

#| Require native support or throw a typed, reason-bearing refusal.
method require(Str:D $id --> Decision:D) {
    my $decision = self.status($id);
    self!refuse($decision) unless $decision.supported;
    $decision
}

method !refuse(Decision:D $decision --> Nil) {
    X::LibTmux::Unsupported.new(:feature($decision.id), :state($decision.state),
        :reason($decision.reason),
        :message("Feature {$decision.id}: {$decision.reason}")).throw
}

#| Inspect an upstream defect. applies means handling is needed, not completed.
method workaround(Str:D $id --> Decision:D) {
    my $spec = $!catalogue.workaround($id);
    return Decision.new(:$id, :kind<defect>, :state(Unknown),
        :reason("Unknown workaround $id"), :evidence($!source)) unless $spec.defined;
    self!decision($spec)
}

#| All discoverable feature decisions for this immutable observation.
method features(--> List:D) {
    $!catalogue.all-capabilities.grep(*.kind eq 'feature').map({ self!decision($_) }).List
}

#| All declared defects, including those which do not apply to this release.
method workarounds(--> List:D) {
    $!catalogue.all-capabilities.grep(*.kind eq 'defect').map({ self!decision($_) }).List
}

#| Codec identifier selected through catalogue policy: qa or t6.
method codec-profile(--> Str:D) {
    self.require('managed-commands');
    return 'qa' if self.supports('format-argument-quote');
    my $fallback = self.status('format-argument-quote').fallback;
    self.require($fallback);
    't6'
}

#| Required legacy decoding stage: vis or none. No repair has run here.
method output-repair(--> Str:D) {
    self.require('managed-commands');
    self.workaround('format-output-vis').applies ?? 'vis' !! 'none'
}

#| Default captured-layout dialect. Control negotiation remains explicit.
method layout-profile(--> Str:D) {
    self.require('managed-commands');
    return 'classic' if $!negotiated-features.first(* eq 'control-mode').defined
        && !$!negotiated-features.first(* eq 'control-new-layouts').defined;
    self.supports('layout-json') ?? 'json' !! 'classic'
}

#| Availability of a registered field, independent of acquisition completeness.
method field-status(Str:D $entity, Str:D $name --> Decision:D) {
    my $field = $!catalogue.field($entity, $name);
    my $id = "field:$entity.$name";
    return Decision.new(:$id, :kind<field>, :state(Unknown),
        :reason("Unknown field $entity.$name"), :evidence($!source)) unless $field.defined;
    my $profile-state = self!profile-state;
    return Decision.new(:$id, :kind<field>, :state($profile-state),
        :reason(self!profile-reason), :source($field.source), :evidence($!source))
        unless $profile-state == Supported;
    my $available = $!parsed-daemon-version.at-least(parse-tmux-version($field.since));
    Decision.new(:$id, :kind<field>, :state($available ?? Supported !! NotSupported),
        :reason($available ?? "Field $entity.$name is declared in this release"
            !! "Field $entity.$name requires {$field.since}"),
        :source($field.source), :evidence($!source))
}

#| Whether the observed daemon supports the registered field; unknown means False.
method supports-field(Str:D $entity, Str:D $name --> Bool:D) {
    self.field-status($entity, $name).supported
}

#| Return the supported field specification or throw Unsupported with its reason.
method require-field(Str:D $entity, Str:D $name) {
    my $decision = self.field-status($entity, $name);
    self!refuse($decision) unless $decision.supported;
    $!catalogue.field($entity, $name)
}

=begin pod
=head1 Capability observations
Construction consumes explicit observations and packaged catalogue data. It
never launches tmux. Replacing a daemon or negotiating connection flags needs
a new capability object. The engine binds these observations to actual
daemon identity; this class does not establish that identity by itself.

C<supports> and C<require> describe native features. A fallback identifies an
alternative which the caller must choose explicitly. C<workaround> describes
required handling; it never claims the repair was performed. Field support
does not mean the field was acquired or is available in every context.
=end pod
