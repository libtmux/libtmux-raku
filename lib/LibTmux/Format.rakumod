use v6.d;

unit module LibTmux::Format;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Catalogue;
use LibTmux::Capabilities;

sub bad(Str:D $message, Str:D :$schema = '', Str:D :$field = '',
        Int:D :$row = 0, Int:D :$offset = 0 --> Nil) {
    X::LibTmux::Decode.new(:$message, :$schema, :$field, :$row, :$offset).throw
}

sub strict-text(Blob:D $bytes, *%location --> Str:D) {
    my $text;
    try {
        $text = $bytes.decode('utf8');
        CATCH { default { bad('Invalid UTF-8 text', |%location) } }
    }
    $text
}

sub argument-bytes(Blob:D $token, *%location --> Blob:D) {
    bad('Empty argument token', |%location) unless $token.elems;
    strict-text($token, |%location); # Only the wire must be UTF-8; octal payloads need not be.
    my Int $quote = $token[0] == any(34, 39) ?? $token[0] !! 0;
    my Int $end = $token.elems;
    my Int $i = 0;
    if $quote {
        bad('Unclosed argument quote', |%location)
            unless $end >= 2 && $token[$end - 1] == $quote;
        $i = 1;
        $end--;
    }
    my @decoded;
    my %escapes = 97 => 7, 98 => 8, 102 => 12, 110 => 10,
        114 => 13, 116 => 9, 118 => 11;
    while $i < $end {
        my $at = $i;
        my $byte = $token[$i++];
        if $byte == 92 {
            bad('Truncated argument escape', |%location,
                :offset((%location<offset> // 0) + $at)) if $i == $end;
            my $escape = $token[$i++];
            if %escapes{$escape}:exists {
                @decoded.push(%escapes{$escape});
            } elsif 48 <= $escape <= 55 {
                bad('Truncated octal escape', |%location,
                    :offset((%location<offset> // 0) + $at)) if $i + 2 > $end;
                my $second = $token[$i++];
                my $third = $token[$i++];
                bad('Invalid octal escape', |%location,
                    :offset((%location<offset> // 0) + $at))
                    unless 48 <= $second <= 55 && 48 <= $third <= 55;
                my $value = ($escape - 48) * 64 + ($second - 48) * 8 + $third - 48;
                bad('Octal escape is not a non-NUL byte', |%location,
                    :offset((%location<offset> // 0) + $at)) unless 1 <= $value <= 255;
                @decoded.push($value);
            } elsif $escape == any(92, 39, 34, 35, 59, 36, 125, 123, 37, 126) {
                @decoded.push($escape);
            } else {
                bad('Unknown argument escape', |%location,
                    :offset((%location<offset> // 0) + $at));
            }
        } else {
            bad('Raw control byte in argument token', |%location,
                :offset((%location<offset> // 0) + $at)) if $byte < 32 || $byte == 127;
            bad('Internal argument quote', |%location,
                :offset((%location<offset> // 0) + $at))
                if ($quote && $byte == $quote) || (!$quote && $byte == any(34, 39));
            bad('Unquoted argument separator', |%location,
                :offset((%location<offset> // 0) + $at))
                if !$quote && $byte == any(32, 35, 59, 36, 123, 125, 37);
            @decoded.push($byte);
        }
    }
    Blob.new(@decoded)
}

sub repair-vis(Blob:D $token, *%location --> Blob:D) {
    strict-text($token, |%location);
    my @decoded;
    my Int $i = 0;
    my %escapes = 97 => 7, 98 => 8, 102 => 12, 110 => 10,
        114 => 13, 116 => 9, 118 => 11;
    while $i < $token.elems {
        my $at = $i;
        my $byte = $token[$i++];
        if $byte != 92 {
            bad('Raw control byte in VIS output', |%location,
                :offset((%location<offset> // 0) + $at)) if $byte < 32 || $byte == 127;
            @decoded.push($byte);
            next;
        }
        bad('Truncated VIS escape', |%location,
            :offset((%location<offset> // 0) + $at)) if $i == $token.elems;
        my $escape = $token[$i++];
        if %escapes{$escape}:exists {
            @decoded.push(%escapes{$escape});
        } elsif 48 <= $escape <= 55 {
            bad('Truncated VIS octal escape', |%location,
                :offset((%location<offset> // 0) + $at)) if $i + 2 > $token.elems;
            my $second = $token[$i++];
            my $third = $token[$i++];
            bad('Invalid VIS octal escape', |%location,
                :offset((%location<offset> // 0) + $at))
                unless 48 <= $second <= 55 && 48 <= $third <= 55;
            my $value = ($escape - 48) * 64 + ($second - 48) * 8 + $third - 48;
            bad('VIS escape is not a non-NUL byte', |%location,
                :offset((%location<offset> // 0) + $at)) unless 1 <= $value <= 255;
            @decoded.push($value);
        } else {
            bad('Unknown VIS escape', |%location,
                :offset((%location<offset> // 0) + $at));
        }
    }
    Blob.new(@decoded)
}

#| Internal native argument-token decoding; no shell or tmux evaluation occurs.
sub decode-argument-token(Blob:D $token, *%location --> Blob:D) is export(:internal) {
    argument-bytes($token, |%location)
}

#| Internal output repair after the caller removes a record's final LF byte.
sub decode-command-output(Blob:D $bytes, Str:D :$repair!, *%location --> Blob:D)
        is export(:internal) {
    return Blob.new($bytes.list) if $repair eq 'none';
    return repair-vis($bytes, |%location) if $repair eq 'vis';
    bad('Unknown command output repair profile', |%location)
}

sub tilde-bytes(Blob:D $token, *%location --> Blob:D) {
    my %escapes = '7E' => 126, '5C' => 92, '24' => 36,
        '0D' => 13, '0A' => 10, '09' => 9;
    my @decoded;
    my Int $i = 0;
    while $i < $token.elems {
        my $at = $i;
        my $byte = $token[$i++];
        if $byte == 126 {
            bad('Truncated tilde escape', |%location,
                :offset((%location<offset> // 0) + $at)) if $i + 2 > $token.elems;
            my $key = $token[$i++].chr ~ $token[$i++].chr;
            bad('Unknown tilde escape', |%location,
                :offset((%location<offset> // 0) + $at)) unless %escapes{$key}:exists;
            @decoded.push(%escapes{$key});
        } else {
            bad('Unescaped legacy framing byte', |%location,
                :offset((%location<offset> // 0) + $at)) if $byte == any(0, 9, 10, 13, 36, 92);
            @decoded.push($byte);
        }
    }
    Blob.new(@decoded)
}

#| Exact captured field bytes and scalar values. Text conversion is explicit.
class DecodedRow is export {
    #| Versioned projection identity, including entity and acquisition context.
    has Str:D $.schema is required;
    #| Daemon key used to scope this projection or decoded row.
    has Str:D $.incarnation = '';
    #| One-based record number used in decode diagnostics.
    has Int:D $.row is required;
    #| Immutable map of field names to their decoded original bytes.
    has Map:D $.raw is required;
    has Map:D $!scalars is required;
    has Map:D $!states is required;
    has Map:D $!offsets is required;

    #| Refuse direct construction; rows must come from Projection.decode-row.
    method new(|) { bad('Construct rows through Projection.decode-row') }

    submethod BUILD(Str:D :$!schema!, Str:D :$!incarnation = '', Int:D :$!row!,
                    Map:D :$raw!, Map:D :$scalars!, Map:D :$states!, Map:D :$offsets!) {
        bad('Row number must be positive', :schema($!schema)) unless $!row ~~ Positive;
        my $names = $raw.keys.sort.List;
        bad('Row state and offset keys must match captured fields', :schema($!schema))
            unless $states.keys.sort.List eqv $names && $offsets.keys.sort.List eqv $names;
        my %raw-copy; my %scalar-copy; my %state-copy; my %offset-copy;
        for $raw.kv -> $field, $bytes {
            bad('Captured fields require byte values', :schema($!schema), :$field)
                unless $bytes ~~ Blob:D;
            my $state = $states{$field};
            bad('Captured field state must be present or known null', :schema($!schema), :$field)
                unless $state ~~ ValueState:D && $state == any(Present, KnownNull);
            bad('Captured field offset must be nonnegative', :schema($!schema), :$field)
                unless $offsets{$field} ~~ Count;
            %raw-copy{$field} = Blob.new($bytes.list);
            %state-copy{$field} = $state;
            %offset-copy{$field} = $offsets{$field}.Int;
        }
        for $scalars.kv -> $field, $value {
            bad('Captured scalar must belong to a present field', :schema($!schema), :$field)
                unless ($raw{$field}:exists) && $states{$field} == Present;
            bad('Captured scalar must be immutable text, integer or Boolean',
                :schema($!schema), :$field)
                unless $value ~~ Str:D || $value ~~ Int:D;
            %scalar-copy{$field} = $value;
        }
        $!raw = %raw-copy.Map;
        $!scalars = %scalar-copy.Map;
        $!states = %state-copy.Map;
        $!offsets = %offset-copy.Map;
    }

    #| Copy an observation without substituting unvalidated field state.
    method clone(*%changes --> DecodedRow:D) {
        bad('Decode a new row to change captured fields') if %changes;
        self.Mu::clone
    }

    method !require(Str:D $name --> Nil) {
        X::LibTmux::MissingData.new(:field($name), :state(Unloaded),
            :message("Field $name was not projected")).throw unless $!raw{$name}:exists;
        Nil
    }

    #| Return immutable bytes before Unicode normalization, including invalid UTF-8.
    method bytes(Str:D $name --> Blob:D) {
        self!require($name);
        $!raw{$name}
    }

    #| Distinguish domain null from a present empty value.
    method state(Str:D $name --> ValueState:D) {
        self!require($name);
        $!states{$name}
    }

    #| Return a typed scalar or strict Unicode text; known domain null returns Nil.
    method value(Str:D $name) {
        self!require($name);
        return Nil if $!states{$name} == KnownNull;
        return $!scalars{$name} if $!scalars{$name}:exists;
        strict-text($!raw{$name}, :schema($!schema), :row($!row),
            :field($name), :offset($!offsets{$name}))
    }
}

#| Ordered registered fields with an explicit acquisition context and codec.
class Projection is export {
    #| Entity schema selected from the authoritative field catalogue.
    has Str:D $.entity is required;
    #| Acquisition context which determines field availability.
    has Str:D $.context is required;
    #| Ordered declared fields; their order defines the wire record.
    has List:D $.fields is required;
    #| Source-qualified quoting profile used to encode free-text fields.
    has Str:D $.codec-profile is required;
    #| Declared command-output repair policy applied before field decoding.
    has Str:D $.output-repair is required;
    #| Daemon key used to scope this projection or decoded row.
    has Str:D $.incarnation is required;
    #| Versioned projection identity, including entity and acquisition context.
    has Str:D $.schema is required;
    #| Complete tmux FORMAT template with versioned framing and escaped text fields.
    has Str:D $.template is required;

    #| Reconfigured projections must pass the catalogue and capability constructor.
    method clone(*%changes --> Projection:D) {
        bad('Use Projection.new to change a prepared projection') if %changes;
        self.Mu::clone
    }

    #| Construct a validated projection; decoded rows must instead come from decode-row.
    method new(Str:D :$entity!, Positional:D :$fields!,
               LibTmux::Capabilities:D :$capabilities!, Str :$context) {
        my $registry = catalogue();
        bad("Unknown projection entity $entity") unless $registry.has-entity($entity);
        my $selected-context = $context // $registry.fields($entity)[0].context;
        bad('Projection requires at least one field') unless $fields.elems;
        my @specs;
        my %names;
        for $fields.List -> $name {
            bad('Projection field names must be strings') unless $name ~~ Str:D;
            bad("Duplicate projection field $name") if %names{$name}++;
            my $spec = $capabilities.require-field($entity, $name);
            bad('Unsafe catalogue field name') unless $spec.name ~~ /^ <[a..z]> <[a..z0..9-]>* $/;
            bad("Field $name does not belong to context $selected-context")
                unless $spec.context eq $selected-context;
            @specs.push($spec);
        }
        for @specs -> $spec {
            bad("Field {$spec.name} requires projected {$spec.null-dependency}")
                if $spec.null-dependency.chars && !(%names{$spec.null-dependency}:exists);
            bad("Nullable field {$spec.name} lacks a domain policy")
                if $spec.nullable && !$spec.null-when.chars;
        }
        my $profile = $capabilities.codec-profile;
        my $repair = $capabilities.output-repair;
        bad('Unknown FORMAT codec profile') unless $profile eq any(<qa t6>);
        bad('Unknown FORMAT output repair') unless $repair eq any(<none vis>);
        bad('Argument codec cannot use legacy output repair') if $profile eq 'qa' && $repair ne 'none';
        my $schema = 'libtmux.format/v1:' ~ $entity ~ ':' ~ $selected-context
            ~ ':' ~ $profile ~ ':' ~ $repair ~ ':' ~ @specs.map(*.name).join(',');
        my @expressions = @specs.map(-> $spec {
            my $variable = $spec.format;
            bad('Unsafe catalogue FORMAT variable') unless $variable ~~ /^ <[a..z0..9_]>+ $/;
            if $spec.kind ne 'text' { '#{' ~ $variable ~ '}' }
            elsif $profile eq 'qa' { '#{q/a:' ~ $variable ~ '}' }
            else {
                '#{s/~/~7E/;s/\\\\/~5C/;s/[$]/~24/;s/' ~ "\r"
                    ~ '/~0D/;s/' ~ "\n" ~ '/~0A/;s/' ~ "\t" ~ '/~09/:' ~ $variable ~ '}'
            }
        });
        self.bless(:$entity, :context($selected-context),
            :fields(@specs.map({ $_<> }).eager.List), :codec-profile($profile),
            :output-repair($repair), :incarnation($capabilities.incarnation), :$schema,
            :template(('LTM1', $schema, $profile, |@expressions, 'END').join("\t")))
    }

    method !scalar($spec, Blob:D $bytes, *%location) {
        my $text = strict-text($bytes, |%location);
        given $spec.kind {
            when 'text' { return Nil }
            when 'bool' {
                bad('Boolean field must be exactly 0 or 1', |%location)
                    unless $text eq any('0', '1');
                return $text eq '1';
            }
            when 'uint' {
                bad('Unsigned integer requires ASCII digits', |%location)
                    unless $text ~~ /^ <[0..9]>+ $/;
                return $text.Int;
            }
            when 'int' {
                bad('Integer requires signed ASCII digits', |%location)
                    unless $text ~~ /^ '-'? <[0..9]>+ $/;
                return $text.Int;
            }
            default {
                my $prefix = { 'session-id' => '$', 'window-id' => '@', 'pane-id' => '%' }{$spec.kind};
                bad('Invalid identifier field', |%location)
                    unless $prefix.defined && $text.starts-with($prefix)
                        && $text.substr(1) ~~ /^ <[0..9]>+ $/;
                return $text;
            }
        }
    }

    #| Decode one terminated row's contents. FrameDecoder owns stream boundaries.
    method decode-row(Blob:D $line, Int:D :$row = 1, Int:D :$offset = 0,
                      Positive:D :$max-field-bytes = 1024 * 1024 --> DecodedRow:D) {
        my @parts;
        my @starts = 0;
        my $part = Buf.new;
        for $line.list.kv -> $index, $byte {
            bad('Raw NUL or record terminator', :schema($!schema), :$row,
                :offset($offset + $index)) if $byte == any(0, 10);
            if $byte == 9 {
                @parts.push(Blob.new($part.list));
                $part = Buf.new;
                @starts.push($index + 1);
            } else {
                bad('Encoded field exceeds limit', :schema($!schema), :$row,
                    :field($!fields[@parts.elems - 3].name),
                    :offset($offset + $index))
                    if 3 <= @parts.elems < $!fields.elems + 3
                        && $part.elems >= $max-field-bytes;
                $part.append($byte);
            }
        }
        @parts.push(Blob.new($part.list));
        bad('Projection field count mismatch', :schema($!schema), :$row, :$offset)
            unless @parts.elems == $!fields.elems + 4;
        for 0 => 'LTM1', 1 => $!schema, 2 => $!codec-profile,
            (@parts.elems - 1) => 'END' -> $expected {
            bad('Projection schema or framing mismatch', :schema($!schema), :$row,
                :offset($offset + @starts[$expected.key]))
                unless @parts[$expected.key] eqv Blob.new($expected.value.encode('utf8').list);
        }
        my %raw; my %scalars; my %states; my %offsets; my %empty-tokens;
        for $!fields.kv -> $index, $spec {
            my $field = $spec.name;
            my %location = :schema($!schema), :$row, :$field,
                :offset($offset + @starts[$index + 3]);
            my $bytes = @parts[$index + 3];
            if $spec.kind eq 'text' {
                if $!codec-profile eq 'qa' {
                    # tmux skips q/a for callback NULL; validate its domain evidence below.
                    if !$bytes.elems && $spec.nullable { %empty-tokens{$field} = True }
                    else { $bytes = argument-bytes($bytes, |%location) }
                } else {
                    $bytes = tilde-bytes($!output-repair eq 'vis'
                        ?? repair-vis($bytes, |%location) !! $bytes, |%location);
                }
            }
            %raw{$field} = Blob.new($bytes.list);
            %offsets{$field} = %location<offset>;
            my $null = $spec.nullable && $spec.null-when eq 'empty' && !$bytes.elems;
            %states{$field} = $null ?? KnownNull !! Present;
            %scalars{$field} = self!scalar($spec, $bytes, |%location)
                unless $null || $spec.kind eq 'text';
        }
        for $!fields.grep(*.null-when eq 'not-grouped') -> $spec {
            if !%scalars{$spec.null-dependency} {
                bad('Ungrouped session has a group name', :schema($!schema), :$row,
                    :field($spec.name), :offset(%offsets{$spec.name})) if %raw{$spec.name}.elems;
                %states{$spec.name} = KnownNull;
            }
        }
        for %empty-tokens.keys -> $field {
            bad('Empty argument token lacks domain null evidence', :schema($!schema), :$row,
                :$field, :offset(%offsets{$field})) unless %states{$field} == KnownNull;
        }
        DecodedRow.bless(:schema($!schema), :incarnation($!incarnation), :$row, :raw(%raw.Map),
            :scalars(%scalars.Map), :states(%states.Map), :offsets(%offsets.Map))
    }
}

=begin pod
=head1 Declared FORMAT projections
A Projection validates ordered catalogue field names, acquisition context,
capabilities, and nullable-field dependencies before generating a template.
Its schema identifies the field order, codec, and output-repair profile.
The separately retained incarnation binds a prepared projection to a daemon;
the engine validates that identity before dispatch.

Feed binary output to FrameDecoder and call finish at process completion.
An incomplete record, malformed token, exceeded bound, or mismatched schema
throws X::LibTmux::Decode and closes the decoder. Row numbers start at one;
offsets count bytes from the start of the response. Field conversion errors
identify the field's starting offset; token errors locate the offending byte.

DecodedRow.bytes retains exact immutable payload bytes. Its value method
performs strict UTF-8 conversion for text only when requested. State reports
domain null independently from a present empty string, zero, or false.
Rows are constructed through Projection.decode-row and retain the projection's
daemon identity as a string; they do not retain an executor or connection.
An empty raw q/a token is accepted only when its declared null policy and
projected dependencies establish domain null; present empty text remains quoted.
No decoding stage evaluates tmux commands, shell syntax, or Raku source.
=end pod

#| Incremental LF framing over bytes with terminal failure and explicit limits.
class FrameDecoder is export {
    #| Declared projection used to frame and decode every accepted record.
    has Projection:D $.projection is required;
    #| Maximum cumulative response bytes accepted by this decoder.
    has Positive:D $.max-bytes = 8 * 1024 * 1024;
    #| Maximum incomplete record bytes retained between feed calls.
    has Positive:D $.max-buffer-bytes = 8 * 1024 * 1024;
    #| Maximum encoded field size in bytes.
    has Positive:D $.max-field-bytes = 1024 * 1024;
    #| Maximum complete records accepted before finish.
    has Positive:D $.max-rows = 100000;
    has Buf $!buffer = Buf.new;
    has Int $!offset = 0;
    has Int $!rows = 0;
    has Bool $!closed = False;

    #| A new stream needs a new decoder; buffered state cannot be shallow-copied.
    method clone(|) {
        bad('Construct a new FrameDecoder instead of cloning stream state',
            :schema($!projection.schema), :offset($!offset))
    }

    #| Yield complete decoded rows eagerly; incomplete bytes remain owned here.
    method feed(Blob:D $chunk --> List:D) {
        bad('Decoder is closed', :schema($!projection.schema), :offset($!offset)) if $!closed;
        my @rows;
        CATCH { default { $!closed = True; .rethrow } }
        bad('Response exceeds byte limit', :schema($!projection.schema),
            :row($!rows + 1), :offset($!max-bytes))
            if $chunk.elems > $!max-bytes - $!offset;
        for $chunk.list -> $byte {
            if $byte == 10 {
                bad('Row count exceeds limit', :schema($!projection.schema),
                    :row($!rows + 1), :offset($!offset)) if $!rows >= $!max-rows;
                @rows.push($!projection.decode-row(Blob.new($!buffer.list),
                    :row(++$!rows), :offset($!offset - $!buffer.elems),
                    :max-field-bytes($!max-field-bytes)));
                $!buffer = Buf.new;
            } else {
                bad('Incomplete row exceeds buffer limit', :schema($!projection.schema),
                    :row($!rows + 1), :offset($!offset)) if $!buffer.elems >= $!max-buffer-bytes;
                $!buffer.append($byte);
            }
            $!offset++;
        }
        @rows.List
    }

    #| Close successfully only on a complete record boundary.
    method finish(--> Nil) {
        bad('Decoder is closed', :schema($!projection.schema), :offset($!offset)) if $!closed;
        $!closed = True;
        bad('Truncated final record', :schema($!projection.schema),
            :row($!rows + 1), :offset($!offset)) if $!buffer.elems;
        Nil
    }
}
