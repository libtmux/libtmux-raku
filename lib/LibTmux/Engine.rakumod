use v6.d;

unit module LibTmux::Engine;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Capabilities;
use LibTmux::Command :DEFAULT, :internals;
use LibTmux::Transport;
use LibTmux::Format;

sub invalid(Str:D $message --> Nil) {
    X::LibTmux::Command.new(:$message, :kind<argument>, :outcome(NotStarted)).throw
}

sub text-value(Mu $value, Str:D $name, Bool :$empty = False --> Str:D) {
    invalid("$name must be a defined string without NUL")
        unless $value.^isa(Str) && $value.defined && !$value.contains("\0");
    invalid("$name cannot be empty") unless $empty || $value.chars;
    $value.Str
}

#| Immutable connection settings. Construction performs no tmux operation.
class Endpoint is export {
    #| Executable name or path used for direct argv invocation.
    has Str:D $.binary = 'tmux';
    #| Named tmux socket; empty selects the normal socket policy.
    has Str:D $.socket-name = '';
    #| Explicit socket path, resolved against the captured working directory.
    has Str:D $.socket-path = '';
    #| Explicit tmux configuration path; empty leaves the native choice unchanged.
    has Str:D $.config-file = '';
    #| Copied child environment with ambient TMUX and TMUX_PANE removed.
    has Map:D $.environment = Map.new;
    #| Absolute working directory used when launching command clients.
    has IO::Path:D $.cwd = $*CWD;
    #| Immutable executable/global-argument prefix, including UTF-8 mode.
    has List:D $.argv = ().List;
    #| Length-delimited endpoint key; this alone does not identify a daemon lifetime.
    has Str:D $.key = '';

    #| Validate and copy endpoint settings without contacting tmux.
    method new(:$binary = 'tmux', :$socket-name = '', :$socket-path = '',
               :$config-file = '', :$environment = %*ENV, :$cwd = $*CWD) is single-operation {
        my $bin = text-value($binary, 'binary');
        my $name = text-value($socket-name, 'socket-name', :empty);
        my $path = text-value($socket-path, 'socket-path', :empty);
        my $config = text-value($config-file, 'config-file', :empty);
        invalid('Specify socket-name or socket-path, not both') if $name.chars && $path.chars;
        invalid('socket-name cannot contain a slash or be a directory traversal')
            if $name.contains('/') || $name eq any('.', '..');
        invalid('cwd must be a defined path without NUL')
            unless ($cwd ~~ Str:D || $cwd ~~ IO::Path:D) && !$cwd.Str.contains("\0");
        my $directory = $cwd.IO.absolute.IO;
        invalid('environment must be associative') unless $environment ~~ Associative:D;
        my %copy;
        for $environment.kv -> Mu $key, Mu $value {
            my $entry = text-value($key, 'environment key');
            invalid('environment keys cannot contain equals') if $entry.contains('=');
            my $text = text-value($value, 'environment value', :empty);
            %copy{$entry} = $text unless $entry eq any(<TMUX TMUX_PANE>);
        }
        # Relative paths resolve in the captured cwd, not a later caller's cwd.
        $path = $directory.add($path).absolute if $path.chars && !$path.IO.is-absolute;
        $config = $directory.add($config).absolute if $config.chars && !$config.IO.is-absolute;
        my @argv = $bin, '-u';
        @argv.append('-S', $path) if $path.chars;
        @argv.append('-L', $name) if $name.chars;
        @argv.append('-f', $config) if $config.chars;
        my $key = ($bin, $path, $name, $directory.Str, %copy<TMUX_TMPDIR> // '')
            .map({ .chars ~ ':' ~ $_ }).join('|');
        self.bless(:binary($bin), :socket-name($name), :socket-path($path),
            :config-file($config), :environment(%copy.Map), :cwd($directory),
            :argv(@argv.map({ $_<> }).List), :$key)
    }

    #| Rebuild derived argv and identity when copying configuration.
    method clone(*%changes --> Endpoint:D) {
        my %arguments = binary => $!binary, socket-name => $!socket-name,
            socket-path => $!socket-path, config-file => $!config-file,
            environment => $!environment, cwd => $!cwd;
        for %changes.kv -> $name, $value {
            invalid("Unknown endpoint setting $name") unless %arguments{$name}:exists;
            %arguments{$name} = $value;
        }
        self.WHAT.new(|%arguments)
    }
}

#| Value-only daemon identity. Retaining it keeps no process or executor alive.
class Incarnation is export {
    #| Endpoint key observed for this daemon incarnation.
    has Str:D $.endpoint-key is required;
    #| Linux boot identifier contributing to process identity.
    has Str:D $.boot-id is required;
    #| Observed daemon process ID, combined with boot and start evidence.
    has Positive:D $.pid is required;
    #| Linux process start counter in kernel clock ticks.
    has Count:D $.start-ticks is required;
    #| Daemon-reported start time in Unix seconds, used by the command fence.
    has Count:D $.start-time is required;
    #| Exact daemon-reported version text; distinct from client executable version.
    has Str:D $.daemon-version is required;

