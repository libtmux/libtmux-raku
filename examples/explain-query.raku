use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<work>,
        :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    $server.snapshot.panes.single.ref.set-title('editor');

    my %wide = width => %(gte => 60);
    my %titled = AND => [%wide, %(title => %(contains => 'edit'))];

    my $wide-plan = $server.explain-panes(:where(%wide));
    say 'width: fully pushed = ' ~ $wide-plan.fully-pushed;
    my $plan = $server.explain-panes(:where(%titled));
    say 'width and title: fully pushed = ' ~ $plan.fully-pushed;
    say 'tmux filter: ' ~ $plan.source-filter;

    my @matches = $server.query-panes(:where(%titled)).map(*.title);
    say 'Matches: ' ~ @matches.join(', ');
    try {
        $server.query-panes(:where(%titled), :pushdown<require>);
        CATCH {
            when X::LibTmux::Unsupported {
                say 'require: refused, title stays local';
            }
        }
    }
}
