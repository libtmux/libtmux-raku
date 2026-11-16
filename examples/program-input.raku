use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<programs>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    unless $server.capabilities.supports('managed-program') {
        say 'Managed programs require a qualified tmux 3.8 daemon';
        return;
    }

    my $program = $server.start-program(['/bin/sh', '-c',
        'IFS= read -r answer; printf "ANSWER:%s\n" "$answer"']);
    LEAVE $program.close if $program.defined;
    my $cancel = Cancellation.new;
    $cancel.cancel;
    try {
        await $program.wait-async(:$cancel);
        CATCH {
            when X::LibTmux::Command {
                .rethrow unless .kind eq 'cancelled';
                say 'Wait cancelled; program retained';
            }
        }
    }
    $program.send-text("Raku\n");
    my $result = $program.wait;
    say $result.screen.decode('utf8-c8').lines.first(*.starts-with('ANSWER:'));
    say 'Exit: ' ~ $result.exitcode;
}
