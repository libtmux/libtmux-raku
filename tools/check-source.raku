use v6.d;
use JSON::Fast;

# Source hygiene and distribution inventory, not a formatter or static analyzer.
my $root = $?FILE.IO.parent.parent.absolute.IO;
my $listing = run 'git', '-C', $root.Str, 'ls-files', '-z',
    '--cached', '--others', '--exclude-standard', :out;
my @paths = $listing.out.slurp(:close).split("\0").grep(*.chars).unique.sort;
die 'Could not enumerate repository files' unless $listing.exitcode == 0;
my @errors;
my %text = set(<rakumod rakutest raku rakudoc md json yml yaml toml>);
for @paths -> $relative {
    my $path = $root.add($relative);
    next if $path.l || !$path.f || !(%text{$path.extension}:exists);
    my $text = $path.slurp;
    @errors.push("$relative: CR line endings") if $text.contains("\r");
    @errors.push("$relative: missing final LF") if $text.chars && !$text.ends-with("\n");
    for $text.lines.kv -> $index, $line {
        @errors.push("$relative:{$index + 1}: trailing whitespace") if $line ~~ / <[\t\ ]> $/;
    }
    if $path.extension eq 'rakumod' {
        @errors.push("$relative: missing stable language declaration")
            unless $text.starts-with("use v6.d;\n");
    }
    if $path.extension eq 'md' {
        for $text.match(/ \] '(' $<target>=[ <-[\s\) #]>+ ] [ '#' <-[\)]>* ]? ')' /, :g) -> $link {
            my $target = ~$link<target>;
            next if $target ~~ /^ <[A..Za..z]> <[A..Za..z0..9+\-.]>* ':' /;
            next if $target.starts-with('/') || $target.starts-with('#');
            @errors.push("$relative: missing relative link target $target")
                unless $path.parent.add($target).e;
        }
        @errors.push("$relative: shell examples must use console fences")
            if $text.lines.first({ $_ eq any('```sh', '```bash', '```shell') }).defined;
    }
}

my $meta = from-json($root.add('META6.json').slurp);
my @modules = @paths.grep({ .starts-with('lib/') && .ends-with('.rakumod') }).sort;
my @provided = $meta<provides>.values.sort;
@errors.push('META6.json provides does not match installed source inventory')
    unless @modules.List eqv @provided.List;
my @resources = @paths.grep(*.starts-with('resources/')).map(*.substr(10)).sort;
@errors.push('META6.json resources does not match runtime resource inventory')
    unless @resources.List eqv $meta<resources>.sort.List;
for <CONTRIBUTING.md WRITING.md> -> $guide {
    @errors.push("$guide belongs under .github") if $root.add($guide).e;
    @errors.push("Missing .github/$guide") unless $root.add('.github').add($guide).f;
}
@errors.push('CLAUDE.md must remain a relative AGENTS.md symlink')
    unless $root.add('CLAUDE.md').l && $root.add('CLAUDE.md').resolve eq $root.add('AGENTS.md');
die @errors.join("\n") if @errors;
say "PASS: source hygiene, relative file links and {@modules.elems} provided modules";
