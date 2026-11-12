use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<instruments>,
        :width(160), :height(40), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;

    my $telescope = $server.snapshot.panes.single.ref;
    my $weather = $telescope.split(:horizontal, :shell-command('exec cat'));
    my $recorder = $weather.split(:shell-command('exec cat'));
    $telescope.set-title('Starlight telescope');
    $weather.set-title('Orion weather');
    $recorder.set-title('Spectrum recorder');

    my $snapshot = $server.snapshot;
    my @wide := $snapshot.panes.where(%(width => %(gte => 60)));
    my $selected = @wide.filter(*.title.ends-with('telescope')).single;
    say "Wide telescope: {$selected.title}";

    my @others = $snapshot.panes.grep(*.id ne $selected.id).map(*.title).sort;
    say 'Other instruments: ' ~ @others.join(', ');
}
