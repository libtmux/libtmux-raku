use v6.d;

=begin pod
=NAME LibTmux
=DESCRIPTION
Core distribution for explicit tmux observations and commands.
The initial foundation provides typed identifiers and operational errors.
Server, graph and query APIs are under development.
=end pod

unit module LibTmux;

use LibTmux::Types;
use LibTmux::Exceptions;
