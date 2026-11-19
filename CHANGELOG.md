# Changelog

## Unreleased

- Rename the `observatory.raku` example to `session-workflow.raku`; its server
  is now named `work`.
- Add the `explain-query.raku` example, which shows how a query filter is
  planned, and `resize-panes.raku`, which splits, resizes and kills panes.
- Document the `Server` class with a directory of its methods by task.
- Document the `SessionRef`, `WindowRef` and `PaneRef` classes with a
  directory of their methods by task.
- Link the issue tracker from the package metadata.
- Show installing the examples from the zef release and running a saved
  program in the examples guide. `session-workflow.raku` and
  `batch-recovery.raku` print `Stopped the tmux server and removed its socket`
  and no longer test `/proc`; the example check now fails an example that
  leaves a tmux process behind.

## 0.0.1 - 2026-11-13

- Initial release.
