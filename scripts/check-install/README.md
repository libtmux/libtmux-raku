# check-install

Installs LibTmux into an empty directory with `zef` and loads it from a
separate consumer program, so a missing file or a wrong dependency fails here
and not on a user's machine. The consumer also checks that the installed
version, authority and dependencies match `META6.json`.

By default it packs the working tree. `--archive` installs a release archive,
and `--registry` installs the version `META6.json` names from the Zef registry:

```console
$ raku scripts/check-install/check-install.raku --archive=LibTmux-0.0.1.tar.gz
```

`ci.yml` runs it on the tested archive and `release.yml` runs it with
`--registry` after the upload. It needs `zef`, `git` and `tar` on `PATH`.
