use v6.d;

use LibTmux::Engine;

unit class LibTmux::Control::Connection does Acquirer does CommandExecutor;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Transport;
use LibTmux::Command :DEFAULT, :internals;
use LibTmux::Format;
use LibTmux::Control;
use LibTmux::Control :internal;
use LibTmux::Model;
use LibTmux::Query::Plan :DEFAULT, :internal;
use LibTmux::Query::Execution;

sub invalid(Str:D $message --> Nil) {
    X::LibTmux::Command.new(:kind<argument>, :outcome(NotStarted), :$message).throw
}

sub token(--> Str:D) {
    my $handle = '/dev/urandom'.IO.open(:r, :bin);
    LEAVE $handle.close;
    my $bytes = $handle.read(16);
    invalid('Cannot obtain a control correlation token') unless $bytes.elems == 16;
    $bytes.list.map(*.fmt('%02x')).join
}

my class Environment {
    has Map:D $.entries is required;
    method Bool(--> Bool:D) { True }
    method hash(--> Hash:D) { $!entries.Hash }
}

#| Ordered command records observed before a separate queue barrier completed.
class Acknowledgement does Receipt {
    #| Ordered response blocks and unframed output preceding the completion barrier.
    has List:D $.records = ().List;
    #| Unique connection identity; reconnecting always creates a new epoch.
    has Str:D $.epoch is required;
    submethod TWEAK() { $!records = $!records.map({ $_<> }).List }
    #| Whether any framed response ended with a command error guard.
    method failed(--> Bool:D) { so $!records.grep({ $_ ~~ Response && .failed }) }
    #| Retained protocol payload bytes, excluding bounded record metadata.
    method output-bytes(--> Count:D) {
        [+] $!records.map({ $_ ~~ Response ?? .payload.elems !! .raw.elems })
    }
    #| Copy response and unframed payload bytes in their received order.
    method payload(--> Blob:D) {
        my $bytes = Buf.new;
        for $!records.list -> $record {
            if $record ~~ Response { $bytes.append($record.payload) }
            else { $bytes.append($record.raw); $bytes.push(10) }
        }
        Blob.new($bytes.list)
    }
    #| Refuse altered copies of this received acknowledgement.
    method clone(|) { invalid('An acknowledgement cannot be cloned') }
}

my class Request {
    has Int:D $.id is required;
    has Str:D $.wire is required;
    has Str:D $.prefix is required;
    has Blob:D $.marker is required;
    has Bool:D $.check = True;
    has Instant:D $.deadline is required;
    has Promise $.reply .= new;
    has $!vow;
    has Bool $.sent is rw = False;
    has Bool $.settled is rw = False;
    has Int $.bytes is rw = 0;
    has @.records;
    has $.timer is rw;
    has Tap $.cancel-tap is rw;
    submethod TWEAK() { $!vow = $!reply.vow }
    method finish($value, $error --> Nil) {
        return if $!settled;
        $!settled = True;
        $error.defined ?? $!vow.break($error) !! $!vow.keep($value);
        $!timer.cancel if $!timer.defined;
        $!cancel-tap.close if $!cancel-tap.defined;
    }
}

#| Captured connection settings; retaining them owns no process.
has Endpoint:D $.endpoint is required;
has Observation:D $!observation is required;
#| Session used for the initial attach; explicit client switching can later change it.
has SessionId:D $.session-id is required;
#| Default request deadline budget in milliseconds from admission.
has Positive:D $.timeout-ms = 10_000;
#| Separate termination and reaping budget in milliseconds.
has Positive:D $.cleanup-timeout-ms = 1_000;
#| Maximum admitted requests, including the active request and queued cancellations.
has Positive:D $.max-pending = 128;
#| Per-response output-byte limit; retained stderr has the same separate bound.
has Positive:D $.max-output-bytes = 8 * 1024 * 1024;
#| Maximum encoded command size in bytes, including tmux quoting.
has Positive:D $.max-command-bytes = 12 * 1024;
#| Unique connection identity; reconnecting always creates a new epoch.
has Str:D $.epoch = '';
has EventStream $!events;
has Decoder $!decoder;
has Proc::Async $!proc;
has Promise $!process;
has Promise $!worker;
has Promise $!launched .= new;
has $!launch-vow;
has Promise $!closed .= new;
has $!close-vow;
has Lock $!lock .= new;
has Lock $!decode-lock .= new;
has Channel $!queue .= new;
has Int $!next = 0;
has %!pending;
has Request $!active;
has Bool $!closing = False;
has Bool $!reaped = False;
has Exception $!failure;
has Buf $!stderr = Buf.new;
has Tap $!out-tap;
has Tap $!err-tap;

