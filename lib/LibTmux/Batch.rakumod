use v6.d;

#| Sequential bounded commands with explicit completion evidence and partial outcomes.
unit module LibTmux::Batch;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Engine;
use LibTmux::Command;
use LibTmux::Transport;

sub invalid(Str:D $message --> Nil) {
    X::LibTmux::Command.new(:kind<argument>, :outcome(NotStarted), :$message).throw
}

sub positive(Mu $value --> Bool:D) {
    so ($value.^isa(Int) && !$value.^isa(Bool) && $value.defined && $value > 0)
}

sub name(Str:D $value --> Str:D) {
    invalid('Operation names must contain 1 through 256 characters without NUL')
        unless 1 <= $value.chars <= 256 && !$value.contains("\0");
    $value
}

#| Caller-supplied evidence for one named operation, not a command acknowledgement.
class Evidence is export {
    #| Unique batch operation name this observation was armed to verify.
    has Str:D $.operation is required;
    #| Caller description of the observed postcondition, limited to 4096 characters.
    has Str:D $.description is required;
    #| Whether that postcondition held; False records a failed effect contract.
    has Bool:D $.satisfied is required;

    submethod TWEAK() {
        name($!operation);
        invalid('Evidence needs a nonempty description of at most 4096 characters')
            unless 1 <= $!description.chars <= 4096 && !$!description.contains("\0");
    }

    #| Validate replacement observation data; cloning does not reobserve an effect.
    method clone(*%changes --> Evidence:D) {
        my %values = operation => $!operation, description => $!description, satisfied => $!satisfied;
        for %changes.kv -> $key, $value {
            invalid("Unknown evidence setting $key") unless %values{$key}:exists;
            %values{$key} = $value;
        }
        self.WHAT.new(|%values)
    }
}

#| One immutable command and an explicit completion contract.
class Operation is export {
    #| Batch-unique correlation name, limited to 256 characters without NUL.
    has Str:D $.name is required;
    #| Immutable command admitted before any batch entry is dispatched.
    has Invocation:D $.command is required;
    #| Accept command acknowledgement as completion without external effect proof.
    has Bool:D $.acknowledgement-only = False;
    #| Caller-owned Promise of Evidence; undefined in acknowledgement-only mode.
    has Promise $.evidence = Promise;

    submethod TWEAK() {
        name($!name);
        invalid('Choose acknowledgement-only or an evidence Promise, exclusively')
            unless $!acknowledgement-only != $!evidence.defined;
    }

    #| Revalidate replacements; unchanged evidence retains its one-shot Promise.
    method clone(*%changes --> Operation:D) {
        my %values = name => $!name, command => $!command,
            acknowledgement-only => $!acknowledgement-only, evidence => $!evidence;
        for %changes.kv -> $key, $value {
            invalid("Unknown operation setting $key") unless %values{$key}:exists;
            %values{$key} = $value;
        }
        self.WHAT.new(|%values)
    }
}

#| One position's outcome, preserving its acknowledgement and original exception.
class OperationResult is export {
    #| Zero-based position in the admitted batch, including skipped entries.
    has Count:D $.index is required;
    #| Correlation name copied from the admitted operation.
    has Str:D $.name is required;
    #| Complete, Failed, Skipped or Indeterminate under this entry's completion scope.
    has Outcome:D $.outcome is required;
    #| command means acknowledgement; effect additionally requires satisfied Evidence.
    has Str:D $.completion-scope is required;
    #| Successful executor Receipt, or an undefined value when none was received.
    has $.acknowledgement;
    #| Observed caller Evidence when received, including an unsatisfied observation.
    has Evidence $.evidence;
    #| Original execution/evidence exception; undefined for complete or skipped work.
    has Exception $.error;
    #| Why dispatch was omitted; empty for an operation that was attempted.
    has Str:D $.skip-reason = '';
    #| Admission time for this position, even when dispatch was skipped.
    has Instant:D $.started is required;
    #| Time its outcome was recorded, not proof that an uncertain effect stopped.
    has Instant:D $.finished is required;

    #| Refuse fabricated results; only Batch.run constructs execution observations.
    method new(|) { invalid('OperationResult values are produced by Batch.run') }
    #| Refuse altered copies of recorded execution outcomes.
    method clone(|) { invalid('OperationResult values cannot be cloned') }
    #| Whether a successful command acknowledgement was received before any later failure.
    method acknowledged(--> Bool:D) { $!acknowledgement.defined }
    #| Preserve backend effect certainty even when batch classification differs.
    method error-outcome(--> Outcome) {
        $!error ~~ X::LibTmux::Command ?? $!error.outcome !! Outcome
    }
}

