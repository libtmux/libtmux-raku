use v6.d;
use JSON::Fast;

sub MAIN(Str:D $tag, Str:D :$meta = 'META6.json') {
    my %metadata = from-json($meta.IO.slurp);
    die 'Release distribution must be LibTmux' unless %metadata<name> eq 'LibTmux';
    my $version = %metadata<version>;
    die 'Release version must have three numeric components'
        unless $version ~~ Str && $version ~~ /^ \d+ '.' \d+ '.' \d+ $/;
    die "Tag must match META6.json version: expected v$version"
        unless $tag eq "v$version";
    die 'Release authority must be zef:libtmux'
        unless %metadata<auth> eq 'zef:libtmux';
    say $version;
}
