# check-source

Checks the files Git tracks or would track for what the other tools assume:

- no CR line endings, trailing whitespace or missing final newline in text
  files;
- a `use v6.d;` first line in every module;
- relative Markdown links that resolve, and `console` fences for shell
  examples;
- `META6.json` `provides` and `resources` that list exactly the modules and
  resource files present;
- `CONTRIBUTING.md` and `WRITING.md` under `.github`, and `CLAUDE.md` as a
  relative symlink to `AGENTS.md`.

It is not a formatter. `ci.yml` runs it first in the quality job:

```console
$ raku scripts/check-source/check-source.raku
```
