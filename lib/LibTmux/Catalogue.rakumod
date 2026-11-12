use v6.d;

#| Packaged, source-qualified fields, relationships, options and release profiles.
unit module LibTmux::Catalogue;

use JSON::Fast;
use LibTmux::Exceptions;

#| Parsed release spelling; an exact release can still lack a support profile.
class TmuxVersion is export {
    #| Original input, including any executable banner or unqualified suffix.
    has Str:D $.raw is required;
    #| Release spelling without the optional tmux prefix; empty when unqualified.
    has Str:D $.release = '';
    #| Whether the spelling is a stable release, independent of supported versions.
    has Bool:D $.stable = False;
    #| Numeric major component; zero for an unqualified spelling.
    has Int:D $.major = 0;
    #| Numeric minor component; zero for an unqualified spelling.
    has Int:D $.minor = 0;
    #| Lowercase patch-release letter, or empty for a plain or unqualified release.
    has Str:D $.suffix = '';

    #| Compare stable release components, including tmux's letter suffix.
    method at-least(TmuxVersion:D $other --> Bool:D) {
        return False unless $!stable && $other.stable;
        for ($!major, $!minor, $!suffix.chars ?? $!suffix.ord !! 0)
            Z ($other.major, $other.minor, $other.suffix.chars ?? $other.suffix.ord !! 0)
            -> ($left, $right) {
            return True if $left > $right;
            return False if $left < $right;
        }
        True
    }
}

#| Preserve the raw string and reject vendor/development suffixes as unqualified.
sub parse-tmux-version(Str:D $raw --> TmuxVersion:D) is export {
    my $match = $raw.trim ~~ /^ [ 'tmux' \s+ ]?
        $<major>=<[0..9]>+ '.' $<minor>=<[0..9]>+ $<suffix>=<[a..z]>? $/;
    return TmuxVersion.new(:$raw) unless $match;
    my $suffix = ~$match<suffix>;
    my $release = ~$match<major> ~ '.' ~ ~$match<minor> ~ $suffix;
    TmuxVersion.new(:$raw, :$release, :stable,
        :major(+$match<major>), :minor(+$match<minor>), :$suffix)
}

#| Immutable source identity for one explicitly supported tmux release.
class ReleaseProfile {
    has Str:D $.version is required;
    has Str:D $.commit is required;
    #| Immutable upstream tree for this release's pinned commit.
    method source(--> Str:D) { 'https://github.com/tmux/tmux/tree/' ~ $!commit }
}

#| One field's acquisition, decoding and portable-query contract.
class FieldSpec {
    has Str:D $.entity is required;
    has Str:D $.name is required;
    has Str:D $.wire-name is required;
    has Str:D $.format is required;
    has Str:D $.context is required;
    has Str:D $.kind is required;
    has Bool:D $.nullable is required;
    has Str:D $.decoder is required;
    has List:D $.operators is required;
    has List:D $.pushdown is required;
    has Int $.pushdown-minimum;
    has Int $.pushdown-maximum;
    has Str:D $.pushdown-source = '';
    has Str:D $.since is required;
    has Str:D $.source is required;
    has Str:D $.null-when = '';
    has Str:D $.null-dependency = '';
}

#| A local graph relationship with an explicit multiplicity and target schema.
class RelationSpec {
    has Str:D $.entity is required;
    has Str:D $.name is required;
    has Str:D $.wire-name is required;
    has Str:D $.target is required;
    has Str:D $.cardinality is required;
    has Bool:D $.nullable is required;
}

#| Availability or a known upstream defect; handling is a policy, not an effect.
class CapabilitySpec {
    has Str:D $.id is required;
    has Str:D $.name is required;
    has Str:D $.kind is required;
    has Str:D $.handling is required;
    has Str:D $.reason is required;
    has Str:D $.source is required;
    has Str:D $.since is required;
    has List:D $.releases is required;
    has List:D $.commands is required;
    has List:D $.blocked-by = ().List;
    has Str:D $.fallback = '';
}

