use v6.d;

use JSON::Fast;
use LibTmux::Catalogue;

#| Print the supported tmux endpoints as the JSON a GitHub Actions matrix
#| reads. `--github-output` prints `value=JSON` for $GITHUB_OUTPUT.
sub MAIN(Bool :$github-output = False) {
    my @include = support-policy().endpoints.map: -> $release {
        %(tmux => $release.version, commit => $release.commit)
    };
    my $matrix = to-json(%(include => @include), :!pretty);
    say $github-output ?? "value=$matrix" !! $matrix;
}
