use v6.d;

use JSON::Fast;
use LibTmux::Catalogue;

sub manifest(--> Hash:D) {
    my $catalogue = catalogue();
    my $support = support-policy();
    my @fields = $catalogue.all-fields.map: -> $field {
        %(entity => $field.entity, name => $field.name, wireName => $field.wire-name,
            format => $field.format, context => $field.context, kind => $field.kind,
            nullable => $field.nullable, decoder => $field.decoder,
            nullWhen => $field.null-when, nullDependency => $field.null-dependency,
            operators => $field.operators.Array, pushdown => $field.pushdown.Array,
            pushdownMinimum => $field.pushdown-minimum, pushdownMaximum => $field.pushdown-maximum,
            pushdownSource => $field.pushdown-source,
            since => $field.since, source => $field.source)
    };
    my @relations = $catalogue.all-relations.map: -> $relation {
        %(entity => $relation.entity, name => $relation.name,
            wireName => $relation.wire-name, target => $relation.target,
            cardinality => $relation.cardinality, nullable => $relation.nullable)
    };
    my @capabilities = $catalogue.all-capabilities.map: -> $spec {
        my %record = id => $spec.id, name => $spec.name, kind => $spec.kind,
            handling => $spec.handling, reason => $spec.reason, source => $spec.source,
            releases => $spec.releases.Array, commands => $spec.commands.Array,
            fallback => $spec.fallback;
        %record<since> = $spec.since if $spec.since.chars;
        %record<blockedBy> = $spec.blocked-by.Array if $spec.blocked-by.elems;
        %record
    };
    my @options = $catalogue.all-options.map: -> $spec {
        my %record = name => $spec.name, kind => $spec.kind, since => $spec.since,
            before => $spec.before, source => $spec.source, scopes => $spec.scopes.Array,
            choices => $spec.choices.Array, array => $spec.is-array,
            hook => $spec.is-hook, style => $spec.is-style;
        %record<minimum> = $spec.minimum if $spec.minimum.defined;
        %record<maximum> = $spec.maximum if $spec.maximum.defined;
        %record
    };
    %(schema => 'libtmux.catalogue-manifest/v1', port => 'raku',
        minimum => $support.minimum, latest => $support.latest,
        fields => @fields, relations => @relations, capabilities => @capabilities,
        options => @options)
}

sub documentation(--> Str:D) {
    my $catalogue = catalogue();
    my @lines = '=begin pod', '', '=head1 LibTmux field and capability catalogue', '',
        'Generated from the packaged resources. Edit the resources and regenerate this file.', '',
        'Availability identifies source support; it does not establish acquisition completeness.', '';
    for $catalogue.entities.List -> $entity {
        @lines.append("=head2 $entity", '');
        for $catalogue.fields($entity).List -> $field {
            @lines.append("=item C<{$field.name}> / C<{$field.wire-name}>", '',
                "FORMAT C<{$field.format}>; {$field.kind}; context {$field.context}; "
                    ~ "nullable {$field.nullable}; since {$field.since}.", '',
                ($field.nullable ?? "Null policy: {$field.null-when}; dependency: "
                    ~ ($field.null-dependency || 'none') ~ '.' !! ''), '',
                'Operators: ' ~ $field.operators.join(', ') ~ '.', '',
                ($field.pushdown.elems ?? 'Exact source operators: ' ~ $field.pushdown.join(', ') ~ '.' !! ''), '',
                ($field.pushdown-minimum.defined ?? "Source numeric domain: {$field.pushdown-minimum} through {$field.pushdown-maximum}." !! ''), '',
                ($field.pushdown-source.chars ?? "Pushdown evidence: L<{$field.pushdown-source}>" !! ''), '',
                "Source: L<{$field.source}>", '');
        }
        for $catalogue.relations($entity).List -> $relation {
            @lines.append("=item C<{$relation.name}> relation", '',
                "{$relation.cardinality} {$relation.target}; nullable {$relation.nullable}.", '');
        }
    }
    @lines.append('=head2 Features and required handling', '');
    for $catalogue.all-capabilities.List -> $spec {
        my $availability = $spec.releases.elems
            ?? 'exact releases ' ~ $spec.releases.join(', ')
            !! "since {$spec.since}";
        @lines.append("=item C<{$spec.id}>", '',
            "{$spec.kind}; {$spec.handling}; $availability. {$spec.reason}", '',
            ($spec.fallback.chars ?? "Fallback: C<{$spec.fallback}>." !! ''), '',
            ($spec.blocked-by.elems ?? 'Blocked by: ' ~ $spec.blocked-by.join(', ') ~ '.' !! ''), '',
            "Source: L<{$spec.source}>", '');
    }
    @lines.append('=head2 Option types and scopes', '');
    for $catalogue.all-options.List -> $spec {
        my $range = 'since ' ~ $spec.since;
        $range ~= ', before ' ~ $spec.before if $spec.before.chars;
        @lines.append("=item C<{$spec.name}>", '',
            "{$spec.kind}; scope " ~ $spec.scopes.join(', ') ~ "; $range."
                ~ ($spec.is-array ?? ' Array.' !! '') ~ ($spec.is-hook ?? ' Hook.' !! ''), '',
            ($spec.choices.elems ?? 'Choices: ' ~ $spec.choices.join(', ') ~ '.' !! ''), '',
            ($spec.minimum.defined ?? "Range: {$spec.minimum} through {$spec.maximum}." !! ''), '',
            "Source: L<{$spec.source}>", '');
    }
    @lines.append('=end pod', '');
    @lines.join("\n")
}

sub accessors(--> Str:D) {
    my %types = text => 'Str', bool => 'Bool', uint => 'Count', int => 'Int',
        session-id => 'SessionId', window-id => 'WindowId', pane-id => 'PaneId';
    my @lines = 'use v6.d;', '', 'unit module LibTmux::Fields;', '',
        'use LibTmux::Types;', '',
        '# Generated by tools/catalogue.raku --format=raku. Edit resources/catalogue.json.', '';
    for catalogue().entities.list -> $entity {
        my $role = $entity.split('-').map(*.tc).join ~ 'Fields';
        @lines.push("role $role is export \{");
        for catalogue().fields($entity).list -> $field {
            my $name = $field.name;
            die "Invalid Raku field name $name" unless $name ~~ /^ <[a..z]> <[a..z0..9\-]>* $/;
            my $type = %types{$field.kind} // die "Unknown scalar kind {$field.kind}";
            $type ~= ':D' unless $field.nullable;
            @lines.push("    #| Captured C<{$field.format}>; local {$field.kind} access.");
            @lines.push('    method ' ~ $name ~ '(--> ' ~ $type
                ~ ") \{ self.value('$name') \}");
        }
        @lines.append('}', '');
    }
    @lines.join("\n")
}

#| Validate source data, emit a derived reference, or check a generated file.
sub MAIN(Bool :$check = False, Str :$format = 'json', Str :$output = '') {
    my $rendered = do given $format {
        when 'json' { to-json(manifest(), :sorted-keys) ~ "\n" }
        when 'rakudoc' { documentation() }
        when 'raku' { accessors() }
        default { die "Unknown catalogue format $format" }
    };
    if $check {
        if $output.chars {
            die "Generated catalogue differs: $output"
                unless $output.IO.f && $output.IO.slurp eq $rendered;
        }
        say 'Catalogue valid' ~ ($output.chars ?? '; generated output matches' !! '');
    } elsif $output.chars {
        $output.IO.parent.mkdir;
        $output.IO.spurt($rendered);
    } else {
        print $rendered;
    }
}
