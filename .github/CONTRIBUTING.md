# Contributing

Read [AGENTS.md](../AGENTS.md) for change discipline,
[WRITING.md](WRITING.md) for prose and commit conventions, and
[SCRIPTS.md](SCRIPTS.md) for the support scripts.

## Toolchain

[.tool-versions](../.tool-versions) pins the Rakudo compiler on MoarVM.
The library targets stable Raku 6.d.

Install the pinned Raku plugin for mise before installing the compiler:

```console
$ mise plugins install raku \
    https://github.com/m-dango/asdf-raku.git#dd8c1ef91f2b9805f94c4165d6b3029b3fbf2a06
```

Install the compiler outside the validation loops:

```console
$ mise install raku
```

Verify the selected compiler:

```console
$ mise exec -- raku --version
```

The binary includes zef. Install the declared dependencies before validation:

```console
$ mise exec -- zef install --deps-only .
```

Install author-only metadata and TAP tools separately:

```console
$ mise exec -- zef install App::Prove6 Test::META
```
Keep the compiler's default frontend enabled. Verify upstream releases
before advancing the pin.

## Checks

Check source hygiene, relative file links and distribution inventory:

```console
$ mise exec -- raku scripts/check-source/check-source.raku
```

This check does not rewrite code, format Raku syntax or perform static analysis.

Run focused unit tests through the distribution mapping:

```console
$ mise exec -- prove6 --jobs=2 -I. t/unit
```

Run the package test path used during installation:

```console
$ mise exec -- zef test .
```

Check the catalogue-derived native accessors:

```console
$ mise exec -- raku -I. scripts/catalogue/catalogue.raku \
    --format=raku \
    --output=lib/LibTmux/Fields.rakumod \
    --check
```

Check the generated human reference separately:

```console
$ mise exec -- raku -I. scripts/catalogue/catalogue.raku \
    --format=rakudoc \
    --output=docs/reference/catalogue.rakudoc \
    --check
```

Omit `--check` to regenerate either file after editing the runtime catalogue.

Check package metadata with the author tool:

```console
$ mise exec -- raku xt/meta.rakutest
```

Compile the public import. Compilation executes BEGIN/CHECK code and is not
an independent style linter:

```console
$ mise exec -- raku -I. -c lib/LibTmux.rakumod
```

Install into a temporary repository and load it from a fresh process outside
the checkout. This outer check removes its temporary installation afterward:

```console
$ mise exec -- raku scripts/check-install/check-install.raku
```

The outer live suite requires an explicit tmux binary. Set `LIBTMUX_TEST_TMUX`
to its absolute executable path; never point a fixture at an existing socket.
The typed `support-policy` in `LibTmux::Catalogue` defines the supported
releases. CI derives the oldest and newest endpoints from that policy and
verifies their source and executable versions. See the
[tmux compatibility policy](../docs/adr/0001-tmux-compatibility.md).

| Setting | Owner and meaning | Failure behavior |
| --- | --- | --- |
| `LIBTMUX_TEST_TMUX` | Live fixtures and the example runner select one explicit tmux executable. | Missing, relative or nonexecutable paths fail before fixture setup; no PATH fallback or skipped live tests. |
| `TMUX_VERSION` | CI builds the policy commit with the shared `build-tmux` action and compares the reported version. | A reported-version mismatch fails the lane. |

`LIBTMUX_TEST_TMUX` is test-only. It does not change the production
`Server.new` executable default or select a borrowed socket. Each fixture owns
its temporary directory and explicit socket and clears inherited `TMUX` and
`TMUX_PANE` for its children.

```console
$ mise exec -- prove6 -I. -It/lib xt/live
```

The ordinary `t/` suite contains pure tests; `xt/live/` is an explicit outer
gate. Required CI runs both endpoints and cannot treat skipped live tests as
success. Test helpers under `t/lib/` are author code, not installed modules.
The outer suite needs no other language. The PTY fixture binds libc through
NativeCall and blocks in `poll`. Stand-ins for the tmux binary are Raku scripts
that `Test::LibTmux::Wrapper` writes and that replace themselves with the real
binary, and the daemon-exit waits use pidfds.

A wrapper start is one `raku` launch that loads the fixture modules. The
stand-in is a file that `write-wrapper` writes and that runs `exec-program` on
`/bin/true`. This command timed it on a host at a load average near 5, with
the precompiled modules warm:

```console
$ hyperfine -N --warmup 3 --runs 20 ./wrapper
```

The mean was 0.22 s. One launch with a fresh precompile store took 0.85 s, from
`time ./wrapper` with `RAKUDO_PRECOMP_DIR` pointing at an empty directory. The
15 s ceiling in `client.rakutest` and the 30 s ceilings in `server.rakutest`
and `control-no-start.rakutest` are about 18 and 35 times that cold start, so a
loaded host passes and a hung wrapper still fails. A ceiling adds no wait to a
passing run. These figures are from the local host, not from a CI runner.

Check that the README and native guide quote complete canonical example files.
This check requires no tmux process:

```console
$ mise exec -- raku scripts/check-examples/check-examples.raku --check-source
```

