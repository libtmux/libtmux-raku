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

LibTmux controls tmux from Raku: create sessions and panes, send keys, capture
terminal output, and find panes by their properties. Query a captured object
graph locally, then use explicit commands to change the running server.

## Install

Requires Linux, Raku 6.d and tmux 3.3a through 3.8. See the
[compatibility policy](docs/adr/0001-tmux-compatibility.md) for supported releases
and feature detection. Install from this checkout; there is no published Raku
distribution yet. The [toolchain guide](.github/CONTRIBUTING.md#toolchain) covers
Raku and zef setup.

```console
$ zef install .
```

## Create and find panes

Start a private tmux server, split its first pane, and find the telescope in a
fresh snapshot. `LEAVE` closes the owned server when the program exits,
including on an exception.

This is the complete [quickstart program](examples/quickstart.raku):

<!-- runs: examples/quickstart.raku -->

```raku
use LibTmux;

my $server = Server.start(:name<observatory>, :shell-command('exec cat'));
LEAVE $server.close if $server.defined;

my $before = $server.snapshot;
my $left = $before.panes.single.ref;
my $right = $left.split(:horizontal, :shell-command('exec cat'));
$left.set-title('Starlight telescope');
$right.set-title('Orion weather');

my $after = $server.snapshot;
my $telescope = $after.panes.filter(*.title.starts-with('Starlight')).single;
say "{$telescope.title}: {$after.panes.elems} panes";
```

It prints `Starlight telescope: 2 panes`. The earlier snapshot still contains one
pane: commands through `.ref` change tmux, while snapshots keep the state they
captured. `.filter` takes a Raku predicate and `.single` requires exactly one
match. Reading those selections makes no further tmux calls.

Run it from the checkout with tmux on `PATH`:

```console
$ raku -I. examples/quickstart.raku
```

The [examples guide](examples/README.md) also shows sending text, observing
output through a control-event `Supply`, capturing the screen, querying with
validated data, and recovering after a command batch fails.

## Server ownership and support

`Server.start` creates and owns a daemon on a private socket. `Server.new`
configures a borrowed endpoint; closing it leaves that daemon running. Close
both explicitly. Control connections and terminal attachments have their own
lifetimes and also need closing.

Capabilities come from the running daemon. Check
`$snapshot.capabilities.supports('pane-floating')`, for example, before offering
a floating-pane operation. Unknown releases are refused conservatively; the
[field and capability reference](docs/reference/catalogue.rakudoc) lists feature
requirements and unavailable values.

## Documentation

- [Native API guide](lib/LibTmux.rakumod): snapshots, references, queries,
  control events, asynchronous operations and batch outcomes.
- [Examples](examples/README.md): complete programs with checked results and
  owned cleanup.
- [Contributing](.github/CONTRIBUTING.md): compiler setup and validation.
- [Writing conventions](.github/WRITING.md) and
  [API documentation authoring](docs/documentation.rakudoc).
- [MIT license](LICENSE) and [artwork provenance](docs/assets/README.md).
