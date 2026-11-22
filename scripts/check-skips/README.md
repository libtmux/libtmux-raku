# check-skips

Reads TAP on standard input, copies it to standard output, and fails if any
test line carries a `# SKIP` directive. The required live contracts must run
every test, so a skipped test fails the lane.

`ci.yml` pipes the live suite through it:

```console
$ prove6 --verbose -I. -It/lib xt/live \
    | raku scripts/check-skips/check-skips.raku
```

The pipeline fails when `prove6` fails, because the step runs with `pipefail`.

Test a clean run and each spelling of the directive, with no tmux:

```console
$ raku scripts/check-skips/tests/check-skips.rakutest
```
