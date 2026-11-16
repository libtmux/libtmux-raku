use v6.d;
use lib $?FILE.IO.parent(2).add('lib');
use Scripts::Filesystem;

# Upload the tested release archive to the zef registry with `fez`. `fez` reads
# its account key from a config file, so the script writes one from $FEZ_KEY in
# a private directory and removes it afterwards, also when the upload fails.
# Run by release.yml in the `fez` environment, after `zef install fez`.
#
#   raku scripts/fez-upload/fez-upload.raku dist/LibTmux-X.Y.Z.tar.gz

#| Run `fez` on the archive with a one-off config holding the key; return its exit code.
sub upload(Str:D $archive, Str:D $key --> Int:D) {
    # Fez is installed by the publishing job only, so load it when it is needed.
    require Fez::Util::Config <&env-config>;
    require Fez::Util::Json <&to-j>;
    my %config = env-config();
    %config<ecosystems> = { zef => %config<host> };
    %config<key> = $key;
    my $directory = private-directory('libtmux-fez');
    LEAVE remove-tree($directory) if $directory.defined && $directory.e;
    my $config = $directory.add('fez-publish.json');
    $config.spurt(to-j(%config));
    my %environment = %*ENV;
    %environment<FEZ_CONFIG> = $config.Str;
    run('fez', '--unattended', 'upload', "--file=$archive", :env(%environment)).exitcode
}

sub MAIN(Str:D $archive) {
    my $key = %*ENV<FEZ_KEY> // '';
    unless $key.chars {
        note 'Set FEZ_KEY in the fez environment before publishing.';
        exit 1;
    }
    my $status = upload($archive, $key);
    exit $status if $status;
}
