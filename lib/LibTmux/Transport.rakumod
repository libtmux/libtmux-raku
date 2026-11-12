use v6.d;
unit module LibTmux::Transport;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Command :DEFAULT, :internals;

class Executor { ... }

#| One-shot cancellation shared by explicitly selected operations.
class Cancellation is export {
    trusts Executor;
    has Lock $!lock .= new;
    has Bool $!cancelled = False;
    has Promise $!notification .= new;
    has $!vow;
    has Int $!next = 0;
    has %!observers;

    submethod TWEAK() { $!vow = $!notification.vow }

    #| Lifecycle owners cannot share mutable state through a shallow clone.
    method clone(|) { invalid('Cancellation cannot be cloned') }
    #| Read cancellation state without I/O.
    method cancelled(--> Bool:D) { $!lock.protect({ $!cancelled }) }
    #| Observe cancellation through a Promise which only this token can resolve.
    method when-cancelled(--> Promise:D) { $!notification }
    #| Cancel all subscribed operations once; repeated calls have no further effect.
    method cancel(--> Nil) {
        my @observers = $!lock.protect({
            return if $!cancelled;
            $!cancelled = True;
            $!vow.keep(True);
            my @pending = %!observers.values;
            %!observers = ();
            @pending.List
        });
        .() for @observers;
    }

    method !subscribe(&observer --> Int:D) {
        my $id = $!lock.protect({
            if $!cancelled { 0 } else {
                %!observers{++$!next} = &observer;
                $!next
            }
        });
        observer() unless $id;
        $id
    }
    method !unsubscribe(Int:D $id --> Nil) {
        $!lock.protect({ %!observers{$id}:delete });
    }
}

#| Internal retained-output accounting shared by command executor adapters.
role Receipt is export {
    method output-bytes(--> Count:D) { ... }
}

#| Captured child output. Complete means process completion, not application effects.
class Result does Receipt is export {
    #| Captured stdout bytes; no text normalization or implicit decoding is applied.
    has Blob:D $.stdout = Blob.new;
    #| Captured stderr bytes, drained concurrently with stdout.
    has Blob:D $.stderr = Blob.new;
    #| Child exit status; inspect signal separately for signal termination.
    has Int:D $.exitcode = 0;
    #| Terminating signal number, or zero for ordinary process exit.
    has Int:D $.signal = 0;
    #| Owned client process ID associated with this result.
    has Int:D $.pid = 0;
    #| Whether the owned client completion was joined.
    has Bool:D $.reaped = True;
    #| Known command outcome; Complete does not prove an external application effect.
    has Outcome:D $.outcome = Complete;

    submethod TWEAK() {
        $!stdout = Blob.new($!stdout.list);
        $!stderr = Blob.new($!stderr.list);
    }

    #| Retained stdout and stderr bytes, excluding fixed metadata and object overhead.
    method output-bytes(--> Count:D) { $!stdout.elems + $!stderr.elems }

    #| Reconstruct copies through the constructor, including replacement byte buffers.
    method clone(*%changes --> Result:D) {
        my %values = stdout => $!stdout, stderr => $!stderr,
            exitcode => $!exitcode, signal => $!signal, pid => $!pid,
            reaped => $!reaped, outcome => $!outcome;
        for %changes.kv -> $name, $value {
            invalid("Unknown Result attribute $name") unless %values{$name}:exists;
            %values{$name} = $value;
        }
        self.WHAT.new(|%values)
    }
}

# Proc::Async treats an empty Hash as an omitted environment on Rakudo 2026.09.
my class Environment {
    has Map:D $.entries is required;
    method Bool(--> Bool:D) { True }
    method hash(--> Hash:D) { $!entries.Hash }
}

my class Stop {
    has Lock $!lock .= new;
    has Str $!reason = '';
    has Bool $!finished = False;
    has Promise $.notification .= new;
    has $!vow;
    submethod TWEAK() { $!vow = $!notification.vow }
    method reason(--> Str:D) { $!lock.protect({ $!reason }) }
    method signal(Str:D $reason --> Nil) {
        $!lock.protect({
            unless $!reason.chars || $!finished {
                $!reason = $reason;
                $!vow.keep(True);
            }
        });
    }
    method launch(&spawn --> Bool:D) {
        $!lock.protect({
            return False if $!reason.chars;
            spawn();
            True
        })
    }
    method finish(--> Str:D) {
        $!lock.protect({ $!finished = True; $!reason })
    }
}

