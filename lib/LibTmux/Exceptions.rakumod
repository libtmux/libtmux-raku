use v6.d;

unit module LibTmux::Exceptions;

use LibTmux::Types;

#| Base for explicit library failures; operational failures are never absence.
class GLOBAL::X::LibTmux is Exception {
    has Str:D $.message = 'LibTmux operation failed';
}

#| A child command failed; outcome states whether an effect may have occurred.
class GLOBAL::X::LibTmux::Command is X::LibTmux {
    has Int $.exitcode;
    has Str:D $.kind = 'exit';
    has Outcome:D $.outcome = Indeterminate;
    has Blob:D $.stdout = Blob.new;
    has Blob:D $.stderr = Blob.new;
    has Int $.pid;
    has Int $.signal;
    has Bool:D $.reaped = False;
    has Exception $.cause;

    submethod TWEAK() {
        $!stdout = Blob.new($!stdout.list);
        $!stderr = Blob.new($!stderr.list);
    }

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
    has Str:D $.schema = '';
    has Str:D $.field = '';
    has Count:D $.row = 0;
    has Count:D $.offset = 0;
}

#| Criteria are invalid before any collection traversal occurs.
class GLOBAL::X::LibTmux::InvalidFilter is X::LibTmux {
    has Str:D $.path = '';
}

#| A requested local field or relation was not acquired in this observation.
class GLOBAL::X::LibTmux::MissingData is X::LibTmux {
    has Str:D $.field = '';
    has ValueState:D $.state = Unloaded;
}

#| Exact or optional cardinality was violated.
class GLOBAL::X::LibTmux::Cardinality is X::LibTmux {
    has Count:D $.count is required;
    has Str:D $.entity = '';
}

#| A capability is unavailable or not established for the connected daemon.
class GLOBAL::X::LibTmux::Unsupported is X::LibTmux {
    has Str:D $.feature = '';
    has SupportState:D $.state = Unknown;
    has Str:D $.reason = '';
}

#| A target belongs to a daemon incarnation which is no longer current.
class GLOBAL::X::LibTmux::StaleReference is X::LibTmux { }

#| Contextual rows disagree about one physical entity in a capture interval.
class GLOBAL::X::LibTmux::InconsistentSnapshot is X::LibTmux {
    has Str:D $.entity = '';
    has Str:D $.field = '';
}
