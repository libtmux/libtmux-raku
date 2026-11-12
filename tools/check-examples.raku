use v6.d;
use NativeCall;

sub mkdtemp(CArray[uint8] --> Pointer) is native { * }

my $root = $?FILE.IO.parent.parent.absolute.IO;
my $quickstart = $root.add('examples/quickstart.raku');
my @readme = $root.add('README.md').slurp.split("```raku\n");
die 'README must contain one marked Raku quickstart block'
    unless @readme.elems == 2
        && @readme[0].ends-with("<!-- runs: examples/quickstart.raku -->\n\n");
my @block = @readme[1].split("```\n", 2);
die 'README quickstart must match the complete examples/quickstart.raku file'
    unless @block.elems == 2 && @block[0] eq $quickstart.slurp;

my $binary = %*ENV<LIBTMUX_TEST_TMUX> // die 'LIBTMUX_TEST_TMUX must name the qualified endpoint binary';
die 'LIBTMUX_TEST_TMUX must be an executable absolute path'
    unless $binary.IO.is-absolute && $binary.IO.f && $binary.IO.x;
my @examples = $root.add('examples').dir.grep(*.extension eq 'raku').sort;
die 'No executable examples were found' unless @examples;

my $template = $*TMPDIR.add('libtmux-raku-examples-XXXXXX').Str.encode;
my $bytes = CArray[uint8].new(|$template.list, 0);
die 'Could not create isolated example executable directory' unless mkdtemp($bytes);
my $temporary = Blob.new((^$template.elems).map({ $bytes[$_] })).decode.IO;
my $link = $temporary.add('tmux');
LEAVE {
    $link.unlink if $link.defined && $link.l;
    $temporary.rmdir if $temporary.defined && $temporary.d;
}
symlink($binary, $link.Str) or die 'Could not select the example tmux executable';
my %environment = %*ENV;
%environment<PATH> = $temporary.Str ~ ':' ~ (%environment<PATH> // '/usr/bin:/bin');
%environment<TMUX TMUX_PANE>:delete;

for @examples -> $example {
    my @arguments;
    @arguments.push("--tmux=$binary") unless $example eq $quickstart;
    my $process = run $*EXECUTABLE.Str, '-I.', $example.Str, |@arguments,
        :cwd($root), :env(%environment), :out;
    my $output = $process.out.slurp(:close);
    die "Example failed: {$example.basename}" unless $process.exitcode == 0;
    die 'Quickstart output did not match the documented result'
        if $example eq $quickstart && $output ne "Starlight telescope: 2 panes\n";
    print $output;
}
say "PASS: {@examples.elems} executable examples";
