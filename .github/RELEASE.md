# Releasing LibTmux

The first release is `0.0.1`, published as
`LibTmux:ver<0.0.1>:auth<zef:libtmux>`. Pushing `v0.0.1` starts the
[Release workflow](workflows/release.yml): CI validates the tagged commit,
tests its archive, retains that archive, uploads it with Fez, and checks a
fresh registry installation.

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

Set the version in [META6.json](../META6.json), retain `zef:libtmux`, and
prepare the changes in a PR. Release tags use `v` followed by the exact
three-component numeric package version, such as `v0.0.1`.

Run the checks in [CONTRIBUTING.md](CONTRIBUTING.md#checks), including the
release identity contracts:

```console
$ /usr/bin/time -p mise exec -- raku xt/release.rakutest
```

CI builds an archive from its checked-out commit and installs that exact
archive outside the checkout. Required quality and tmux jobs must pass.
Changes to the Release workflow also run a rehearsal on the PR, with the
publishing and registry jobs skipped.

After this workflow is merged, prepare and retain an archive without
publishing or requesting a key:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-raku \
    --ref master \
    --field mode=prepare
```

Inspect the resulting run and download its `release-candidate` artifact.
It contains `LibTmux-0.0.1.tar.gz` and `SHA256SUMS` for the initial release.
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
$ mise exec -- raku tools/check-release.raku v0.0.1
```

Create an annotated tag:

```console
$ git tag -a v0.0.1 -m 'Release 0.0.1'
```

Push only that tag to begin publication:

```console
$ git push origin refs/tags/v0.0.1
```

The workflow reruns CI for the tagged commit. It uploads the retained,
checksum-verified archive only after those checks pass. A branch or PR
cannot enter the publishing job. Releases run serially and do not cancel
an active upload.

The `Verify registry installation` job refreshes the package index and
installs the exact version and authority into a temporary repository. A
fresh process outside the checkout loads every provided module, checks
the packaged catalogue and API contracts, and verifies installed identity.
Treat publication as verified only after this job passes.

## Complete a manual upload or recover a failed run

If CI passed but the upload failed before publication, correct the Fez
account or `FEZ_KEY`, then use **Re-run failed jobs** on that run. This
reuses its retained archive. Avoid rerunning all jobs: an existing artifact
name stops an attempted replacement of that run's archive.

If you need to publish manually, download `release-candidate` from the
tagged run, extract it into `dist/release`, and check the files:

```console
$ cd dist/release && sha256sum --check SHA256SUMS
```

From that directory, use your logged-in Fez account to upload the retained
initial-release archive:

```console
$ mise exec -- fez upload --file=LibTmux-0.0.1.tar.gz
```

Then request registry verification for that tag, without another upload:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-raku \
    --ref v0.0.1 \
    --field mode=verify
```

If an upload succeeded but indexing is still pending, rerun only the failed
registry job once the version is available. The workflow does not wait in
a polling loop. Fez accepts one upload per distribution version; do not
repeat an upload that succeeded, move its tag, or rebuild its archive to
repair a partial release. Preserve the files, check registry state, and
use a new version for code or packaging fixes.

An explicit retry of an upload that has not succeeded is also available:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-raku \
    --ref v0.0.1 \
    --field mode=publish
```

[publishing]: https://docs.raku.org/language/distributions/uploading
[fez]: https://github.com/tony-o/raku-fez