submethod BUILD(:$!endpoint!, :$observation!, :$!session-id!, :$!timeout-ms = 10_000,
    :$!cleanup-timeout-ms = 1_000, :$!max-pending = 128,
    :$!max-output-bytes = 8 * 1024 * 1024, :$!max-command-bytes = 12 * 1024,
    :$max-events = 256, :$max-event-bytes = 1024 * 1024) {
    $!observation = $observation.clone(:capabilities($observation.capabilities.clone(
        :negotiated-features(('control-mode',).List))));
    $!epoch = token();
    $!events = EventStream.new(:$max-events, :max-bytes($max-event-bytes));
    $!decoder = Decoder.new(:max-response-bytes($!max-output-bytes));
}

submethod TWEAK() {
    $!launch-vow = $!launched.vow;
    $!close-vow = $!closed.vow;
}

#| Refuse unstarted owners; construct a live owner through connect.
method new(|) { invalid('Use Control::Connection.connect for an owned live connection') }
#| Refuse cloning of a process and its pending request state.
method clone(|) { invalid('An owning control connection cannot be cloned') }
#| All taps share this process; each receives independently bounded live delivery.
method events(--> Supply:D) { $!events.Supply }
#| Return the immutable identity and negotiated capabilities established at connection time.
method observation(--> Observation:D) { $!observation }
#| Shared completion Promise for connection shutdown; callers cannot resolve it.
method closed(--> Promise:D) { $!closed }
#| Whether the owned control client has exited and been joined.
method reaped(--> Bool:D) { $!lock.protect({ $!reaped }) }
#| Terminal connection error, or an undefined Exception after normal close.
method failure(--> Exception) { $!lock.protect({ $!failure }) }
#| Owned control-client PID, or undefined before successful process creation.
method pid(--> Int) { $!proc.defined && $!proc.pid.status == Kept ?? $!proc.pid.result !! Int }

#| Observe, attach and verify a persistent connection to an exact session ID.
method connect(*%options --> LibTmux::Control::Connection:D) is single-operation { await self.connect-async(|%options) }
#| Resolve to a verified connection or reject after bounded startup cleanup.
method connect-async(:$endpoint!, :$session-id!, :$incarnation = Incarnation,
    :$timeout-ms = 10_000, :$cleanup-timeout-ms = 1_000, :$max-pending = 128,
    :$max-output-bytes = 8 * 1024 * 1024, :$max-command-bytes = 12 * 1024,
    :$max-events = 256, :$max-event-bytes = 1024 * 1024,
    :$new-layouts = 'auto', :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    my $deadline;
    my $error;
    try {
        invalid('endpoint must be an Endpoint') unless $endpoint ~~ Endpoint:D;
        invalid('session-id must be an exact session ID') unless $session-id ~~ SessionId:D;
        invalid('incarnation must be an Incarnation when supplied')
            unless $incarnation === Incarnation || $incarnation ~~ Incarnation:D;
        invalid('Control limits must be positive integers') unless
            ($timeout-ms, $cleanup-timeout-ms, $max-pending, $max-output-bytes,
                $max-command-bytes, $max-events, $max-event-bytes).all ~~ Positive:D;
        invalid('new-layouts must be auto, True or False')
            unless ($new-layouts ~~ Str:D && $new-layouts eq 'auto') || $new-layouts ~~ Bool:D;
        invalid('cancel must be a Cancellation token')
            unless $cancel === Cancellation || $cancel ~~ Cancellation:D;
        $deadline = now + $timeout-ms / 1000;
        CATCH { default { $error = $_ } }
    }
    return Promise.broken($error) if $error.defined;
    start {
        my $runtime = Runtime.new(:$endpoint, :$timeout-ms, :$max-output-bytes, :$max-command-bytes);
        LEAVE $runtime.close;
        my $observed = $runtime.observe(:$deadline, :$cancel);
        X::LibTmux::StaleReference.new(:message('Control target belongs to another daemon')).throw
            if $incarnation.defined && $incarnation.key ne $observed.incarnation.key;
        $observed.capabilities.require('control-mode');
        my $modern = $new-layouts ~~ Bool:D ?? $new-layouts
            !! $observed.capabilities.supports('control-new-layouts');
        $observed.capabilities.require('control-new-layouts') if $modern;
        my $connection = self.bless(:$endpoint, :observation($observed), :$session-id,
            :$timeout-ms, :$cleanup-timeout-ms, :$max-pending, :$max-output-bytes,
            :$max-command-bytes, :$max-events, :$max-event-bytes);
        my $failure;
        try {
            $connection!launch;
            await $connection!submit(Invocation, :$deadline, :$cancel);
            if $modern {
                await $connection!submit(Invocation.new(:argv(['refresh-client', '-f', 'new-layouts'])),
                    :$deadline, :$cancel);
                $connection!negotiated;
            }
            CATCH { default { $failure = $_ } }
        }
        if $failure.defined {
            my $cleanup-error;
            try { $connection.close; CATCH { default { $cleanup-error = $_ } } }
            X::LibTmux::Command.new(:kind<cleanup>, :outcome(Indeterminate),
                :cause($failure), :pid($connection.pid), :reaped(False),
                :message("Control startup failed and cleanup failed: {$cleanup-error.message}")).throw
                if $cleanup-error.defined;
            $failure.rethrow;
        }
        $connection
    }
}

