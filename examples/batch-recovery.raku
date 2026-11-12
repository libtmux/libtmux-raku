use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<mission-control>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $before = $server.snapshot;
    my $batch = Batch.new(:operations([
        Operation.new(:name<fuel>, :acknowledgement-only,
            :command(Invocation.new(:argv(['set-option', '-s', '@fuel', 'ready'])))),
        Operation.new(:name<launch>, :acknowledgement-only,
            :command(Invocation.new(:argv(['libtmux-example-unknown-command='])))),
        Operation.new(:name<orbit>, :acknowledgement-only,
            :command(Invocation.new(:argv(['set-option', '-s', '@orbit', 'entered'])))),
    ]));
    my $report = $server.run-batch($batch);
    die 'Batch attribution was wrong'
        unless $report.operations.map(*.outcome).List eqv (Complete, Failed, Skipped);
    my $options = $server.options;
    die 'The successful first effect disappeared' unless $options.get('@fuel') eq 'ready';
    die 'A skipped operation ran' if $options.entries(:name<@orbit>).elems;
    say .name ~ ': ' ~ .outcome ~ ' (scope: ' ~ .completion-scope ~ ')' for $report.operations;

    $options.unset('@fuel');
    die 'Explicit recovery failed' if $options.entries(:name<@fuel>).elems;
    say 'Recovery: removed the first effect explicitly';
    my $pid = $before.incarnation.pid;
    my $directory = $server.endpoint.socket-path.IO.parent;
    $server.close;
    die 'Owned daemon or socket directory survived cleanup' if "/proc/$pid".IO.e || $directory.e;
    say 'Owned daemon and socket cleaned up';
}
