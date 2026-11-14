<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../docs/assets/logo-512.png" width="128" height="128" alt="libtmux for Raku">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux Raku examples

</div>

Complete programs that start a private tmux server, do one job and close it.
Run them from the repository root after the
[toolchain setup](../.github/CONTRIBUTING.md#toolchain), with tmux on `PATH`:

```console
$ zef install .
```

| Task | Program | Raku facilities |
| --- | --- | --- |
| Create and find panes | [Quickstart](quickstart.raku) | Objects, `LEAVE`, a native predicate |
| Select wide panes | [Pane queries](query-panes.raku) | Typed selections, query hashes, `grep`, `map`, `sort` |
| Choose where a query runs | [Query plan](explain-query.raku) | `explain-panes`, `:pushdown` |
| Add a status pane | [Floating panes](floating-panes.raku) | Capability checks and a tiled fallback |
| Watch pane output | [Watch output](watch-output.raku) | `Promise`, `Supply`, `react`, `whenever` |
| Combine the workflow | [Session workflow](session-workflow.raku) | Events, captured graphs and query plans |
| Recover after a command fails | [Batch recovery](batch-recovery.raku) | Typed outcomes and explicit recovery |

## Create and find panes

[`quickstart.raku`](quickstart.raku) splits one pane, titles both and finds
`editor` in a fresh snapshot. The earlier snapshot still has one pane.

```console
$ raku -I. examples/quickstart.raku
```

It prints `editor: 2 panes`.

## Select wide panes

[`query-panes.raku`](query-panes.raku) creates `editor`, `tests` and `logs`.
`.where` selects wide panes, `.filter` finds `editor`, `.single` checks the
count, and `.grep`, `.map` and `.sort` list the rest.

```console
$ raku -I. examples/query-panes.raku
```

It prints `Wide pane: editor` and `Other panes: logs, tests`.

- Bind a typed selection with `:=`; `=` copies it into a plain array.
- Repeated traversal reads the captured members and does not refresh tmux.

## Choose where a query runs

[`explain-query.raku`](explain-query.raku) explains two pane queries, runs one,
and shows `:pushdown<require>` refusing the query that keeps a title test local.

```console
$ raku -I. examples/explain-query.raku
```

It prints whether each query is fully pushed to tmux, the filter tmux gets,
the match, and the refusal.

## Add a status pane

[`floating-panes.raku`](floating-panes.raku) creates an empty `status` pane:
floating when the daemon reports `pane-floating`, tiled otherwise.

```console
$ raku -I. examples/floating-panes.raku
```

It prints `Status pane: floating` or `Status pane: tiled`, then `status`.

## Watch pane output

[`watch-output.raku`](watch-output.raku) subscribes to pane-output events, sends
text to `cat` and collects the echoed bytes with `react` and `whenever`. Then it
checks the captured screen.

```console
$ raku -I. examples/watch-output.raku
```

It prints `hello from Raku` and `Screen capture confirmed`.

- A deadline bounds the wait.
- Several subscribers can share one connection.
- Sending text and pressing Enter are separate calls.

## Run the complete session workflow

[`session-workflow.raku`](session-workflow.raku) creates panes, sends input,
watches control-mode output and captures the screen. It filters a snapshot,
then compares an exact source query with the captured pane.

```console
$ raku -I. examples/session-workflow.raku
```

The output includes `Session: 2 panes`, `editor: hello from Raku` and
`Owned clients, daemon and socket cleaned up`.

## Recover after a command fails

[`batch-recovery.raku`](batch-recovery.raku) sets an option, sends an invalid
command and checks that the next command was skipped. It then removes the
first effect.

```console
$ raku -I. examples/batch-recovery.raku
```

It prints the `Complete`, `Failed` and `Skipped` outcomes, then
`Recovery: removed the first effect explicitly` and
`Owned daemon and socket cleaned up`.

A failed batch does not undo commands that already succeeded.

## Select a tmux executable

Every program except the quickstart takes `--tmux=PATH`. The quickstart runs
`tmux` from `PATH`.

The [example check](../tools/check-examples.raku) runs every program against
`LIBTMUX_TEST_TMUX`, compares its output and rejects leftover sockets. See
[Contributing](../.github/CONTRIBUTING.md#checks).
