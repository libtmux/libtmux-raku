# Scripts

This policy covers the support scripts in this repository: files under
`scripts/`, CI helpers, generators and checkers. It applies the libtmux
decision in [libtmux/docs#323](https://github.com/libtmux/docs/pull/323).

## Keep a script only for a current use

A script stays when this project runs it today: a CI job, a release step, a
code generator, a documentation check, or a maintainer task named in
[CONTRIBUTING.md](CONTRIBUTING.md).

- Parity with Python libtmux or tmuxp is not a use. Delete comparison
  harnesses, oracles, ledgers and generated fixtures, and the CI steps that
  install them.
- A shell step that creates, prepares or stops tmux for an example or test
  means the library lacks an operation. File an issue for the operation and
  remove the step when it lands.
- Delete scripts nothing calls.
- Tooling several ports share lives once, as a shared workflow or action, not
  as a vendored copy.

## Language

Scripts are Raku, run with `raku`, the same interpreter CI uses for the
library. Do not add shell or Python script files.

## Layout and checks

- A script with tests lives in `scripts/<name>/`, with a `README.md` (what it
  does, who runs it, how) and `tests/`. A short single-purpose script may be
  one file with a usage header.
- Raku has no formatter or linter that CI runs, so scripts pass the checks the
  library passes: their tests under `prove6`, `check-source` for whitespace,
  links and the file inventory, and `check-compile`, which runs `raku -c` on
  `scripts/`, `examples/` and `t/lib/`. Compilation is the type check Raku has.
- Shared helpers live in `scripts/lib/`. A script loads them with `use lib`
  relative to its own path, so it runs from any directory.
- Use current language and tool idioms; no shims below the project's floor.
- Before a new or rewritten script merges, a reviewer who did not write it
  checks it against [WRITING.md](WRITING.md) and
  [no-ai-slop](https://github.com/petergyang/no-ai-slop).

## What stays

- GitHub Actions `run:` lines that call one command. Flags, a redirect such as
  `>> "$GITHUB_OUTPUT"`, or a pipe into one tool count as one command.
  Anything with a conditional, a loop, a second command or an inline
  `awk`, `jq` or `raku -e` program is a script under `scripts/<name>/`, or a
  step for each command.
- Calls to system tools such as `git`, `tar`, `gh` and `sha256sum` from a Raku
  script. They are not a second scripting language: the script reads their
  output in Raku.
- A capability Raku lacks comes from a test-only Raku dependency, not from a
  second language.
- Test data that is not a comparison, such as workspace files a loader reads.

## Measured exception

`ci.yml` step "Read the declared compiler" runs one `sed` substitution on
`.tool-versions` before any Raku exists, because its output chooses the
compiler that `Raku/setup-raku` installs. A Raku script cannot run there. A
bootstrap compiler would add an install to the `prepare` job and a second
version to keep in step: in CI run 43799750176 the `Raku/setup-raku` step took
2 s and the earlier awk step 0 s, from the job steps of that run:

```console
$ gh run view 43799750176 --repo libtmux/libtmux-raku --json jobs
```

`check-tool-versions` runs after the install and checks that
`.tool-versions` holds one well-formed `raku` entry and that the installed
compiler is that release, so the `sed` line carries no checks.
