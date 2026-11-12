use v6.d;
unit module LibTmux::Selection;

use LibTmux::Exceptions;
use LibTmux::Query;

#| Eager captured membership; transformations perform no acquisition or commands.
role Selection[::T, Str:D $schema] does Iterable does Positional[T] is export {
    has List:D $!members = ();

    submethod BUILD(Mu :$items = ()) {
        X::LibTmux.new(:message('Selection items must be a finite positional collection')).throw
            unless !$items.^isa(Junction) && $items ~~ Positional:D;
        my $iterator = $items.iterator;
        X::LibTmux.new(:message('Selection items must not be lazy')).throw if $iterator.is-lazy;
        my @captured;
        loop {
            my Mu $item := $iterator.pull-one;
            last if $item =:= IterationEnd;
            X::LibTmux.new(:message("Selection requires defined {T.^name} members")).throw
                unless !$item.^isa(Junction) && $item ~~ T:D;
            @captured.push($item);
        }
        $!members = @captured.map(-> $value { $value }).eager.List;
    }

    #| Revalidate and copy membership when cloning a concrete selection.
    method clone(Mu :$items = $!members) { self.WHAT.new(:$items) }

    #| Entity schema retained even by an empty selection.
    method entity(--> Str:D) { $schema }
    #| Return a fresh iterator over captured eager membership.
    method iterator { $!members.iterator }
    #| Delegate positional lookup to captured membership with native Raku indexing behavior.
    method AT-POS($index) { $!members.AT-POS($index) }
    #| Check an index locally without acquiring or refreshing data.
    method EXISTS-POS($index) { $!members.EXISTS-POS($index) }
    #| Return the exact captured membership count.
    method elems(--> Int:D) { $!members.elems }
    #| True when captured membership is nonempty.
    method Bool(--> Bool:D) { so $!members.elems }
    #| Return eager replayable membership with native list semantics.
    method list(--> List:D) { $!members.list }
    #| Return captured membership without writable element containers.
    method List(--> List:D) { $!members.List }
    #| Materialize an independent mutable membership array; contained views remain shared.
    method Array(--> Array:D) { $!members.Array }
    #| Return a fresh native sequence over captured membership.
    method Seq(--> Seq:D) { $!members.Seq }
    #| Use native matching and adverbs, returning a Seq rather than another selection.
    method grep(|capture) { $!members.grep(|capture) }
    #| Use native mapping; projections may change element type.
    method map(|capture) { $!members.map(|capture) }
    #| Use native sorting and return its ordinary Raku result.
    method sort(|capture) { $!members.sort(|capture) }
    #| Use native first-match behavior, including native absence semantics.
    method first(|capture) { $!members.first(|capture) }
    #| Construct the native one junction; this is not exact-cardinality retrieval.
    method one { $!members.one }
    #| Construct the native any junction over captured membership.
    method any { $!members.any }
    #| Construct the native all junction over captured membership.
    method all { $!members.all }
    #| Construct the native none junction over captured membership.
    method none { $!members.none }

    #| Run a callback once per member in order and preserve this concrete selection type.
    method filter(&predicate) {
        my @found;
        for $!members.list -> $member {
            my $result = predicate($member);
            $result.exception.throw if $result.^isa(Failure);
            @found.push($member) if $result;
        }
        self.WHAT.new(:items(@found))
    }
    #| Compile criteria before traversal, including on an empty selection.
    method where(Mu $criteria) {
        X::LibTmux::InvalidFilter.new(:message('Junctions belong in local native matching')).throw
            if $criteria.^isa(Junction);
        my $filter = $criteria ~~ Filter:D ?? $criteria
            !! Filter.compile($criteria, :entity($schema));
        X::LibTmux::InvalidFilter.new(:message('Filter and selection schemas differ')).throw
            unless $filter.entity eq $schema;
        self.filter(-> $member { $filter.matches($member) })
    }
    #| Return exactly one member or throw its observed cardinality.
    method single(--> T:D) {
        X::LibTmux::Cardinality.new(:count(self.elems), :entity($schema),
            :message("Expected one $schema; captured {self.elems}")).throw unless self.elems == 1;
        $!members[0]
    }
    #| Return Nil for zero members, the sole member for one, otherwise throw.
    method single-or-nil {
        self.elems ?? self.single !! Nil
    }
}

=begin pod
=head1 Captured selections

A concrete selection consumes C<Selection[Pane, 'pane']> or another catalogue
entity schema. C<new(:items)> copies finite, eager, defined membership. It does
not deep-clone member objects. Observation classes must supply their own
read-only field contract.

Binding C<my @panes := $snapshot.panes> preserves the selection. Array
assignment materializes ordinary array membership; assigning to a scalar
itemizes the selection. Use C<$panes.List> when explicit list traversal is
wanted. Each iterator and Seq is fresh. Array conversion is independently
mutable; List membership cannot be replaced.

C<where> accepts criterion data or a compiled Filter and validates the schema
before traversal. C<filter> invokes one callback per member, eagerly in source
order, and throws a directly returned Failure before Boolean coercion. Both
return the same concrete selection type and preserve order and duplicates.
Native C<grep>, C<map>, C<sort>, C<first> and junctions delegate to the captured
List, including grep adverbs. They retain native return and evaluation rules.
C<one> constructs a junction; exact cardinality uses C<single>.
=end pod
