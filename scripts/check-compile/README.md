# check-compile

Compiles every `.raku` and `.rakumod` file under the directories you name with
`raku -c`, so a syntax or import error fails here and not when the file first
runs. Compilation runs compile-time code and is not a linter or a type checker;
it is the type check Raku has.

`ci.yml` runs it on the examples, the support scripts and the test helpers. The
library has its own step, which compiles the public import:

```console
$ raku scripts/check-compile/check-compile.raku examples scripts t/lib
```

Each file compiles with `-I.` and `-It/lib`, as the tests that use them are run.

Test a passing tree, a file that does not compile and a missing directory:

```console
$ raku scripts/check-compile/tests/check-compile.rakutest
```
