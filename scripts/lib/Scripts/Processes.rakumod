use v6.d;

# Process helpers shared by the support scripts and their tests.
unit module Scripts::Processes;

#| Return the IDs of the live processes whose command line contains `$needle`.
#| It reads `/proc`, so it needs Linux, which the library requires too.
sub processes-naming(Str:D $needle --> List:D) is export {
    '/proc'.IO.dir.grep({ .basename ~~ /^ \d+ $/ }).map({
        my $command-line = try .add('cmdline').slurp(:bin);
        $command-line.defined && $command-line.decode('utf8-c8').contains($needle)
            ?? .basename.Int !! Empty
    }).sort.List
}
