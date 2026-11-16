use v6.d;

#| Compile every `.raku` and `.rakumod` file under the given directories with
#| `raku -c`, so a syntax or import error fails here and not when the file
#| first runs. Compilation runs compile-time code; it is not a linter.
sub MAIN(*@directories, Str:D :$root = $?FILE.IO.parent(3).Str) {
    die 'Name at least one directory' unless @directories;
    my $base = $root.IO.absolute.IO;
    my @files = @directories.map(-> $directory {
        my $path = $base.add($directory);
        die "$directory is not a directory under $base" unless $path.d;
        find-sources($path).Slip
    }).sort;
    die 'No Raku source files were found' unless @files;
    my @failed;
    for @files -> $file {
        my $process = run $*EXECUTABLE.Str, '-I.', '-It/lib', '-c', $file.Str,
            :cwd($base), :out, :err;
        $process.out.slurp(:close);
        my $err = $process.err.slurp(:close);
        next unless $process.exitcode;
        note "FAIL: {$file.relative($base)}";
        note $err;
        @failed.push($file);
    }
    exit 1 if @failed;
    say "PASS: {@files.elems} files compile";
}

sub find-sources(IO::Path:D $directory --> Seq:D) {
    gather for $directory.dir.sort -> $entry {
        if $entry.d && !$entry.l {
            take $_ for find-sources($entry);
        } elsif $entry.f && $entry.extension eq 'raku'|'rakumod' {
            take $entry;
        }
    }
}