    #| Return the length-delimited identity key without I/O.
    method key(--> Str:D) {
        ($!endpoint-key, $!boot-id, $!pid.Str, $!start-ticks.Str, $!start-time.Str)
            .map({ .chars ~ ':' ~ $_ }).join('|')
    }
}

#| One immutable pairing of daemon identity and capability evidence.
class Observation is export {
    #| Captured daemon identity used to reject references after replacement.
    has Incarnation:D $.incarnation is required;
    #| Immutable capability evidence bound to the same daemon incarnation.
    has LibTmux::Capabilities:D $.capabilities is required;

    submethod TWEAK() {
        X::LibTmux::Decode.new(:schema<capabilities>,
            :message('Capability evidence does not match daemon identity')).throw
            unless $!capabilities.incarnation eq $!incarnation.key
                && $!capabilities.daemon-version eq $!incarnation.daemon-version;
    }

    #| Reconstruct a validated immutable observation from copied values.
    method clone(*%changes --> Observation:D) {
        my %arguments = incarnation => $!incarnation, capabilities => $!capabilities;
        for %changes.kv -> $name, $value {
            invalid("Unknown observation setting $name") unless %arguments{$name}:exists;
            %arguments{$name} = $value;
        }
        self.WHAT.new(|%arguments)
    }
}

sub process-evidence(Int:D $pid --> Map:D) {
    my %evidence;
    my $failure;
    try {
        my $stat = "/proc/$pid/stat".IO.slurp;
        my $end = $stat.rindex(')');
        X::LibTmux::StaleReference.new(:message('Malformed process identity')).throw
            unless $end.defined;
        my @fields = $stat.substr($end + 1).words;
        X::LibTmux::StaleReference.new(:message('Process has exited')).throw
            if @fields[0] eq any(<Z X x>);
        X::LibTmux::StaleReference.new(:message('Missing process start time')).throw
            unless @fields.elems >= 20 && @fields[19] ~~ /^ <[0..9]>+ $/;
        my $boot = '/proc/sys/kernel/random/boot_id'.IO.slurp.trim;
        X::LibTmux::StaleReference.new(:message('Malformed boot identity')).throw
            unless $boot ~~ /^ <[a..f0..9\-]>+ $/;
        %evidence = boot-id => $boot, start-ticks => @fields[19].Int;
        CATCH { default { $failure = $_ } }
    }
    X::LibTmux::StaleReference.new(:message('Daemon process identity is unavailable')).throw
        if $failure.defined;
    %evidence.Map
}

sub nonce(--> Str:D) {
    my $handle = '/dev/urandom'.IO.open(:r, :bin);
    LEAVE $handle.close;
    my $bytes = $handle.read(16);
    X::LibTmux::Command.new(:kind<identity>, :outcome(NotStarted),
        :message('Cannot obtain an identity probe token')).throw unless $bytes.elems == 16;
    $bytes.list.map(*.fmt('%02x')).join
}

sub command-failure(Result:D $result, Str:D $kind = 'exit' --> Nil) {
    X::LibTmux::Command.new(:$kind, :outcome(Failed),
        :stdout($result.stdout), :stderr($result.stderr), :exitcode($result.exitcode),
        :signal($result.signal), :pid($result.pid), :reaped($result.reaped),
        :message("tmux command failed with exit {$result.exitcode}")).throw
}

#| Explicit acquisition surface shared by subprocess and persistent control owners.
role Acquirer is export {
    method endpoint(--> Endpoint:D) { ... }
    method timeout-ms(--> Positive:D) { ... }
    method observe(Cancellation :$cancel = Cancellation,
                   :$deadline = Instant --> Observation:D) { ... }
    method read(Projection:D $projection, Invocation:D $listing,
                Incarnation:D :$incarnation!, Cancellation :$cancel = Cancellation,
                :$deadline = Instant --> List:D) { ... }
}

#| Internal command-owner contract; validation is local and execution owns its lifecycle.
role CommandExecutor is export {
    method validate-command(Invocation:D $command, Incarnation:D :$incarnation! --> Nil) { ... }
    method execute-async($command, *%options --> Promise:D) { ... }
}

#| Owns bounded client execution. Captured records must not retain this owner.
class Runtime does Acquirer does CommandExecutor is export {
    #| Captured connection settings; retaining them owns no process.
    has Endpoint:D $.endpoint is required;
    has Executor $!executor;
    has Lock $!lock .= new;
    has Observation $!observation;
    has Bool $!closed = False;
    #| Maximum encoded command size in bytes, including tmux quoting.
    has Positive:D $.max-command-bytes = 12 * 1024;
    has Positive:D $.timeout-ms = 10_000;

