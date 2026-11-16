# Shared script modules

Helpers more than one support script or script test uses. A file here is not
part of the distribution: `META6.json` does not list it and `zef` does not
install it.

`Scripts::Filesystem` exports two subs:

- `private-directory($prefix)` creates an empty directory under `$*TMPDIR` that
  only the caller can enter, through `mkdtemp(3)`.
- `remove-tree($path)` deletes a path and everything under it without following
  a symbolic link.

A script or test loads them relative to its own path, so it runs from any
directory:

```raku
use lib $?FILE.IO.parent(2).add('lib');
use Scripts::Filesystem;
```

Test them:

```console
$ raku scripts/lib/tests/filesystem.rakutest
```
