use v6.d;
unit module LibTmux::Query;

use JSON::Fast;
use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Catalogue;

#| Immutable resource limits applied before recursive validation or JSON parsing.
class Limits is export {
    #| Maximum serialized filter bytes before JSON decoding or after encoding.
    has Positive:D $.max-wire-bytes = 1024 * 1024;
    #| Maximum recursive criterion nesting depth.
    has Positive:D $.max-depth = 32;
    #| Maximum copied criterion nodes, including operands and containers.
    has Positive:D $.max-nodes = 4096;
    #| Maximum operands in one membership criterion.
    has Positive:D $.max-members = 1024;
}

my constant %WIRE-OPERATORS =
    equals => 'equals', 'not-equals' => 'notEquals', in => 'in', 'not-in' => 'notIn',
    lt => 'lt', lte => 'lte', gt => 'gt', gte => 'gte', contains => 'contains',
    'starts-with' => 'startsWith', 'ends-with' => 'endsWith', 'is-null' => 'isNull',
    some => 'some', every => 'every', none => 'none', is => 'is', 'is-not' => 'isNot';
my constant %NATIVE-OPERATORS = %WIRE-OPERATORS.invert;
my constant SAFE-INTEGER = 2 ** 53 - 1;

sub invalid(Str:D $message, Str:D $path = '' --> Nil) {
    X::LibTmux::InvalidFilter.new(:$message, :$path).throw;
}
sub text-value(Str:D $value, Str:D $path --> Str:D) {
    invalid('Text contains bytes which are not Unicode', $path)
        unless $value.encode('utf8').decode('utf8') eq $value;
    $value.NFC.Str
}
sub finite(Mu $value --> Bool:D) {
    return False if $value ~~ Bool;
    return True if $value ~~ Int:D;
    return $value.denominator != 0 if $value ~~ Rat:D || $value ~~ FatRat:D;
    so $value ~~ Num:D && $value == $value && $value != Inf && $value != -Inf
}
sub literal-match(Str:D $actual, Str:D $operand, Str:D $operator --> Bool:D) {
    my @source = text-value($actual, 'observed text').NFC.list;
    my @needle = $operand.NFC.list;
    return False if @needle.elems > @source.elems;
    my @starts = $operator eq 'starts-with' ?? (0,)
        !! $operator eq 'ends-with' ?? (@source.elems - @needle.elems,)
        !! (0 .. @source.elems - @needle.elems);
    for @starts -> $start {
        return True if [&&] (^@needle.elems).map({ @source[$start + $_] == @needle[$_] });
    }
    False
}
sub equal(Mu $actual, Mu $expected, Str:D $kind --> Bool:D) {
    given $kind {
        when 'bool' { so $actual.Int == $expected.Int }
        when 'uint' | 'int' { so $actual == $expected }
        default { so text-value($actual, 'observed text') eq $expected }
    }
}
sub require-state($view, Str:D $name --> ValueState:D) {
    my $state = $view.state($name);
    X::LibTmux::MissingData.new(:field($name), :$state,
        :message("Observed $name is $state")).throw
        unless $state == Present || $state == KnownNull;
    $state
}

#| Read-only validated expression node. Field names come from the catalogue.
class Node is export {
    has Str:D $.kind is required;
    #| Entity schema against which every field and relationship was validated.
    has Str:D $.entity is required;
    has Str:D $.name = '';
    has Str:D $.wire-name = '';
    has Str:D $.operator = '';
    has Str:D $.field-kind = '';
    has Str:D $.target = '';
    has Mu $.operand;
    has List:D $.children = ();