method !negotiated(--> Nil) {
    $!observation = $!observation.clone(:capabilities($!observation.capabilities.clone(
        :negotiated-features(('control-mode', 'control-new-layouts').List))));
}

method !launch(--> Nil) {
    LEAVE $!launch-vow.keep(True);
    $!proc = Proc::Async.new(:w, |$!endpoint.argv,
        '-N', '-C', 'attach-session', '-f', 'ignore-size', '-t', $!session-id);
    $!out-tap = $!proc.stdout(:bin).tap(-> $chunk {
        try {
            $!decode-lock.protect({
                self!record($_) for $!decoder.feed($chunk).list;
            });
            CATCH { default { self!stop($_) } }
        }
    }, :quit({ self!stop($_) }));
    $!err-tap = $!proc.stderr(:bin).tap(-> $chunk {
        my $overflow = $!lock.protect({
            my $remaining = $!max-output-bytes - $!stderr.elems;
            $!stderr.append($chunk.subbuf(0, $remaining min $chunk.elems));
            $chunk.elems > $remaining
        });
        self!stop(X::LibTmux::Command.new(:kind<overflow>,
            :message('Control stderr exceeded its byte limit'))) if $overflow;
    }, :quit({ self!stop($_) }));
    try {
        $!process = $!proc.start(:ENV(Environment.new(:entries($!endpoint.environment))),
            :cwd($!endpoint.cwd));
        CATCH { default {
            my $failure = X::LibTmux::Command.new(:kind<spawn>, :outcome(NotStarted),
                :message('Could not spawn control client'), :cause($_));
            self!stop($failure);
            $failure.throw;
        } }
    }
    $!worker = start { self!work };
    my $watcher = $!process.then(-> $done {
        my $failure;
        try {
            $!decode-lock.protect({ $!decoder.finish });
            CATCH { default { $failure = $_ } }
        }
        $failure //= X::LibTmux::Command.new(
            :kind($!proc.ready.status == Broken ?? 'spawn' !! 'disconnected'),
            :outcome($!proc.ready.status == Broken ?? NotStarted !! Indeterminate),
            :message('Control client disconnected'), :pid(self.pid),
            :stderr(Blob.new($!stderr.list)), :reaped($done.status == Kept));
        self!stop($failure);
    });
}

method !record($record --> Nil) {
    if $record ~~ Event {
        $!events.emit($record);
        return unless $record ~~ UnframedOutput;
    }
    my $fatal;
    $!lock.protect({
        return if $!closing;
        # Initial attach and hook responses use flags 0, not our submitted group.
        return if $record ~~ Response && $record.flags == 0;
        return unless $!active.defined && !$!active.settled;
        if $record ~~ Response && $record.payload.decode('utf8-c8').starts-with($!active.prefix) {
            if $record.failed || !($record.payload eqv $!active.marker) {
                $fatal = X::LibTmux::StaleReference.new(
                    :message('Connected daemon does not match the observed incarnation'));
            } else {
                my $reply = Acknowledgement.new(:records($!active.records.List), :$!epoch);
                my $failure = $reply.failed && $!active.check
                    ?? X::LibTmux::Command.new(:kind<control-command>, :outcome(Failed),
                        :stdout($reply.payload), :message('Control command reported an error')) !! Exception;
                $!active.finish($reply, $failure);
            }
        } else {
            $!active.bytes += $record ~~ Response ?? $record.payload.elems !! $record.raw.elems + 1;
            if $!active.bytes > $!max-output-bytes || $!active.records.elems >= 4096 {
                $fatal = X::LibTmux::Command.new(:kind<overflow>,
                    :message('Control command output exceeded its limit'));
            } else { $!active.records.push($record) }
        }
    });
    self!stop($fatal) if $fatal.defined;
}

