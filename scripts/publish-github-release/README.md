# publish-github-release

Creates or completes the GitHub release for a version tag and attaches the
tested archive and its checksums. It publishes the release only after both
assets are present, so a failed run leaves a draft.

`release.yml` runs it with `GH_TOKEN` set, in the job that follows registry
verification. Rerunning it is safe: an asset with the same digest is
kept, and an asset with a different digest stops the run.

Pass the directory holding `LibTmux-X.Y.Z.tar.gz` and `SHA256SUMS`, the tag
and the repository:

```console
$ raku scripts/publish-github-release/publish-github-release.raku \
    dist \
    v0.0.1 \
    libtmux/libtmux-raku
```

It needs `gh` and `sha256sum` on `PATH` and the `JSON::Fast` dependency.

Test it against a stand-in `gh`, with no network:

```console
$ raku scripts/publish-github-release/tests/publish-github-release.rakutest
```
