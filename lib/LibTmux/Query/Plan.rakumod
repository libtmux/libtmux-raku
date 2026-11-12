use v6.d;

unit module LibTmux::Query::Plan;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Catalogue;
use LibTmux::Capabilities;
use LibTmux::Command;
use LibTmux::Format;
use LibTmux::Query;

my constant SAFE-INTEGER = 2**53 - 1;
my constant MAX-FORMAT-DEPTH = 64;

sub invalid(Str:D $message, Str:D $path = 'pushdown' --> Nil) {
    X::LibTmux::InvalidFilter.new(:$message, :$path).throw
}

#| Validate one closed source policy before a facade performs daemon I/O.
sub query-policy(Mu $value --> Str:D) is export(:internal) {
    invalid('Pushdown policy must be one defined string')
        unless $value.defined && $value.^isa(Str);
    invalid('Pushdown policy must be auto, never, or require')
        unless $value eq any(<auto never require>);
    $value
}

sub acquisition-context(Str:D $entity --> Str:D) {
    $entity eq 'session-group' ?? 'grouped-session' !! $entity
}

class Step {
    has Str:D $.path is required;
    has Str:D $.kind is required;
    has Bool:D $.exact = False;
    has Str:D $.expression = '';
    has Str:D $.reason = '';
    has Count:D $.depth = 0;
    has List:D $.children = ().List;
}

class Requirement {
    has Str:D $.path is required;
    has Str:D $.entity is required;
    has Str:D $.name is required;
    has Str:D $.target = '';
    has Str:D $.cardinality = '';
}

# Balanced Boolean trees stay below tmux's source-qualified recursion limit.
sub combine(Str:D $operator, @expressions --> Str:D) {
    return $operator eq '&&' ?? '1' !! '0' unless @expressions;
    return @expressions[0] if @expressions.elems == 1;
    my $middle = @expressions.elems div 2;
    '#{' ~ $operator ~ ':' ~ combine($operator, @expressions[^$middle]) ~ ','
        ~ combine($operator, @expressions[$middle..*]) ~ '}'
}

sub tree-depth(Int:D $count --> Int:D) {
    my $depth = 0;
    my $remaining = $count;
    while $remaining > 1 { $remaining = ($remaining + 1) div 2; $depth++ }
    $depth
}

my class Planner {
    has LibTmux::Capabilities:D $.capabilities is required;
    has Positive:D $.max-filter-bytes is required;
    has @!fields;
    has @!relations;

    method fields(--> List:D) { @!fields.map({ $_<> }).List }
    method relations(--> List:D) { @!relations.map({ $_<> }).List }

    method translate(Node:D $node, Str:D $path = 'where' --> Step:D) {
        my @children;
        my $expression = '';
        my $reason = '';
        my $exact = False;
        my $depth = 0;
        given $node.kind {
            when 'all' | 'and' | 'or' | 'not' {
                for $node.children.kv -> $i, $child {
                    @children.push(self.translate($child, $path ~ '.' ~ $node.kind ~ "[$i]"));
                }
                $exact = so @children.all.exact;
                if $node.kind eq any(<all and>) {
                    my @usable;
                    for @children -> $child {
                        @usable.push($child) if $child.expression.chars;
                        last unless $child.exact;
                    }
                    $expression = combine('&&', @usable.map(*.expression))
                        if @usable || !@children;
                    $depth = (@usable ?? @usable.map(*.depth).max !! 0) + tree-depth(@usable.elems);
                    $reason = 'Source restriction stops at the first residual subtree to preserve local errors and short-circuit order'
                        unless $exact;
                } elsif $exact {
                    if $node.kind eq 'not' {
                        $expression = '#{==:' ~ @children[0].expression ~ ',0}';
                        $depth = @children[0].depth + 1;
                    } else {
                        $expression = combine('||', @children.map(*.expression));
                        $depth = (@children ?? @children.map(*.depth).max !! 0) + tree-depth(@children.elems);
                    }
                } else {
                    $reason = 'OR and NOT require an exact translation of the complete subtree';
                }
            }
            when 'relation' {
                my $relation = catalogue().relation($node.entity, $node.name);
                @!relations.push(Requirement.new(:path($path ~ '.' ~ $node.name),
                    :entity($node.entity), :name($node.name), :target($relation.target),
                    :cardinality($relation.cardinality)));
                for $node.children.list -> $child {
                    @children.push(self.translate($child, $path ~ '.' ~ $node.name ~ '.' ~ $node.operator));
                }
                $reason = 'Relationship predicates require complete related data and remain local';
            }
            when 'field' {
                my $field = $!capabilities.require-field($node.entity, $node.name);
                my $context = acquisition-context($node.entity);
                X::LibTmux::MissingData.new(:field($node.entity ~ '.' ~ $node.name),
                    :state(Unavailable),
                    :message("Field {$node.entity}.{$node.name} is unavailable in $context acquisition context")).throw
                    unless $field.context eq $context;
                @!fields.push(Requirement.new(:path($path ~ '.' ~ $node.name),
                    :entity($node.entity), :name($node.name)));
                if !$field.pushdown.first(* eq $node.operator).defined {
                    $reason = 'The field catalogue has no exact source implementation for this operator';
                } else {
                    my @operands = $node.operator eq any(<in not-in>)
                        ?? $node.operand.list !! ($node.operand,);
                    my $numeric = $field.kind eq any(<uint int>);
                    if $numeric && @operands.first({ $_ !~~ Int:D || $_ ~~ Bool
                            || $_.abs > SAFE-INTEGER }).defined {
                        $reason = 'Numeric source comparison requires exactly represented integer operands';
                    } else {
                        my %operators = equals => '==', not-equals => '!=',
                            lt => '<', lte => '<=', gt => '>', gte => '>=';
                        my $operator = %operators{$node.operator} // '==';
                        my @expressions = @operands.map(-> $operand {
                            my $literal = $field.kind eq 'bool' ?? $operand.Int.Str !! $operand.Str;
                            '#{' ~ ($numeric ?? 'e|' !! '') ~ $operator ~ ':#{'
                                ~ $field.format ~ '},' ~ $literal ~ '}'
                        });
                        $expression = $node.operator eq any(<in not-in>)
                            ?? combine('||', @expressions) !! @expressions[0];
                        $depth = 3 + tree-depth(@expressions.elems);
                        if $node.operator eq 'not-in' {
                            $expression = '#{==:' ~ $expression ~ ',0}';
                            $depth++;
                        }
                        $exact = True;
                    }
                }
            }
            default { invalid('Unknown validated query node') }
        }
        if $expression.encode.elems > $!max-filter-bytes || $depth > MAX-FORMAT-DEPTH {
            $expression = ''; $exact = False; $depth = 0;
            $reason = 'Source expression exceeds the bounded byte or nesting budget';
        }
        Step.new(:$path, :kind($node.kind), :$exact, :$expression, :$reason, :$depth,
            :children(@children.map({ $_<> }).List))
    }
}

