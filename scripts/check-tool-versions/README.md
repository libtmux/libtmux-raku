# check-tool-versions

Checks that `.tool-versions` declares exactly one `raku` entry, written as
`raku` and a Rakudo release such as `2026.09`, and that the compiler running
the script is that release. It prints the declared version.

`ci.yml` installs the compiler named by `.tool-versions` and then runs this
check, so a malformed file or a compiler other than the pinned one fails the
`prepare` job. The first read of the file, which picks the compiler to
install, runs before any Raku exists; [SCRIPTS.md](../../.github/SCRIPTS.md)
records that step as the one exception.

```console
$ raku scripts/check-tool-versions/check-tool-versions.raku
```

Test each malformed file and a mismatched compiler, with no network:

```console
$ raku scripts/check-tool-versions/tests/check-tool-versions.rakutest
```
