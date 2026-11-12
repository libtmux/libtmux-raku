use v6.d;
use LibTmux;
use LibTmux::Control;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<observatory>,
        :width(160), :height(32), :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $before = $server.snapshot;
    my $left = $before.panes.single.ref;
    my $right = $left.split(:horizontal, :shell-command('exec cat'));
    $left.set-title('Starlight telescope');
    $right.set-title('Orion weather');

    my $connection = $server.open-control(:session-id($before.sessions.single.id));
    LEAVE $connection.close if $connection.defined;
    my $seen = Promise.new;
    my $vow = $seen.vow;
    my $lock = Lock.new;
    my $output = '';
    my $message = 'Starlight exposure complete: 42 stars catalogued';
    my $tap = $connection.events.tap(-> $event {
        if $event ~~ PaneOutput && $event.pane-id eq $left.id {
            $lock.protect({
                $output ~= $event.data.decode('utf8-c8');
                die 'Example output exceeded its bound' if $output.chars > 65536;
                $vow.keep(True) if $seen.status == Planned && $output.contains($message);
            });
        }
    }, :quit(-> $error { $lock.protect({ $vow.break($error) if $seen.status == Planned }) }));
    LEAVE $tap.close if $tap.defined;
    $left.send-text($message);
    $left.send-keys('Enter');
    my $wait = await Promise.anyof($seen, Promise.in(2));
    die 'No matching pane output arrived before the deadline' unless $seen.status == Kept;
    die 'Capture did not contain the observed output' unless $left.capture.decode('utf8').contains($message);

    my $after = $connection.snapshot;
    my @instruments := $after.panes.where(%(width => %(gte => 60)));
    my $telescope = @instruments.filter(*.title.starts-with('Starlight')).single;
    die 'Captured membership or titles were wrong' unless @instruments.elems == 2;
    die 'An earlier snapshot changed' unless $before.panes.elems == 1;
    my $plan = $server.explain-panes(:where(%(id => $left.id, width => %(gte => 60))));
    die 'The declared scalar query was not exactly pushable' unless $plan.fully-pushed;
    die 'Source acquisition selected the wrong pane'
        unless $server.query-panes(:where(%(id => $left.id)), :pushdown<require>).single.id eq $left.id;

    say "Observatory: {@instruments.elems} instruments";
    say "{$telescope.title}: $message";
    say 'Floating panes: ' ~ ($after.capabilities.supports('pane-floating') ?? 'available' !! 'unavailable');
    say "Query: {$plan.acquisition-mode}, exact source restriction";

    my $pid = $after.incarnation.pid;
    my $directory = $server.endpoint.socket-path.IO.parent;
    $tap.close;
    $connection.close;
    $server.close;
    die 'Owned daemon or socket directory survived cleanup' if "/proc/$pid".IO.e || $directory.e;
    say 'Owned clients, daemon and socket cleaned up';
}
