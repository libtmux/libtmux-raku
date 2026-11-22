# Writing

This file adds Raku, RakuDoc/Pod, and `LibTmux` conventions to
[`libtmux/.github/WRITING.md`][org-writing], which governs voice, plain
CommonMark, 80-column repository prose wrapping, unwrapped issue and
pull-request paragraphs, slop removal, and commit and pull-request format.
[CONTRIBUTING.md](CONTRIBUTING.md) owns the development workflow.

Distinguish planned, implemented, tested, and published behavior. Answer
questions before editing. When responding to feedback, state agreement or
disagreement before describing changes.

## Guides and API documentation

Lead with the reader's task, installation, the smallest complete working
example, its result, and operational limits.

Keep API contracts beside their definitions and conceptual explanations in
one guide. Link to each instead of duplicating descriptions. Document inputs,
outputs, errors, ownership, I/O, and cleanup where relevant. Use RakuDoc/Pod
for native API documentation.

Comments explain invariants, constraints, or intent that the code does not
make clear. Remove comments that merely narrate the next expression.

### Code blocks

Code blocks are paste-and-run units:

- Use `console` fences and a `$ ` prefix for shell commands.
- Put one command in each block. An explicit `&&`, `;`, or `\` chain counts
  as one command.
- Put prerequisites, comments, and explanations outside the fence.
- Split long commands with `\`, placing each flag on its own continuation line.
- Run complete examples and check their stated results. Mark proposals as
  proposals until runnable examples exist.

Examples that touch tmux own their socket and cleanup. A compile-only check
does not establish tmux behavior. Extract public snippets from checked source
or verify that they remain aligned.

## Examples

<!-- shared:examples -->

An example is code written for a reader: a program under `examples/`, code in
a doc comment or docstring, and every fenced block in a README or docs page.
Shell blocks also follow [Code blocks](#code-blocks).

The text between the shared markers is the same in every libtmux port.
Change it in all of them together.

### Width

- **Examples stay within 80 columns.** They render in fixed-width boxes that
  scroll sideways, and 80 columns fits a libtmux.org code block in a
  laptop-width window. Comments inside examples wrap at 80 too.
- **The width check enforces it.** It reads the tracked files that
  `.github/example-width.toml` names and fails on a wider line. It measures
  the whole source line, so code in a doc comment counts its indent and
  comment marker. It skips output (a fence tagged `text`, and what a
  `console` block prints), hidden setup lines, and a line that is only a URL;
  an untagged fence counts as code.
- **A line that must stay wider is listed there with its reason.** An entry
  that no longer matches a line fails the check, so no stale entry stays.
- **The formatter's width is the hard limit for all other source.** Example
  directories set their formatter to 80 where the formatter takes a width.

### Reaching 80

- **Change the code, not the line breaks.** A formatter rejoins any line that
  fits its width. Name a sub-expression, use a short example name, hide setup
  the reader does not need, or print less.
- **Break at the outermost level when a break is still needed:** after an
  opening parenthesis with one argument per line, one call per line in a
  chain, one field per line in a literal.
- **Put a comment on its own line above the code it explains.** Never trail
  one after code in an example, unless the repository's example runner reads
  it there, as with an assertion marker.
- **Break a long string at a word boundary,** never inside a tmux format
  (`#{...}`) or an escape sequence; the joined text stays the same.
- **Continue a long command in a `console` block the way its shell does:**
  `\` after a `$ ` prompt, a backtick after `PS> `, one flag per continuation
  line.

### What never breaks

- **Output a test compares.** Wrapping it changes what the test expects.
- **A block copied from a source file.** Fix the width in the source and run
  the sync command; never edit the copy.
- **Marker lines and URLs,** which tools and readers take whole.

<!-- /shared:examples -->

### In this repository

- **Hard limit:** examples stay within 80 columns, enforced by the
  `check-example-width` action of `libtmux/.github` and
  `.github/example-width.toml`. No Raku formatter runs in CI; see
  [Formatting and additional analysis](CONTRIBUTING.md#formatting-and-additional-analysis).
- **Not formatted:** every example (`examples/*.raku`, RakuDoc code blocks in
  `lib/` and `docs/`, and fenced blocks in Markdown files). Hold them to 80
  columns by hand.
- **Runs, compiles, exempt:** `scripts/check-compile/check-compile.raku`
  compiles `examples/`, and `scripts/check-examples/check-examples.raku` runs
  every `examples/*.raku` program against the qualified `LIBTMUX_TEST_TMUX`
  binary and checks its output and cleanup. Fences tagged `text` and unprompted
  output lines in `console` blocks are exempt.
- **Compared output and copied blocks:** never wrap output compared in
  `scripts/check-examples/check-examples.raku`. Edit `examples/NAME.raku`, copy
  the file into its `<!-- runs: examples/NAME.raku -->` fence in `README.md`
  and `=comment runs: examples/NAME.raku` block in `lib/LibTmux.rakumod`, and
  check alignment with
  `raku scripts/check-examples/check-examples.raku --check-source`.

Bad, over 80:

```raku
    my $connection = await $server.open-control-async(:session-id($snapshot.sessions.single.id));
```

Good, name the value first:

```raku
    my $session-id = $snapshot.sessions.single.id;
    my $connection = await $server.open-control-async(:$session-id);
```

## README shape

- Open with the logo block, a centred title and a badge row: CI, the registry
  version once published, the libtmux.org docs page once it returns 200, and
  the license. Never link a page that does not exist.
- Make each `##` heading a task in the reader's words, such as "Find and filter
  panes".
- Make each `###` heading an API: its name in code, linked to its libtmux.org
  reference page, then a colon and its job in plain words.
- Under a heading, give a line or two of linked sibling APIs, the checked
  example, what it prints, at most one short note and a `More:` link.
- Keep paragraphs to three lines. Write a list of facts as bullets.
- Skip feature inventories. The sections and examples show what exists.
- State requirements as floors a reader can act on, such as "tmux 3.3a or
  newer". Leave out toolchain patch versions, CI matrix narration and kernel
  details; link the page that holds them.
- Cut what a reader would assume or never need: that examples are tested, how
  docs are built, what the checks cover.
- Start each example with its imports, so it pastes into a file and runs.
- Start and clean up the example's own tmux server through the library, never
  through `tmux` or `rm` in the shell.
- Show only examples that come from a file CI runs. Mark each with
  `<!-- runs: examples/NAME.raku -->`;
  `scripts/check-examples/check-examples.raku` compares the bytes.
- Show the features the library has, each under an API-linked heading with a
  checked example: queries and filters, the query planner, batches and control
  mode.
- Close with "What it leaves out" and "Support and status" as short bold-lead
  bullets, compact documentation links, and the [libtmux.org](https://libtmux.org/)
  family line.
- Use absolute URLs only in `README.md`, because Raku Land renders the README
  away from the repository.

## Commits and pull requests

Follow `scope(type[detail]): concise description` (50-character subject,
72-character body lines, `why:` and `what:` separated by a blank line) and the
pull-request rules in [`libtmux/.github/WRITING.md`][org-commits]. Use a
lowercase scope unless it names a proper product or class, and keep temporary
validation results in the review discussion.

[org-writing]: https://github.com/libtmux/.github/blob/main/WRITING.md
[org-commits]: https://github.com/libtmux/.github/blob/main/WRITING.md#commits-and-pull-requests
