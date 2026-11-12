use v6.d;

unit module LibTmux::Configuration;

use LibTmux::Types;
use LibTmux::Exceptions;
use LibTmux::Catalogue;
use LibTmux::Capabilities;
use LibTmux::Command :DEFAULT, :internals;
use LibTmux::Engine;
use LibTmux::Transport;
use LibTmux::Operations;
use LibTmux::Format :DEFAULT, :internal;

sub bad(Str:D $message, Str:D :$field = '' --> Nil) {
    X::LibTmux::Decode.new(:$message, :schema<configuration>, :$field).throw
}
sub text-argument($text, Str:D $label, Bool :$empty = False --> Str:D) {
    invalid-argument("$label must be defined text without NUL")
        unless $text ~~ Str:D && !$text.contains("\0") && ($empty || $text.chars);
    $text.Str
}
sub record-bytes(Blob:D $output, Str:D $repair --> List:D) {
    my @rows; my $start = 0;
    for ^$output.elems -> $i {
        next unless $output[$i] == 10;
        @rows.push(decode-command-output($output.subbuf($start, $i - $start), :$repair));
        $start = $i + 1;
    }
    bad('Truncated command output record') unless $start == $output.elems;
    @rows.List
}

role Scoped {
    #| Captured connection settings; retaining them owns no process.
    has Endpoint:D $.endpoint is required;
    #| Captured daemon identity used to reject references after replacement.
    has Incarnation:D $.incarnation is required;
    has Str:D $.scope = 'server';
    has Str:D $.target = '';
    has Bool:D $.global = False;
    has Positive:D $.timeout-ms = 10_000;
    #| Combined output-byte limit for one owned command response.
    has Positive:D $.max-output-bytes = 8 * 1024 * 1024;
    #| Maximum encoded command size in bytes, including tmux quoting.
    has Positive:D $.max-command-bytes = 12 * 1024;

    submethod TWEAK() {
        invalid-argument('Configuration endpoint and incarnation disagree')
            unless $!endpoint.key eq $!incarnation.endpoint-key;
        invalid-argument('Unknown configuration scope')
            unless $!scope eq any(<server session window pane>);
        invalid-argument('Global configuration has no object target')
            if $!global && ($!target.chars || $!scope eq any(<server pane>));
        unless $!global {
            my $valid = do given $!scope {
                when 'server' { !$!target.chars }
                when 'session' { so $!target ~~ SessionId }
                when 'window' { so $!target ~~ WindowId }
                when 'pane' { so $!target ~~ PaneId }
            };
            invalid-argument('Configuration target has the wrong identity type') unless $valid;
        }
    }
    #| Copy endpoint, scope and limits through constructor validation.
    method clone(*%changes) {
        my %arguments = endpoint => $!endpoint, incarnation => $!incarnation,
            scope => $!scope, target => $!target, global => $!global,
            timeout-ms => $!timeout-ms, max-output-bytes => $!max-output-bytes,
            max-command-bytes => $!max-command-bytes;
        for %changes.kv -> $name, $value {
            invalid-argument("Unknown configuration setting $name") unless %arguments{$name}:exists;
            %arguments{$name} = $value;
        }
        self.WHAT.new(|%arguments)
    }
    method !capabilities() { operation-capabilities($!incarnation) }
    method !scope-flags(--> List:D) {
        my @flags;
        @flags.push('-s') if $!scope eq 'server';
        @flags.push('-w') if $!scope eq 'window';
        @flags.push('-p') if $!scope eq 'pane';
        @flags.push('-g') if $!global;
        @flags.append('-t', $!target) if $!target.chars;
        @flags.List
    }
    method !with-runtime(&body) {
        my $deadline = now + $!timeout-ms / 1000;
        self!capabilities.require('managed-commands');
        my $runtime = Runtime.new(:endpoint($!endpoint), :timeout-ms($!timeout-ms),
            :max-output-bytes($!max-output-bytes), :max-command-bytes($!max-command-bytes));
        LEAVE $runtime.close if $runtime.defined;
        my $value = body($runtime, $deadline);
        X::LibTmux::Command.new(:kind<timeout>, :outcome(Complete),
            :message('Configuration decoding exceeded the operation deadline')).throw
            if now >= $deadline;
        $value<>
    }
    method !execute(@argv, Blob:D :$stdin = Blob.new, Bool :$check = True,
                    :&decode = -> $result { $result }) {
        my $command = Invocation.new(:@argv, :max-bytes($!max-command-bytes));
        self!with-runtime(-> $runtime, $deadline {
            decode($runtime.execute($command, :incarnation($!incarnation), :$stdin, :$check, :$deadline))
        })
    }
}