method !work(--> Nil) {
    loop {
        my $request = $!queue.receive;
        last unless $request ~~ Request;
        my $send = $!lock.protect({
            if $!closing || $request.settled { False }
            else { $!active = $request; $request.sent = True; True }
        });
        if $send {
            try {
                await $!proc.ready;
                await $!proc.write($request.wire.encode('utf8-c8'));
                await $request.reply;
                CATCH { default {
                    self!stop(X::LibTmux::Command.new(:kind<io>, :cause($_),
                        :message('Control write failed'))) unless $request.settled;
                } }
            }
        }
        $!lock.protect({
            $!active = Request if $!active.defined && $!active.id == $request.id;
            %!pending{$request.id}:delete;
        });
    }
}

method !expire(Request:D $request, Str:D $kind --> Nil) {
    my $stop = False;
    my $failure;
    $!lock.protect({
        return if $request.settled;
        $failure = X::LibTmux::Command.new(:$kind,
            :outcome($request.sent ?? Indeterminate !! NotStarted),
            :message("Control request $kind"));
        $stop = $request.sent;
        $request.finish(Any, $failure) unless $stop;
    });
    self!stop($failure) if $stop;
}

method !submit($command, Instant:D :$deadline!, :$cancel = Cancellation,
    Bool:D :$check = True --> Promise:D) {
    my $request;
    my $error;
    try {
        invalid('Control command must be an Invocation')
            unless $command === Invocation || $command ~~ Invocation:D;
        invalid('cancel must be a Cancellation token')
            unless $cancel === Cancellation || $cancel ~~ Cancellation:D;
        X::LibTmux::Command.new(:kind<cancelled>, :outcome(NotStarted),
            :message('Control request cancelled before admission')).throw
            if $cancel.defined && $cancel.cancelled;
        X::LibTmux::Command.new(:kind<timeout>, :outcome(NotStarted),
            :message('Control deadline expired before admission')).throw if $deadline <= now;
        my $prefix = 'LTC1-' ~ token() ~ ' ';
        my $identity = $!observation.incarnation;
        my $expected = $prefix ~ $identity.pid ~ '/' ~ $identity.start-time
            ~ '/' ~ $identity.daemon-version ~ "\n";
        my $barrier = Invocation.new(:argv(['display-message', '-p',
            $prefix ~ '#{pid}/#{start_time}/#{version}']), :max-bytes($!max-command-bytes));
        my $wire = $command.defined ?? Invocation.new(:argv($command.argv),
            :max-bytes($!max-command-bytes)).source ~ "\n" !! '';
        $wire ~= $barrier.source ~ "\n";
        $!lock.protect({
            X::LibTmux::Command.new(:kind<closed>, :outcome(NotStarted),
                :message('Control connection is closed')).throw if $!closing;
            X::LibTmux::Command.new(:kind<overflow>, :outcome(NotStarted),
                :message('Control pending queue is full')).throw if %!pending.elems >= $!max-pending;
            $request = Request.new(:id(++$!next), :$wire, :$prefix,
                :marker(Blob.new($expected.encode.list)),
                :$deadline, :$check);
            %!pending{$request.id} = $request;
        });
        my $timer = $*SCHEDULER.cue({ self!expire($request, 'timeout') },
            :in(0 max ($deadline - now).Numeric));
        $!lock.protect({
            $request.timer = $timer;
            $timer.cancel if $request.settled;
        });
        if $cancel.defined {
            my $tap = $cancel.when-cancelled.Supply.tap(
                -> $ { self!expire($request, 'cancelled') }, :quit({ self!stop($_) }));
            $!lock.protect({
                $request.cancel-tap = $tap;
                $tap.close if $request.settled;
            });
        }
        $!lock.protect({
            if $!closing { %!pending{$request.id}:delete }
            else { $!queue.send($request) }
        });
        CATCH { default { $error = $_ } }
    }
    $error.defined ?? Promise.broken($error) !! $request.reply
}

#| Execute one raw command, waiting for a separate queue barrier; no rollback is implied.
method execute($command, *%options --> Acknowledgement:D) is single-operation { await self.execute-async($command, |%options) }