#| Captured per-operation results. No runtime, control owner or caller task is retained.
class Report is export {
    #| Eager immutable membership containing one OperationResult per admitted entry.
    has List:D $.operations is required;
    #| Time before command preflight began; the overall deadline starts here.
    has Instant:D $.started is required;
    #| Time all positions were classified, including the undispatched suffix.
    has Instant:D $.finished is required;
    #| One absolute deadline shared by execution and caller-evidence waiting.
    has Instant:D $.deadline is required;
    #| Cause that requested a stop; undefined when no stopping condition occurred.
    has Exception $.stop-error;
    #| Counted receipt and Command-error bytes, with shared causes counted once.
    has Count:D $.output-bytes = 0;
    #| Admission threshold in bytes; the final retained response may exceed it.
    has Positive:D $.output-budget-bytes is required;

    #| Refuse fabricated reports; only Batch.run records a complete batch attempt.
    method new(|) { invalid('Report values are produced by Batch.run') }
    #| Refuse altered copies of recorded batch outcomes.
    method clone(|) { invalid('Report values cannot be cloned') }
    #| Aggregate uncertainty first, then failure, skipped work, and complete work.
    method outcome(--> Outcome:D) {
        return Indeterminate if $!operations.first(*.outcome == Indeterminate).defined;
        return Failed if $!operations.first(*.outcome == Failed).defined;
        return Skipped if $!operations.first(*.outcome == Skipped).defined;
        Complete
    }
}

sub classification(Exception:D $error --> Outcome:D) {
    return Indeterminate unless $error ~~ X::LibTmux::Command;
    $error.outcome == any(Indeterminate, Complete) ?? Indeterminate !! Failed
}

sub error-output(Exception $error, %counted --> Count:D) {
    my $bytes = 0;
    my $current = $error;
    while $current.defined && $current.^isa(X::LibTmux::Command) {
        my $identity = $current.WHICH.Str;
        last if %counted{$identity}:exists;
        %counted{$identity} = True;
        $bytes += $current.stdout.elems + $current.stderr.elems;
        $current = $current.cause;
    }
    $bytes
}

sub stopped(Instant:D $deadline, Cancellation $cancel --> Exception) {
    return X::LibTmux::Command.new(:kind<cancelled>, :outcome(NotStarted),
        :message('Batch cancelled before the next dispatch'))
        if $cancel.defined && $cancel.cancelled;
    return X::LibTmux::Command.new(:kind<timeout>, :outcome(NotStarted),
        :message('Batch deadline expired before the next dispatch')) if now >= $deadline;
    Exception
}

sub await-evidence(Operation:D $operation, Instant:D $deadline, Cancellation $cancel --> Evidence:D) {
    my $before = stopped($deadline, $cancel);
    X::LibTmux::Command.new(:kind($before.kind), :outcome(Indeterminate),
        :cause($before), :message('Batch stopped before effect evidence was inspected')).throw
        if $before.defined;
    my $settled = Promise.new;
    my $vow = $settled.vow;
    my $lock = Lock.new;
    my &finish = -> Str:D $kind, Mu $value {
        $lock.protect({ $vow.keep([$kind, $value]) if $settled.status == Planned });
    };
    my $tap = $operation.evidence.Supply.tap(
        -> Mu $value { finish('value', $value) }, :quit(-> $error { finish('error', $error) }));
    LEAVE $tap.close if $tap.defined;
    my $timer = $*SCHEDULER.cue({ finish('error', X::LibTmux::Command.new(
        :kind<timeout>, :outcome(Indeterminate), :message('Batch effect evidence timed out'))) },
        :in(0 max ($deadline - now).Numeric));
    LEAVE $timer.cancel if $timer.defined;
    my $cancel-tap = $cancel.defined ?? $cancel.when-cancelled.Supply.tap(-> $ {
        finish('error', X::LibTmux::Command.new(:kind<cancelled>, :outcome(Indeterminate),
            :message('Batch cancelled while waiting for effect evidence')));
    }) !! Tap;
    LEAVE $cancel-tap.close if $cancel-tap.defined;
    my ($kind, $value) = (await $settled).list;
    $value.throw if $kind eq 'error';
    $value.exception.throw if $value.^isa(Failure);
    X::LibTmux::Command.new(:kind<evidence>, :outcome(Indeterminate),
        :message('Evidence Promise did not resolve to Evidence for this operation')).throw
        unless $value.^isa(Evidence) && $value.operation eq $operation.name;
    $value
}

#| A finite replayable sequence of explicit commands, without transaction semantics.
class Batch is export {
    #| Captured eager Operation membership; replay preserves this order.
    has List:D $.operations = ().List;
    #| Maximum admitted operation count, enforced during incremental traversal.
    has Positive:D $.max-operations = 256;
    #| Maximum sum of encoded Invocation source bytes before executor guard encoding.
    has Positive:D $.max-command-bytes = 1024 * 1024;
    #| Stop further dispatch once retained output reaches this byte threshold.
    has Positive:D $.output-budget-bytes = 8 * 1024 * 1024;

