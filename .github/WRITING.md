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

Lead with the reader's task. Once a usable package exists, show installation,
the smallest complete example, its result, and operational limits. Until
then, state the scaffold status without invented usage or install commands.

Keep API contracts beside their definitions and conceptual explanations in
one guide. Link to each instead of duplicating descriptions. Document inputs,
outputs, errors, ownership, I/O, and cleanup where relevant. Use RakuDoc/Pod
for native API documentation when modules exist.

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