my class Work {
    has Stop $.stop .= new;
    has Promise $.done .= new;
    has $!vow;
    submethod TWEAK() { $!vow = $!done.vow }
    method complete($result, $error --> Nil) {
        $error.defined ?? $!vow.break($error) !! $!vow.keep($result);
    }
}

sub invalid(Str:D $message --> Nil) {
    X::LibTmux::Command.new(:kind<argument>, :outcome(NotStarted), :$message).throw;
}

sub cancellation-observer(Stop:D $stop --> Callable:D) {
    -> { $stop.signal('cancelled') }
}
sub deadline(Stop:D $stop, Positive:D $milliseconds) {
    $*SCHEDULER.cue({ $stop.signal('timeout') }, :in($milliseconds / 1000))
}

#| Owns bounded subprocess operations and joins all admitted work during close.
class Executor is export {
    has Positive:D $.timeout-ms = 10_000;
    #| Combined output-byte limit for one owned command response.
    has Positive:D $.max-output-bytes = 8 * 1024 * 1024;
    has Positive:D $.cleanup-timeout-ms = 1_000;
    has Lock $!lock .= new;
    has Bool $!closing = False;
    has Int $!next = 0;
    has %!work;
    has Promise $!closed .= new;
    has $!closed-vow;
    has Exception $!cleanup-failure;

    submethod TWEAK() { $!closed-vow = $!closed.vow }

    #| Lifecycle owners cannot share mutable state through a shallow clone.
    method clone(|) { invalid('Executor cannot be cloned') }
    #| Await the same bounded operation used by execute-async.
    method execute(Mu $argv, *%options --> Result:D) is single-operation {
        await self.execute-async($argv, |%options)
    }

    #| Snapshot arguments and run one child; errors break the returned Promise.
    method execute-async(Mu $argv, Mu :$stdin = Blob.new,
        Mu :$environment = %*ENV, Mu :$cwd = $*CWD,
        Mu :$cancel = Cancellation, Mu :$check = True,
        Mu :$timeout-ms = $!timeout-ms --> Promise:D) is single-operation('async') {
        my Str @arguments;
        my Blob $input;
        my Environment $env;
        my IO::Path $directory;
        my $error;
        try {
            for $argv, $stdin, $environment, $cwd, $cancel, $check, $timeout-ms -> Mu $value {
                invalid('An operation argument cannot be a Junction') if $value.^isa(Junction);
            }
            invalid('argv must be a nonempty positional collection')
                unless $argv ~~ Positional:D && $argv.elems;
            for $argv.list -> Mu $argument {
                invalid('every argv value must be a defined Str without NUL')
                    unless !$argument.^isa(Junction) && $argument ~~ Str:D && !$argument.contains("\0");
                @arguments.push($argument.Str);
            }
            invalid('the executable must not be empty') unless @arguments[0].chars;
            invalid('stdin must be a defined Blob') unless $stdin ~~ Blob:D;
            $input = Blob.new($stdin.list);
            invalid('environment must be associative') unless $environment ~~ Associative:D;
            my %entries;
            for $environment.kv -> Mu $key, Mu $value {
                invalid('environment names and values must be defined NUL-free strings')
                    unless !$key.^isa(Junction) && !$value.^isa(Junction) &&
                        $key ~~ Str:D && $key.chars && !$key.contains('=') &&
                        !$key.contains("\0") && $value ~~ Str:D && !$value.contains("\0");
                %entries{$key.Str} = $value.Str;
            }
            $env = Environment.new(:entries(%entries.Map));
            invalid('cwd must be a defined path without NUL')
                unless ($cwd ~~ Str:D || $cwd ~~ IO::Path:D) && !$cwd.Str.contains("\0");
            $directory = $cwd.IO.absolute.IO;
            invalid('cancel must be a Cancellation token')
                unless $cancel === Cancellation || $cancel ~~ Cancellation:D;
            invalid('check must be a defined Bool') unless $check ~~ Bool:D;
            invalid('timeout-ms must be a positive integer') unless $timeout-ms ~~ Positive:D;
            CATCH { default { $error = $_ } }
        }
        return Promise.broken($error) if $error.defined;
        my $work = Work.new;
        my $id;
        $!lock.protect({
            if $!closing {
                $error = X::LibTmux::Command.new(:kind<closed>, :outcome(NotStarted),
                    :message('executor is closed'));
            } else {
                $id = ++$!next;
                %!work{$id} = $work;
            }
        });
        return Promise.broken($error) if $error.defined;
        my $subscription = $cancel.defined
            ?? $cancel!Cancellation::subscribe(cancellation-observer($work.stop)) !! 0;
        my $timer = deadline($work.stop, $timeout-ms);
        my $worker = start {
            LEAVE $timer.cancel;
            my $result;
            my $failure;
            try {
                $result = self!perform($work, @arguments, $input, $env, $directory, $check);
                CATCH { default { $failure = $_ } }
            }
            $cancel!Cancellation::unsubscribe($subscription) if $cancel.defined;
            $!lock.protect({
                if $failure ~~ X::LibTmux::Command &&
                    $failure.outcome == Indeterminate && !$failure.reaped {
                    $!cleanup-failure //= $failure;
                }
                $work.complete($result, $failure);
                %!work{$id}:delete;
            });
        };
        $work.done
    }