    method evaluate($view --> Bool:D) {
        given $!kind {
            when 'all' | 'and' {
                for $!children.list -> $child { return False unless $child.evaluate($view) }
                return True;
            }
            when 'or' {
                for $!children.list -> $child { return True if $child.evaluate($view) }
                return False;
            }
            when 'not' { return !$!children[0].evaluate($view) }
        }
        my $state = require-state($view, $!name);
        return ($state == KnownNull) == $!operand if $!operator eq 'is-null';
        return False if $state == KnownNull;
        if $!kind eq 'relation' {
            my $related = $view.relation($!name);
            if $!operator eq 'is' || $!operator eq 'is-not' {
                my $match = $!children[0].evaluate($related);
                return $!operator eq 'is' ?? $match !! !$match;
            }
            for $related.list -> $member {
                my $match = $!children[0].evaluate($member);
                return True if $!operator eq 'some' && $match;
                return False if $!operator eq 'every' && !$match;
                return False if $!operator eq 'none' && $match;
            }
            return $!operator ne 'some';
        }
        my $actual = $view.value($!name);
        given $!operator {
            when 'equals' { equal($actual, $!operand, $!field-kind) }
            when 'not-equals' { !equal($actual, $!operand, $!field-kind) }
            when 'in' | 'not-in' {
                my $found = so $!operand.first({ equal($actual, $_, $!field-kind) }).defined;
                $!operator eq 'in' ?? $found !! !$found
            }
            when 'lt' { so $actual < $!operand }
            when 'lte' { so $actual <= $!operand }
            when 'gt' { so $actual > $!operand }
            when 'gte' { so $actual >= $!operand }
            default { literal-match($actual, $!operand, $!operator) }
        }
    }
}

