use v6.d;
use NativeCall;

# Directory helpers shared by the support scripts and their tests.
unit module Scripts::Filesystem;

sub mkdtemp(CArray[uint8] --> Pointer) is native { * }

#| Create an empty directory under `$*TMPDIR` that only the caller can enter.
#| The name is `$prefix-` and six random characters.
sub private-directory(Str:D $prefix --> IO::Path:D) is export {
    my $template = $*TMPDIR.add("{$prefix}-XXXXXX").Str.encode;
    my $bytes = CArray[uint8].new(|$template.list, 0);
    die "Could not create a private directory under $*TMPDIR" unless mkdtemp($bytes);
    Blob.new((^$template.elems).map({ $bytes[$_] })).decode.IO
}

#| Delete a path and everything under it. A symbolic link is removed, never followed.
sub remove-tree(IO::Path:D $path --> Nil) is export {
    if $path.d && !$path.l {
        remove-tree($_) for $path.dir;
        $path.rmdir;
    } else {
        $path.unlink;
    }
}
