use v6.d;
use JSON::Fast;
use NativeCall;

sub mkdtemp(CArray[uint8] --> Pointer) is native { * }

sub MAIN(Str:D :$archive = '', Bool :$registry = False) {
    die 'Choose an archive or the registry' if $archive.chars && $registry;
    my $source = $?FILE.IO.parent.parent.absolute.IO;
    my $template = $*TMPDIR.add('libtmux-raku-install-XXXXXX').Str.encode;
    my $bytes = CArray[uint8].new(|$template.list, 0);
    die 'could not create isolated installation directory' unless mkdtemp($bytes);
    my $temporary = Blob.new((^$template.elems).map({ $bytes[$_] })).decode.IO;

    sub remove-tree(IO::Path:D $path) {
        if $path.d && !$path.l {
            remove-tree($_) for $path.dir;
            $path.rmdir;
        } else {
            $path.unlink;
        }
    }
    LEAVE remove-tree($temporary) if $temporary.e;

    my $started = now;
    my $installed = $temporary.add('installed');
    my %environment = %*ENV;
    %environment<TMPDIR> = $temporary.Str;
    %environment<ZEF_CONFIG_TEMPDIR> = $temporary.add('zef').Str;
    my $metadata = from-json($source.add('META6.json').slurp);
    my $package = $archive.chars ?? $archive.IO.absolute.IO !! $temporary.add('LibTmux.tar.gz');
    if !$registry && !$archive.chars {
        my $listing = run 'git', '-C', $source.Str, 'ls-files', '-z',
            '--cached', '--others', '--exclude-standard', :out;
        my @paths = $listing.out.slurp(:close).split("\0").grep(*.chars).unique.sort;
        die 'Could not enumerate archive inputs' unless $listing.exitcode == 0 && @paths;
        die 'Archive input escapes its source root'
            if @paths.first({ .starts-with('/') || .split('/').first(* eq '..').defined }).defined;
        my $manifest = $temporary.add('archive-files');
        $manifest.spurt(@paths.join("\0") ~ "\0");
        my $packed = run 'tar', '-C', $source.Str, '-czf', $package.Str,
            '--null', '--files-from', $manifest.Str;
        die 'Could not create the source archive' unless $packed.exitcode == 0;
        my $contents = run 'tar', '-tzf', $package.Str, :out;
        my @contents = $contents.out.slurp(:close).lines.sort;
        die 'Archive contents differ from the declared working-tree inventory'
            unless $contents.exitcode == 0 && @contents.List eqv @paths.List;
    }
    if !$registry {
        die 'Package archive does not exist' unless $package.f;
        my $contents = run 'tar', '-xOf', $package.Str, 'META6.json', :out;
        my $packed-meta = $contents.out.slurp(:close);
        die 'Archive metadata differs from the checkout'
            unless $contents.exitcode == 0 && from-json($packed-meta) eqv $metadata;
    }
    my $distribution = $registry
        ?? "{$metadata<name>}:ver<{$metadata<version>}>:auth<{$metadata<auth>}>"
        !! $package.Str;
    my $installation = run 'zef', |($registry ?? ['--update'] !! []), 'install', $distribution,
        "--install-to=inst#{$installed}", :env(%environment);
    die 'isolated package installation failed' unless $installation.exitcode == 0;

    my $consumer = $temporary.add('consumer');
    $consumer.mkdir;
    my @loads;
    for $metadata<provides>.keys.sort -> $module {
        die 'invalid provided module name' unless $module ~~ /^ <[A..Za..z]> <[A..Za..z0..9\-:]>* $/;
        @loads.push("need $module;");
    }
    my $code = q:to/CONSUMER/;
    use v6.d;
    use LibTmux:auth<zef:libtmux>;
    use JSON::Fast;
    die 'identifier contract failed' unless '%7' ~~ PaneId;
    die 'typed failure contract failed'
        unless X::LibTmux::Cardinality.new(:count(2)) ~~ Exception;
    die 'public owner import failed' unless Server === LibTmux::Server;
    my $server = Server.new(:binary('/nonexistent/installed-lib-test'));
    LEAVE $server.close;
    die 'constructing a borrowed facade performed startup' if $server.owned;
    my $filter = Filter.compile(%(active => True), :entity<pane>);
    die 'installed portable filter failed' unless Filter.from-json($filter.to-json).entity eq 'pane';
    my $selection = PaneSelection.new(:items([]));
    die 'empty selection lost its schema' unless $selection.entity eq 'pane' && $selection.elems == 0;
    my $unit = $*REPO.resolve(CompUnit::DependencySpecification.new(
        :short-name<LibTmux>, :auth<zef:libtmux>));
    die 'consumer loaded a different installed library'
        unless $unit.repo.path-spec eq @*ARGS[0];
    die 'installed release identity differs from the checkout'
        unless $unit.distribution.meta<version> eq from-json(@*ARGS[2])<version>
            && $unit.distribution.meta<auth> eq from-json(@*ARGS[2])<auth>;
    die 'installed runtime dependency inventory changed'
        unless $unit.distribution.meta<depends>.List eqv from-json(@*ARGS[1]).List;
    CONSUMER
    $code ~= @loads.join("\n") ~ "\n";
    if $metadata<provides>{'LibTmux::Catalogue'}:exists {
        $code ~= q:to/CATALOGUE/;
    use LibTmux::Catalogue;
    die 'installed catalogue resource failed' unless catalogue().field('pane', 'id').defined;
    die 'installed support policy failed' unless support-policy().endpoints.elems;
    CATALOGUE
    }
    $code ~= "say 'installed consumer PASS';\n";
    $consumer.add('main.raku').spurt($code);

    %environment<RAKULIB PERL6LIB>:delete;
    my $result = run $*EXECUTABLE.Str, "-Iinst#{$installed}", 'main.raku', "inst#{$installed}",
        to-json($metadata<depends>, :!pretty), to-json($metadata, :!pretty),
        :cwd($consumer), :env(%environment);
    die 'installed consumer failed' unless $result.exitcode == 0;
    say "whole command: {(now - $started).round(0.001)} s";
}