    #| Copy finite membership and validate all size/name limits without I/O.
    method new(Mu :$operations!, Mu :$max-operations = 256,
               Mu :$max-command-bytes = 1024 * 1024,
               Mu :$output-budget-bytes = 8 * 1024 * 1024, *%unknown) {
        invalid('Unknown batch setting: ' ~ %unknown.keys.sort.join(', ')) if %unknown;
        invalid('Batch limits must be positive integers')
            unless positive($max-operations) && positive($max-command-bytes)
                && positive($output-budget-bytes);
        invalid('Batch operations must be a positional collection')
            if $operations.^isa(Junction) || $operations !~~ Positional:D;
        my $iterator = $operations.iterator;
        invalid('Batch membership cannot be lazy') if $iterator.is-lazy;
        my @copy;
        my %names;
        my $bytes = 0;
        loop {
            my $operation := $iterator.pull-one;
            last if $operation =:= IterationEnd;
            invalid('Batch exceeds its operation limit') if @copy.elems >= $max-operations;
            invalid('Batch membership requires defined Operation values')
                unless $operation.^isa(Operation) && $operation.defined;
            invalid('Batch operation names must be unique') if %names{$operation.name}:exists;
            %names{$operation.name} = True;
            $bytes += $operation.command.source.encode('utf8-c8').elems;
            invalid('Batch exceeds its total command byte limit') if $bytes > $max-command-bytes;
            @copy.push($operation<>);
        }
        self.bless(:operations(@copy.map({ $_<> }).eager.List), :$max-operations,
            :$max-command-bytes, :$output-budget-bytes)
    }

    #| Revalidate changed membership or limits; unchanged evidence is not rearmed.
    method clone(*%changes --> Batch:D) {
        my %values = operations => $!operations, max-operations => $!max-operations,
            max-command-bytes => $!max-command-bytes, output-budget-bytes => $!output-budget-bytes;
        for %changes.kv -> $key, $value {
            invalid("Unknown batch setting $key") unless %values{$key}:exists;
            %values{$key} = $value;
        }
        self.WHAT.new(|%values)
    }

    #| Run sequentially through a caller-owned executor; collect every position.
    method run(*%options --> Report:D) { await self.run-async(|%options) }

