# check-release

Checks a release tag against `META6.json` and prints the package version. It
requires the tag to be `v` and the version, the distribution to be `LibTmux`
and the authority to be `zef:libtmux`.

With `--dist=DIRECTORY` it also checks the archive in that directory: its
checksum must match `SHA256SUMS`, its recorded commit must be `--commit`
(default `HEAD`), and its `META6.json` must equal the checkout's.

`ci.yml` and `release.yml` run it, and `.github/RELEASE.md` describes where it
sits in a release:

```console
$ raku scripts/check-release/check-release.raku v0.0.1
```

Test the tag and archive checks against fixture metadata and a fixture Git
repository:

```console
$ raku scripts/check-release/tests/check-release.rakutest
```

```console
$ raku scripts/check-release/tests/check-release-archive.rakutest
```
