# export-docs

Extracts the public API from the library's source with the Rakudo compiler's
RakuAST and RakuDoc, and writes it as JSON for the documentation site. The
output records each declaration, its documentation, the files and revision it
came from, and the declarations that lack documentation. Parsing trusted
source can run compile-time code, so run it only on this repository.

`ci.yml` runs it and requires `missingDocumentation` to be empty:

```console
$ raku -I. scripts/export-docs/export-docs.raku --output=docs/_build/api.json
```

`docs/documentation.rakudoc` describes the extraction. Test it against fixture
source:

```console
$ raku -I. scripts/export-docs/tests/export-docs.rakutest
```