#| Validate an encoded command against this connection without I/O or queue admission.
method validate-command(Invocation:D $command, Incarnation:D :$incarnation! --> Nil) is single-operation {
    X::LibTmux::StaleReference.new(:message('Command belongs to another daemon')).throw
        unless $incarnation.key eq $!observation.incarnation.key;
    Invocation.new(:argv($command.argv), :max-bytes($!max-command-bytes));
}

method !deadline($requested --> Instant:D) {
    invalid('deadline must be an Instant when supplied')
        unless $requested === Instant || $requested ~~ Instant:D;
    my $limit = now + $!timeout-ms / 1000;
    $requested.defined && $requested < $limit ?? $requested !! $limit
}

#| Queue one command and resolve its ordered acknowledgement; cancellation may close the connection.
method execute-async($command, :$incarnation = Incarnation, :$cancel = Cancellation,
    :$check = True, :$deadline = Instant --> Promise:D) is single-operation('async') {
    my $until;
    my $error;
    try {
        invalid('Control command must be an Invocation') unless $command ~~ Invocation:D;
        invalid('check must be a Bool') unless $check ~~ Bool:D;
        invalid('incarnation must be an Incarnation when supplied')
            unless $incarnation === Incarnation || $incarnation ~~ Incarnation:D;
        X::LibTmux::StaleReference.new(:message('Command belongs to another daemon')).throw
            if $incarnation.defined && $incarnation.key ne $!observation.incarnation.key;
        $until = self!deadline($deadline);
        CATCH { default { $error = $_ } }
    }
    return Promise.broken($error) if $error.defined;
    self!submit($command, :deadline($until), :$cancel, :$check)
}

#| Read a declared projection through the connection's negotiated codec profile.
method read(Projection:D $projection, Invocation:D $listing,
    Incarnation:D :$incarnation!, :$deadline = Instant, :$cancel = Cancellation --> List:D) is single-operation {
    my $until = self!deadline($deadline);
    X::LibTmux::StaleReference.new(:message('Projection belongs to another daemon')).throw
        unless $projection.incarnation eq $incarnation.key
            && $incarnation.key eq $!observation.incarnation.key;
    my $caps = $!observation.capabilities;
    X::LibTmux::Decode.new(:schema($projection.schema),
        :message('Projection does not match the control codec profile')).throw
        unless $projection.codec-profile eq $caps.codec-profile
            && $projection.output-repair eq $caps.output-repair;
    $caps.require-field($projection.entity, .name) for $projection.fields.list;
    my $report = self.execute(Invocation.new(:argv([|$listing.argv, '-F', $projection.template])),
        :$incarnation, :deadline($until), :$cancel);
    my $decoder = FrameDecoder.new(:$projection);
    my $rows = $decoder.feed($report.payload);
    $decoder.finish;
    X::LibTmux::Command.new(:kind<timeout>, :outcome(Complete),
        :message('Control read deadline expired after decoding')).throw if now >= $until;
    $rows.list
}

#| Verify the connected daemon through a queue barrier without acquiring a graph.
method observe(*%options --> Observation:D) is single-operation { await self.observe-async(|%options) }
#| Verify daemon identity through a queued barrier and resolve the captured observation.
method observe-async(:$deadline = Instant, :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    my $until;
    my $error;
    try { $until = self!deadline($deadline); CATCH { default { $error = $_ } } }
    return Promise.broken($error) if $error.defined;
    start {
        await self!submit(Invocation, :deadline($until), :$cancel);
        $!observation
    }
}

#| Acquire a fresh graph through this connection; retained views keep no connection alive.
method snapshot(Cancellation :$cancel = Cancellation --> Snapshot:D) is single-operation { await self.snapshot-async(:$cancel) }
#| Resolve a fresh graph acquired within one deadline, with explicit cancellation.
method snapshot-async(Cancellation :$cancel = Cancellation --> Promise:D) is single-operation('async') {
    my $deadline = now + $!timeout-ms / 1000;
    start { capture(self, :required-incarnation($!observation.incarnation), :$deadline, :$cancel) }
}

