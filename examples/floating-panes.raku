use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<flight-deck>,
        :width(120), :height(36), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $snapshot = $server.snapshot;
    my $main = $snapshot.panes.single.ref;
    my $floating = $snapshot.capabilities.supports('pane-floating');
    my $auxiliary = $floating
        ?? $main.new-floating(:width(40), :height(12), :x(2), :y(2), :empty)
        !! $main.split(:horizontal, :empty);
    $auxiliary.set-title('Aurora telemetry');

    my $after = $server.snapshot;
    die 'The auxiliary pane was not captured' unless $after.panes.elems == 2;
    say 'Telemetry placement: ' ~ ($floating ?? 'floating' !! 'tiled');
    say $after.panes.where(%(id => $auxiliary.id)).single.title;
}
