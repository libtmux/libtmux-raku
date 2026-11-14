# Releasing LibTmux

Package versions use three numeric components, such as `0.0.2`; annotated
Git tags add a `v` prefix, such as `v0.0.2`. The first published version is
[`0.0.1`](https://github.com/libtmux/libtmux-raku/releases/tag/v0.0.1).
Pushing a version tag starts the
[Release workflow](workflows/release.yml): CI validates the tagged commit,
tests its archive, retains that archive, uploads it with Fez, and checks a
fresh registry installation. After that check passes, it creates a GitHub
release with generated notes, the tested archive, and `SHA256SUMS`.

The API remains experimental during `0.x`. The required matrix qualifies
Linux, the compiler in [.tool-versions](../.tool-versions), and the supported
tmux endpoints. It does not establish other compiler or platform support.

The maintainer must create the Fez account or organization and set `FEZ_KEY`
before the first automated upload. Preparing a release requires no key.

## Set up the publishing account

Install the pinned publisher with the compiler from
[the contributor guide](CONTRIBUTING.md#toolchain):

```console
$ mise exec -- zef install 'fez:ver<100.0.2>:auth<zef:tony-o>'
```

Register a Fez account interactively:

```console
$ mise exec -- fez register
```

The publishing identity must control `zef:libtmux`. For a shared account,
register a personal Fez user, then create the `libtmux` organization. In the
following command, enter the organization's email address and press Enter:

```console
$ read -r FEZ_ORG_EMAIL && \
    mise exec -- fez org create libtmux "$FEZ_ORG_EMAIL"
```

If another maintainer already controls that organization, have them invite
your Fez user, then accept the invitation:

```console
$ mise exec -- fez org accept libtmux
```

GitHub organization ownership does not reserve a Fez authority. If
`zef:libtmux` is unavailable, resolve ownership before releasing; changing
the authority requires updating the metadata and release checks in a PR.

Log in again to obtain a current key and refresh organization membership:

```console
$ mise exec -- fez login
```

Create the `fez` environment in the repository's
[environment settings](https://github.com/libtmux/libtmux-raku/settings/environments).
Allow release tags matching `v*`. Add its `FEZ_KEY` secret with the
login-issued key. This command transfers the local key directly to GitHub
without displaying it:

```console
$ mise exec -- raku <<'RAKU'
use Fez::Util::Config;
my $key = config-value('key');
die 'Run fez login first' unless $key;
my $gh = run 'gh', 'secret', 'set', 'FEZ_KEY', '--env', 'fez',
    '--repo', 'libtmux/libtmux-raku', :in;
$gh.in.print($key);
$gh.in.close;
exit $gh.exitcode;
RAKU
```

The command requires an authenticated GitHub CLI with permission to manage
that repository's environment secrets. Renew the secret after Fez reports
an expired key. The workflow supplies no username or password to Fez.

Fez uses an API key; its documented publishing flow has no OIDC trusted
publisher setup. See the [Raku publishing guide][publishing] and
[Fez client][fez]. Keep the key out of commits, artifacts, and logs.

## Prepare and review a release

Choose an unpublished version and set it in [META6.json](../META6.json).
Retain `zef:libtmux`. Move the changes from `Unreleased` into a dated version
section in [CHANGELOG.md](../CHANGELOG.md), then prepare the changes in a PR.
The commands below use `0.0.2` as an example; replace it with that version.

Run the checks in [CONTRIBUTING.md](CONTRIBUTING.md#checks), including the
release identity contracts:

```console
$ /usr/bin/time -p mise exec -- raku xt/release.rakutest
```

CI builds an archive from its checked-out commit and installs that exact
archive outside the checkout. Required quality and tmux jobs must pass.
Changes to the release workflows and helpers also run a rehearsal on the PR,
with publishing, registry verification, and GitHub release creation skipped.

After this workflow is merged, prepare and retain an archive without
publishing or requesting a key:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-raku \
    --ref master \
    --field mode=prepare
```

Inspect the resulting run and download its `release-candidate` artifact.
It contains `LibTmux-VERSION.tar.gz` and `SHA256SUMS` for the declared version.
The artifact expires after 90 days. Preserve the original files if an
upload is interrupted or you plan to publish manually.

## Publish a version tag

Merge the release preparation PR. Start from the approved commit on
`master` with a clean working tree:

```console
$ git switch master
```

```console
$ git pull --ff-only origin master
```

Confirm that the master CI run for this commit passed. Validate the tag
against the local metadata:

```console
$ mise exec -- raku tools/check-release.raku v0.0.2
```

Create an annotated tag:

```console
$ git tag -a v0.0.2 -m 'Release 0.0.2'
```

Push only that tag to begin publication:

```console
$ git push origin refs/tags/v0.0.2
```

The workflow reruns CI for the tagged commit. It uploads the retained,
checksum-verified archive only after those checks pass. A branch or PR
cannot enter the publishing job. Releases run serially and do not cancel
an active upload.

The `Verify registry installation` job refreshes the package index and
installs the exact version and authority into a temporary repository. A
fresh process outside the checkout loads every provided module, checks
the packaged catalogue and API contracts, and verifies installed identity.
Treat publication as verified only after this job passes. The GitHub release
job then attaches the retained files. It completes an interrupted draft,
preserves matching assets and notes on retries, and rejects conflicting
asset digests. Only that job receives `contents: write`; Fez receives its
key only in the upload step.

If GitHub leaves an empty asset in `starter` state after a failed upload,
confirm that it has zero bytes and remove that placeholder before retrying
the GitHub release job. An unknown digest stops recovery for manual inspection;
do not remove a completed asset to bypass a digest conflict. See GitHub's
[release asset upload behavior](https://docs.github.com/en/rest/releases/assets#upload-a-release-asset).

## Complete a manual upload or recover a failed run

Keep recovery on the original tagged run whenever possible. **Re-run failed
jobs** preserves successful jobs and their retained archive. A full rerun
restores the original archive, validates its checksum, Git commit and metadata,
and tests those bytes again. It skips an upload that already succeeded in
that run. If an upload was attempted and the artifact is unavailable, recovery
stops rather than rebuilding it.

If the upload step failed or was cancelled after it started, check whether
Fez accepted the distribution before retrying. The workflow refuses an
ambiguous retry. Correct an account or key problem and use an explicit
`publish` dispatch only after confirming that Fez did not accept the upload.
Do not infer absence from a stale package mirror.

If you need to publish manually, download `release-candidate` from the
tagged run, extract it into `dist/release`, and check the files:

```console
$ cd dist/release && sha256sum --check SHA256SUMS
```

From that directory, use your logged-in Fez account to upload the retained
archive for that version:

```console
$ mise exec -- fez upload --file=LibTmux-0.0.2.tar.gz
```

Then request registry verification for that tag, without another upload:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-raku \
    --ref v0.0.2 \
    --field mode=verify
```

This dispatch verifies the registry only. It does not publish GitHub assets
from its newly built archive. After a manual upload, use the original tested
files for the GitHub release as well.

An accepted Fez upload can precede the mirror used by a fresh zef client.
For `0.0.1`, the first registry check failed before the mirror refreshed;
a registry-only retry passed roughly ten minutes after upload. This is an
observed delay, not a guaranteed indexing interval. Refresh your local index
with `zef update` before checking availability. The default mirror can lag
the publishing service.

Once indexing completes, select **Re-run jobs** on the failed registry job
in the original run. This also resumes its dependent GitHub release job.
For the CLI equivalent, enter the original run ID from its Actions URL:

```console
$ read -r RELEASE_RUN_ID && \
    RELEASE_JOB_ID=$(gh run view "$RELEASE_RUN_ID" \
        --repo libtmux/libtmux-raku \
        --json jobs \
        --jq '.jobs[] | select(.name == "Verify registry installation") | .databaseId') && \
    test -n "$RELEASE_JOB_ID" && \
    gh run rerun "$RELEASE_RUN_ID" \
        --repo libtmux/libtmux-raku \
        --job "$RELEASE_JOB_ID"
```

The workflow does not poll while holding a runner. Automatic delayed
resumption is tracked in [issue #5](https://github.com/libtmux/libtmux-raku/issues/5).

Fez accepts one upload per distribution version. Do not repeat an upload
that succeeded, move its tag, or rebuild its archive to repair a partial
release. Preserve the files and use a new version for code or packaging fixes.

An explicit retry of an upload that has not succeeded is also available:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-raku \
    --ref v0.0.2 \
    --field mode=publish
```

[publishing]: https://docs.raku.org/language/distributions/uploading
[fez]: https://github.com/tony-o/raku-fez
