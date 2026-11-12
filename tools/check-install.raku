use v6.d;

my $source = $?FILE.IO.parent.parent.absolute.IO;
my $temporary = $*TMPDIR.add("libtmux-raku-install-{$*PID}-{1000000000.rand.Int}");
$temporary.mkdir;
$temporary.chmod(0o700);

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
my $installation = run 'zef', 'install', $source.Str,
    "--install-to=inst#{$installed}";
die 'isolated package installation failed' unless $installation.exitcode == 0;

my $consumer = $temporary.add('consumer');
$consumer.mkdir;
$consumer.add('main.raku').spurt(q:to/CONSUMER/);
use v6.d;
use LibTmux:auth<github:libtmux>;
use LibTmux::Types;
use LibTmux::Exceptions;
die 'identifier contract failed' unless '%7' ~~ PaneId;
die 'typed failure contract failed'
    unless X::LibTmux::Cardinality.new(:count(2)) ~~ Exception;
say 'installed consumer PASS';
CONSUMER

my %environment = %*ENV;
%environment<RAKULIB PERL6LIB>:delete;
my $result = run $*EXECUTABLE.Str, "-Iinst#{$installed}", 'main.raku',
    :cwd($consumer), :env(%environment);
die 'installed consumer failed' unless $result.exitcode == 0;
say "whole command: {(now - $started).round(0.001)} s";
