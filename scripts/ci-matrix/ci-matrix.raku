use v6.d;

use JSON::Fast;
use LibTmux::Catalogue;

my @include = support-policy().endpoints.map: -> $release {
    %(tmux => $release.version, commit => $release.commit)
};
say to-json(%(include => @include), :!pretty);