#| Pure, inspectable source restrictions plus the original local filter.
class Plan is export {
    #| Original validated predicate, retained for every local result check.
    has Filter:D $.filter is required;
    #| Root entity schema; empty results retain this type contract.
    has Str:D $.entity is required;
    #| Requested source policy: auto, never or require.
    has Str:D $.pushdown is required;
    #| Whether the complete predicate has an enabled exact source implementation.
    has Bool:D $.fully-pushed is required;
    #| Actual candidate FORMAT restriction, or empty when source work is deferred.
    has Str:D $.source-filter is required;
    #| Acquire one listing or a full graph; relation predicates require full-graph.
    has Str:D $.acquisition-mode is required;
    #| Why the plan selected its acquisition mode and source restriction policy.
    has Str:D $.acquisition-reason is required;
    #| Identity rule for contextual rows: scoped-id, session-index or scoped-record.
    has Str:D $.identity-normalization is required;
    #| Immutable root-field decoding schema bound to the observed daemon identity.
    has Projection:D $.projection is required;
    #| Listing argv without -F; execute only for listing mode through a guarded reader.
    has Invocation:D $.candidate-command is required;
    #| Translation tree with paths, exactness, expressions and local-work reasons.
    has Step:D $.steps is required;
    #| Captured field requirements, including fields reached through relationships.
    has List:D $.required-fields is required;
    #| Complete relationship paths needed by the original local predicate.
    has List:D $.required-relations is required;

    #| Refuse unchecked construction; compile a validated filter with capabilities.
    method new(|) { invalid('Construct plans through Plan.compile') }
    #| Refuse altered prepared values; compile again to preserve evidence bindings.
    method clone(|) { invalid('Compile a new plan instead of cloning a prepared plan') }