Run every example against the same explicit `LIBTMUX_TEST_TMUX` endpoint binary.
The runner checks displayed source, expected output, and that no socket
directory or process is left behind.
It places a `tmux` symlink to the selected binary in a private temporary directory
first on the child `PATH`, then removes that directory on exit. Programs other
than the minimal quickstart also receive the binary through `--tmux`:

```console
$ mise exec -- raku scripts/check-examples/check-examples.raku
```

Logo exports and their upstream source provenance live in
[assets](../assets/README.md).
Keep artwork build dependencies in the upstream artwork project.

Check tracked edits for whitespace errors:

```console
$ git diff --check
```

Inspect new files separately. Check the staged diff before committing:

```console
$ git diff --cached --check
```

Verify relative instruction links and the `CLAUDE.md` symlink when changing
guides. Whitespace checks do not establish package or tmux compatibility.
Report `PASS`, `FAIL`, `PARTIAL`, and `UNVERIFIED` distinctly.

Time the entire command, including startup and setup. Retain every required
check and investigate runs that exceed these budgets:

| Loop | Scope | Budget | Target |
| --- | --- | --- | --- |
| Inner | Changed critical behavior | <5 s | <2 s |
| Mid | Unit suites, lint, generated-file checks | <30 s | <10 s |
| Outer | Builds, package checks, real tmux, full CI matrix | <5 min | <60 s |

Keep network access, installations, builds, browsers, sleeps, and broad scans
out of inner and mid loops. Tag slow checks with a reason and run them in
the outer loop. Investigate excessive setup before adding tests. Investigate waits
over one second; prefer events and subscriptions. Benchmarks are separate:
less than ten minutes per run and one hour per sweep.

## Script tests

Each script under `scripts/<name>/` has a `README.md` and `tests/`. Run every
script test with the runner CI uses:

```console
$ mise exec -- prove6 --jobs=2 -I. scripts
```

Run one script's test by name. `catalogue`, `ci-matrix` and `export-docs` need
`-I.`; `check-source` does not:

```console
$ mise exec -- raku scripts/check-source/tests/check-source.rakutest
```

The script tests start no tmux and need no network.
[SCRIPTS.md](SCRIPTS.md) lists the checks CI runs on the scripts themselves.

## Raku conventions

- Use `META6.json` for package metadata, `.rakumod` for modules, `.rakutest`
  for tests, `.raku` for scripts, and RakuDoc/Pod for API documentation.
- Declare the language level with `raku`, separate runtime, build, and test
  dependencies, and list installed module paths explicitly in `provides`.
  Use SPDX license identifiers and HTTPS source links.
- Use core `Test` and run suites with `App::Prove6`. Use distribution imports
  (`-I.`) when checking public imports so an undeclared module cannot hide
  behind `-Ilib`.
- Use zef for dependency and installed-package checks. A GitHub authority
  does not establish ownership of a `zef:` publishing account.
- Use `Raku/setup-raku` in CI, pin actions to full commits, and read the
  compiler version from `.tool-versions`.
  Keep Linux required and verify additional platforms before claiming them.

## Formatting and additional analysis

Follow [native documentation authoring](../docs/documentation.rakudoc) for
declarator comments, API extraction, coverage checks and shared rendering.

Keep formatter changes opt-in and review their diffs. Run affected behavioral
tests after formatting; compiler-backed tools can execute compile-time code.

| Tool | Use | Limit |
| --- | --- | --- |
| [Raku Navigator][navigator] | Optional navigation; set `raku.formatting.enable` to `false`. | Formatting can alter quoted strings and Pod indentation. |
| [rakufmt][rakufmt] | Optional formatting with diff review and affected tests. | No required formatting gate. |
| [static][static] | Optional targeted advisory checks. | Rejects valid Instant arithmetic, Blob byte counts and custom BUILD arguments. |

These limits apply to the linked tool revisions. Keep the tools outside runtime
dependencies and timed unit loops. Compiler import and behavioral tests remain
required.

## tmux isolation

The runtime floor is tmux 3.3a on Linux. For tests and probes,
use unique owned sockets and temporary directories. Clear inherited `TMUX`
and `TMUX_PANE`. Never use or stop the default server or a borrowed server.
Clean up owned resources on success, failure, and cancellation, and verify
that owned processes exit. Command acknowledgement alone does not establish
operation completion.

## Review and publication

Describe the concrete problem and resulting behavior. Include relevant
verification and its limits. Keep commits focused and preserve unrelated
work. Repository privacy, pushes, and publication follow
[repository boundaries](../AGENTS.md#repository-boundaries).
See [RELEASE.md](RELEASE.md) for Fez account setup and version-tag publication.

[navigator]: https://github.com/bscan/RakuNavigator/tree/ccd511dbd156f396eed613f21adbcd8e38a8c784
[rakufmt]: https://github.com/ugexe/Raku-rakufmt/tree/529a707df7d76feedfc536e50b9d52acc942c076
[static]: https://github.com/FCO/static/tree/a3c731c5462a95ddba634a8d1e5903e0f415bca9