my class Compiler {
    #| Immutable validation and serialization bounds used by this compiled filter.
    has Limits:D $.limits is required;
    has Int $!nodes = 0;
    has %!active;

    method copy(Mu $value, Str:D $path = 'where', Int:D $depth = 0) {
        invalid('Criteria exceed the node limit', $path) if ++$!nodes > $!limits.max-nodes;
        invalid('Criteria exceed the nesting limit', $path) if $depth > $!limits.max-depth;
        invalid('Junctions belong in local native matching', $path) if $value.^isa(Junction);
        if $value ~~ Associative:D || $value ~~ Positional:D {
            my $id = $value.WHICH.Str;
            invalid('Cyclic criteria are not supported', $path) if %!active{$id}:exists;
            %!active{$id} = True;
            LEAVE %!active{$id}:delete;
            if $value ~~ Associative {
                my %copy;
                for $value.kv -> $key, $entry {
                    invalid('Criteria keys must be strings', $path) unless $key ~~ Str:D;
                    %copy{$key} = self.copy($entry, "$path.$key", $depth + 1);
                }
                return %copy.Map;
            }
            my $iterator = $value.iterator;
            invalid('Lazy collections are not bounded criteria', $path) if $iterator.is-lazy;
            my @copy;
            loop {
                my Mu $entry := $iterator.pull-one;
                last if $entry =:= IterationEnd;
                @copy.push(self.copy($entry, "$path\[\]", $depth + 1));
            }
            return @copy.map({ $_<> }).List;
        }
        return $value.Bool if $value ~~ Bool:D;
        return text-value($value, $path) if $value ~~ Str:D;
        return $value if finite($value);
        invalid('Unsupported criteria value; use local native matching', $path);
    }

    method operand(Mu $value, $field, Str:D $path, Bool:D :$wire) {
        given $field.kind {
            when 'bool' {
                invalid('Boolean field requires a Bool operand', $path) unless $value ~~ Bool:D;
            }
            when 'int' | 'uint' {
                invalid('Numeric field requires a finite number, excluding Bool', $path)
                    unless finite($value);
                return portable-number($value, $path, :reading) if $wire;
            }
            when 'session-id' { invalid('Invalid session ID operand', $path) unless $value ~~ SessionId }
            when 'window-id' { invalid('Invalid window ID operand', $path) unless $value ~~ WindowId }
            when 'pane-id' { invalid('Invalid pane ID operand', $path) unless $value ~~ PaneId }
            default { invalid('Text field requires a Str operand', $path) unless $value ~~ Str:D }
        }
        $value
    }

    method compile(Map:D $data, Str:D $entity, Str:D $path = 'where', Bool :$wire = False --> Node:D) {
        catalogue().fields($entity);
        my @nodes;
        for $data.kv -> $key, $value {
            my $at = "$path.$key";
            if $key eq any(<AND OR NOT>) {
                if $key eq 'NOT' {
                    invalid('NOT requires one criterion', $at) unless $value ~~ Map:D;
                    @nodes.push(Node.new(:kind<not>, :$entity,
                        :children((self.compile($value, $entity, $at, :$wire),))));
                } else {
                    invalid("$key requires a collection of complete criteria", $at)
                        unless $value ~~ List:D;
                    my @children;
                    for $value.list -> $criterion {
                        invalid("$key members must be criteria", $at) unless $criterion ~~ Map:D;
                        @children.push(self.compile($criterion, $entity, $at, :$wire));
                    }
                    @nodes.push(Node.new(:kind($key.lc), :$entity,
                        :children(@children.map({ $_<> }).List)));
                }
                next;
            }
            my $field = $wire ?? catalogue().fields($entity).first(*.wire-name eq $key)
                !! catalogue().field($entity, $key);
            my $relation = $wire ?? catalogue().relations($entity).first(*.wire-name eq $key)
                !! catalogue().relation($entity, $key);
            invalid("Unknown $entity field or relation $key", $at)
                unless $field.defined || $relation.defined;
            if $field.defined {
                my $operations = $value ~~ Map:D ?? $value !! Map.new(equals => $value);
                for $operations.kv -> $raw-op, $operand {
                    my $op = $wire ?? (%NATIVE-OPERATORS{$raw-op} // '') !! $raw-op;
                    invalid("Invalid operator $raw-op for $key", $at)
                        unless $field.operators.first(* eq $op).defined;
                    my $checked;
                    if $op eq 'is-null' {
                        invalid('is-null requires a Bool', $at) unless $operand ~~ Bool:D;
                        $checked = $operand;
                    } elsif $op eq 'in' || $op eq 'not-in' {
                        invalid('Membership requires a positional collection', $at)
                            unless $operand ~~ List:D;
                        invalid('Membership exceeds the member limit', $at)
                            if $operand.elems > $!limits.max-members;
                        $checked = $operand.map({ self.operand($_, $field, $at, :$wire) }).eager.List;
                    } else {
                        $checked = self.operand($operand, $field, $at, :$wire);
                    }
                    @nodes.push(Node.new(:kind<field>, :$entity, :name($field.name),
                        :wire-name($field.wire-name), :operator($op), :field-kind($field.kind),
                        :operand($checked)));
                }
            } else {
                invalid('Relations require an operator mapping', $at) unless $value ~~ Map:D;
                for $value.kv -> $raw-op, $operand {
                    my $op = $wire ?? (%NATIVE-OPERATORS{$raw-op} // '') !! $raw-op;
                    my @allowed = $relation.cardinality eq 'many' ?? <some every none> !! <is is-not>;
                    @allowed.push('is-null') if $relation.nullable;
                    invalid("Invalid relation operator $raw-op", $at)
                        unless @allowed.first(* eq $op).defined;
                    my @children;
                    if $op eq 'is-null' {
                        invalid('is-null requires a Bool', $at) unless $operand ~~ Bool:D;
                    } else {
                        invalid('Relation predicate must be a criterion', $at) unless $operand ~~ Map:D;
                        @children.push(self.compile($operand, $relation.target, $at, :$wire));
                    }
                    @nodes.push(Node.new(:kind<relation>, :$entity, :name($relation.name),
                        :wire-name($relation.wire-name), :operator($op), :target($relation.target),
                        :operand($op eq 'is-null' ?? $operand !! Mu),
                        :children(@children.map({ $_<> }).List)));
                }
            }
        }
        Node.new(:kind<all>, :$entity, :children(@nodes.map({ $_<> }).List))
    }
}

sub portable-number(Mu $value, Str:D $path, Bool :$reading = False) {
    invalid('Wire number must be finite and within the safe integer range', $path)
        unless finite($value) && $value.abs <= SAFE-INTEGER;
    return $value if $value ~~ Int;
    if !$reading && ($value ~~ Rat || $value ~~ FatRat) {
        my $denominator = $value.denominator;
        invalid('Exact rational is not representable in the binary64 wire domain', $path)
            unless ($denominator +& ($denominator - 1)) == 0
                && $value.numerator.abs < 2 ** 53 && $denominator <= 2 ** 1074;
    }
    my $number = $value.Num;
    invalid('Wire number underflows binary64', $path) if $number == 0 && $value != 0;
    $number
}
sub node-data(Node:D $node, Bool :$wire = False --> Map:D) {
    my %data;
    for $node.children.list -> $child {
        if $child.kind eq any(<and or not>) {
            %data{$child.kind.uc} = $child.kind eq 'not'
                ?? node-data($child.children[0], :$wire)
                !! $child.children.map({ node-data($_, :$wire) }).eager.List;
        } else {
            my $name = $wire ?? $child.wire-name !! $child.name;
            my $operator = $wire ?? %WIRE-OPERATORS{$child.operator} !! $child.operator;
            my %operators = (%data{$name} // Map.new).Hash;
            my $operand = $child.operand;
            if $child.kind eq 'relation' && $child.operator ne 'is-null' {
                $operand = node-data($child.children[0], :$wire);
            } elsif $wire && $child.field-kind eq any(<int uint>) && $child.operator ne 'is-null' {
                $operand = $operand ~~ List
                    ?? $operand.map({ portable-number($_, $name) }).eager.List
                    !! portable-number($operand, $name);
            }
            %operators{$operator} = $operand;
            %data{$name} = %operators.Map;
        }
    }
    %data.Map
}

sub check-json(Str:D $text, Limits:D $limits --> Nil) {
    invalid('JSON exceeds the byte limit') if $text.encode('utf8').elems > $limits.max-wire-bytes;
    my $depth = 0;
    my $quoted = False;
    my $escaped = False;
    my $number = '';
    my &finish-number = {
        if $number.chars {
            invalid('JSON numeric token is too long') if $number.chars > 64;
            if $number ~~ /^ <[0..9+\-.]> / {
                invalid('Invalid JSON numeric spelling') unless $number ~~ /^ '-'?
                    [ '0' | <[1..9]> <[0..9]>* ] [ '.' <[0..9]>+ ]?
                    [ <[eE]> <[+\-]>? <[0..9]>+ ]? $/;
                my $exponent = $number ~~ / <[eE]> ( <[+\-]>? <[0..9]>+ ) $ /;
                invalid('JSON exponent exceeds the binary64 bound')
                    if $exponent && ($exponent[0].chars > 5 || $exponent[0].Int.abs > 324);
                my $converted = $number.Num;
                invalid('JSON number overflows binary64') unless finite($converted);
                my $mantissa = $number.split(/<[eE]>/)[0];
                invalid('JSON number underflows binary64')
                    if $converted == 0 && $mantissa ~~ /<[1..9]>/;
            }
            $number = '';
        }
    };
    for $text.comb -> $character {
        if $quoted {
            invalid('JSON strings cannot contain unescaped control characters')
                if $character.ord < 32;
            if $escaped { $escaped = False }
            elsif $character eq '\\' { $escaped = True }
            elsif $character eq '"' { $quoted = False }
            next;
        }
        if $character ~~ /^ <[0..9.eE+\-]> $/ {
            $number ~= $character;
            invalid('JSON numeric token is too long') if $number.chars > 64;
            next;
        }
        finish-number();
        given $character {
            when '"' { $quoted = True }
            when '{' | '[' {
                invalid('JSON exceeds the nesting limit') if ++$depth > $limits.max-depth + 2;
            }
            when '}' | ']' { --$depth }
        }
    }
    finish-number();
}

#| A schema-validated local matcher with copied, immutable criteria and AST.
class Filter is export {
    #| Entity schema against which every field and relationship was validated.
    has Str:D $.entity is required;
    #| Immutable validation and serialization bounds used by this compiled filter.
    has Limits:D $.limits is required;
    #| Deep-copied normalized query data, independent of the caller containers.
    has Map:D $.criteria is required;
    #| Validated immutable expression tree used by matches and ACCEPTS.
    has Node:D $.ast is required;

    #| Refuse unvalidated construction; use compile or from-json.
    method new(|) { invalid('Construct filters with compile or from-json') }
    #| Recompile changed criteria instead of bypassing validation with Mu.clone.
    method clone(|) { invalid('Filters cannot be cloned; compile the changed criteria') }
    #| Validate the entire criterion before observing any member.
    method compile(Mu $criteria, Mu :$entity!, Mu :$limits = Limits.new,
                   *%unknown --> Filter:D) {
        invalid('Unknown filter setting: ' ~ %unknown.keys.sort.join(', ')) if %unknown;
        invalid('Entity must be one defined string', 'entity')
            unless $entity.defined && $entity.^isa(Str);
        invalid('Filter limits must be one defined Limits value', 'limits')
            unless $limits.defined && $limits.^isa(Limits);
        my $compiler = Compiler.new(:$limits);
        my $copy = $compiler.copy($criteria);
        invalid('A criterion must be one associative value') unless $copy ~~ Map:D;
        my $ast = $compiler.compile($copy, $entity);
        self.bless(:$entity, :$limits, :$ast, :criteria(node-data($ast)))
    }
    #| Evaluate locally using the fixed entity/state/value/relation view protocol.
    method matches($view --> Bool:D) {
        invalid('Filter and observed entity schemas differ') unless $view.entity eq $!entity;
        $!ast.evaluate($view)
    }
    #| Participate as a native matcher without changing data equality semantics.
    multi method ACCEPTS(Filter:D: Mu $view --> Bool:D) { self.matches($view) }
    #| Encode the proposed wire schema; reject exact numbers that would round.
    method to-json(--> Str:D) {
        my $json = JSON::Fast::to-json(%(schema => 'libtmux.where/v1',
            entity => $!entity, where => node-data($!ast, :wire)), :!pretty);
        check-json($json, $!limits);
        $json
    }
    #| Bound bytes and nesting before JSON::Fast, then validate the closed wire grammar.
    method from-json(Mu $input, Mu :$limits = Limits.new, *%unknown --> Filter:D) {
        invalid('Unknown filter setting: ' ~ %unknown.keys.sort.join(', ')) if %unknown;
        invalid('Filter limits must be one defined Limits value', 'limits')
            unless $limits.defined && $limits.^isa(Limits);
        my $text;
        try {
            if $input ~~ Blob:D {
                invalid('JSON exceeds the byte limit') if $input.elems > $limits.max-wire-bytes;
                $text = $input.decode('utf8');
            } elsif $input ~~ Str:D {
                $text = text-value($input, 'JSON');
            } else { invalid('JSON input must be Str or Blob') }
            CATCH { default {
                .rethrow if $_ ~~ X::LibTmux::InvalidFilter;
                invalid('JSON input is not valid UTF-8');
            } }
        }
        check-json($text, $limits);
        my $data;
        try {
            $data = JSON::Fast::from-json($text);
            CATCH { default { invalid('Invalid JSON input') } }
        }
        invalid('Wire filter requires exactly schema, entity and where')
            unless $data ~~ Hash:D && $data.keys.sort.List eqv <entity schema where>;
        invalid('Unknown wire schema') unless $data<schema> ~~ Str:D
            && $data<schema> eq 'libtmux.where/v1';
        invalid('Wire entity must be a string') unless $data<entity> ~~ Str:D;
        my $entity = $data<entity>;
        my $compiler = Compiler.new(:$limits);
        my $copy = $compiler.copy($data<where>);
        invalid('Wire where must be an object') unless $copy ~~ Map:D;
        my $ast = $compiler.compile($copy, $entity, :wire);
        self.bless(:$entity, :$limits, :$ast, :criteria(node-data($ast)))
    }
}

=begin pod
=head1 Validated local criteria

C<Filter.compile(%criteria, :entityE<lt>paneE<gt>)> validates and copies one
criterion before any entity is read. C<matches($view)> and native smartmatching
through C<ACCEPTS> use the same evaluator. The view protocol has four fixed
methods: C<entity>, C<state($name)>, C<value($name)> and C<relation($name)>.
Names are checked against the catalogue; input keys never become method calls.

Field values abbreviate equality. Operator mappings support C<equals>,
C<not-equals>, C<in>, C<not-in>, numeric C<lt/lte/gt/gte>, literal C<contains>,
C<starts-with>, C<ends-with>, and nullable fields' C<is-null>. Operators and
fields at the same level are conjoined. Numeric operands exclude Bool and
non-finite values. Text is NFC normalized and literal matching compares
codepoints, including positions inside a grapheme. Invalid UTF8-C8 bytes are
refused; byte comparison belongs to a separate interface.

C<AND> and C<OR> accept collections of complete criteria. C<NOT> accepts one
criterion. Empty criteria and AND are true; empty OR and in are false; empty
not-in is true. Boolean evaluation short-circuits after schema validation.
For example, an OR whose first branch matches does not read an unloaded field
in its second branch. Unknown fields in either branch still fail compilation.

To-many relations support C<some>, C<every> and C<none>. One C<some> requires
one child to satisfy its complete subtree. Separate existential subtrees may
use different children. Loaded empty relations yield false, true and true,
respectively. To-one relations support C<is>, C<is-not>, and C<is-null> where
the relation is nullable. No evaluation performs I/O.

KnownNull satisfies only an explicit null test. For example,
C<dead-status =E<gt> %(not-equals =E<gt> 0)> is false when status is KnownNull;
C<NOT =E<gt> %(dead-status =E<gt> %(not-equals =E<gt> 0))> is true. Likewise a
null group fails both C<is> and C<is-not>. Unsupported, Unavailable and Unloaded
states throw MissingData when evaluated. They are never empty relations,
empty strings, zero or false.

C<criteria> exposes normalized nested Maps and Lists. C<ast> exposes immutable
nodes for source planning: kind, entity, name, wire-name, operator, field-kind,
target, operand and children. Cloning a Filter is refused; compile changed data
to preserve validation. Native callbacks, Junctions, regexes, type objects,
lazy collections and cycles are not criterion data.

=head1 Proposed JSON representation

C<to-json> and C<Filter.from-json(Str|Blob)> use JSON::Fast and the proposed
C<libtmux.where/v1> envelope with exactly C<schema>, C<entity> and C<where>.
This is a Raku proposal, not a claim of tested cross-port wire compatibility.
Catalogue wire names are stable camelCase names; compound operator names use
camelCase too, such as C<notEquals>, C<startsWith>, C<isNull> and C<isNot>.
JSON::Fast uses the last value for a duplicate object key.
The bounded preflight also rejects malformed numeric spellings and raw control
characters in strings; parsing remains delegated to JSON::Fast.

Wire numbers use finite binary64 values bounded in absolute magnitude by
C<2**53-1>, with integers in that safe range kept exact. Decimal JSON operands
are interpreted as binary64. Export of an exact Rat or FatRat requires a
power-of-two denominator, a numerator below 2**53 in absolute magnitude and
a lossless nonzero binary64 conversion. In particular, local C<1/3> criteria
remain valid but cannot be serialized by rounding to C<0.333333>. JSON numeric
tokens are limited to 64 characters and exponents to absolute value 324;
overflow and nonzero underflow are refused.

Limits defaults are 1 MiB wire input/output, depth 32, 4096 copied value nodes
and 1024 membership operands. Byte length and structural JSON depth are checked
before parsing while respecting quoted strings and escapes. Native and decoded
criteria then share bounded recursive validation. Supply an immutable Limits
value to compile or from-json to choose tighter limits.
=end pod
