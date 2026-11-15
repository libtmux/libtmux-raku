use v6.d;
unit module Test::LibTmux::Wrapper;

use NativeCall;

sub execv(Str, CArray[Str] --> int32) is native { * }

#| Replace this process with `$program`, as exec(3) does. The program keeps the
#| PID, the open descriptors and the controlling terminal of the caller.
sub exec-program(Str:D $program, *@arguments --> Nil) is export {
    execv($program, CArray[Str].new($program, |@arguments, Str));
    note "exec failed: $program";
    exit 127;
}

#| Write an executable Raku script that stands in for a tmux binary. `*%values`
#| become `my $name = value;` lines before `$body`, so the body names binary
#| and file paths without string splicing. The script imports `exec-program`
#| and the Fixture helpers.
sub write-wrapper(IO::Path:D $path, Str:D $body, *%values --> IO::Path:D) is export {
    my $library = $?FILE.IO.absolute.IO.parent(3);
    my $variables = %values.sort.map({ "my \${.key} = {.value.raku};\n" }).join;
    $path.spurt("#!/usr/bin/env raku\nuse lib {$library.Str.raku};\n"
        ~ "use Test::LibTmux::Fixture;\nuse Test::LibTmux::Wrapper;\n$variables$body");
    $path.chmod(0o700);
    $path
}
