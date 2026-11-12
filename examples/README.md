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

Build an observatory display, watch a downlink, and recover from a failed launch.
These complete Raku programs use [LibTmux](../README.md) to own private tmux
servers. Each closes its clients and daemon when it exits.

Run commands from the repository root after the
[toolchain setup](../.github/CONTRIBUTING.md#toolchain), with a supported tmux
executable on `PATH`:

```console
$ zef install .
```

| Task | Program | Raku facilities |
| --- | --- | --- |
| Create and find panes | [Quickstart](quickstart.raku) | Objects, `LEAVE`, a native predicate |
| Choose wide instruments | [Pane queries](query-panes.raku) | Typed selections, query hashes, `grep`, `map`, `sort` |
| Add a telemetry display | [Floating panes](floating-panes.raku) | Capability checks and a tiled fallback |
| Receive a downlink | [Watch output](watch-output.raku) | `Promise`, `Supply`, `react`, `whenever` |
| Combine the workflow | [Observatory](observatory.raku) | Events, captured graphs and query plans |
| Recover from a failed launch | [Batch recovery](batch-recovery.raku) | Typed outcomes and explicit recovery |

## Create and find panes

The [quickstart](quickstart.raku) is the complete first program in the root
README. It creates two panes, sets their titles, and finds the telescope through
a fresh snapshot. The earlier snapshot retains one pane.

```console
$ raku -I. examples/quickstart.raku
```

It prints `Starlight telescope: 2 panes`.

## Choose wide instruments

The [pane query program](query-panes.raku) creates a telescope, weather display
and spectrum recorder. `.where` selects the wide panes, `.filter` finds the
telescope, and `.single` checks cardinality. Native `.grep`, `.map` and `.sort`
produce the remaining instrument names as ordinary Raku values.

```console
$ raku -I. examples/query-panes.raku
```

It prints `Wide telescope: Starlight telescope` and
`Other instruments: Orion weather, Spectrum recorder`.

Use `:=` when binding a typed selection to an array variable. Assignment with
`=` materializes ordinary array membership. Repeated traversal reads the
captured members; it does not refresh tmux.

## Add a telemetry display

The [floating-pane program](floating-panes.raku) creates an Aurora telemetry
pane. It checks the daemon's `pane-floating` capability, chooses a floating pane
when available, and otherwise splits the tiled window.

```console
$ raku -I. examples/floating-panes.raku
```

It prints the selected placement, then `Aurora telemetry`. The empty display
has no child process on profiles that report an absent PID; the pane still
belongs to the captured graph. Consult capabilities before offering an
operation to a user.

## Receive a downlink

The [output watcher](watch-output.raku) awaits asynchronous snapshot and control
connection operations, subscribes to pane-output events, and sends the downlink.
`react` and `whenever` collect fragmented bytes until the complete message
arrives. It then checks the captured screen.

```console
$ raku -I. examples/watch-output.raku
```

It prints `Starlight downlink: 42 stars catalogued` and `Screen capture confirmed`.
The deadline bounds the wait. Multiple event subscribers share the same owned
connection. Sending text and pressing Enter are separate operations.

## Run the complete observatory

The [observatory](observatory.raku) combines pane creation, literal input,
control-mode observation and screen capture. It filters a snapshot with query
data and a Raku predicate, then compares an exact source query with the captured
pane. Its query plan shows where evaluation takes place.

```console
$ raku -I. examples/observatory.raku
```

The output includes `Observatory: 2 instruments`,
`Starlight telescope: Starlight exposure complete: 42 stars catalogued`, and
`Owned clients, daemon and socket cleaned up`.

## Recover after a command fails

The [batch recovery example](batch-recovery.raku) sets an option, sends an
invalid command, and checks that the following command was skipped. It verifies
the first effect and removes it explicitly.

```console
$ raku -I. examples/batch-recovery.raku
```

It reports `Complete`, `Failed` and `Skipped` outcomes, followed by
`Recovery: removed the first effect explicitly` and
`Owned daemon and socket cleaned up`. A failed batch does not undo commands
that already succeeded.

## Select a tmux executable

Every program except the minimal quickstart accepts `--tmux`. For that
quickstart, select the supported binary through `PATH`. The repository's
[example check](../tools/check-examples.raku) selects `LIBTMUX_TEST_TMUX` through
a private temporary `PATH`, checks displayed source against these files, runs
all programs, checks their results, and rejects leftover owned socket
directories. See [Contributing](../.github/CONTRIBUTING.md#checks) for validation.
