# Changelog

## Unreleased

- Add `Server.start-program` and `Server.run-program` for literal argv in an
  owned PTY, with input, retained exit results and bounded rendered output.
  Managed programs require a qualified tmux 3.8 daemon and Linux 6.9 or newer.
- Preserve optional subset defaults during command admission.
- Rename the `observatory.raku` example to `session-workflow.raku`; its server
  is now named `work`.
- Add the `explain-query.raku` example, which shows how a query filter is
  planned, and `resize-panes.raku`, which splits, resizes and kills panes.
- Document the `Server` class with a directory of its methods by task.
- Link the issue tracker from the package metadata.

## 0.0.1 - 2026-11-13

- Initial release.
