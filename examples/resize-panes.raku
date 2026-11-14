use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>,
        :width(120), :height(30), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $before = $server.snapshot;
    my $window = $before.windows.single.ref;
    my $editor = $before.panes.single.ref;
    my $logs = $editor.split(:horizontal, :shell-command('exec cat'));

    $window.resize(:width(100), :height(20));
    $editor.resize(:width(30));
    my $sized = $server.snapshot;
    say "window: {$sized.windows.single.width}x{$sized.windows.single.height}";
    say "editor: {$sized.panes.where(%(id => $editor.id)).single.width} columns";

    $logs.kill;
    say "panes: {$server.snapshot.panes.elems}";
}
