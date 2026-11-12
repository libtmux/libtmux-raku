# Contributing

This private repository is implementing the Raku core library. The package
foundation is testable; the complete API and compatibility gates remain in
development. No package release has been published.
Read [AGENTS.md](../AGENTS.md) for change discipline and
[WRITING.md](WRITING.md) for prose and commit conventions.

## Toolchain

[.tool-versions](../.tool-versions) pins Rakudo 2026.09 on MoarVM. It is the
latest stable [upstream release][rakudo] verified on 2026-11-11 and implements
Raku 6.d. The language level and compiler release are separate versions.

Mise needs the Raku asdf plugin installed explicitly. The plugin is older
than the compiler; its current release feed includes the pinned archive.
Install the inspected plugin revision before installing the compiler:

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

Run focused unit tests through the distribution mapping:

```console
$ mise exec -- prove6 -I. t/unit
```

Run the package test path used during installation:

```console
$ mise exec -- zef test .
```

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
$ mise exec -- raku tools/check-install.raku
```

The outer live suite requires an explicit tmux binary and fails if it is
missing. Set `LIBTMUX_TMUX` to the source-pinned endpoint binary prepared by
the test environment; never point a fixture at an existing socket:

```console
$ mise exec -- prove6 -I. -It/lib xt/live
```

The ordinary `t/` suite contains pure tests; `xt/live/` is an explicit outer
gate. Required CI runs both endpoints and cannot treat skipped live tests as
success. Test helpers under `t/lib/` are author code, not installed modules.

Logo exports and their upstream source provenance live in [docs/assets](../docs/assets/README.md).
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

Time the entire command, including startup and setup. These are pragmatic
targets; record and justify adjustments rather than dropping required checks:

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

## Raku conventions

- Use `META6.json` for package metadata, `.rakumod` for modules, `.rakutest`
  for tests, `.raku` for scripts, and RakuDoc/Pod for API documentation.
- Declare the language level with `raku`, separate runtime, build, and test
  dependencies, and list installed module paths explicitly in `provides`.
  Use SPDX license identifiers and HTTPS source links.
- Prefer core `Test`. Use distribution imports (`-I.`) when checking public
  imports so an undeclared module cannot hide behind `-Ilib`. Consider
  `App::Prove6` when a real suite needs a runner.
- Use zef for dependency and installed-package checks. A GitHub authority
  does not establish ownership of a `zef:` publishing account.
- When CI is added, use the maintained `Raku/setup-raku` action, pin actions
  to full commits, and read the compiler version from `.tool-versions`.
  Keep Linux required and verify additional platforms before claiming them.

These conventions follow the [distribution guide][distribution],
[zef's package checks][zef-ci], [App::Rak's metadata][rak-meta], and
[Mi6's author-test workflow][mi6-ci]. Active libraries sometimes retain old
action versions or legacy metadata; evaluate those choices independently.

## Formatting and additional analysis

Keep formatter changes opt-in and review their diffs. A bounded evaluation on
the pinned compiler tested grammars, regexes, heredocs, quote operators,
comments, Pod and multi signatures:

| Tool | Evaluated result | Repository policy |
| --- | --- | --- |
| [Raku Navigator 0.5.3][navigator] | Changed quoted string values and Pod indentation | Set `raku.formatting.enable` to `false`; navigation remains optional. |
| [rakufmt 0.0.1][rakufmt] | Preserved 18 behavioral assertions, comments, Pod and repeated formatting | Experimental author tool; no required formatting gate. |
| [static 0.0.1][static] | Detected a type mismatch accepted by plain compilation | Advisory default `fail-on-mismatch`; do not enforce uncertainty rejection. |

These results apply to the linked source revisions and the bounded corpus,
not every Raku program. Neither formatter success nor idempotence proves
semantic preservation. Run affected behavioral tests after formatting.
Compiler-backed formatting and analysis may execute compile-time code.
Keep these tools outside runtime dependencies and timed unit loops.

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

[rakudo]: https://github.com/rakudo/rakudo/releases/tag/2026.09
[distribution]: https://docs.raku.org/language/distributions/configuration-structure
[zef-ci]: https://github.com/ugexe/zef/blob/a5289115b669adfe8afd2bea52d031320fed5d78/.github/workflows/tests.yml
[rak-meta]: https://github.com/lizmat/App-Rak/blob/3123265d994a2067c32d93addc6295eb5554505b/META6.json
[mi6-ci]: https://github.com/skaji/mi6/blob/235a052d7655b809d7a669ec1d57487b70afbf90/.github/workflows/test.yml
[navigator]: https://github.com/bscan/RakuNavigator/tree/ccd511dbd156f396eed613f21adbcd8e38a8c784
[rakufmt]: https://github.com/ugexe/Raku-rakufmt/tree/529a707df7d76feedfc536e50b9d52acc942c076
[static]: https://github.com/FCO/static/tree/a3c731c5462a95ddba634a8d1e5903e0f415bca9