#| One source-qualified option type, scope and operand range.
class OptionSpec {
    #| Native option name, without an array index.
    has Str:D $.name is required;
    #| Native operand category used by typed option validation and decoding.
    has Str:D $.kind is required;
    #| First declared support profile using this exact option variant.
    has Str:D $.since is required;
    #| Exclusive ending profile; empty when this variant has no declared end.
    has Str:D $.before = '';
    #| Pinned options-table.c source from which this variant was extracted.
    has Str:D $.source is required;
    #| Permitted server, session, window or pane scopes; membership is read-only.
    has List:D $.scopes is required;
    #| Closed native choice vocabulary; empty for other operand categories.
    has List:D $.choices = ().List;
    #| Whether callers must address individual numeric array elements.
    has Bool:D $.is-array = False;
    #| Whether the option stores hook command lists.
    has Bool:D $.is-hook = False;
    #| Whether string values use tmux style syntax.
    has Bool:D $.is-style = False;
    #| Lowest accepted integer in the option's native units; undefined outside numeric schemas.
    has Int $.minimum;
    #| Highest accepted integer in the option's native units; undefined outside numeric schemas.
    has Int $.maximum;
}

sub invalid(Str:D $message --> Nil) {
    X::LibTmux::Decode.new(:$message, :schema<catalogue>).throw
}

sub text-value($value, Str:D $label --> Str:D) {
    invalid("$label must be nonempty text") unless $value ~~ Str:D && $value.chars;
    $value.Str
}

sub string-list($value, Str:D $label --> List:D) {
    invalid("$label must be an array") unless $value ~~ Array:D;
    $value.map({ text-value($_, $label) }).eager.List
}

sub read-resource(Str:D $name --> Hash:D) {
    my $resource = %?RESOURCES{$name};
    invalid("Missing distribution resource $name") unless $resource.defined;
    my $bytes = $resource.slurp(:bin);
    invalid("Oversized distribution resource $name") if $bytes.elems > 1024 * 1024;
    my $data = from-json($bytes.decode('utf8'));
    invalid("Resource $name must contain an object") unless $data ~~ Hash:D;
    $data
}

#| Ordered release profiles are the sole source of the floor and CI endpoints.
class SupportPolicy {
    #| Read-only profiles in strictly increasing release order, each with pinned source identity.
    has List:D $.releases is required;

    #| Oldest declared supported release; no older compatibility is inferred.
    method minimum(--> Str:D) { $!releases[0].version }
    #| Newest declared supported release, independent of unqualified future releases.
    method latest(--> Str:D) { $!releases[*-1].version }
    #| Exact declared profile, or Nil for an undeclared spelling.
    method profile(Str:D $version) { $!releases.first(*.version eq $version) }
    #| Oldest and newest profiles for required CI, deduplicated for a single release.
    method endpoints(--> List:D) {
        $!releases.elems == 1 ?? ($!releases[0],).List
            !! ($!releases[0], $!releases[*-1]).List
    }
}

sub build-support-policy(--> SupportPolicy:D) {
    my @pins =
        '3.3a' => '0b355ae8114511e1ff6359272b164f1cdf718e80',
        '3.4' => '9ae69c3795ab5ef6b4d760f6398cd9281151f632',
        '3.5' => 'ac44566c9c7e3e94d23be6def4c7ae83472543f5',
        '3.5a' => '549c35b06165f6ae023115eb76f83f2cbf945395',
        '3.6' => '0dac7fe434d029a4f0b819cba8eb7963df291990',
        '3.6a' => 'cc117b5048f77a4842820f8ebbe3a86e5c077224',
        '3.6b' => '0623d1e968423ad0c192e0d8debf1258671063d5',
        '3.7' => '81f88f8517c9fc5371b56cf117530c6b477c96ac',
        '3.7a' => '0e418b62d259ce8da8970f75732cc6632ee4c3a0',
        '3.7b' => 'e802909de06012a4df6209d55e86487c56223163',
        '3.7c' => 'e476c1230b958df0cb12977517d24b3dc931375b',
        '3.8' => '7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53';
    my @releases;
    my TmuxVersion $previous;
    for @pins -> $pin {
        my Str $version = $pin.key;
        my Str $commit = $pin.value;
        my $parsed = parse-tmux-version($version);
        invalid("Unstable support release $version") unless $parsed.stable;
        invalid('Support releases must be strictly increasing')
            if $previous.defined && $previous.at-least($parsed);
        invalid('Invalid source commit') unless $commit ~~ /^ <[0..9a..f]> ** 40 $/;
        @releases.push(ReleaseProfile.new(:$version, :$commit));
        $previous = $parsed;
    }
    SupportPolicy.new(:releases(@releases.map({ $_<> }).List))
}

