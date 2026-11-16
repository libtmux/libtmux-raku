# fez-upload

Uploads the tested release archive to the zef registry. `fez` reads its account
key from a config file, so the script writes one from `FEZ_KEY` into a private
directory, runs `fez --unattended upload`, and removes the config afterwards,
also when the upload fails. It exits with the status of `fez` and never prints
the key.

`release.yml` runs it in the `fez` environment, which holds `FEZ_KEY`, after
installing the pinned `fez`. [RELEASE.md](../../.github/RELEASE.md) describes
the account setup and where the upload sits in a release:

```console
$ FEZ_KEY=... raku scripts/fez-upload/fez-upload.raku dist/LibTmux-0.0.1.tar.gz
```

The script loads `Fez::Util::Config` and `Fez::Util::Json` when it runs, so
it compiles without `fez` installed.

Test it against stand-ins for `fez` and its two modules, with no network and no
key:

```console
$ raku scripts/fez-upload/tests/fez-upload.rakutest
```
