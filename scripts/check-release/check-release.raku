use v6.d;
use JSON::Fast;

#| Check a release tag against META6.json and print the package version.
#| An empty tag stands for the tag of the metadata's own version.
#| `--github-output` prints `version=X.Y.Z` for $GITHUB_OUTPUT.
sub MAIN(Str:D $tag, Str:D :$meta = 'META6.json', Str:D :$dist = '',
         Str:D :$commit = 'HEAD', Bool :$github-output = False) {
    my %metadata = from-json($meta.IO.slurp);
    die 'Release distribution must be LibTmux' unless %metadata<name> eq 'LibTmux';
    my $version = %metadata<version>;
    die 'Release version must have three numeric components'
        unless $version ~~ Str && $version ~~ /^ \d+ '.' \d+ '.' \d+ $/;
    die "Tag must match META6.json version: expected v$version"
        unless ($tag || "v$version") eq "v$version";
    die 'Release authority must be zef:libtmux'
        unless %metadata<auth> eq 'zef:libtmux';
    if $dist.chars {
        my $directory = $dist.IO.absolute.IO;
        my $name = "LibTmux-$version.tar.gz";
        my $archive = $directory.add($name);
        die 'Retained release archive is missing' unless $archive.f;
        my $checksum = capture('sha256sum', $name, :cwd($directory));
        die 'Archive checksum does not match SHA256SUMS'
            unless $directory.add('SHA256SUMS').slurp eq $checksum;
        my $expected = capture('git', 'rev-parse', $commit ~ '^{commit}').trim;
        my $unpack = run 'gzip', '-dc', $archive.Str, :out;
        my $identity = run 'git', 'get-tar-commit-id', :in($unpack.out), :out;
        my $actual = $identity.out.slurp(:close).trim;
        die 'Archive commit does not match the release commit'
            if $unpack.exitcode || $identity.exitcode || $actual ne $expected;
        my %packed = from-json(capture('tar', '-xOf', $archive.Str, 'META6.json'));
        die 'Archive metadata does not match META6.json' unless %packed eqv %metadata;
    }
    say $github-output ?? "version=$version" !! $version;
}

sub capture(*@command, :$cwd = $*CWD --> Str:D) {
    my $process = run |@command, :$cwd, :out;
    my $output = $process.out.slurp(:close);
    die "Release check failed: {@command[0]}" if $process.exitcode;
    $output
}
