use v6.d;

# Build the release archive of a commit and its checksums: `LibTmux-VERSION.tar.gz`
# and `SHA256SUMS`, in DIRECTORY. `check-release --dist` then verifies them. Run
# by ci.yml on a fresh release; a retried run restores the retained pair
# instead (see scripts/release-retry).
#
#   raku scripts/build-archive/build-archive.raku DIRECTORY X.Y.Z

sub refuse(Str:D $message --> Nil) {
    note $message;
    exit 1;
}

sub capture(*@command, :$cwd = $*CWD --> Str:D) {
    my $process = run |@command, :$cwd, :out;
    my $output = $process.out.slurp(:close);
    refuse "{@command[0..1].join(' ')} failed" if $process.exitcode;
    $output
}

#| `--source` is the repository to archive and `--commit` the commit to pack.
sub MAIN(Str:D $directory, Str:D $version, Str:D :$source = $?FILE.IO.parent(3).Str,
         Str:D :$commit = 'HEAD') {
    refuse "Version must have three numeric components: $version"
        unless $version ~~ /^ \d+ '.' \d+ '.' \d+ $/;
    my $target = $directory.IO.absolute.IO;
    my $name = "LibTmux-$version.tar.gz";
    refuse "$target already holds $name or SHA256SUMS"
        if $target.add($name).e || $target.add('SHA256SUMS').e;
    $target.mkdir;
    capture 'git', '-C', $source, 'archive', '--format=tar.gz',
        "--output={$target.add($name)}", $commit;
    $target.add('SHA256SUMS').spurt(capture('sha256sum', $name, :cwd($target)));
}
