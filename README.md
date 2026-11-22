<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="https://raw.githubusercontent.com/libtmux/libtmux-raku/HEAD/assets/logo.svg" type="image/svg+xml">
    <img src="https://raw.githubusercontent.com/libtmux/libtmux-raku/HEAD/assets/logo.png" width="128" height="128" alt="libtmux for Raku">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Raku

[![CI](https://github.com/libtmux/libtmux-raku/actions/workflows/ci.yml/badge.svg)](https://github.com/libtmux/libtmux-raku/actions/workflows/ci.yml)
[![LibTmux](https://raku.land/zef:libtmux/LibTmux/badges/version)](https://raku.land/zef:libtmux/LibTmux)
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/raku/)
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

## Resize and remove panes

### [`PaneRef.resize`][api-pane-resize] and [`PaneRef.kill`][api-pane-kill]: size and remove panes

Split a pane, size the window and the first pane, then kill the second pane.
[`WindowRef.resize`][api-window-resize] sizes a window. A window, a session
and the daemon go with [`WindowRef.kill`][api-window-kill],
[`SessionRef.kill`][api-session-kill] and
[`Server.kill-server`][api-server-kill-server].

<!-- runs: examples/resize-panes.raku -->

```raku
use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>,
        :width(120), :height(30), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $before = $server.snapshot;
    my $window = $before.windows.single.ref;
    my $editor = $before.panes.single.ref;
    my $logs = $editor.split(:horizontal, :shell-command('exec cat'));

    $window.resize(:width(100), :height(20));
    $editor.resize(:width(30));
    my $sized = $server.snapshot;
    my $pane = $sized.panes.where(%(id => $editor.id)).single;
    say "window: {$sized.windows.single.width}x{$sized.windows.single.height}";
    say "editor: {$pane.width} columns";

    $logs.kill;
    say "panes: {$server.snapshot.panes.elems}";
}
```

It prints `window: 100x20`, `editor: 30 columns` and `panes: 1`.

- `resize` takes `:width` and `:height`, or `:direction` with `:amount`. It
  refuses a mix of the two.

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
    my $server = Server.start(:binary($tmux), :name<work>,
        :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    $server.snapshot.panes.single.ref.set-title('editor');

    my %wide = width => %(gte => 60);
    my %titled = AND => [%wide, %(title => %(contains => 'edit'))];

    my $wide-plan = $server.explain-panes(:where(%wide));
    say 'width: fully pushed = ' ~ $wide-plan.fully-pushed;
    my $plan = $server.explain-panes(:where(%titled));
    say 'width and title: fully pushed = ' ~ $plan.fully-pushed;
    say 'tmux filter: ' ~ $plan.source-filter;

    my @matches = $server.query-panes(:where(%titled)).map(*.title);
    say 'Matches: ' ~ @matches.join(', ');
    try {
        $server.query-panes(:where(%titled), :pushdown<require>);
        CATCH {
            when X::LibTmux::Unsupported {
                say 'require: refused, title stays local';
            }
        }
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

[`Options.describe`][api-options-describe] gives an option's type, scopes and
first release; [`Server.options`][api-server-options] and
[`Server.hooks`][api-server-hooks] read and set options and hooks.

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
the [field, option, hook and capability
reference][repo-docs-reference-catalogue-rakudoc].

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
    my $server = Server.start(:binary($tmux), :name<output>,
        :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $snapshot = await $server.snapshot-async;
    my $pane = $snapshot.panes.single.ref;
    my $session-id = $snapshot.sessions.single.id;
    my $connection = await $server.open-control-async(:$session-id);
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
        whenever start {
            $pane.send-text($message);
            $pane.send-keys('Enter');
        } { }
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
    my $server = Server.start(:binary($tmux), :name<recovery>,
        :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $before = Invocation.new(
        :argv(['set-option', '-s', '@before-failure', 'set']));
    my $invalid = Invocation.new(:argv(['libtmux-example-unknown-command=']));
    my $after = Invocation.new(
        :argv(['set-option', '-s', '@after-failure', 'set']));
    my $batch = Batch.new(:operations([
        Operation.new(:name<set-option>, :acknowledgement-only,
            :command($before)),
        Operation.new(:name<invalid-command>, :acknowledgement-only,
            :command($invalid)),
        Operation.new(:name<skipped-option>, :acknowledgement-only,
            :command($after)),
    ]));
    my $report = $server.run-batch($batch);
    my @outcomes = $report.operations.map(*.outcome);
    die 'Batch attribution was wrong'
        unless @outcomes.List eqv (Complete, Failed, Skipped);
    my $options = $server.options;
    die 'The successful first effect disappeared'
        unless $options.get('@before-failure') eq 'set';
    die 'A skipped operation ran'
        if $options.entries(:name<@after-failure>).elems;
    for $report.operations -> $op {
        say "{$op.name}: {$op.outcome} (scope: {$op.completion-scope})";
    }

    $options.unset('@before-failure');
    die 'Explicit recovery failed'
        if $options.entries(:name<@before-failure>).elems;
    say 'Recovery: removed the first effect explicitly';
    $server.close;
    say 'Stopped the tmux server and removed its socket';
}
```

It prints:

```text
set-option: Complete (scope: command)
invalid-command: Failed (scope: command)
skipped-option: Skipped (scope: command)
Recovery: removed the first effect explicitly
Stopped the tmux server and removed its socket
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

Headings above link to the [API reference][raku-reference] on libtmux.org.

- [Native API guide][repo-lib-libtmux-rakumod]: the object graph, queries,
  capabilities, async execution, control events and recovery.
- [Examples][repo-examples-readme-md]: complete Raku programs with checked
  results.
- [Contributing][repo-github-contributing-md]: compiler setup and validation.
- [API documentation authoring][repo-docs-documentation-rakudoc] and
  [writing conventions][repo-github-writing-md].
- [MIT license][repo-license] and [artwork provenance][repo-assets-readme-md].

Part of the [libtmux.org](https://libtmux.org/) family alongside Python
[`libtmux`](https://github.com/tmux-python/libtmux), sibling
[language ports](https://github.com/libtmux) and
[`tmux`](https://github.com/tmux/tmux).

[api-batch]: https://libtmux.org/en/raku/latest/reference/libtmux-batch-batch/
[api-capabilities-supports]: https://libtmux.org/en/raku/latest/reference/libtmux-capabilities-supports/
[api-connection-events]: https://libtmux.org/en/raku/latest/reference/libtmux-control-connection-events/
[api-operation]: https://libtmux.org/en/raku/latest/reference/libtmux-batch-operation/
[api-options-describe]: https://libtmux.org/en/raku/latest/reference/libtmux-configuration-options-describe/
[api-pane-capture]: https://libtmux.org/en/raku/latest/reference/libtmux-model-paneref-capture/
[api-pane-kill]: https://libtmux.org/en/raku/latest/reference/libtmux-model-paneref-kill/
[api-pane-resize]: https://libtmux.org/en/raku/latest/reference/libtmux-model-paneref-resize/
[api-pane-selection-filter]: https://libtmux.org/en/raku/latest/reference/libtmux-model-paneselection-filter/
[api-pane-selection-where]: https://libtmux.org/en/raku/latest/reference/libtmux-model-paneselection-where/
[api-pane-send-keys]: https://libtmux.org/en/raku/latest/reference/libtmux-model-paneref-send-keys/
[api-pane-send-text]: https://libtmux.org/en/raku/latest/reference/libtmux-model-paneref-send-text/
[api-pane-split]: https://libtmux.org/en/raku/latest/reference/libtmux-model-paneref-split/
[api-server-close]: https://libtmux.org/en/raku/latest/reference/libtmux-server-close/
[api-server-explain-panes]: https://libtmux.org/en/raku/latest/reference/libtmux-server-explain-panes/
[api-server-hooks]: https://libtmux.org/en/raku/latest/reference/libtmux-server-hooks/
[api-server-kill-server]: https://libtmux.org/en/raku/latest/reference/libtmux-server-kill-server/
[api-server-new]: https://libtmux.org/en/raku/latest/reference/libtmux-server-new/
[api-server-new-session]: https://libtmux.org/en/raku/latest/reference/libtmux-server-new-session/
[api-server-open-control]: https://libtmux.org/en/raku/latest/reference/libtmux-server-open-control/
[api-server-open-control-async]: https://libtmux.org/en/raku/latest/reference/libtmux-server-open-control-async/
[api-server-options]: https://libtmux.org/en/raku/latest/reference/libtmux-server-options/
[api-server-query-panes]: https://libtmux.org/en/raku/latest/reference/libtmux-server-query-panes/
[api-server-run-batch]: https://libtmux.org/en/raku/latest/reference/libtmux-server-run-batch/
[api-server-start]: https://libtmux.org/en/raku/latest/reference/libtmux-server-start/
[api-session-kill]: https://libtmux.org/en/raku/latest/reference/libtmux-model-sessionref-kill/
[api-session-new-window]: https://libtmux.org/en/raku/latest/reference/libtmux-model-sessionref-new-window/
[api-snapshot-capabilities]: https://libtmux.org/en/raku/latest/reference/libtmux-model-snapshot-capabilities/
[api-window-kill]: https://libtmux.org/en/raku/latest/reference/libtmux-model-windowref-kill/
[api-window-resize]: https://libtmux.org/en/raku/latest/reference/libtmux-model-windowref-resize/
[raku-land]: https://raku.land/zef:libtmux/LibTmux
[raku-reference]: https://libtmux.org/en/raku/latest/reference/
[repo-assets-readme-md]: https://github.com/libtmux/libtmux-raku/blob/master/assets/README.md
[repo-changelog-md]: https://github.com/libtmux/libtmux-raku/blob/master/CHANGELOG.md
[repo-docs-adr-0001-tmux-compatibility-md]: https://github.com/libtmux/libtmux-raku/blob/master/docs/adr/0001-tmux-compatibility.md
[repo-docs-documentation-rakudoc]: https://github.com/libtmux/libtmux-raku/blob/master/docs/documentation.rakudoc
[repo-docs-reference-catalogue-rakudoc]: https://github.com/libtmux/libtmux-raku/blob/master/docs/reference/catalogue.rakudoc
[repo-examples-readme-md]: https://github.com/libtmux/libtmux-raku/blob/master/examples/README.md
[repo-examples-session-workflow-raku]: https://github.com/libtmux/libtmux-raku/blob/master/examples/session-workflow.raku
[repo-github-contributing-md]: https://github.com/libtmux/libtmux-raku/blob/master/.github/CONTRIBUTING.md
[repo-github-contributing-md-toolchain]: https://github.com/libtmux/libtmux-raku/blob/master/.github/CONTRIBUTING.md#toolchain
[repo-github-writing-md]: https://github.com/libtmux/libtmux-raku/blob/master/.github/WRITING.md
[repo-lib-libtmux-rakumod]: https://github.com/libtmux/libtmux-raku/blob/master/lib/LibTmux.rakumod
[repo-license]: https://github.com/libtmux/libtmux-raku/blob/master/LICENSE
