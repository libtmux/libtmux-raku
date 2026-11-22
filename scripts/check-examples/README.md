# check-examples

Checks that every Raku snippet in `README.md` and `lib/LibTmux.rakumod` is the
byte-for-byte text of the example it names, then runs each program in
`examples/`, compares its output with the documented result and rejects an
example that leaves a socket directory or a process behind.

`ci.yml` runs the source check on every push and the full run in each tmux job.
The source check needs no tmux:

```console
$ raku scripts/check-examples/check-examples.raku --check-source
```

The full run needs `LIBTMUX_TEST_TMUX`, the absolute path of the tmux to test
against:

```console
$ LIBTMUX_TEST_TMUX=/usr/local/bin/tmux \
    raku scripts/check-examples/check-examples.raku
```

Test that a snippet which differs from its example fails the check:

```console
$ raku scripts/check-examples/tests/check-examples.rakutest
```
