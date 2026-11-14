use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<recovery>, :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $before = $server.snapshot;
    my $batch = Batch.new(:operations([
        Operation.new(:name<set-option>, :acknowledgement-only,
            :command(Invocation.new(:argv(['set-option', '-s', '@before-failure', 'set'])))),
        Operation.new(:name<invalid-command>, :acknowledgement-only,
            :command(Invocation.new(:argv(['libtmux-example-unknown-command='])))),
        Operation.new(:name<skipped-option>, :acknowledgement-only,
            :command(Invocation.new(:argv(['set-option', '-s', '@after-failure', 'set'])))),
    ]));
    my $report = $server.run-batch($batch);
    die 'Batch attribution was wrong'
        unless $report.operations.map(*.outcome).List eqv (Complete, Failed, Skipped);
    my $options = $server.options;
    die 'The successful first effect disappeared' unless $options.get('@before-failure') eq 'set';
    die 'A skipped operation ran' if $options.entries(:name<@after-failure>).elems;
    say .name ~ ': ' ~ .outcome ~ ' (scope: ' ~ .completion-scope ~ ')' for $report.operations;

    $options.unset('@before-failure');
    die 'Explicit recovery failed' if $options.entries(:name<@before-failure>).elems;
    say 'Recovery: removed the first effect explicitly';
    my $pid = $before.incarnation.pid;
    my $directory = $server.endpoint.socket-path.IO.parent;
    $server.close;
    die 'Owned daemon or socket directory survived cleanup' if "/proc/$pid".IO.e || $directory.e;
    say 'Owned daemon and socket cleaned up';
}