    submethod BUILD(:$!endpoint!, :$!max-command-bytes = 12 * 1024,
                    :$!timeout-ms = 10_000, :$max-output-bytes = 8 * 1024 * 1024) {
        $!executor = Executor.new(:timeout-ms($!timeout-ms), :$max-output-bytes);
    }

    method !deadline(Mu $requested --> Instant:D) {
        invalid('deadline must be an Instant when supplied')
            unless $requested === Instant || $requested ~~ Instant:D;
        my $limit = now + $!timeout-ms / 1000;
        $requested.defined && $requested < $limit ?? $requested !! $limit
    }

    method !remaining(Instant:D $deadline, Outcome:D :$outcome = NotStarted --> Positive:D) {
        my $remaining = (($deadline - now) * 1000).ceiling.Int;
        X::LibTmux::Command.new(:kind<timeout>, :$outcome,
            :message('Operation deadline expired')).throw
            unless $remaining > 0;
        $remaining
    }

    method !admit(--> Nil) {
        $!lock.protect({
            X::LibTmux::Command.new(:kind<closed>, :outcome(NotStarted),
                :message('tmux runtime is closed')).throw if $!closed;
        });
    }

    method !dispatch(Invocation:D $command, *%options --> Result:D) {
        self!admit;
        # Reapply this owner's limit even when a caller constructed the command.
        my $bounded = Invocation.new(:argv($command.argv), :max-bytes($!max-command-bytes));
        $!executor.execute((|$!endpoint.argv, |$bounded.as-argv).List,
            :environment($!endpoint.environment), :cwd($!endpoint.cwd), |%options)
    }

    method !probe(Cancellation :$cancel = Cancellation,
                  Positive :$timeout-ms = $!timeout-ms --> Map:D) {
        my $marker = 'libtmux-probe-' ~ nonce() ~ '=';
        my $command = Invocation.new(:argv([
            'run-shell', '-C', $marker ~ '#{version}/#{pid}/#{start_time}',
        ]));
        my $result = self!dispatch($command, :!check, :$cancel, :$timeout-ms);
        my $prefix = "unknown command: $marker";
        my $diagnostic = $result.stderr.decode('utf8-c8');
        command-failure($result, 'identity') unless $result.exitcode == 1
            && !$result.signal && !$result.stdout.elems
            && $diagnostic.starts-with($prefix) && $diagnostic.ends-with("\n");
        my $payload = $diagnostic.substr($prefix.chars, $diagnostic.chars - $prefix.chars - 1);
        my @parts = $payload.split('/');
        command-failure($result, 'identity') unless @parts.elems == 3
            && @parts[0].chars && !@parts[0].contains("\n")
            && @parts[1] ~~ /^ <[0..9]>+ $/ && @parts[1].Int > 0
            && @parts[2] ~~ /^ <[0..9]>+ $/;
        Map.new(daemon-version => @parts[0], pid => @parts[1].Int,
            start-time => @parts[2].Int)
    }

