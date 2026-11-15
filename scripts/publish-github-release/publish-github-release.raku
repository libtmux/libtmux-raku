use v6.d;
use JSON::Fast;

# Create or complete the GitHub release for a tag from the tested archive and
# its checksums, then publish it. Safe to rerun: existing assets with the same
# digest are kept, a different digest is refused. Run by release.yml with
# GH_TOKEN set.
#
#   raku scripts/publish-github-release/publish-github-release.raku \
#       DIRECTORY vX.Y.Z OWNER/REPOSITORY

sub refuse(Str:D $message --> Nil) {
    note $message;
    exit 1;
}

sub gh(*@arguments --> Nil) {
    my $process = run 'gh', |@arguments;
    refuse "gh {@arguments[0..1].join(' ')} failed" if $process.exitcode;
}

sub digest(IO::Path:D $file --> Str:D) {
    my $process = run 'sha256sum', $file.Str, :out;
    my $line = $process.out.slurp(:close);
    refuse "sha256sum failed for {$file.basename}" if $process.exitcode;
    "sha256:{$line.words[0]}"
}

sub MAIN(Str:D $directory, Str:D $tag, Str:D $repository) {
    my $base = $directory.IO.resolve;
    refuse "Tag must look like vX.Y.Z: $tag" unless $tag ~~ /^ v \d+ '.' \d+ '.' \d+ $/;
    my @files = "LibTmux-{$tag.substr(1)}.tar.gz", 'SHA256SUMS';
    for @files -> $file {
        refuse "Missing release file: {$base.add($file)}" unless $base.add($file).f;
    }

    my $listing = run 'gh', 'api', '--paginate', '--slurp', "repos/$repository/releases", :out;
    my $json = $listing.out.slurp(:close);
    refuse 'gh api failed' if $listing.exitcode;
    my @matches = from-json($json).map({ .Slip }).grep(*<tag_name> eq $tag);
    refuse 'Duplicate release tag' if @matches > 1;
    my $exists = @matches == 1;
    my %release = $exists ?? @matches[0] !! %();

    # Check every existing asset before changing even an incomplete release.
    my %names;
    for @files -> $file {
        my @assets = (%release<assets> // []).grep(*<name> eq $file);
        refuse 'Duplicate release asset' if @assets > 1;
        next unless @assets;
        %names{$file} = True;
        my $existing = @assets[0]<digest> // 'unknown';
        refuse "Refusing to replace release asset: $file" if $existing ne digest($base.add($file));
    }

    unless $exists {
        gh 'release', 'create', $tag, '--repo', $repository, '--verify-tag',
            '--draft', '--title', $tag, '--generate-notes';
        %release = draft => True;
    }
    for @files -> $file {
        gh 'release', 'upload', $tag, $base.add($file).Str, '--repo', $repository
            unless %names{$file};
    }
    gh 'release', 'edit', $tag, '--repo', $repository, '--draft=false'
        if %release<draft> === True;
}