#| One observed option value. The source schema determines its native scalar type.
class OptionValue is export {
    #| Exact observed resource or option name.
    has Str:D $.name is required;
    #| Array member index; undefined for a scalar option.
    has Int $.index;
    #| Whether the effective value came from an ancestor option scope.
    has Bool:D $.inherited = False;
    #| Decoded native option value; its type follows the option catalogue.
    has Mu $.value is required;
}

sub option-value($spec, Blob:D $bytes) {
    my $text = $bytes.decode('utf8-c8');
    given $spec.kind {
        when 'flag' {
            bad('Invalid option flag', :field($spec.name)) unless $text eq any(<on off>);
            $text eq 'on'
        }
        when 'number' {
            bad('Invalid option integer', :field($spec.name)) unless $text ~~ /^ '-'? <[0..9]>+ $/;
            bad('Option integer is outside its declared range', :field($spec.name))
                unless $spec.minimum <= $text.Int <= $spec.maximum;
            $text.Int
        }
        when 'choice' {
            bad('Option choice is outside the declared profile', :field($spec.name))
                unless $spec.choices.first(* eq $text).defined;
            $text
        }
        when 'string' { decode-argument-token($bytes).decode('utf8-c8') }
        default { $text }
    }
}

sub option-entries(Blob:D $output, Str:D $repair, &describe --> List:D) {
    my @entries;
    for record-bytes($output, $repair) -> $row {
        my $text = $row.decode('utf8-c8');
        my $head = $text ~~ /^ $<name>=[ <-[\[\*\s]>+ ]
            [ '[' $<index>=<[0..9]>+ ']' ]? $<parent>='*'? [ ' ' $<value>=.* ]? $/;
        bad('Malformed option output') unless $head;
        my $field = ~$head<name>;
        my $spec = describe($field);
        next unless $head<value>.defined;
        my $offset = $head<value>.from;
        my $prefix = $text.substr(0, $offset).encode('utf8-c8').elems;
        my $value = option-value($spec, $row.subbuf($prefix));
        @entries.push(OptionValue.new(:name($field),
            :index($head<index>.defined ?? +$head<index> !! Int),
            :inherited(so $head<parent>.chars), :$value));
    }
    @entries.List
}

#| Typed native options. Reads and writes are explicit daemon operations.
class Options does Scoped is export {
    #| Inspect the source-qualified schema locally; user options have text values.
    method describe(Str:D $name --> LibTmux::Catalogue::OptionSpec:D) {
        self!capabilities.require('managed-commands');
        if $name ~~ /^ '@' <[A..Za..z0..9_\-]>+ $/ {
            return LibTmux::Catalogue::OptionSpec.new(:$name, :kind<string>,
                :since(support-policy().minimum), :scopes((self.scope,).List),
                :source(support-policy().profile(self.incarnation.daemon-version).source
                    .subst('/tree/', '/blob/') ~ '/options.c'));
        }
        my $spec = catalogue().option($name, self.incarnation.daemon-version);
        X::LibTmux::Unsupported.new(:feature("option:$name"), :state(NotSupported),
            :reason('Option is absent from the declared daemon profile'),
            :message("Unknown or unavailable option $name")).throw unless $spec.defined;
        invalid-argument("Option $name does not belong to scope {self.scope}")
            unless $spec.scopes.first(* eq self.scope).defined;
        $spec
    }
    #| Read values, array indices and inherited provenance as captured entries.
    method entries(Str :$name, Bool :$effective = True --> List:D) is single-operation {
        CATCH {
            when X::LibTmux::Command {
                return ().List if $name.defined && $name.starts-with('@')
                    && .kind eq 'exit' && .exitcode == 1 && !.signal && !.stdout.elems
                    && .stderr.list eqv "invalid option: $name\n".encode.list;
                .rethrow
            }
        }
        self.describe($name) if $name.defined;
        my @argv = 'show-options', |self!scope-flags;
        @argv.push('-A') if $effective;
        @argv.push($name) if $name.defined;
        self!execute(@argv, :decode(-> $result {
            option-entries($result.stdout, self!capabilities.output-repair,
                -> $field { self.describe($field) })
        }))
    }
    #| Read a native scalar, an array Map, or Nil for an absent local value/member.
    method get(Str:D $name, Int :$index, Bool :$effective = True) is single-operation {
        my $spec = self.describe($name);
        invalid-argument('Array index must be nonnegative and refer to an array')
            if $index.defined && ($index !~~ Count || !$spec.is-array);
        my @entries = self.entries(:$name, :$effective);
        if $spec.is-array && !$index.defined {
            return Map.new(@entries.map({ .index => .value }));
        }
        my $entry = $index.defined ?? @entries.first({ .index.defined && .index == $index })
            !! @entries.first;
        $entry.defined ?? $entry.value !! Nil
    }
    #| Validate a typed value and set one scalar or explicitly indexed array member.
    method set(Str:D $name, $value, Int :$index --> Result:D) is single-operation {
        my $spec = self.describe($name);
        invalid-argument('Array options require an explicit nonnegative index')
            if $spec.is-array && (!$index.defined || $index !~~ Count);
        invalid-argument('Scalar options cannot have an array index') if !$spec.is-array && $index.defined;
        my Str $argument = do given $spec.kind {
            when 'flag' {
                invalid-argument('Flag option requires Bool') unless $value ~~ Bool:D;
                $value ?? 'on' !! 'off'
            }
            when 'number' {
                invalid-argument('Numeric option requires an integer in its declared range')
                    unless $value ~~ Int:D && $value !~~ Bool
                        && $spec.minimum <= $value <= $spec.maximum;
                $value.Str
            }
            when 'choice' {
                invalid-argument('Choice option requires a declared text value')
                    unless $value ~~ Str:D && $spec.choices.first(* eq $value).defined;
                $value
            }
            when 'command' {
                invalid-argument('Command option requires Invocation') unless $value ~~ Invocation:D;
                $value.source
            }
            default { text-argument($value, 'Option value', :empty) }
        };
        my $key = $name ~ ($index.defined ?? "[$index]" !! '');
        self!execute(['set-option', |self!scope-flags, '--', $key, $argument])
    }
    #| Remove a local value or array member; tmux's inherited/default value may remain.
    method unset(Str:D $name, Int :$index --> Result:D) is single-operation {
        my $spec = self.describe($name);
        invalid-argument('Option index must be nonnegative and refer to an array')
            if $index.defined && (!$spec.is-array || $index !~~ Count);
        self!execute(['set-option', |self!scope-flags, '-u', '--',
            $name ~ ($index.defined ?? "[$index]" !! '')])
    }
    #| Explicit schema escape hatch. tmux validates the option and interprets its value.
    method set-raw(Str:D $name, Str:D $value --> Result:D) is single-operation {
        text-argument($name, 'Raw option name'); text-argument($value, 'Raw option value', :empty);
        self!execute(['set-option', |self!scope-flags, '--', literal-format($name), $value])
    }
    #| Read raw native output for an option outside the declared typed schema.
    method get-raw(Str:D $name --> Blob:D) is single-operation {
        text-argument($name, 'Raw option name');
        self!execute(['show-options', |self!scope-flags, '-v', '--', literal-format($name)]).stdout
    }
}

#| Environment absence and an explicit removed marker are different states.
class EnvironmentValue is export {
    #| Exact observed resource or option name.
    has Str:D $.name is required;
    #| Captured environment bytes, preserved separately from text conversion.
    has Blob:D $.bytes = Blob.new;
    #| Whether tmux marks this variable for removal from child environments.
    has Bool:D $.removed = False;
    #| Whether this entry belongs to the explicitly requested hidden environment.
    has Bool:D $.hidden = False;
    submethod TWEAK() { $!bytes = Blob.new($!bytes.list) }
    #| Decode captured bytes losslessly, or return Nil for an explicit removed marker.
    method value() { $!removed ?? Nil !! $!bytes.decode('utf8-c8') }
    #| Revalidate copies and detach mutable byte input.
    method clone(*%changes) {
        my %arguments = name => $!name, bytes => $!bytes, removed => $!removed, hidden => $!hidden;
        for %changes.kv -> $key, $value {
            invalid-argument("Unknown environment value field $key") unless %arguments{$key}:exists;
            %arguments{$key} = $value;
        }
        self.WHAT.new(|%arguments)
    }
}

sub environment-name($name --> Str:D) {
    text-argument($name, 'Environment name');
    invalid-argument('Environment names must use the portable variable alphabet')
        unless $name ~~ /^ <[A..Za..z_]> <[A..Za..z0..9_]>* $/;
    $name
}


#| Internal decoder for native show-environment -s output; never evaluates shell text.
sub decode-environment(Blob:D $output, Str:D $repair, Bool:D $hidden --> List:D)
    is export(:internal) {
    my $bytes = Buf.new;
    for record-bytes($output, $repair) -> $row { $bytes.append($row); $bytes.push(10) }
    my @values; my int $i = 0;
    while $i < $bytes.elems {
        my $start = $i;
        if $i + 6 <= $bytes.elems
            && $bytes[$i] == 117 && $bytes[$i + 1] == 110
            && $bytes[$i + 2] == 115 && $bytes[$i + 3] == 101
            && $bytes[$i + 4] == 116 && $bytes[$i + 5] == 32 {
            $i += 6;
            my $name-start = $i;
            $i++ while $i < $bytes.elems && $bytes[$i] != 59;
            bad('Truncated removed environment entry')
                unless $i + 1 < $bytes.elems && $bytes[$i + 1] == 10;
            my $name = $bytes.subbuf($name-start, $i - $name-start).decode('utf8-c8');
            bad('Malformed environment variable name', :field($name))
                unless $name ~~ /^ <[A..Za..z_]> <[A..Za..z0..9_]>* $/;
            @values.push(EnvironmentValue.new(:$name, :removed, :$hidden));
            $i += 2;
        } else {
            $i++ while $i < $bytes.elems && $bytes[$i] != 61;
            bad('Truncated environment assignment')
                unless $i + 1 < $bytes.elems && $bytes[$i + 1] == 34;
            my $name = $bytes.subbuf($start, $i - $start).decode('utf8-c8');
            bad('Malformed environment variable name', :field($name))
                unless $name ~~ /^ <[A..Za..z_]> <[A..Za..z0..9_]>* $/;
            $i += 2;
            my $value = Buf.new;
            loop {
                bad('Unclosed environment value') if $i >= $bytes.elems;
                my $byte = $bytes[$i++];
                last if $byte == 34;
                if $byte == 92 {
                    bad('Truncated environment escape') if $i >= $bytes.elems;
                    $byte = $bytes[$i++];
                    bad('Unknown environment escape') unless $byte == any(36, 96, 34, 92);
                }
                $value.push($byte);
            }
            my $suffix = "; export $name;\n".encode;
            bad('Malformed environment export suffix')
                unless $i + $suffix.elems <= $bytes.elems
                    && $bytes.subbuf($i, $suffix.elems).list eqv $suffix.list;
            $i += $suffix.elems;
            @values.push(EnvironmentValue.new(:$name, :bytes($value), :$hidden));
        }
    }
    @values.List
}

#| Session or global environment, including hidden and removed entries.
class Environment does Scoped is export {
    method !flags(--> List:D) {
        invalid-argument('Environment scope must be server or session')
            unless self.scope eq any(<server session>);
        self.scope eq 'server' || self.global ?? ('-g',).List !! ('-t', self.target).List
    }
    #| Capture normal entries, or only hidden entries when requested explicitly.
    method list(Bool :$hidden = False --> List:D) is single-operation {
        my @argv = 'show-environment', '-s', |self!flags;
        @argv.push('-h') if $hidden;
        self!execute(@argv, :decode(-> $result {
            decode-environment($result.stdout, self!capabilities.output-repair, $hidden)
        }))
    }
    #| Find a captured entry; Nil means absent from the requested visibility class.
    method get(Str:D $name, Bool :$hidden = False) is single-operation {
        CATCH {
            when X::LibTmux::Command {
                return Nil if .kind eq 'exit' && .exitcode == 1 && !.signal
                    && !.stdout.elems
                    && .stderr.list eqv "unknown variable: $name\n".encode.list;
                .rethrow
            }
        }
        environment-name($name);
        my @argv = 'show-environment', '-s', |self!flags;
        @argv.push('-h') if $hidden;
        @argv.append('--', $name);
        self!execute(@argv, :decode(-> $result {
            my @values = decode-environment($result.stdout, self!capabilities.output-repair, $hidden);
            bad('Named environment lookup returned another entry', :field($name))
                if @values.elems > 1 || (@values.elems && @values[0].name ne $name);
            @values.first
        }))
    }
    #| Store literal text without FORMAT or shell expansion; NUL is not representable.
    method set(Str:D $name, Str:D $value, Bool :$hidden = False --> Result:D) is single-operation {
        environment-name($name); text-argument($value, 'Environment value', :empty);
        my @argv = 'set-environment', |self!flags;
        @argv.push('-h') if $hidden;
        @argv.append('--', $name, $value);
        self!execute(@argv)
    }
    #| Delete an entry from this environment.
    method unset(Str:D $name --> Result:D) is single-operation {
        environment-name($name);
        self!execute(['set-environment', |self!flags, '-u', '--', $name])
    }
    #| Store a removed marker so the variable is omitted from newly spawned processes.
    method remove(Str:D $name --> Result:D) is single-operation {
        environment-name($name);
        self!execute(['set-environment', |self!flags, '-r', '--', $name])
    }
}

#| Buffer metadata is separate from explicitly acquired binary contents.
class BufferInfo is export {
    #| Exact observed resource or option name.
    has Str:D $.name is required;
    #| Buffer content length in bytes; content acquisition is separate.
    has Count:D $.size is required;
    #| Buffer creation time as Unix seconds.
    has Count:D $.created is required;
    #| Native buffer preview text; it is not the complete binary content.
    has Str:D $.sample is required;
}

#| Server-scoped paste buffers with binary load and save operations.
class Buffers does Scoped is export {
    method !server(--> Nil) {
        invalid-argument('Buffers belong to the server scope') unless self.scope eq 'server';
    }
    #| Acquire buffer metadata without loading the complete contents.
    method list(--> List:D) is single-operation {
        self!server;
        my $projection = Projection.new(:entity<buffer>, :context<buffer>,
            :fields(<name size created sample>.List), :capabilities(self!capabilities));
        self!with-runtime(-> $runtime, $deadline {
            $runtime.read($projection, Invocation.new(:argv(['list-buffers'])),
                :incarnation(self.incarnation), :$deadline).map(-> $row {
                    BufferInfo.new(:name($row.value('name')), :size($row.value('size')),
                        :created($row.value('created')), :sample($row.value('sample')))
                }).List
        })
    }
    #| Acquire complete buffer bytes, including NUL, within the output bound.
    method get(Str:D $name --> Blob:D) is single-operation {
        self!server; text-argument($name, 'Buffer name');
        self!capabilities.require('buffer-save');
        self!execute(['save-buffer', '-b', $name, '-']).stdout
    }
    #| Load binary stdin into the named server buffer.
    method put(Str:D $name, Blob:D $bytes --> Result:D) is single-operation {
        self!server; text-argument($name, 'Buffer name');
        self!execute(['load-buffer', '-b', $name, '-'], :stdin($bytes))
    }
    #| Delete the named buffer.
    method delete(Str:D $name --> Result:D) is single-operation {
        self!server; text-argument($name, 'Buffer name');
        self!execute(['delete-buffer', '-b', $name])
    }
    #| Rename a buffer without decoding its contents.
    method rename(Str:D $name, Str:D $new-name --> Result:D) is single-operation {
        self!server; text-argument($name, 'Buffer name'); text-argument($new-name, 'New buffer name');
        self!execute(['set-buffer', '-b', $name, '-n', $new-name])
    }
    #| Paste into an explicit pane, optionally deleting the buffer afterward.
    method paste(Str:D $name, PaneId:D $pane, Bool :$delete = False,
                 Bool :$bracketed = False, Str :$separator --> Result:D) is single-operation {
        self!server; text-argument($name, 'Buffer name');
        my @argv = 'paste-buffer', '-b', $name, '-t', $pane;
        @argv.push('-d') if $delete;
        @argv.push('-p') if $bracketed;
        @argv.append('-s', text-argument($separator, 'Paste separator', :empty)) if $separator.defined;
        self!execute(@argv)
    }
}

#| Named hook command arrays. Reading a hook never executes its command source.
class Hooks does Scoped is export {
    method !describe(Str:D $name --> LibTmux::Catalogue::OptionSpec:D) {
        self!capabilities.require('managed-commands');
        my $spec = catalogue().option($name, self.incarnation.daemon-version);
        X::LibTmux::Unsupported.new(:feature("hook:$name"), :state(NotSupported),
            :reason('Hook is absent from the declared daemon profile'),
            :message("Unknown or unavailable hook $name")).throw
            unless $spec.defined && $spec.is-hook;
        invalid-argument("Hook $name does not belong to scope {self.scope}")
            unless $spec.scopes.first(* eq self.scope).defined;
        $spec
    }
    #| Read local hook entries; each value is native printed command source.
    method list(Str :$name --> List:D) is single-operation {
        invalid-argument('Hooks require session, window or pane scope') if self.scope eq 'server';
        self!describe($name) if $name.defined;
        my @argv = 'show-hooks', |self!scope-flags;
        @argv.push($name) if $name.defined;
        self!execute(@argv, :decode(-> $result {
            option-entries($result.stdout, self!capabilities.output-repair,
                -> $field { self!describe($field) })
        }))
    }
    #| Set one hook index to a validated tmux command; the command is deferred.
    method set(Str:D $name, Invocation:D $command, Count:D :$index = 0 --> Result:D) is single-operation {
        self!describe($name);
        self!execute(['set-hook', |self!scope-flags, '--', "$name\[$index]", $command.source])
    }
    #| Append one command to the hook array using tmux's native array allocation.
    method append(Str:D $name, Invocation:D $command --> Result:D) is single-operation {
        self!describe($name);
        self!execute(['set-hook', |self!scope-flags, '-a', '--', $name, $command.source])
    }
    #| Remove a hook array or one explicit index.
    method unset(Str:D $name, Count :$index --> Result:D) is single-operation {
        self!describe($name);
        self!execute(['set-hook', |self!scope-flags, '-u', '--',
            $name ~ ($index.defined ?? "[$index]" !! '')])
    }
    #| Queue a hook now. Acknowledgement does not prove its commands' effects.
    method run(Str:D $name --> Result:D) is single-operation {
        self!describe($name);
        self!execute(['set-hook', |self!scope-flags, '-R', '--', $name])
    }
}

#| Captured binding metadata. Legacy listings leave note-state Unloaded.
class KeyBinding is export {
    #| Key-table name in which the binding was observed.
    has Str:D $.table is required;
    #| Native tmux key spelling.
    has Str:D $.key is required;
    #| Whether tmux allows this binding to repeat.
    has Bool:D $.repeat is required;
    #| Observed tmux command syntax; retaining it does not execute it.
    has Str:D $.command-source is required;
    #| Binding note text when the selected profile can acquire it.
    has Str:D $.note = '';
    #| Availability of the note; older profiles retain Unloaded rather than inventing text.
    has ValueState:D $.note-state = Unloaded;
}

sub key-table(Str:D $table --> Str:D) {
    invalid-argument('Key table must use letters, digits, underscore or hyphen')
        unless $table ~~ /^ <[A..Za..z0..9_\-]>+ $/;
    $table
}

#| Server key tables. Invocation keeps stored command arguments distinct.
class KeyBindings does Scoped is export {
    method !server(--> Nil) {
        invalid-argument('Key tables belong to the server scope') unless self.scope eq 'server';
    }
    #| Bind a key to one command, with optional repeatability and literal note.
    method bind(Str:D $key, Invocation:D $command, Str:D :$table = 'prefix',
                Bool :$repeat = False, Str :$note --> Result:D) is single-operation {
        self!server; key-table($table); text-argument($key, 'Key');
        my @argv = 'bind-key', '-T', $table;
        @argv.push('-r') if $repeat;
        @argv.append('-N', text-argument($note, 'Binding note', :empty)) if $note.defined;
        @argv.append('--', $key, $command.source);
        self!execute(@argv)
    }
    #| Remove one binding. Unknown tables remain operational errors.
    method unbind(Str:D $key, Str:D :$table = 'prefix' --> Result:D) is single-operation {
        self!server; key-table($table); text-argument($key, 'Key');
        self!execute(['unbind-key', '-T', $table, '--', $key])
    }
    #| Remove the explicitly named table and all its bindings.
    method clear(Str:D $table --> Result:D) is single-operation {
        self!server; key-table($table);
        self!execute(['unbind-key', '-a', '-T', $table])
    }
    #| Capture one table; modern profiles include notes, legacy profiles mark them unloaded.
    method list(Str:D :$table = 'prefix' --> List:D) is single-operation {
        self!server; key-table($table);
        if self!capabilities.supports('key-binding-format') {
            my $projection = Projection.new(:entity<key-binding>, :context<key-binding>,
                :fields(<table key repeat command-source note>.List), :capabilities(self!capabilities));
            return self!with-runtime(-> $runtime, $deadline {
                $runtime.read($projection, Invocation.new(:argv(['list-keys', '-T', $table])),
                    :incarnation(self.incarnation), :$deadline).map(-> $row {
                        KeyBinding.new(:table($row.value('table')), :key($row.value('key')),
                            :repeat($row.value('repeat')), :command-source($row.value('command-source')),
                            :note($row.value('note')), :note-state(Present))
                    }).List
            });
        }
        self!execute(['list-keys', '-T', $table], :decode(-> $result {
            my @bindings;
            for record-bytes($result.stdout,
                    self!capabilities.output-repair) -> $row {
                my $text = $row.decode('utf8-c8');
                my $match = $text ~~ /^ 'bind-key' \s+ $<repeat>=[ '-r' \s+ ]?
                    '-T' \s+ $<table>=\S+ \s+
                    $<key>=[ '"' [ '\\' . | <-["\\]> ]* '"'
                        | "'" <-[']>* "'" | [ '\\' . | <-[\s\\]> ]+ ]
                    \s+ $<command>=.* $/;
                bad('Malformed native key binding') unless $match && ~$match<table> eq $table;
                @bindings.push(KeyBinding.new(:$table,
                    :key(decode-argument-token((~$match<key>).encode('utf8-c8')).decode('utf8-c8')),
                    :repeat(so $match<repeat>.chars), :command-source(~$match<command>)));
            }
            @bindings.List
        }))
    }
}


=begin pod
=head1 Configuration and stored commands

Options, Environment, Buffers, Hooks and KeyBindings are value-only facades
bound to an endpoint and daemon incarnation. Construction and schema access
perform no I/O. Each operation owns and closes its temporary command runtime;
it checks daemon identity and applies one timeout and output bound.

Options use source-qualified types and ranges from L<LibTmux::Catalogue>.
Flags require Bool, numeric options reject Bool, and array writes require an
explicit index. C<entries> preserves inherited provenance; C<get> returns a
native scalar or an indexed Map. Unknown native options use the explicitly
named raw operations. User options in the typed API use C<@> followed by
letters, digits, underscores or hyphens. Native printed command values are
source text, not parsed Invocation values.

Environment reads distinguish an absent entry, an explicit removed marker,
and hidden entries. C<:hidden> selects hidden entries only. Environment names
use the portable variable alphabet. C<get> requests only that name; C<list>
refuses a native entry whose name falls outside the declared alphabet.
Values preserve bytes through UTF8-C8;
reading the shell-shaped output never executes it. Buffer content is acquired
separately as Blob and may contain NUL.

Hooks and key bindings accept L<LibTmux::Command::Invocation> for commands
to store. Reads preserve tmux's printed command source without executing or
reconstructing it. Legacy key listings mark notes Unloaded; modern projected
listings capture them. Key table names use letters, digits, underscores or
hyphens so legacy native listings remain unambiguous.

Hook C<run> acknowledges queuing. Paste and other mutations acknowledge tmux
commands; they do not prove that a pane application consumed input or that a
hook's asynchronous work completed. Timeouts after dispatch cannot roll back
server effects. Captured values do not refresh themselves.
=end pod