    #| Compile without I/O. require refuses any residual source work before acquisition.
    method compile(Mu $filter, Mu :$capabilities!,
                   Mu :$pushdown = 'auto', Mu :$max-filter-bytes = 4096 --> Plan:D) {
        invalid('Expected one defined compiled filter', 'filter')
            unless $filter.defined && $filter.^isa(Filter);
        invalid('Expected one defined daemon capability observation', 'capabilities')
            unless $capabilities.defined && $capabilities.^isa(LibTmux::Capabilities);
        query-policy($pushdown);
        invalid('Source expression byte limit must be one positive integer', 'max-filter-bytes')
            unless $max-filter-bytes.defined && $max-filter-bytes.^isa(Int)
                && !$max-filter-bytes.^isa(Bool) && $max-filter-bytes > 0;
        $capabilities.require('managed-commands');
        my %listings = session => ['list-sessions'], pane => ['list-panes', '-a'],
            window => ['list-windows', '-a'], window-link => ['list-windows', '-a'],
            client => ['list-clients'], buffer => ['list-buffers'],
            session-group => ['list-sessions', '-f', '#{session_grouped}'];
        my $entity = $filter.entity;
        invalid("No query acquisition profile for $entity") unless %listings{$entity}:exists;
        my $planner = Planner.new(:$capabilities, :$max-filter-bytes);
        my $steps = $planner.translate($filter.ast);
        my $can-filter = $entity eq any(<session pane window window-link>);
        my $fully-pushed = $pushdown ne 'never' && $can-filter && $steps.exact;
        if $pushdown eq 'require' && !$fully-pushed {
            X::LibTmux::Unsupported.new(:feature<query-pushdown>, :state(NotSupported),
                :reason($steps.reason || 'The listing has no proven exact source filter'),
                :message('The complete predicate cannot run exactly at the source')).throw;
        }
        my $needs-graph = so $planner.relations.elems;
        my $acquisition-mode = $needs-graph ?? 'full-graph' !! 'listing';
        my $acquisition-reason = $needs-graph
            ?? 'Relation evaluation needs a complete graph; source restriction is deferred'
            !! $pushdown eq 'never' ?? 'The never policy keeps all filtering local'
            !! 'Acquire the declared root projection and recheck the original filter locally';
        my $source-filter = $pushdown ne 'never' && $can-filter && !$needs-graph
            ?? $steps.expression !! '';
        my @argv = %listings{$entity}.list;
        @argv.append('-f', $source-filter) if $source-filter.chars;
        my $context = acquisition-context($entity);
        my @fields = catalogue().fields($entity).grep({
            .context eq $context && $capabilities.supports-field($entity, .name)
        }).map(*.name);
        my $projection = Projection.new(:$entity, :$context, :fields(@fields), :$capabilities);
        my $normalization = $entity eq any(<pane window session>) ?? 'scoped-id'
            !! $entity eq 'window-link' ?? 'session-index' !! 'scoped-record';
        self.bless(:$filter, :$entity, :$pushdown, :$fully-pushed, :$source-filter,
            :$acquisition-mode, :$acquisition-reason,
            :$projection, :candidate-command(Invocation.new(:@argv)), :$steps,
            :identity-normalization($normalization), :required-fields($planner.fields),
            :required-relations($planner.relations))
    }
    #| Candidate filtering must never supply an incomplete child set to relation predicates.
    method complete-graph-required(--> Bool:D) { so $!required-relations.elems }
    #| Recheck the original validated predicate locally on a fully acquired candidate.
    method matches($view --> Bool:D) { $!filter.matches($view) }
}

=begin pod
=head1 Planning an explicit read

C<Plan.compile($filter, :$capabilities)> performs no I/O. C<auto> uses proven
scalar restrictions; C<never> leaves filtering local; C<require> throws unless
the complete predicate has an exact source implementation. The capability
value must come from the daemon incarnation that will execute the read.

For C<acquisition-mode> C<listing>, pass C<projection> and C<candidate-command>
together to the guarded reader. The command does not include C<-F>: the reader
adds the projection's template. Normalize physical entity IDs or session/index
link keys according to C<identity-normalization>, then apply C<matches> to every
candidate. It always evaluates the original validated filter, including when
C<fully-pushed> is true.

For C<full-graph>, acquire one complete snapshot and apply C<matches> to its
root entities. Do not execute the candidate command. C<source-filter> is empty;
C<acquisition-reason> explains why an otherwise eligible scalar restriction is
deferred. C<required-relations> retains each relationship path. Filtering child
rows first would change C<every> and C<none>, and intersecting a separately
acquired candidate set with a later graph can lose matches during mutation.

=head1 Inspecting source work

C<steps> exposes the translation tree, paths, exactness, expressions and refusal
reasons. Eligible conjuncts can restrict candidates while text remains local.
An AND restriction follows the captured evaluator order and stops at the first
residual subtree, retaining that subtree's own safe prefix if present. It never
moves a later restriction ahead of local work that may throw. Use an explicit
AND array when the ordering of residual evaluation matters; hash iteration is
not an ordering contract.
An OR or NOT subtree is emitted only when the complete subtree is exact.
Text and relationship predicates remain local. Empty Boolean and membership
nodes retain the same identities as the local query evaluator.

ID matching uses tmux string equality. Flags use exact zero/one equality.
Numeric comparisons use arithmetic FORMAT expressions, never lexical ordering.
The catalogue records source-proven UInt32 dimension and nonnegative Int32
window-index domains. Only integer operands within the exact IEEE-754 integer
range are eligible. Bounded operands alone cannot establish source equivalence:
the observed field's complete domain must also fit the arithmetic conversion.
Fractional operands, nullable fields and unqualified numeric fields stay local.

Boolean expressions are balanced and bounded by bytes and nesting depth. An
oversized expression remains local under C<auto> and is refused by C<require>.
The guarded reader still enforces its own complete command/output/time limits.
=end pod
