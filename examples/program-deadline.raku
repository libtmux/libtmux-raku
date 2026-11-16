use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<programs>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    unless $server.capabilities.supports('managed-program') {
        say 'Managed programs require a qualified tmux 3.8 daemon';
        return;
    }

    try {
        $server.run-program(['/bin/cat'], :timeout-ms(20));
        CATCH {
            when X::LibTmux::Command {
                .rethrow unless .kind eq 'timeout';
                say 'Run deadline expired; owned program closed';
            }
        }
    }
    die 'The program session remained after cleanup' unless $server.snapshot.sessions.elems == 1;
    say 'Other session preserved';
}
