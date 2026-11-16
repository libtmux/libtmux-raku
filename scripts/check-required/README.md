# check-required

Fails the `required` job of `ci.yml` unless every job the run declared
succeeded. The job names come from the run itself: `Prepare`, `Quality` and one
`tmux X.Y` job for each endpoint in the matrix. A skipped, cancelled, repeated
or missing job fails the check, so a branch protection rule can require this one
job.

The script checks the matrix has the shape `ci-matrix` prints (one or two
endpoints, each with a distinct tmux version and a distinct 40-digit commit),
then asks `gh api` for the jobs of the latest attempt. `GH_TOKEN` must be set:

```console
$ raku scripts/check-required/check-required.raku \
    --prepare=success \
    --quality=success \
    --live=success \
    --matrix='{"include":[...]}' \
    --repository=libtmux/libtmux-raku \
    --run-id=123
```

It needs `gh` on `PATH` and the `JSON::Fast` dependency.

Test it against a stand-in `gh` and a fixture job list, with no network:

```console
$ raku scripts/check-required/tests/check-required.rakutest
```
