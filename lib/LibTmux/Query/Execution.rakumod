use v6.d;

unit module LibTmux::Query::Execution;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Engine;
use LibTmux::Transport;
use LibTmux::Model;
use LibTmux::Query;
use LibTmux::Query::Plan;

#| Internal validation shared by explicit source-query facades.
sub query-filter(Mu $entity, Mu $criteria --> Filter:D) is export {
    X::LibTmux::InvalidFilter.new(:path<entity>,
        :message('Query entity must be a defined scalar string')).throw
        unless $entity.^isa(Str) && $entity.defined;
    if $criteria.^isa(Filter) && $criteria.defined {
        X::LibTmux::InvalidFilter.new(:path<entity>,
            :message('Compiled filter belongs to another entity schema')).throw
            unless $criteria.entity eq $entity;
        return $criteria;
    }
    Filter.compile($criteria, :$entity)
}

#| Acquire a plan without retaining the source owner in the resulting selection.
sub acquire-plan(Acquirer:D $source, Plan:D $plan,
                 Cancellation :$cancel = Cancellation,
                 Instant:D :$deadline = now + $source.timeout-ms / 1000 --> Positional:D) is export {
    my $started = now;
    my $observation = $source.observe(:$deadline, :$cancel);
    X::LibTmux::StaleReference.new(:message('Query plan belongs to a replaced daemon')).throw
        unless $observation.incarnation.key eq $plan.projection.incarnation;
    my $snapshot;
    if $plan.complete-graph-required {
        $snapshot = capture($source, :required-incarnation($observation.incarnation), :$deadline, :$cancel);
    } else {
        my $rows = $source.read($plan.projection, $plan.candidate-command,
            :incarnation($observation.incarnation), :$deadline, :$cancel);
        my $after = $source.observe(:$deadline, :$cancel);
        X::LibTmux::StaleReference.new(:message('Daemon changed during query acquisition')).throw
            unless $after.incarnation.key eq $observation.incarnation.key;
        $snapshot = Snapshot.new(:endpoint($source.endpoint), :$observation,
            :$started, :ended(now), :rows(%($plan.entity => $rows)),
            :complete($plan.source-filter.chars ?? () !! ($plan.entity,)));
    }
    my $selection = $snapshot.selection($plan.entity).where($plan.filter);
    X::LibTmux::Command.new(:kind<timeout>, :outcome(Complete),
        :message('Query deadline expired after local evaluation')).throw if now >= $deadline;
    $selection
}

=begin pod
=head1 Explicit source acquisition

This internal adapter executes the same plan through subprocess and persistent
control acquisition. Scalar-only queries acquire declared entity records and
leave unrequested relationships unloaded. A relation predicate requires a full
graph capture; the planner defers source restrictions in that mode. It never
uses a filtered child set as evidence for C<every> or C<none>.

All results recheck the original validated predicate locally. Captures describe
an observation interval, not an atomic transaction. Projection/incarnation checks
reject a plan prepared for a replaced daemon. The same deadline covers source
reads, decoding and local evaluation.
=end pod