    #| Observe the daemon and client separately, verifying process identity twice.
    method observe(Cancellation :$cancel = Cancellation, :$deadline = Instant --> Observation:D) is single-operation {
        await self.observe-async(:$cancel, :$deadline)
    }

    method observe-async(:$cancel = Cancellation, :$deadline = Instant --> Promise:D) is single-operation('async') {
        my $until;
        my $error;
        try { $until = self!deadline($deadline); CATCH { default { $error = $_ } } }
        return Promise.broken($error) if $error.defined;
        start {
            self!admit;
            my $client = $!executor.execute(($!endpoint.binary, '-V').List,
                :environment($!endpoint.environment), :cwd($!endpoint.cwd), :$cancel,
                :timeout-ms(self!remaining($until)));
            my $version = $client.stdout.decode('utf8-c8');
            X::LibTmux::Decode.new(:schema<client-version>,
                :message('Unexpected tmux client version response')).throw
                unless $version ~~ /^ 'tmux ' <-[\n]>+ "\n" $/;
            $version = $version.substr(5, $version.chars - 6);
            my $first = self!probe(:$cancel, :timeout-ms(self!remaining($until)));
            my $process = process-evidence($first<pid>);
            my $second = self!probe(:$cancel, :timeout-ms(self!remaining($until)));
            my $after = process-evidence($first<pid>);
            unless $first eqv $second && $process eqv $after {
                self!invalidate;
                X::LibTmux::StaleReference.new(
                    :message('Daemon changed during identity acquisition')).throw;
            }
            my $identity = Incarnation.new(:endpoint-key($!endpoint.key), |$first, |$process);
            my $caps = LibTmux::Capabilities.new(:daemon-version($first<daemon-version>),
                :client-version($version), :incarnation($identity.key),
                :source('Daemon FORMAT probe with Linux boot and process identity'));
            my $observation = Observation.new(:incarnation($identity), :capabilities($caps));
            self!remaining($until, :outcome(Complete));
            $!lock.protect({ $!observation = $observation unless $!closed });
            $observation
        }
    }

    method !invalidate(--> Nil) { $!lock.protect({ $!observation = Observation }); }

    method !current(Incarnation:D $identity --> Nil) {
        self!admit;
        my $current = try process-evidence($identity.pid);
        unless $identity.endpoint-key eq $!endpoint.key && $current.defined
            && $current<boot-id> eq $identity.boot-id
            && $current<start-ticks> == $identity.start-ticks {
            self!invalidate;
            X::LibTmux::StaleReference.new(
                :message('Command reference belongs to a replaced or unavailable daemon')).throw;
        }
    }

    method !guard(Invocation:D $command, Incarnation:D $incarnation, Str:D $refusal --> Invocation:D) {
        my $condition = '#{==:#{pid}/#{start_time},'
            ~ $incarnation.pid ~ '/' ~ $incarnation.start-time ~ '}';
        Invocation.new(:argv([
            'if-shell', '-F', $condition, $command.source, $refusal,
        ]), :max-bytes($!max-command-bytes))
    }

    #| Validate the complete guarded encoding without I/O, for batch admission.
    method validate-command(Invocation:D $command, Incarnation:D :$incarnation! --> Nil) is single-operation {
        invalid('Command incarnation belongs to another endpoint')
            unless $incarnation.endpoint-key eq $!endpoint.key;
        LibTmux::Capabilities.new(:daemon-version($incarnation.daemon-version),
            :incarnation($incarnation.key)).require('managed-commands');
        self!guard($command, $incarnation, 'libtmux-stale-' ~ ('0' x 32) ~ '=');
    }

    #| Dispatch inside a PID/start-time fence after checking Linux process identity.
    method execute($command, *%options --> Result:D) is single-operation {
        await self.execute-async($command, |%options)
    }

