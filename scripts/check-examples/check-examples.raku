use v6.d;
use lib $?FILE.IO.parent(2).add('lib');
use Scripts::Filesystem;
use Scripts::Processes;

my $root = $?FILE.IO.parent(3).absolute.IO;
my $quickstart = $root.add('examples/quickstart.raku');

sub check-snippets(Str:D $document, Str:D $marker, Str:D $opening,
                   Str:D $code-start, Str:D $closing --> Int:D) {
    my $source = $root.add($document).slurp;
    my @sections = $source.split($marker);
    die "$document must mark every Raku example with its canonical source"
        unless @sections.elems > 1
            && @sections.elems - 1 == $source.split($code-start).elems - 1;
    for @sections.skip(1) -> $section {
        my @header = $section.split($opening, 2);
        die "Malformed example marker in $document" unless @header.elems == 2;
        my $path = @header[0];
        die "Invalid example path in $document"
            unless $path ~~ /^ 'examples/' <[A..Za..z0..9\-]>+ '.raku' $/;
        my @block = @header[1].split($closing, 2);
        die "$document snippet differs from $path"
            unless @block.elems == 2 && $root.add($path).f
                && @block[0] eq $root.add($path).slurp;
    }
    @sections.elems - 1
}

#| Check that the README and the native guide quote the examples they name,
#| then, unless `--check-source` is given, run every example against the tmux
#| named by LIBTMUX_TEST_TMUX. An example that leaves a socket directory or a
#| process behind fails.
sub MAIN(Bool :$check-source = False) {
    my $snippets = check-snippets('README.md', '<!-- runs: ',
        " -->\n\n```raku\n", "```raku\n", "```\n")
        + check-snippets('lib/LibTmux.rakumod', '=comment runs: ',
            "\n\n=begin code :lang<raku>\n", "=begin code :lang<raku>\n", "=end code\n");
    say "PASS: $snippets complete documentation examples match their source";
    return if $check-source;

    my %expected =
        quickstart => ["editor: 2 panes\n"],
        query-panes => ["Wide pane: editor\n"
            ~ "Other panes: logs, tests\n"],
        floating-panes => ['floating', 'tiled'].map({ "Status pane: $_\nstatus\n" }).Array,
        resize-panes => ["window: 100x20\neditor: 30 columns\npanes: 1\n"],
        watch-output => ["hello from Raku\nScreen capture confirmed\n"],
        explain-query => ["width: fully pushed = True\n"
            ~ "width and title: fully pushed = False\n"
            ~ "tmux filter: #\{e|>=:#\{pane_width},60}\n"
            ~ "Matches: editor\n"
            ~ "require: refused, title stays local\n"],
        batch-recovery => ["set-option: Complete (scope: command)\n"
            ~ "invalid-command: Failed (scope: command)\n"
            ~ "skipped-option: Skipped (scope: command)\n"
            ~ "Recovery: removed the first effect explicitly\n"
            ~ "Stopped the tmux server and removed its socket\n"];

    my $binary = %*ENV<LIBTMUX_TEST_TMUX> // die 'LIBTMUX_TEST_TMUX must name the qualified endpoint binary';
    die 'LIBTMUX_TEST_TMUX must be an executable absolute path'
        unless $binary.IO.is-absolute && $binary.IO.f && $binary.IO.x;
    my @examples = $root.add('examples').dir.grep(*.extension eq 'raku').sort;
    die 'No executable examples were found' unless @examples;

    my $temporary = private-directory('libtmux-raku-examples');
    LEAVE remove-tree($temporary) if $temporary.defined && $temporary.e;
    my $link = $temporary.add('tmux');
    symlink($binary, $link.Str) or die 'Could not select the example tmux executable';
    my %environment = %*ENV;
    %environment<PATH> = $temporary.Str ~ ':' ~ (%environment<PATH> // '/usr/bin:/bin');
    %environment<TMPDIR> = $temporary.Str;
    %environment<TMUX TMUX_PANE LIBTMUX_SOCKET LIBTMUX_SOCKET_PATH RAKULIB PERL6LIB>:delete;

    for @examples -> $example {
        my @arguments;
        @arguments.push("--tmux=$binary") unless $example eq $quickstart;
        my $process = run $*EXECUTABLE.Str, '-I.', $example.Str, |@arguments,
            :cwd($root), :env(%environment), :out;
        my $output = $process.out.slurp(:close);
        die "Example failed: {$example.basename}" unless $process.exitcode == 0;
        my $name = $example.basename.subst(/ '.raku' $/, '');
        die "Example output did not match the documented result: $name"
            if (%expected{$name}:exists) && !%expected{$name}.first(* eq $output).defined;
        die "Example left an owned socket directory: $name"
            if $temporary.dir.first(*.basename.starts-with('libtmux-owned-')).defined;
        my @leftover = processes-naming($temporary.Str);
        die "Example left a process running: $name (pid {@leftover.join(', ')})" if @leftover;
        print $output;
    }
    say "PASS: {@examples.elems} executable examples";
}
