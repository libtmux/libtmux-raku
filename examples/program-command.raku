use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<programs>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    unless $server.capabilities.supports('managed-program') {
        say 'Managed programs require a qualified tmux 3.8 daemon';
        return;
    }

    my $result = $server.run-program(['/usr/bin/printf', '%s\n', 'hello $() ; literal']);
    say 'Exit: ' ~ $result.exitcode;
    say 'Screen: ' ~ $result.screen.decode('utf8-c8').lines.first(*.chars);
}