    method execute-async($command, :$incarnation, :$stdin = Blob.new,
                         :$cancel = Cancellation, :$check = True,
                         :$deadline = Instant --> Promise:D) is single-operation('async') {
        my $until;
        my Blob $input;
        my $error;
        try {
            $until = self!deadline($deadline);
            invalid('Managed execution requires an Invocation') unless $command ~~ Invocation:D;
            invalid('Managed execution requires an Incarnation') unless $incarnation ~~ Incarnation:D;
            invalid('check must be a defined Bool') unless $check ~~ Bool:D;
            invalid('stdin must be a defined Blob') unless $stdin ~~ Blob:D;
            $input = Blob.new($stdin.list);
            CATCH { default { $error = $_ } }
        }
        return Promise.broken($error) if $error.defined;
        start {
            self!current($incarnation);
            my $caps = LibTmux::Capabilities.new(:daemon-version($incarnation.daemon-version),
                :incarnation($incarnation.key));
            $caps.require('managed-commands');
            my $refusal = 'libtmux-stale-' ~ nonce() ~ '=';
            my $guarded = self!guard($command, $incarnation, $refusal);
            my $result = self!dispatch($guarded, :!check, :stdin($input), :$cancel,
                :timeout-ms(self!remaining($until)));
            if $result.exitcode == 1
                && $result.stderr eqv Blob.new("unknown command: $refusal\n".encode.list) {
                self!invalidate;
                X::LibTmux::StaleReference.new(
                    :message('Daemon changed before the guarded command was dispatched')).throw;
            }
            command-failure($result) if $check && ($result.exitcode || $result.signal);
            $result
        }
    }

    #| Decode one declared listing. The projection must match the same incarnation.
    method read(Projection:D $projection, Invocation:D $listing,
                Incarnation:D :$incarnation!, Cancellation :$cancel = Cancellation,
                :$deadline = Instant --> List:D) is single-operation {
        my $until = self!deadline($deadline);
        X::LibTmux::StaleReference.new(:message('Projection belongs to another daemon')).throw
            unless $projection.incarnation.chars && $projection.incarnation eq $incarnation.key;
        my $caps = LibTmux::Capabilities.new(:daemon-version($incarnation.daemon-version),
            :incarnation($incarnation.key));
        X::LibTmux::Decode.new(:schema($projection.schema),
            :message('Projection codec does not match daemon capabilities')).throw
            unless $projection.codec-profile eq $caps.codec-profile
                && $projection.output-repair eq $caps.output-repair;
        $caps.require-field($projection.entity, .name) for $projection.fields.list;
        my $command = Invocation.new(:argv([
            |$listing.argv, '-F', $projection.template,
        ]), :max-bytes($!max-command-bytes));
        my $result = self.execute($command, :$incarnation, :$cancel, :deadline($until));
        my $decoder = FrameDecoder.new(:$projection);
        my $rows = $decoder.feed($result.stdout);
        $decoder.finish;
        self!remaining($until, :outcome(Complete));
        $rows.list
    }

    #| Bounded escape hatch without daemon identity or compatibility guarantees.
    method raw(Invocation:D $command, *%options --> Result:D) is single-operation {
        self!dispatch($command, |%options)
    }

    method close(--> Nil) { await self.close-async }

    method close-async(--> Promise:D) {
        $!lock.protect({ $!closed = True; $!observation = Observation });
        $!executor.close-async
    }

    #| Reconstruct a validated immutable observation from copied values.
    method clone(| --> Nil) { invalid('An owning runtime cannot be cloned') }
}

=begin pod
=head1 Daemon identity and explicit effects

Endpoint captures argv scope and sanitized environment without I/O. Runtime
owns its executor; Observation and Incarnation retain values only. Observing
capabilities reads the daemon's version separately from the client executable.
Prepared projections and references are bound to that daemon incarnation.

Managed commands check Linux boot ID and process start ticks, then enter one
tmux command-list branch fenced by PID and tmux start time. A replacement
between those steps is refused unless it reuses the same PID and the same
second-resolution start time. That narrow race remains outside this guarantee.
Persistent control connections provide a separate, connection-bound lifetime.

Identity probes use a nonce-bearing invalid command with an equals sign and
hyphen. They cannot match tmux command-alias keys or trigger display-message
hooks. Normal dispatch of canonical built-in commands is assumed; this is not
a protocol for authenticating a hostile daemon or rewriting its configuration.

Closing Runtime stops its owned clients. It does not stop the tmux daemon or
undo effects already performed. C<raw> preserves execution bounds but provides
no managed identity or compatibility guarantee. Text passed to a command may
still have command-specific FORMAT semantics beyond command-language quoting.
=end pod
