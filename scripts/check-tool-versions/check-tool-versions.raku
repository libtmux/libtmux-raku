use v6.d;

#| Check that `.tool-versions` declares exactly one `raku VERSION` entry with a
#| Rakudo release number, and that the running compiler is that release.
sub MAIN(Str:D :$file = $?FILE.IO.parent(3).add('.tool-versions').Str,
         Str:D :$compiler = $*RAKU.compiler.version.Str) {
    my @entries = $file.IO.lines.map(*.words.List).grep({ .elems && .[0] eq 'raku' });
    die "$file must declare exactly one raku version" unless @entries == 1;
    die "$file: the raku entry must be 'raku VERSION'" unless @entries[0].elems == 2;
    my $version = @entries[0][1];
    die "$file: the raku version must be a Rakudo release such as 2026.09, not $version"
        unless $version ~~ /^ \d ** 4 '.' \d ** 2 [ '.' \d+ ]? $/;
    die "The running compiler is $compiler, not the declared $version"
        unless $compiler eq $version;
    say $version;
}
