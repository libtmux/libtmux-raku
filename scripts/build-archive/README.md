# build-archive

Packs a commit into the release archive and its checksums: `LibTmux-X.Y.Z.tar.gz`
from `git archive`, and `SHA256SUMS` from `sha256sum`, both in the directory you
name. It refuses a directory that already holds either file, so it cannot
replace a retained archive.

`ci.yml` runs it on a fresh release, then `check-release --dist` verifies the
pair. A retried run restores the retained pair with `release-retry` and skips
this script:

```console
$ raku scripts/build-archive/build-archive.raku \
    dist \
    0.0.1
```

By default it packs `HEAD` of this repository; `--source` and `--commit`
change that. It needs `git` and `sha256sum` on `PATH`.

Test it against a throwaway repository:

```console
$ raku scripts/build-archive/tests/build-archive.rakutest
```
