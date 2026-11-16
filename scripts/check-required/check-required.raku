use v6.d;
use JSON::Fast;

# Fail the required-checks job unless every job the run declared succeeded:
# `prepare`, `quality`, `live`, and one job per tmux version in the matrix that
# `scripts/ci-matrix` printed. Run by ci.yml with GH_TOKEN set.
#
#   raku scripts/check-required/check-required.raku \
#       --prepare=RESULT --quality=RESULT --live=RESULT \
#       --matrix=JSON --repository=OWNER/REPOSITORY --run-id=ID

sub refuse(Str:D $message --> Nil) {
    note $message;
    exit 1;
}

#| The tmux versions in a matrix of one or two endpoints, each with a distinct
#| tmux version and a distinct 40-digit commit.
sub endpoint-versions(Str:D $json --> List:D) {
    my $matrix = from-json($json);
    refuse 'The matrix must be an object with only an include list'
        unless $matrix ~~ Hash && $matrix.keys.join(',') eq 'include';
    my $include = $matrix<include>;
    refuse 'The matrix must list one or two endpoints'
        unless $include ~~ List && $include.elems == 1|2;
    for $include.list -> $endpoint {
        refuse 'Every endpoint must hold only a commit and a tmux version'
            unless $endpoint ~~ Hash && $endpoint.keys.sort.join(',') eq 'commit,tmux';
        refuse "Invalid tmux version in the matrix: {$endpoint<tmux>.raku}"
            unless $endpoint<tmux> ~~ Str && $endpoint<tmux> ~~ /^ <[0..9]>+ '.' <[0..9]>+ <[a..z]>? $/;
        refuse "Invalid tmux commit in the matrix: {$endpoint<commit>.raku}"
            unless $endpoint<commit> ~~ Str && $endpoint<commit> ~~ /^ <[0..9a..f]> ** 40 $/;
    }
    refuse 'The matrix repeats a tmux version'
        unless $include.map(*<tmux>).unique.elems == $include.elems;
    refuse 'The matrix repeats a tmux commit'
        unless $include.map(*<commit>).unique.elems == $include.elems;
    $include.map(*<tmux>).List
}

#| Every job of the latest attempt of a run, across the pages `gh api` returns.
sub run-jobs(Str:D $repository, Str:D $run --> List:D) {
    my $process = run 'gh', 'api', '--paginate', '--slurp',
        "repos/$repository/actions/runs/$run/jobs?filter=latest&per_page=100", :out;
    my $json = $process.out.slurp(:close);
    refuse 'gh api failed' if $process.exitcode;
    from-json($json).map({ .<jobs>.Slip }).List
}

sub MAIN(Str:D :$prepare!, Str:D :$quality!, Str:D :$live!, Str:D :$matrix!,
         Str:D :$repository!, Str:D :$run-id!) {
    for :$prepare, :$quality, :$live -> $result {
        refuse "The {$result.key} job finished as {$result.value}, not success"
            unless $result.value eq 'success';
    }
    my @expected = 'Prepare', 'Quality', |endpoint-versions($matrix).map({ "tmux $_" });
    my @jobs = run-jobs($repository, $run-id);
    for @expected -> $name {
        # A reusable workflow prefixes its caller's name: "Verify / Prepare".
        my @found = @jobs.grep({ .<name>.split(' / ').tail eq $name });
        refuse "Expected one $name job, found {@found.elems}" unless @found == 1;
        refuse "The $name job is {@found[0]<status>}, not completed"
            unless @found[0]<status> eq 'completed';
        refuse "The $name job concluded {@found[0]<conclusion>}, not success"
            unless @found[0]<conclusion> eq 'success';
    }
    say "PASS: {@expected.join(', ')} succeeded";
}
