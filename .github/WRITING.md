# Writing

This guide governs documentation, comments, commits, and review prose.
[CONTRIBUTING.md](CONTRIBUTING.md) owns the development workflow.

## Voice

Lead with the conclusion or observable result, then support it with evidence.
Use active voice, concrete nouns, and short sentences. Assume no shared
history: explain what an issue or decision means before citing its identifier.

Remove filler, promotional claims, emojis, and agent attribution. Distinguish
planned, implemented, tested, and published behavior. Answer questions before
editing. When responding to feedback, state agreement or disagreement before
describing changes.

## Guides and API documentation

Lead with the reader's task, installation, the smallest complete working
example, its result, and operational limits.

Keep API contracts beside their definitions and conceptual explanations in
one guide. Link to each instead of duplicating descriptions. Document inputs,
outputs, errors, ownership, I/O, and cleanup where relevant. Use RakuDoc/Pod
for native API documentation.

Comments explain invariants, constraints, or intent that the code does not
make clear. Remove comments that merely narrate the next expression.

## Markdown and examples

Use CommonMark with blank lines around headings and lists. Wrap repository
prose at about 80 columns, except tables and long links. Keep GitHub issue
and PR paragraphs unwrapped. Exclude personal information and local machine
paths from published text.

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

## README shape

- Open with the logo block, a centred title and a badge row: CI, the registry
  version once published, the libtmux.org docs page once it returns 200, and
  the license. Never link a page that does not exist.
- Make each `##` heading a task in the reader's words, such as "Find and filter
  panes".
- Make each `###` heading an API: its name in code, linked to its native
  declaration, then a colon and its job in plain words.
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
  `<!-- runs: examples/NAME.raku -->`; `tools/check-examples.raku` compares the
  bytes.
- Show the features the library has, each under an API-linked heading with a
  checked example: queries and filters, the query planner, batches and control
  mode.
- Close with "What it leaves out" and "Support and status" as short bold-lead
  bullets.
- Use absolute URLs only, because Raku Land renders the README away from the
  repository, and pin API links to a commit.

## Commits and pull requests

Use a lowercase scope unless it names a proper product or class. Keep each
commit focused on one topic and explain the durable motivation and changes.
Keep temporary validation results in the review discussion.

```text
scope(type[detail]) Concise description

why: Explanation of necessity or impact.
what:
- Specific technical change
- Related change within the same topic
```

The detail is optional. Use `feat`, `fix`, `refactor`, `docs`, or `chore` as
appropriate. Review descriptions explain the final change for someone who
has not read the conversation, including relevant checks and their limits.
