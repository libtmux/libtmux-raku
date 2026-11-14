<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="https://raw.githubusercontent.com/libtmux/libtmux-raku/HEAD/docs/assets/logo.svg" type="image/svg+xml">
    <img src="https://raw.githubusercontent.com/libtmux/libtmux-raku/HEAD/docs/assets/logo-512.png" width="128" height="128" alt="libtmux for Raku">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Raku

[![CI](https://github.com/libtmux/libtmux-raku/actions/workflows/ci.yml/badge.svg)](https://github.com/libtmux/libtmux-raku/actions/workflows/ci.yml)
[![LibTmux](https://raku.land/zef:libtmux/LibTmux/badges/version)](https://raku.land/zef:libtmux/LibTmux)
[![license](https://img.shields.io/badge/license-MIT-blue)](https://github.com/libtmux/libtmux-raku/blob/master/LICENSE)

</div>

Start a private tmux server, split panes, send input, find panes with plain
Raku predicates, and react to terminal output as it arrives.

## Install

Needs Raku 6.d or newer, tmux 3.3a or newer and Linux. Install from
[Raku Land][raku-land] with its Fez authority:

```console
$ zef install 'LibTmux:auth<zef:libtmux>'
```

To install a checkout instead:

```console
$ zef install .
```

The [toolchain guide][repo-github-contributing-md-toolchain] covers Raku and
zef setup. The [changelog][repo-changelog-md] lists each release.

## Create sessions and panes

### [`Server.start`][api-server-start] and [`PaneRef.split`][api-pane-split]: create and arrange panes

Start a private server, split its first pane and title both panes. Each runs
`cat`, and `LEAVE` closes the server on any exit.

[`Server.new-session`][api-server-new-session] and
[`SessionRef.new-window`][api-session-new-window] add sessions and windows.

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

It prints `editor: 2 panes`. The earlier snapshot still has one pane: `.ref`
commands change tmux, while a snapshot keeps what it captured.

Save it as `quickstart.raku` and run it:

```console
$ raku quickstart.raku
```

From a checkout:

```console
$ raku -I. examples/quickstart.raku
```

More: the [native API guide][repo-lib-libtmux-rakumod].

## Query captured panes

### [`PaneSelection.where`][api-pane-selection-where]: select panes from a snapshot

Select wide panes with query data, then find `editor` with a Raku predicate
through [`filter`][api-pane-selection-filter]. Native `.grep`, `.map` and
`.sort` list the rest.

[`Server.query-panes`][api-server-query-panes] asks tmux for a fresh selection
instead of reading a snapshot.

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

It prints `Wide pane: editor` and `Other panes: logs, tests`.

- Bind with `:=` to keep a typed selection; `=` makes a plain array.
- `where` checks fields and operators; `filter` returns the same selection type.
- `.single` wants exactly one match, `.single-or-nil` allows none. `.one` stays
  Raku's junction.

More: the [native API guide][repo-lib-libtmux-rakumod] covers relations and
portable filters.

## Choose where a query runs

### [`Server.explain-panes`][api-server-explain-panes]: what tmux filters and what Raku filters

[`Server.query-panes`][api-server-query-panes] takes `:pushdown`:

- `auto` (the default) has tmux apply the restrictions it can match exactly,
  then rechecks every result in Raku.
- `never` lists first and filters in Raku.
- `require` throws when any part would stay local.

<!-- runs: examples/explain-query.raku -->

```raku
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    $server.snapshot.panes.single.ref.set-title('editor');

    my %wide = width => %(gte => 60);
    my %titled = AND => [%wide, %(title => %(contains => 'edit'))];

    say 'width: fully pushed = ' ~ $server.explain-panes(:where(%wide)).fully-pushed;
    my $plan = $server.explain-panes(:where(%titled));
    say 'width and title: fully pushed = ' ~ $plan.fully-pushed;
    say 'tmux filter: ' ~ $plan.source-filter;

    say 'Matches: ' ~ $server.query-panes(:where(%titled)).map(*.title).join(', ');
    try {
        $server.query-panes(:where(%titled), :pushdown<require>);
        CATCH { when X::LibTmux::Unsupported { say 'require: refused, title stays local' } }
    }
}
```

It prints:

```text
width: fully pushed = True
width and title: fully pushed = False
tmux filter: #{e|>=:#{pane_width},60}
Matches: editor
require: refused, title stays local
```

More: the [native API guide][repo-lib-libtmux-rakumod].

## Adapt to the running daemon

### [`Capabilities.supports`][api-capabilities-supports]: choose a supported operation

Create an empty `status` pane: floating when the daemon supports it, tiled
otherwise. [`Snapshot.capabilities`][api-snapshot-capabilities] holds what the
daemon, not the client binary, can do.

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

It prints `Status pane: floating` or `Status pane: tiled`, then `status`.

More: the [compatibility policy][repo-docs-adr-0001-tmux-compatibility-md] and
the [field and capability reference][repo-docs-reference-catalogue-rakudoc].

## Watch pane output

### [`ControlConnection.events`][api-connection-events]: receive output through a `Supply`

[`Server.open-control-async`][api-server-open-control-async] (or
[`Server.open-control`][api-server-open-control]) opens a persistent control
connection. Its events are one shared `Supply`, so `react` and `whenever` read
them. This program subscribes, sends text with
[`PaneRef.send-text`][api-pane-send-text] and checks the screen with
[`PaneRef.capture`][api-pane-capture].

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

- `send-text` sends literal text; [`send-keys('Enter')`][api-pane-send-keys]
  submits it.
- Output arrives as bytes, so split or invalid UTF-8 survives.

More: the longer [session workflow program][repo-examples-session-workflow-raku]
also queries and explains.

## Run commands in a batch

### [`Server.run-batch`][api-server-run-batch]: run commands in order, keep every outcome

Build a [`Batch`][api-batch] of [`Operation`][api-operation] values. Each one
reports `Complete`, `Failed` or `Skipped`. Here the second fails, the third is
skipped, and the program removes the first effect itself.

<!-- runs: examples/batch-recovery.raku -->

```raku
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<recovery>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $before = $server.snapshot;
    my $batch = Batch.new(:operations([
        Operation.new(:name<set-option>, :acknowledgement-only,
            :command(Invocation.new(:argv(['set-option', '-s', '@before-failure', 'set'])))),
        Operation.new(:name<invalid-command>, :acknowledgement-only,
            :command(Invocation.new(:argv(['libtmux-example-unknown-command='])))),
        Operation.new(:name<skipped-option>, :acknowledgement-only,
            :command(Invocation.new(:argv(['set-option', '-s', '@after-failure', 'set'])))),
    ]));
    my $report = $server.run-batch($batch);
    die 'Batch attribution was wrong'
        unless $report.operations.map(*.outcome).List eqv (Complete, Failed, Skipped);
    my $options = $server.options;
    die 'The successful first effect disappeared' unless $options.get('@before-failure') eq 'set';
    die 'A skipped operation ran' if $options.entries(:name<@after-failure>).elems;
    say .name ~ ': ' ~ .outcome ~ ' (scope: ' ~ .completion-scope ~ ')' for $report.operations;

    $options.unset('@before-failure');
    die 'Explicit recovery failed' if $options.entries(:name<@before-failure>).elems;
    say 'Recovery: removed the first effect explicitly';
    my $pid = $before.incarnation.pid;
    my $directory = $server.endpoint.socket-path.IO.parent;
    $server.close;
    die 'Owned daemon or socket directory survived cleanup' if "/proc/$pid".IO.e || $directory.e;
    say 'Owned daemon and socket cleaned up';
}
```

It prints:

```text
set-option: Complete (scope: command)
invalid-command: Failed (scope: command)
skipped-option: Skipped (scope: command)
Recovery: removed the first effect explicitly
Owned daemon and socket cleaned up
```

A failed batch does not roll back earlier commands.

More: the [examples guide][repo-examples-readme-md].

## Close what you open

### [`Server.close`][api-server-close]: stop a server you started

- [`Server.start`][api-server-start] owns a private server; `close` stops it.
- [`Server.new`][api-server-new] borrows a server; `close` leaves it running.
- Control connections and attachments have their own lifetimes. Close them too.
- A reference refuses a replacement server that reuses its ids.

## What it leaves out

- **Live objects.** A snapshot is what tmux said when you asked. It does not
  change when tmux does.
- **Rollback.** A failed batch does not undo commands that already ran.
- **Callbacks in tmux.** Raku predicates always run locally.

## Support and status

- **Experimental.** The API may change between `0.x` releases. The
  [changelog][repo-changelog-md] marks each break.
- **tmux 3.3a or newer.** A release the library does not list yet is refused.
- **Linux.** Other platforms are unverified.

## Documentation

Headings above link to the native declarations and their RakuDoc comments.

- [Native API guide][repo-lib-libtmux-rakumod]: the object graph, queries,
  capabilities, async execution, control events and recovery.
- [Examples][repo-examples-readme-md]: complete Raku programs with checked results.
- [Contributing][repo-github-contributing-md]: compiler setup and validation.
- [API documentation authoring][repo-docs-documentation-rakudoc] and
  [writing conventions][repo-github-writing-md].
- [MIT license][repo-license] and [artwork provenance][repo-docs-assets-readme-md].

[api-batch]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Batch.rakumod#L206
[api-capabilities-supports]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Capabilities.rakumod#L126
[api-connection-events]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Control/Connection.rakumod#L147
[api-operation]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Batch.rakumod#L53
[api-pane-capture]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Model.rakumod#L257
[api-pane-selection-filter]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Selection.rakumod#L68
[api-pane-selection-where]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Selection.rakumod#L78
[api-pane-send-keys]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Model.rakumod#L248
[api-pane-send-text]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Model.rakumod#L244
[api-pane-split]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Model.rakumod#L279
[api-server-close]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L685
[api-server-explain-panes]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L432
[api-server-new]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L290
[api-server-new-session]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L452
[api-server-open-control]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L575
[api-server-open-control-async]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L579
[api-server-query-panes]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L430
[api-server-run-batch]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L608
[api-server-start]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Server.rakumod#L622
[api-session-new-window]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Model.rakumod#L135
[api-snapshot-capabilities]: https://github.com/libtmux/libtmux-raku/blob/f543ca5de32e04445f4d6e29c66e5dba94ac9a63/lib/LibTmux/Model.rakumod#L662
[raku-land]: https://raku.land/zef:libtmux/LibTmux
[repo-changelog-md]: https://github.com/libtmux/libtmux-raku/blob/master/CHANGELOG.md
[repo-docs-adr-0001-tmux-compatibility-md]: https://github.com/libtmux/libtmux-raku/blob/master/docs/adr/0001-tmux-compatibility.md
[repo-docs-assets-readme-md]: https://github.com/libtmux/libtmux-raku/blob/master/docs/assets/README.md
[repo-docs-documentation-rakudoc]: https://github.com/libtmux/libtmux-raku/blob/master/docs/documentation.rakudoc
[repo-docs-reference-catalogue-rakudoc]: https://github.com/libtmux/libtmux-raku/blob/master/docs/reference/catalogue.rakudoc
[repo-examples-readme-md]: https://github.com/libtmux/libtmux-raku/blob/master/examples/README.md
[repo-examples-session-workflow-raku]: https://github.com/libtmux/libtmux-raku/blob/master/examples/session-workflow.raku
[repo-github-contributing-md]: https://github.com/libtmux/libtmux-raku/blob/master/.github/CONTRIBUTING.md
[repo-github-contributing-md-toolchain]: https://github.com/libtmux/libtmux-raku/blob/master/.github/CONTRIBUTING.md#toolchain
[repo-github-writing-md]: https://github.com/libtmux/libtmux-raku/blob/master/.github/WRITING.md
[repo-lib-libtmux-rakumod]: https://github.com/libtmux/libtmux-raku/blob/master/lib/LibTmux.rakumod
[repo-license]: https://github.com/libtmux/libtmux-raku/blob/master/LICENSE