#| Return the immutable release policy without reading configuration or contacting tmux.
sub support-policy(--> SupportPolicy:D) is export {
    state SupportPolicy $policy = build-support-policy();
    $policy
}

#| Typed schema lookup used by acquisition, local criteria and documentation.
class CatalogueData {
    #| Read-only field records across all registered entity schemas.
    has List:D $.all-fields is required;
    #| Read-only graph relation records, independent of snapshot completeness.
    has List:D $.all-relations is required;
    #| Read-only feature and defect policies with upstream provenance.
    has List:D $.all-capabilities is required;
    #| All option variants; use options(release) to select a qualified profile.
    has List:D $.all-options is required;

    #| Registered schema names in catalogue order, without duplicates.
    method entities(--> List:D) { $!all-fields.map(*.entity).unique.List }
    #| Whether a schema is registered, without inspecting any captured entities.
    method has-entity(Str:D $entity --> Bool:D) {
        so $!all-fields.first(*.entity eq $entity).defined
    }
    #| Registered field records; an unknown entity schema throws InvalidFilter.
    method fields(Str:D $entity --> List:D) {
        self!require-entity($entity);
        $!all-fields.grep(*.entity eq $entity).List
    }
    #| Registered relation records; an unknown entity schema throws InvalidFilter.
    method relations(Str:D $entity --> List:D) {
        self!require-entity($entity);
        $!all-relations.grep(*.entity eq $entity).List
    }
    #| One field record or Nil; an unknown entity schema throws InvalidFilter.
    method field(Str:D $entity, Str:D $name) {
        self!require-entity($entity);
        $!all-fields.first({ .entity eq $entity && .name eq $name })
    }
    #| One relation record or Nil; an unknown entity schema throws InvalidFilter.
    method relation(Str:D $entity, Str:D $name) {
        self!require-entity($entity);
        $!all-relations.first({ .entity eq $entity && .name eq $name })
    }
    #| Feature policy or Nil; defect identifiers belong to workaround.
    method capability(Str:D $id) {
        $!all-capabilities.first({ .kind eq 'feature' && .id eq $id })
    }
    #| Defect policy or Nil, without claiming that handling has occurred.
    method workaround(Str:D $id) {
        $!all-capabilities.first({ .kind eq 'defect' && .id eq $id })
    }
    #| Active option variants for an exact support profile; empty for an unqualified release.
    method options(Str:D $release --> List:D) {
        return ().List unless support-policy().profile($release).defined;
        my $version = parse-tmux-version($release);
        $!all-options.grep({
            $version.at-least(parse-tmux-version(.since))
                && (!.before.chars || !$version.at-least(parse-tmux-version(.before)))
        }).List
    }
    #| One active option variant, or Nil for an unknown option or unqualified release.
    method option(Str:D $name, Str:D $release) {
        return Nil unless support-policy().profile($release).defined;
        my $version = parse-tmux-version($release);
        $!all-options.first({
            .name eq $name && $version.at-least(parse-tmux-version(.since))
                && (!.before.chars || !$version.at-least(parse-tmux-version(.before)))
        })
    }
    method !require-entity(Str:D $entity --> Nil) {
        X::LibTmux::InvalidFilter.new(:path($entity),
            :message("Unknown entity schema $entity")).throw unless self.has-entity($entity);
        Nil
    }
}

