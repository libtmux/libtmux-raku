# Examples

Complete Raku programs using [LibTmux](../README.md). Each starts a private tmux
server through `Server.start` and closes its owned resources. Run the commands
below from the repository root after the
[toolchain setup](../.github/CONTRIBUTING.md#toolchain), with a supported
tmux executable on `PATH`.

## Create and find panes

The [quickstart](quickstart.raku) is the complete program shown in the root
README. It creates two panes, sets their titles, and finds one using a Raku
predicate over a fresh snapshot.

```console
$ raku -I. examples/quickstart.raku
```

It prints `Starlight telescope: 2 panes` and closes the owned server on exit.

## Create panes, watch output and query their state

The [observatory](observatory.raku) splits telescope and weather panes, sends a
message, observes it through control mode, and captures the screen. It filters a
snapshot with query data and a Raku predicate, checks that an older snapshot is
unchanged, and compares a source query with the captured pane.

```console
$ raku -I. examples/observatory.raku
```

The output includes `Observatory: 2 instruments`,
`Starlight telescope: Starlight exposure complete: 42 stars catalogued`, and
`Owned clients, daemon and socket cleaned up`. It also reports whether the
daemon supports floating panes.

## Recover after a command fails

The [batch recovery example](batch-recovery.raku) sets an option, sends an
invalid command, and checks that the following command was skipped. It then
removes the first command's effect explicitly.

```console
$ raku -I. examples/batch-recovery.raku
```

It reports `Complete`, `Failed` and `Skipped` command outcomes, followed by
`Recovery: removed the first effect explicitly` and
`Owned daemon and socket cleaned up`. A failed batch does not undo commands
that already succeeded.

The observatory and batch recovery programs accept `--tmux` to select an
executable. They assert their expected observations and check that their owned
daemon and socket directory have been removed. The quickstart uses `tmux` on
`PATH`. The [example check](../tools/check-examples.raku) selects the required
`LIBTMUX_TEST_TMUX` executable through a private temporary `PATH`, runs these
programs, and rejects an unsuccessful exit. It also checks the quickstart's
exact output and verifies that the root README quotes its complete source.
