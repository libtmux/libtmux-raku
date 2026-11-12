use LibTmux;

my $server = Server.start(:name<observatory>, :shell-command('exec cat'));
LEAVE $server.close if $server.defined;

my $before = $server.snapshot;
my $left = $before.panes.single.ref;
my $right = $left.split(:horizontal, :shell-command('exec cat'));
$left.set-title('Starlight telescope');
$right.set-title('Orion weather');

my $after = $server.snapshot;
my $telescope = $after.panes.filter(*.title.starts-with('Starlight')).single;
say "{$telescope.title}: {$after.panes.elems} panes";