    method !perform(Work:D $work, @arguments, Blob:D $input,
        Environment:D $environment, IO::Path:D $cwd, Bool:D $check --> Result:D) {
        my $reason = $work.stop.reason;
        X::LibTmux::Command.new(:kind($reason), :outcome(NotStarted),
            :message("operation $reason before starting")).throw if $reason.chars;
        my $proc = Proc::Async.new(:w, |@arguments);
        my $stdout = Buf.new;
        my $stderr = Buf.new;
        my $output-lock = Lock.new;
        my Exception $io-failure;
        my &record-io = -> $cause {
            my $error = $cause ~~ Exception ?? $cause
                !! X::LibTmux::Command.new(:kind<io>, :message('process I/O failed'));
            $output-lock.protect({ $io-failure //= $error });
            $work.stop.signal('io');
        };
        my &collect = -> Buf:D $buffer, Blob:D $chunk {
            my $overflow = False;
            try {
                $output-lock.protect({
                    my $remaining = $!max-output-bytes - $stdout.elems - $stderr.elems;
                    $overflow = $chunk.elems > $remaining;
                    $buffer.append($overflow ?? $chunk.subbuf(0, $remaining) !! $chunk);
                });
                $work.stop.signal('overflow') if $overflow;
                CATCH { default { record-io($_) } }
            }
        };
        my $out-tap = $proc.stdout(:bin).tap(
            -> $chunk { collect($stdout, $chunk) }, :quit(&record-io));
        my $err-tap = $proc.stderr(:bin).tap(
            -> $chunk { collect($stderr, $chunk) }, :quit(&record-io));
        LEAVE {
            $out-tap.close if $out-tap.defined;
            $err-tap.close if $err-tap.defined;
        }
        my $done;
        my $spawn-error;
        my $launched;
        try {
            $launched = $work.stop.launch({
                $done = $proc.start(:ENV($environment), :$cwd);
            });
            CATCH { default { $spawn-error = $_ } }
        }
        X::LibTmux::Command.new(:kind<spawn>, :outcome(NotStarted),
            :message('could not spawn command'), :cause($spawn-error)).throw
            if $spawn-error.defined;
        unless $launched {
            $reason = $work.stop.finish;
            X::LibTmux::Command.new(:kind($reason), :outcome(NotStarted),
                :message("operation $reason before starting")).throw;
        }
        my $writer = start {
            try {
                my $pid = await $proc.ready;
                my $written = await $proc.write($input) if $input.elems;
                $proc.close-stdin;
                CATCH { default { record-io($_) } }
            }
        };
        my $settled = Promise.allof($done, $writer);
        await Promise.anyof($settled, $work.stop.notification);
        $reason = $work.stop.reason;
        if $reason.chars && $settled.status == Planned {
            my $closed-input = try $proc.close-stdin;
            my $killed = try $proc.kill(SIGKILL);
            await Promise.anyof($settled, Promise.in($!cleanup-timeout-ms / 1000));
        }
        my $pid = $proc.pid.status == Kept ?? $proc.pid.result !! Int;
        if $settled.status == Planned {
            my ($out, $err);
            $output-lock.protect({
                $out = Blob.new($stdout.list);
                $err = Blob.new($stderr.list);
            });
            X::LibTmux::Command.new(:kind<cleanup>, :outcome(Indeterminate),
                :message('command did not settle after forced termination'),
                :$pid, :stdout($out), :stderr($err), :reaped(False)).throw;
        }
        $reason = $work.stop.finish;
        my $out = Blob.new($stdout.list);
        my $err = Blob.new($stderr.list);
        if $proc.ready.status == Broken {
            X::LibTmux::Command.new(:kind<spawn>, :outcome(NotStarted),
                :message('could not spawn command'), :stdout($out), :stderr($err),
                :cause($proc.ready.cause)).throw;
        }
        if $done.status == Broken {
            X::LibTmux::Command.new(:kind<io>, :outcome(Indeterminate),
                :message('command process failed before completion'), :$pid,
                :stdout($out), :stderr($err), :cause($done.cause)).throw;
        }
        my $status = $done.result;
        if $reason.chars {
            X::LibTmux::Command.new(:kind($reason), :outcome(Indeterminate),
                :message("command stopped: $reason"), :$pid,
                :exitcode($status.exitcode), :signal($status.signal), :reaped,
                :stdout($out), :stderr($err), :cause($io-failure)).throw;
        }
        my $failed = $status.exitcode != 0 || $status.signal != 0;
        if $failed && $check {
            X::LibTmux::Command.new(:kind<exit>, :outcome(Failed),
                :message('command exited unsuccessfully'), :$pid,
                :exitcode($status.exitcode), :signal($status.signal), :reaped,
                :stdout($out), :stderr($err)).throw;
        }
        Result.new(:stdout($out), :stderr($err), :$pid,
            :exitcode($status.exitcode), :signal($status.signal),
            :outcome($failed ?? Failed !! Complete))
    }

    #| Await teardown of every operation admitted by this executor.
    method close(--> Nil) { await self.close-async }
    #| Stop admission and share one teardown completion, including any cleanup failure.
    method close-async(--> Promise:D) {
        my @active;
        my $owner = $!lock.protect({
            if $!closing { False } else {
                $!closing = True;
                @active = %!work.values;
                True
            }
        });
        if $owner {
            .stop.signal('closed') for @active;
            my $cleanup = start {
                await Promise.allof(@active.map(*.done));
                my $failure = $!lock.protect({ $!cleanup-failure });
                $failure.defined ?? $!closed-vow.break($failure)
                    !! $!closed-vow.keep(True);
            };
        }
        $!closed
    }
}

=begin pod
=head1 Bounded child processes

Executor accepts a nonempty positional argv of defined, NUL-free strings.
It invokes that executable directly. Shell syntax, tmux command syntax and
FORMAT expansion belong to callers above this layer.

C<execute> returns a Result. C<execute-async> always returns a Promise,
including for invalid arguments or closed admission. Each call copies argv,
environment entries and input bytes before asynchronous work begins. An
omitted environment copies the current environment; an explicit empty mapping
passes no variables. Input is a Blob, and the child receives EOF after those
bytes are written. Both output streams are binary and drain concurrently.

C<timeout-ms> bounds an admitted operation, C<max-output-bytes> bounds combined
retained stdout/stderr, and C<cleanup-timeout-ms> bounds waiting after forced
termination. Their defaults are 10000 ms, 8388608 bytes and 1000 ms. All are
positive integers. Encoded tmux command size has a separate Engine policy.
C<execute> and C<execute-async> accept an optional C<timeout-ms> override for
callers sharing one deadline across several child operations.

By default a nonzero exit or signal throws X::LibTmux::Command. C<:!check>
returns its Result with outcome Failed instead. Spawn failure, invalid input,
timeout, cancellation, output overflow and I/O failures still throw. Error
records retain bounded output bytes, process identity and reaping evidence.
NotStarted means no child effects were admitted. Failed and Indeterminate do
not mean that earlier effects were rolled back. Complete means child process
completion, not completion of a program controlled through tmux.

Cancellation is one shot. Dropping an operation Promise does not cancel its
child. Explicit cancellation and executor close terminate admitted children;
close callers share one Promise. A close failure remains observable on later
close calls. The executor owns direct child clients, not programs deliberately
started in a tmux pane or arbitrary descendant daemons.
Executor and Cancellation cannot be cloned. Result clones reconstruct and
validate replacement attributes, copying output bytes again.
=end pod
