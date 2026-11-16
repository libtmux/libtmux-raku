# catalogue

Renders the field catalogue in `resources/catalogue.json` as the generated
accessors in `lib/LibTmux/Fields.rakumod`, as the reference guide in
`docs/reference/catalogue.rakudoc`, or as a JSON manifest on standard output.
`--check` fails when the file named by `--output` differs from what the
catalogue produces.

`ci.yml` runs both checks; run the same commands, without `--check`, after
editing the catalogue:

```console
$ raku -I. scripts/catalogue/catalogue.raku \
    --format=raku \
    --output=lib/LibTmux/Fields.rakumod
```

```console
$ raku -I. scripts/catalogue/catalogue.raku \
    --format=rakudoc \
    --output=docs/reference/catalogue.rakudoc
```
