use v6.d;
use LibTmux;
use LibTmux::Control;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<output>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $snapshot = await $server.snapshot-async;
    my $pane = $snapshot.panes.single.ref;
    my $connection = await $server.open-control-async(:session-id($snapshot.sessions.single.id));
    LEAVE $connection.close if $connection.defined;

    my $message = 'hello from Raku';
    my $received = '';
    react {
        whenever $connection.events.grep(PaneOutput) -> $event {
            if $event.pane-id eq $pane.id {
                $received ~= $event.data.decode('utf8-c8');
                die 'Pane output exceeded its bound' if $received.chars > 65536;
                done if $received.contains($message);
            }
        }
        whenever start { $pane.send-text($message); $pane.send-keys('Enter') } { }
        whenever Promise.in(2) { die 'Pane output timed out' }
    }

    die 'The captured screen did not contain the message'
        unless $pane.capture.decode('utf8').contains($message);
    say $message;
    say 'Screen capture confirmed';
}