#| Explain a query against this connection's immutable negotiated capabilities, without I/O.
method explain(Mu $entity, Mu :$where = Map.new, Mu :$pushdown = 'auto', *%unknown --> Plan:D) {
    invalid('Unknown query option ' ~ %unknown.keys.sort.join(', ')) if %unknown;
    query-policy($pushdown);
    Plan.compile(query-filter($entity, $where), :capabilities($!observation.capabilities), :$pushdown)
}
#| Acquire a selection through this connection; retained observations keep no live owner.
method query(Mu $entity, *%options --> Positional:D) { await self.query-async($entity, |%options) }
#| Copy and validate query data before scheduling acquisition and residual evaluation.
method query-async(Mu $entity, Mu :$where = Map.new, Mu :$pushdown = 'auto',
                   Mu :$cancel = Cancellation, *%unknown --> Promise:D) {
    my $deadline = now + $!timeout-ms / 1000;
    my $plan;
    my $error;
    try {
        invalid('Unknown query option ' ~ %unknown.keys.sort.join(', ')) if %unknown;
        invalid('cancel must be one Cancellation token')
            unless $cancel === Cancellation || ($cancel.^isa(Cancellation) && $cancel.defined);
        $plan = self.explain($entity, :$where, :$pushdown);
        CATCH { default { $error = $_ } }
    }
    return Promise.broken($error) if $error.defined;
    start {
        acquire-plan(self, $plan, :$deadline, :$cancel)
    }
}
#| Acquire pane observations with explicit source filtering.
method query-panes(*%options --> PaneSelection:D) { self.query('pane', |%options) }
#| Explain pane restrictions and local residual work.
method explain-panes(*%options --> Plan:D) { self.explain('pane', |%options) }

method !stop(Exception:D $failure = Exception.new --> Nil) {
    my $first = $!lock.protect({
        if $!closing { False } else {
            $!closing = True;
            $!failure = $failure unless $failure.WHAT === Exception;
            for %!pending.values -> $request {
                my $error = X::LibTmux::Command.new(:kind($!failure.defined ?? 'disconnected' !! 'closed'),
                    :outcome($request.sent ?? Indeterminate !! NotStarted), :cause($!failure),
                    :message('Control connection closed before this request completed'));
                $request.finish(Any, $request.sent && $!failure.defined ?? $!failure !! $error);
            }
            $!queue.send(False);
            True
        }
    });
    return unless $first;
    $!failure.defined ?? $!events.finish(:error($!failure)) !! $!events.finish;
    my $cleanup = start {
        await $!launched;
        try $!proc.close-stdin if $!proc.defined;
        try $!proc.kill(SIGKILL) if $!proc.defined && $!process.defined && $!process.status == Planned;
        my @owned = ($!process, $!worker).grep(*.defined);
        my $settled = Promise.allof(@owned);
        await Promise.anyof($settled, Promise.in($!cleanup-timeout-ms / 1000));
        my $error;
        if $settled.status == Planned {
            $error = X::LibTmux::Command.new(:kind<cleanup>, :outcome(Indeterminate),
                :pid(self.pid), :reaped(False), :message('Control client did not settle after termination'));
        } else {
            $!lock.protect({ $!reaped = !$!process.defined || $!process.status == Kept
                || $!proc.ready.status == Broken });
        }
        $!out-tap.close if $!out-tap.defined;
        $!err-tap.close if $!err-tap.defined;
        $error.defined ?? $!close-vow.break($error) !! $!close-vow.keep(True);
    };
}

#| Stop admission, settle every request and reap only this connection's client.
method close(--> Nil) { await self.close-async }
#| Share one bounded shutdown which settles pending work and reaps only this client.
method close-async(--> Promise:D) { self!stop; $!closed }

=begin pod
=head1 Owned control connection

Connection connects to an exact session on an observed daemon. Startup verifies
the daemon again over the persistent connection. The ignore-size client flag
avoids changing pane dimensions. New layouts are negotiated when supported;
older profiles retain their native control layout representation.

Commands are serialized through one bounded queue. A separate unpredictable
FORMAT barrier correlates every response, including nested commands and jobs
which print after their end guard. A barrier means the tmux command queue reached
that point; background jobs and external effects still need domain-specific
completion evidence. Raw command output has the framing limitations described
by L<LibTmux::Control>. Declared projections avoid arbitrary output delimiters.

Each request owns a deadline from admission. Cancelling an unsent request leaves
the connection usable. Timeout or cancellation after dispatch closes the whole
connection because later response ownership is uncertain. Effects already sent
remain indeterminate. Closing stops the client, not the daemon or launched jobs.

An event Supply is shared, live and bounded per subscriber. Reconnect requires a
new Connection and explicit snapshot acquisition; old requests and observations
never migrate automatically. Every connection has a distinct epoch.
=end pod
