use v6.d;
use LibTmux;

sub MAIN(Str:D :$tmux = 'tmux') {
    my $server = Server.start(:binary($tmux), :name<recovery>,
        :shell-command('exec cat'));
    LEAVE $server.close if $server.defined;
    my $before = Invocation.new(
        :argv(['set-option', '-s', '@before-failure', 'set']));
    my $invalid = Invocation.new(:argv(['libtmux-example-unknown-command=']));
    my $after = Invocation.new(
        :argv(['set-option', '-s', '@after-failure', 'set']));
    my $batch = Batch.new(:operations([
        Operation.new(:name<set-option>, :acknowledgement-only,
            :command($before)),
        Operation.new(:name<invalid-command>, :acknowledgement-only,
            :command($invalid)),
        Operation.new(:name<skipped-option>, :acknowledgement-only,
            :command($after)),
    ]));
    my $report = $server.run-batch($batch);
    my @outcomes = $report.operations.map(*.outcome);
    die 'Batch attribution was wrong'
        unless @outcomes.List eqv (Complete, Failed, Skipped);
    my $options = $server.options;
    die 'The successful first effect disappeared'
        unless $options.get('@before-failure') eq 'set';
    die 'A skipped operation ran'
        if $options.entries(:name<@after-failure>).elems;
    for $report.operations -> $op {
        say "{$op.name}: {$op.outcome} (scope: {$op.completion-scope})";
    }

    $options.unset('@before-failure');
    die 'Explicit recovery failed'
        if $options.entries(:name<@before-failure>).elems;
    say 'Recovery: removed the first effect explicitly';
    $server.close;
    say 'Stopped the tmux server and removed its socket';
}
