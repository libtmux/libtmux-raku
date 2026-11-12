use v6.d;

#| Typed acquisition, decoding, query, ownership and command failures.
unit module LibTmux::Exceptions;

use LibTmux::Types;

#| Base for explicit library failures; operational failures are never absence.
class GLOBAL::X::LibTmux is Exception {
    #| Human-readable diagnostic; typed fields carry machine-readable context.
    has Str:D $.message = 'LibTmux operation failed';
}

#| A child command failed; outcome states whether an effect may have occurred.
class GLOBAL::X::LibTmux::Command is X::LibTmux {
    #| Observed child exit status, when a child completion is available.
    has Int $.exitcode;
    #| Failure category such as argument, spawn, exit, timeout, cancelled or cleanup.
    has Str:D $.kind = 'exit';
    #| What is known about effects at the failure boundary.
    has Outcome:D $.outcome = Indeterminate;
    #| Captured stdout bytes available when the operation failed.
    has Blob:D $.stdout = Blob.new;
    #| Captured stderr bytes available when the operation failed.
    has Blob:D $.stderr = Blob.new;
    #| Owned client process ID, when process creation was established.
    has Int $.pid;
    #| Observed terminating signal, when child completion is available.
    has Int $.signal;
    #| Whether cleanup established that the owned client was joined.
    has Bool:D $.reaped = False;
    #| Underlying failure retained when a later boundary adds context.
    has Exception $.cause;

    submethod TWEAK() {
        $!stdout = Blob.new($!stdout.list);
        $!stderr = Blob.new($!stderr.list);
    }

    #| Copy error context with validated fields and independent immutable byte buffers.
    method clone(*%changes --> X::LibTmux::Command:D) {
        my %arguments = message => self.message, exitcode => $!exitcode,
            kind => $!kind, outcome => $!outcome, stdout => $!stdout, stderr => $!stderr,
            pid => $!pid, signal => $!signal, reaped => $!reaped, cause => $!cause;
        for %changes.kv -> $name, $value {
            X::LibTmux::Command.new(:kind<argument>, :outcome(NotStarted),
                :message("Unknown command error field $name")).throw
                unless %arguments{$name}:exists;
            %arguments{$name} = $value;
        }
        self.WHAT.new(|%arguments)
    }
}

#| Captured bytes violate the declared projection or field codec.
class GLOBAL::X::LibTmux::Decode is X::LibTmux {
    #| Declared wire or acquisition schema that rejected the input.
    has Str:D $.schema = '';
    #| Field or relation associated with this failure, when known.
    has Str:D $.field = '';
    #| One-based record number; zero means no record was identified.
    has Count:D $.row = 0;
    #| Zero-based byte offset in the decoder context reported by this error.
    has Count:D $.offset = 0;
}

#| Criteria are invalid before any collection traversal occurs.
class GLOBAL::X::LibTmux::InvalidFilter is X::LibTmux {
    #| Criterion path identifying invalid query data.
    has Str:D $.path = '';
}

#| A requested local field or relation was not acquired in this observation.
class GLOBAL::X::LibTmux::MissingData is X::LibTmux {
    #| Field or relation associated with this failure, when known.
    has Str:D $.field = '';
    #| Availability or support state explaining this refusal.
    has ValueState:D $.state = Unloaded;
}

#| Exact or optional cardinality was violated.
class GLOBAL::X::LibTmux::Cardinality is X::LibTmux {
    #| Exact number of captured matches which violated cardinality.
    has Count:D $.count is required;
    #| Entity schema associated with this failure.
    has Str:D $.entity = '';
}

#| A capability is unavailable or not established for the connected daemon.
class GLOBAL::X::LibTmux::Unsupported is X::LibTmux {
    #| Capability identifier which could not be established or used.
    has Str:D $.feature = '';
    #| Availability or support state explaining this refusal.
    has SupportState:D $.state = Unknown;
    #| Evidence-based explanation of the unsupported or unknown capability.
    has Str:D $.reason = '';
}

#| A target belongs to a daemon incarnation which is no longer current.
class GLOBAL::X::LibTmux::StaleReference is X::LibTmux { }

#| Contextual rows disagree about one physical entity in a capture interval.
class GLOBAL::X::LibTmux::InconsistentSnapshot is X::LibTmux {
    #| Entity schema associated with this failure.
    has Str:D $.entity = '';
    #| Field or relation associated with this failure, when known.
    has Str:D $.field = '';
}
