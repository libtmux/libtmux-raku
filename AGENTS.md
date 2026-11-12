# Agent instructions

This repository is the private Raku libtmux core library. Follow the existing
conventions and keep changes scoped to the active implementation goal.

## Change discipline

- Inspect the current branch, working tree, and remotes before changing them.
  Preserve unrelated changes and existing symlink targets.
- Make the smallest coherent change that solves the verified problem. Keep
  unrelated cleanup out of it.
- Reuse an existing file, helper, API, or test before adding a new one.
- Keep new APIs private until a caller outside the library needs them.
- Add files for distinct responsibilities or independent reuse. Avoid
  single-use wrappers and one-line re-exports.
- Follow native Raku conventions. Sibling ports supply behavioral references;
  their code and test results do not establish Raku support.
- Add tests only for critical behavior. Show that a regression test fails for
  the intended reason before relying on its passing result.
- Verify claims against the current source and commands actually run. Report
  whole-command durations, failures, skips, and unverified behavior.
- Prefer `rg`, `ag`, and `fd` for discovery; use `jq` for JSON.

## Which policy applies

- Setup, validation, tmux isolation, and pull requests:
  [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).
- Documentation, comments, and commit messages:
  [.github/WRITING.md](.github/WRITING.md).

Each guide is the single home for its subject. Keep both guides under
`.github/`. `CLAUDE.md` is a relative symlink to this file.

## Repository boundaries

Keep `libtmux/libtmux-raku` private. Do not push to the `tony` organization.
Use only the repositories and operations authorized for the current task.
The active core goal excludes package publication and changes to other ports.
Do not push to public repositories or open a libtmux/docs PR while the user's
hold remains active. Keep upstream `tmux/tmux` research read-only.

## Merging pull requests

Use a descriptive subject ending in the actual PR number: `Title (#PRNUM)`.
Supply the subject and body explicitly, with `why:` and `what:` sections.
Read back the resulting commit message before starting another merge.
