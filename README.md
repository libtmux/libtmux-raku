<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="docs/assets/logo.svg" type="image/svg+xml">
    <img src="docs/assets/logo-512.png" width="128" height="128" alt="libtmux for Raku">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Raku

</div>

LibTmux controls tmux from Raku: create sessions and panes, find them through
typed snapshots, send input, and react to terminal output. Use ordinary Raku
predicates and collections alongside validated query data and explicit commands.

## Install

Requires Linux, Raku 6.d and tmux 3.3a through 3.8. Install the published package
from [Raku Land](https://raku.land/zef:libtmux/LibTmux) with its Fez authority:

```console
$ zef install 'LibTmux:auth<zef:libtmux>'
```

The API is experimental and may change between `0.x` releases. CI qualifies
Rakudo 2026.09 on Linux with tmux 3.3a and 3.8; other platforms and compiler
versions are unverified. See the [changelog](CHANGELOG.md) for release history.
The [toolchain guide](.github/CONTRIBUTING.md#toolchain) covers Raku and zef setup.
To install a checkout instead:

```console
$ zef install .
```

## Create sessions and panes

### [`Server.start`][api-server-start] and [`PaneRef.split`][api-pane-split]: create and arrange panes

Create a private tmux session named `work`, split its first pane, and set
the pane titles to `editor` and `logs`. Both panes run `cat` as an echo process.
This is the complete [quickstart program](examples/quickstart.raku). `LEAVE`
closes the owned server when the program exits, including on an exception.

<!-- runs: examples/quickstart.raku -->

```raku
use LibTmux;

my $server = Server.start(:name<work>, :shell-command('exec cat'));
LEAVE $server.close if $server.defined;

my $before = $server.snapshot;
my $left = $before.panes.single.ref;
my $right = $left.split(:horizontal, :shell-command('exec cat'));
$left.set-title('editor');
$right.set-title('logs');

my $after = $server.snapshot;
my $editor = $after.panes.filter(*.title eq 'editor').single;
say "{$editor.title}: {$after.panes.elems} panes";
```

It prints `editor: 2 panes`. The earlier snapshot still contains one
pane: commands through `.ref` change tmux, while snapshots retain the state they
captured. Reading a snapshot or following its relationships makes no further
tmux calls.

Run it from the checkout with a supported tmux executable on `PATH`:

```console
$ raku -I. examples/quickstart.raku
```

## Query captured panes

### [`PaneSelection.where`][api-pane-selection-where]: select panes from a snapshot

Create panes titled `editor`, `tests`, and `logs`. Select wide panes with query
data, then use a Raku predicate to find `editor`. The complete
[query program](examples/query-panes.raku) also uses native `.grep`, `.map` and
`.sort` to list the other panes.

<!-- runs: examples/query-panes.raku -->

```raku
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>,
        :width(160), :height(40), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $editor = $server.snapshot.panes.single.ref;
    my $tests = $editor.split(:horizontal, :shell-command('exec cat'));
    my $logs = $tests.split(:shell-command('exec cat'));
    $editor.set-title('editor');
    $tests.set-title('tests');
    $logs.set-title('logs');

    my $snapshot = $server.snapshot;
    my @wide := $snapshot.panes.where(%(width => %(gte => 60)));
    my $selected = @wide.filter(*.title eq 'editor').single;
    say "Wide pane: {$selected.title}";

    my @others = $snapshot.panes.grep(*.id ne $selected.id).map(*.title).sort;
    say 'Other panes: ' ~ @others.join(', ');
}
```

It prints `Wide pane: editor` and
`Other panes: logs, tests`.

Binding with `:=` retains the typed selection. [`where`][api-pane-selection-where]
validates query fields and operators; [`filter`][api-pane-selection-filter]
returns another selection of the same entity type.
Native `.grep` returns a `Seq`, and `.map` can produce ordinary strings.
`.single` requires exactly one result; `.single-or-nil` permits no result.
Raku's `.one` keeps its junction meaning.

For live acquisition, [`query-panes(:where(%criteria))`][api-server-query-panes]
returns a fresh selection. [`explain-panes`][api-server-explain-panes] shows
which restrictions run in tmux and which remain local.
See the [native query guide](lib/LibTmux.rakumod) for
relations, portable filters and source execution.

## Adapt to the running daemon

### [`Capabilities.supports`][api-capabilities-supports]: choose a supported operation

Create an empty `status` pane as a floating pane when supported, with a tiled
split as the fallback. The [capability example](examples/floating-panes.raku)
asks the captured daemon capabilities before choosing an operation.

<!-- runs: examples/floating-panes.raku -->

```raku
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>,
        :width(120), :height(36), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $snapshot = $server.snapshot;
    my $main = $snapshot.panes.single.ref;
    my $floating = $snapshot.capabilities.supports('pane-floating');
    my $auxiliary = $floating
        ?? $main.new-floating(:width(40), :height(12), :x(2), :y(2), :empty)
        !! $main.split(:horizontal, :empty);
    $auxiliary.set-title('status');

    my $after = $server.snapshot;
    die 'The auxiliary pane was not captured' unless $after.panes.elems == 2;
    say 'Status pane: ' ~ ($floating ?? 'floating' !! 'tiled');
    say $after.panes.where(%(id => $auxiliary.id)).single.title;
}
```

It prints `Status pane: floating` or `Status pane: tiled`,
followed by `status`. A newer client executable does not upgrade an
older daemon. Unknown releases are refused conservatively. The
[compatibility policy](docs/adr/0001-tmux-compatibility.md) describes support;
the [field and capability reference](docs/reference/catalogue.rakudoc) lists
feature requirements and unavailable values.

## Watch pane output

### [`Control::Connection.events`][api-connection-events]: receive output through a `Supply`

Asynchronous operations return `Promise` values. A control connection exposes
events through a shared `Supply`; native `react` and `whenever` consume them.
[`Server.open-control-async`][api-server-open-control-async] opens the connection.
This complete [output watcher](examples/watch-output.raku) subscribes before
sending text to `cat`, waits for the echoed bytes, then checks the captured screen.

<!-- runs: examples/watch-output.raku -->

```raku
use v6.d;
use LibTmux;
use LibTmux::Control;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<output>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $snapshot = await $server.snapshot-async;
    my $pane = $snapshot.panes.single.ref;
    my $connection = await $server.open-control-async(:session-id($snapshot.sessions.single.id));
    LEAVE $connection.close if $connection.defined;

    my $message = 'hello from Raku';
    my $received = '';
    react {
        whenever $connection.events.grep(PaneOutput) -> $event {
            if $event.pane-id eq $pane.id {
                $received ~= $event.data.decode('utf8-c8');
                die 'Pane output exceeded its bound' if $received.chars > 65536;
                done if $received.contains($message);
            }
        }
        whenever start { $pane.send-text($message); $pane.send-keys('Enter') } { }
        whenever Promise.in(2) { die 'Pane output timed out' }
    }

    die 'The captured screen did not contain the message'
        unless $pane.capture.decode('utf8').contains($message);
    say $message;
    say 'Screen capture confirmed';
}
```

It prints `hello from Raku` and `Screen capture confirmed`.
The deadline bounds the wait; output events supply the completion evidence.
`send-text` sends literal text, and `send-keys('Enter')` submits it separately.
Pane output arrives as bytes so fragmented or invalid UTF-8 remains available.

The longer [session workflow program](examples/session-workflow.raku) combines pane
creation, output observation, capture, local queries and an explained source
query in one lifecycle.

## Recover after a batch fails

### [`Server.run-batch`][api-server-run-batch]: inspect partial completion

A batch records each operation's outcome. The
[recovery program](examples/batch-recovery.raku) produces `Complete`, `Failed`
and `Skipped`, verifies that the first effect remains, then removes that effect
explicitly. Command acknowledgement alone does not establish application
completion, and a failed batch does not roll back earlier commands.

```console
$ raku -I. examples/batch-recovery.raku
```

The [examples guide](examples/README.md) gives the commands, expected results and
cleanup behavior for every complete program.

## Ownership and documentation

### [`Server.close`][api-server-close]: close an owned daemon

[`Server.start`][api-server-start] creates and owns a daemon on a private socket.
[`Server.new`][api-server-new] configures a borrowed endpoint; closing it leaves
that daemon running. Close both explicitly. Control connections and terminal
attachments have their own lifetimes and also need closing. References are
scoped to the observed daemon incarnation and refuse a replacement daemon.

API links open the native declarations and their RakuDoc comments.

- [Native API guide](lib/LibTmux.rakumod): the object graph, queries,
  capabilities, async execution, control events and recovery.
- [Examples](examples/README.md): complete Raku programs with checked results.
- [Contributing](.github/CONTRIBUTING.md): compiler setup and validation.
- [API documentation authoring](docs/documentation.rakudoc) and
  [writing conventions](.github/WRITING.md).
- [MIT license](LICENSE) and [artwork provenance](docs/assets/README.md).

[api-capabilities-supports]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Capabilities.rakumod#L126
[api-connection-events]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Control/Connection.rakumod#L147
[api-pane-selection-filter]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Selection.rakumod#L68
[api-pane-selection-where]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Selection.rakumod#L78
[api-pane-split]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Model.rakumod#L279
[api-server-close]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L685
[api-server-explain-panes]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L432
[api-server-new]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L290
[api-server-open-control-async]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L579
[api-server-query-panes]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L430
[api-server-run-batch]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L608
[api-server-start]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L622
