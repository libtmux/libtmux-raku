# ci-matrix

Prints the tmux releases CI tests as the JSON a GitHub Actions matrix reads.
The list comes from the support policy in `LibTmux::Catalogue`, so the matrix
and the library agree on the oldest and newest supported tmux.

`ci.yml` runs it in the `prepare` job and feeds the result to the live suite.
`--github-output` prints `value=JSON`, the line the step appends to
`$GITHUB_OUTPUT`:

```console
$ raku -I. scripts/ci-matrix/ci-matrix.raku
```

Test that the matrix equals the typed endpoint profiles:

```console
$ raku -I. scripts/ci-matrix/tests/ci-matrix.rakutest
```