sub load-catalogue(--> CatalogueData:D) {
    my $raw = read-resource('catalogue.json');
    my $support = support-policy();
    invalid('Unexpected catalogue schema') unless $raw<schema> eq 'libtmux.catalogue/v1';
    my @fields; my @relations; my @capabilities; my @options; my %names; my %wires;
    for <fields relations capabilities options> -> $key {
        invalid("Catalogue $key must be an array") unless $raw{$key} ~~ Array:D;
    }
    for $raw<fields>.List -> $row {
        my %copy;
        for <entity name wire-name format context kind decoder source> -> $key {
            %copy{$key} = text-value($row{$key}, "field $key");
        }
        invalid('Invalid field scalar kind') unless %copy<kind>
            eq any(<text uint int bool session-id window-id pane-id>);
        invalid('Invalid field context') unless %copy<context>
            eq any(<session window-link window pane client grouped-session buffer key-binding>);
        invalid('Field decoder disagrees with kind') unless %copy<decoder> eq %copy<kind>;
        invalid('Field nullability must be Boolean') unless $row<nullable> ~~ Bool:D;
        my $key = %copy<entity> ~ '.' ~ %copy<name>;
        my $wire = %copy<entity> ~ '.' ~ %copy<wire-name>;
        invalid("Duplicate field $key") if %names{$key}++ || %wires{$wire}++;
        my $since = $row<since> // $support.minimum;
        invalid("Unknown field release $since") unless $support.profile($since).defined;
        my $operators = string-list($row<operators>, 'field operators');
        my $pushdown = string-list($row<pushdown>, 'field pushdown');
        my @allowed = <equals not-equals in not-in>;
        @allowed.append(<lt lte gt gte>) if %copy<kind> eq any(<uint int>);
        @allowed.append(<contains starts-with ends-with>) if %copy<kind> eq 'text';
        @allowed.push('is-null') if $row<nullable>;
        for $operators.List -> $operator {
            invalid("Invalid operator for field $key")
                unless @allowed.first(* eq $operator).defined;
        }
        for $pushdown.List -> $operator {
            invalid("Undeclared pushdown operator for field $key")
                unless $operators.first(* eq $operator).defined;
        }
        my $minimum = $row<pushdown-minimum> // Int;
        my $maximum = $row<pushdown-maximum> // Int;
        my $pushdown-source = ($row<pushdown-source> // '').Str;
        if $pushdown.elems {
            invalid("Nullable field cannot use the exact scalar pushdown profile: $key") if $row<nullable>;
            invalid("Pushdown requires source evidence: $key") unless $pushdown-source.chars;
            if %copy<kind> eq any(<uint int>) {
                invalid("Numeric pushdown requires an exact bounded source domain: $key")
                    unless $minimum ~~ Int:D && $minimum !~~ Bool
                        && $maximum ~~ Int:D && $maximum !~~ Bool
                        && -(2**53 - 1) <= $minimum <= $maximum <= 2**53 - 1;
            }
        }
        @fields.push(FieldSpec.new(|%copy, :$since, :nullable($row<nullable>),
            :null-when(($row<null-when> // '').Str),
            :null-dependency(($row<null-dependency> // '').Str),
            :$operators, :$pushdown, :pushdown-minimum($minimum),
            :pushdown-maximum($maximum), :$pushdown-source));
    }
    for @fields -> $field {
        invalid('Nullable field requires a declared null policy')
            if $field.nullable && $field.null-when ne 'empty'
                && $field.null-when ne 'not-grouped';
        invalid('Nonnullable field cannot have a null policy')
            if !$field.nullable && $field.null-when.chars;
        if $field.null-when eq 'not-grouped' {
            my $dependency = @fields.first({ .entity eq $field.entity
                && .name eq $field.null-dependency });
            invalid('Null dependency must name a Boolean field in the same entity')
                unless $dependency.defined && $dependency.kind eq 'bool';
        }
    }
    my %entities = @fields.map(*.entity).unique.map({ $_ => True });
    for $raw<relations>.List -> $row {
        my %copy;
        for <entity name wire-name target cardinality> -> $key {
            %copy{$key} = text-value($row{$key}, "relation $key");
        }
        invalid('Unknown relation schema') unless (%entities{%copy<entity>}:exists)
            && (%entities{%copy<target>}:exists);
        invalid('Invalid relation cardinality') unless %copy<cardinality> eq any(<one many>);
        invalid('Relation nullability must be Boolean') unless $row<nullable> ~~ Bool:D;
        my $key = %copy<entity> ~ '.' ~ %copy<name>;
        my $wire = %copy<entity> ~ '.' ~ %copy<wire-name>;
        invalid("Duplicate relation $key") if %names{$key}++ || %wires{$wire}++;
        @relations.push(RelationSpec.new(|%copy, :nullable($row<nullable>)));
    }
    my %capabilities;
    for $raw<capabilities>.List -> $row {
        my %copy;
        for <id name kind handling reason source> -> $key {
            %copy{$key} = text-value($row{$key}, "capability $key");
        }
        invalid('Invalid capability kind') unless %copy<kind> eq any(<feature defect>);
        invalid('Invalid capability handling') unless %copy<handling> eq any(<refuse fallback repair>);
        invalid('Duplicate capability') if %capabilities{%copy<id>}++;
        my $since = $row<since> // (%copy<kind> eq 'defect' ?? '' !! $support.minimum);
        my $releases = string-list($row<releases> // [], 'capability releases');
        invalid('A defect requires exact affected releases')
            if %copy<kind> eq 'defect' && !$releases.elems;
        my @versions = $releases.List;
        @versions.unshift($since) if $since.chars;
        for @versions -> $version {
            invalid("Unknown capability release $version") unless $support.profile($version).defined;
        }
        @capabilities.push(CapabilitySpec.new(|%copy, :$since, :$releases,
            :fallback(($row<fallback> // '').Str),
            :blocked-by(string-list($row<blocked-by> // [], 'capability blockers')),
            :commands(string-list($row<commands>, 'capability commands'))));
    }
    for @capabilities -> $spec {
        invalid('Only features may be blocked by defects')
            if $spec.kind ne 'feature' && $spec.blocked-by.elems;
        for $spec.blocked-by.List -> $id {
            my $defect = @capabilities.first(*.id eq $id);
            invalid("Unknown blocking defect $id") unless $defect.defined && $defect.kind eq 'defect';
        }
        invalid('Unknown capability fallback') if $spec.fallback.chars
            && !(%capabilities{$spec.fallback}:exists);
        invalid('Fallback handling requires a named fallback')
            if $spec.handling eq 'fallback' && !$spec.fallback.chars;
        my %seen;
        my $current = $spec;
        while $current.fallback.chars {
            invalid('Cyclic capability fallback') if %seen{$current.id}++;
            $current = @capabilities.first(*.id eq $current.fallback);
            invalid('A defect cannot serve as a fallback') if $current.kind eq 'defect';
        }
    }
    my %option-names;
    for $raw<options>.List -> $row {
        my $name = text-value($row<name>, 'option name');
        invalid('Duplicate option name') if %option-names{$name}++;
        invalid('Option variants must be a nonempty array')
            unless $row<variants> ~~ Array:D && $row<variants>.elems;
        my $previous;
        for $row<variants>.List -> $variant {
            my %copy;
            for <kind since source> -> $key {
                %copy{$key} = text-value($variant{$key}, "option $key");
            }
            %copy<before> = ($variant<before> // '').Str;
            invalid('Unknown option kind') unless %copy<kind>
                eq any(<flag number string choice colour key command>);
            my @versions = %copy<since>;
            @versions.push(%copy<before>) if %copy<before>.chars;
            for @versions -> $release {
                invalid("Unknown option release $release") unless $support.profile($release).defined;
            }
            my $since = parse-tmux-version(%copy<since>);
            invalid('Invalid option version interval') if %copy<before>.chars
                && $since.at-least(parse-tmux-version(%copy<before>));
            invalid('Option variants overlap or are unordered') if $previous.defined
                && (!$previous.before.chars || !$since.at-least(parse-tmux-version($previous.before)));
            my $scopes = string-list($variant<scopes>, 'option scopes');
            invalid('Invalid option scope') unless $scopes.elems
                && $scopes.all eq any(<server session window pane>);
            my $choices = string-list($variant<choices> // [], 'option choices');
            invalid('Choice option needs its vocabulary') if %copy<kind> eq 'choice' && !$choices.elems;
            for <array hook style> -> $flag {
                invalid('Option flags must be Boolean') unless $variant{$flag} ~~ Bool:D;
                %copy{"is-$flag"} = $variant{$flag};
            }
            for <minimum maximum> -> $bound {
                next unless $variant{$bound}:exists;
                invalid('Option bounds must be integers')
                    unless $variant{$bound} ~~ Int:D && $variant{$bound} !~~ Bool;
                %copy{$bound} = $variant{$bound};
            }
            invalid('Numeric option requires ordered bounds') if %copy<kind> eq 'number'
                && (!%copy<minimum>.defined || !%copy<maximum>.defined
                    || %copy<minimum> > %copy<maximum>);
            $previous = OptionSpec.new(:$name, :$scopes, :$choices, |%copy);
            @options.push($previous);
        }
    }
    CatalogueData.new(:all-fields(@fields.map({ $_<> }).List),
        :all-relations(@relations.map({ $_<> }).List),
        :all-capabilities(@capabilities.map({ $_<> }).List),
        :all-options(@options.map({ $_<> }).List))
}

#| Return the validated packaged catalogue; no tmux command is executed.
sub catalogue(--> CatalogueData:D) is export {
    state $catalogue = load-catalogue();
    $catalogue
}
