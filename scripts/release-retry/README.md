# release-retry

Decides what a rerun of the release workflow may do after an earlier attempt
failed. It reads the run's artifacts and job steps through `gh` and writes
`restored=` or `needed=` to `$GITHUB_OUTPUT`.

`ci.yml` and `release.yml` run it with `GH_TOKEN` set. On a first attempt it
does nothing, except that `upload` reports `needed=true`.

`archive` restores the retained `release-candidate` artifact into a directory.
It refuses to continue when no archive remains but an upload already ran,
because rebuilding would change the released bytes:

```console
$ raku scripts/release-retry/release-retry.raku archive dist
```

`upload` reports whether the Fez upload step still has to run. It refuses when
an earlier upload was interrupted, because the registry state is unknown:

```console
$ raku scripts/release-retry/release-retry.raku upload
```

It needs `gh` on `PATH` and the `JSON::Fast` dependency.

Test it against a stand-in `gh`, with no network:

```console
$ raku scripts/release-retry/tests/release-retry.rakutest
```
