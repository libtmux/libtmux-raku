use v6.d;
use JSON::Fast;

# Decide, on a rerun of a release workflow, whether to restore the retained
# `release-candidate` artifact (`archive`) or whether a Fez upload already ran
# (`upload`). Writes `restored=` and `needed=` to $GITHUB_OUTPUT. Run by ci.yml
# and release.yml with GH_TOKEN set.
#
#   raku scripts/release-retry/release-retry.raku archive DIRECTORY
#   raku scripts/release-retry/release-retry.raku upload

sub refuse(Str:D $message --> Nil) {
    note $message;
    exit 1;
}

sub environment(Str:D $name --> Str:D) {
    %*ENV{$name} // refuse "$name is not set"
}

sub output(Str:D $line --> Nil) {
    environment('GITHUB_OUTPUT').IO.spurt("$line\n", :append);
}

#| Every `$key` item of every page of a paginated `gh api` response.
sub listed(Str:D $url, Str:D $key --> List:D) {
    my $process = run 'gh', 'api', '--paginate', '--slurp', $url, :out;
    my $json = $process.out.slurp(:close);
    refuse 'gh api failed' if $process.exitcode;
    from-json($json).map({
        .{$key} ~~ List ?? .{$key}.Slip !! refuse "gh api: no $key list in a response page"
    }).List
}

sub MAIN(Str:D $mode, Str $directory = '') {
    unless $mode eq 'archive' | 'upload' {
        note 'usage: release-retry.raku archive DIRECTORY | upload';
        exit 64;
    }
    if environment('GITHUB_RUN_ATTEMPT').Int == 1 {
        output('needed=true') if $mode eq 'upload';
        exit 0;
    }
    my $repository = environment('GITHUB_REPOSITORY');
    my $run = environment('GITHUB_RUN_ID');

    if $mode eq 'archive' {
        my @retained = listed("repos/$repository/actions/runs/$run/artifacts?per_page=100", 'artifacts')
            .grep({ .<name> eq 'release-candidate' && .<expired> === False });
        if @retained == 1 {
            my $download = run 'gh', 'run', 'download', $run, '--repo', $repository,
                '--name', 'release-candidate', '--dir', $directory;
            refuse 'gh run download failed' if $download.exitcode;
            output('restored=true');
            exit 0;
        }
        refuse 'More than one retained release archive exists; inspect the run before recovery.'
            if @retained;
    }

    my @uploads = listed("repos/$repository/actions/runs/$run/jobs?filter=all&per_page=100", 'jobs')
        .map({ (.<steps> // []).Slip })
        .grep({ .<name> eq 'Upload the tested archive'
            && .<conclusion>.defined && .<conclusion> ne 'skipped' });
    if $mode eq 'archive' {
        refuse 'The original archive is unavailable after an upload attempt. Recover the original files; do not rebuild this release.'
            if @uploads;
        exit 0;
    }
    if @uploads.first(*<conclusion> eq 'success') {
        say 'An earlier attempt completed this upload; continuing with registry verification.';
        output('needed=false');
    } elsif @uploads {
        refuse 'A previous upload was interrupted. Check Fez state and use verify mode if accepted; do not upload again blindly.';
    } else {
        output('needed=true');
    }
}

