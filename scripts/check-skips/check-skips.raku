use v6.d;

#| Copy TAP from standard input to standard output and fail if any test line
#| carries a `# SKIP` directive, in any case.
sub MAIN() {
    my @skipped;
    for $*IN.lines -> $line {
        say $line;
        @skipped.push($line) if $line ~~ / :i [ ^ | \s ] '#' \s* skip [ \s | $ ] /;
    }
    exit 0 unless @skipped;
    note 'Required live contracts must not skip tests:';
    note "  $_" for @skipped;
    exit 1;
}