    #| Share one deadline across commands and evidence; never invoke caller callbacks.
    method run-async(Mu :$executor!, Mu :$incarnation!, Mu :$timeout-ms = 10_000,
                     Mu :deadline($requested-deadline) = Instant,
                     Mu :$cancel = Cancellation, Mu :$on-error = 'stop',
                     *%unknown --> Promise:D) {
        my $error;
        my $started;
        my $deadline;
        try {
            invalid('Unknown batch operation setting: ' ~ %unknown.keys.sort.join(', ')) if %unknown;
            invalid('Batch executor must implement CommandExecutor')
                unless $executor.^does(CommandExecutor);
            invalid('Batch execution requires a defined executor and Incarnation')
                unless $executor.defined && $incarnation.^isa(Incarnation) && $incarnation.defined;
            invalid('Batch timeout must be a positive integer') unless positive($timeout-ms);
            invalid('Batch deadline must be an Instant when supplied')
                unless $requested-deadline.^isa(Instant)
                    && ($requested-deadline.defined || $requested-deadline === Instant);
            invalid('Batch cancellation requires a Cancellation token')
                unless $cancel.^isa(Cancellation) && ($cancel.defined || $cancel === Cancellation);
            invalid('Batch on-error must be stop or continue')
                unless $on-error.^isa(Str) && $on-error.defined && $on-error eq any(<stop continue>);
            $started = now;
            $deadline = $started + $timeout-ms / 1000;
            $deadline = $requested-deadline
                if $requested-deadline.defined && $requested-deadline < $deadline;
            $executor.validate-command(.command, :$incarnation) for $!operations.list;
            CATCH { default { $error = $_ } }
        }
        return Promise.broken($error) if $error.defined;
        start {
            my @results;
            my Exception $stop;
            my $stop-name = '';
            my $output-bytes = 0;
            my %counted-errors;
            for $!operations.kv -> $index, $operation {
                $stop //= stopped($deadline, $cancel);
                my $began = now;
                my $outcome = Skipped;
                my $acknowledgement;
                my Evidence $evidence;
                my Exception $failure;
                my $skip-reason = $stop.defined
                    ?? ($stop-name.chars ?? "Stopped after operation $stop-name" !! $stop.message) !! '';
                unless $stop.defined {
                    try {
                        my $candidate = await $executor.execute-async($operation.command,
                            :$incarnation, :$cancel, :$deadline);
                        X::LibTmux::Command.new(:kind<receipt>, :outcome(Indeterminate),
                            :message('CommandExecutor did not return a defined Receipt')).throw
                            unless $candidate.defined && $candidate.^does(Receipt);
                        my Mu $retained = $candidate.output-bytes;
                        X::LibTmux::Command.new(:kind<receipt>, :outcome(Indeterminate),
                            :message('Receipt output-bytes must be one nonnegative integer')).throw
                            unless $retained.defined && $retained.^isa(Int)
                                && !$retained.^isa(Bool) && $retained >= 0;
                        $acknowledgement = $candidate;
                        $output-bytes += $retained;
                        if $operation.acknowledgement-only { $outcome = Complete }
                        else {
                            $evidence = await-evidence($operation, $deadline, $cancel);
                            if $evidence.satisfied { $outcome = Complete }
                            else {
                                $failure = X::LibTmux::Command.new(:kind<completion>, :outcome(Failed),
                                    :message('Observed effect did not satisfy the operation contract'));
                                $outcome = Failed;
                            }
                        }
                        CATCH { default {
                            $failure = $_;
                            $outcome = $acknowledgement.defined ?? Indeterminate !! classification($_);
                        } }
                    }
                    if $failure.defined && $on-error eq 'stop' {
                        $stop = $failure;
                        $stop-name = $operation.name;
                    }
                    $output-bytes += error-output($failure, %counted-errors);
                    if $output-bytes >= $!output-budget-bytes && $index + 1 < $!operations.elems {
                        $stop = X::LibTmux::Command.new(:kind<output-budget>, :outcome(NotStarted),
                            :cause($failure), :message('Cumulative batch output threshold reached'));
                        $stop-name = '';
                    }
                }
                @results.push(OperationResult.bless(:$index, :name($operation.name), :$outcome,
                    :completion-scope($operation.acknowledgement-only ?? 'command' !! 'effect'),
                    :$acknowledgement, :$evidence, :error($failure), :$skip-reason,
                    :started($began), :finished(now)));
            }
            Report.bless(:operations(@results.map({ $_<> }).eager.List), :$started,
                :finished(now), :$deadline, :stop-error($stop), :$output-bytes,
                :output-budget-bytes($!output-budget-bytes))
        }
    }
}

=begin pod
=head1 Partial outcomes, not transactions

Operation requires either acknowledgement-only or a Promise of Evidence. In
command scope, Complete means a successful command acknowledgement; it does not
prove an asynchronous external effect. In effect scope, Complete additionally
requires matching named Evidence with satisfied=True. Evidence is supplied by
the caller, who must arm and correlate its operation-specific observer before
dispatch. A name match is not proof of causation. No caller callback runs inside
the batch. Its deadline bounds waiting, not the caller's independent work.
Evidence Promises are one-shot: rerunning effect-aware commands requires newly
armed evidence, rather than treating an old observation as a new completion.

The immutable Batch captures finite membership, preserving order and rejecting
duplicate names. Empty membership is a no-op. run/run-async accept an existing
Runtime, Control connection or compatible CommandExecutor and never close it.
Adapters must validate without effects, honor absolute deadlines and cancellation,
settle their execution Promises with Receipt values, and preserve effect certainty
in typed errors.
All operations share one absolute deadline. A supplied C<:deadline(Instant)>
can shorten the local C<timeout-ms> budget; it never extends that budget. The
same Instant is passed to every command and retained in the report. An already
expired deadline skips dispatch. The executor may use a shorter local limit. Cleanup retains
the executor's own separate bounds. Cancelling a dispatched Control request can
close that connection according to its documented delivery contract.

Every position receives an OperationResult. Failure stops subsequent dispatch
by default; on-error=continue attempts remaining operations while time and
cancellation permit. Never-dispatched suffixes are Skipped. A timed out or lost
in-flight effect is Indeterminate, even if acknowledgement was received. The
original exception and its outcome remain available through error/error-outcome.
No rollback is attempted or promised, and reports retain no executor owner.

output-budget-bytes defaults to 8 MiB. After each operation, Batch counts receipt
output and Command exception stdout/stderr, following shared Command causes only
once. Reaching or exceeding the threshold stops further dispatch even under
on-error=continue. The complete threshold-crossing receipt/error is retained and
the undispatched suffix is Skipped. This is an admission threshold: retained
output can reach the budget plus one executor-bounded response. It is not a hard
RSS cap; object overhead, arbitrary adapter/evidence exceptions and independent
caller-owned tasks remain outside that bound. Such adapters must accurately
report Receipt.output-bytes and bound their own responses.
=end pod
