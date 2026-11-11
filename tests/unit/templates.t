# Template refresh policy: due-ness, targets in use, severity
# deadlines and pruning. Pure functions only.
use strict;
use warnings;
use Test::More;
use PVE::K8s::Templates;

my $day = 86400;
my $T = 'PVE::K8s::Templates';

ok($T->can('refresh_due')->({ 'last-run' => 0 }, 8 * $day), 'never run is due');
ok(!$T->can('refresh_due')->({ 'last-run' => 2 * $day }, 8 * $day),
    'run 6 days ago is not due');
ok($T->can('refresh_due')->({ 'last-run' => 1 * $day }, 8 * $day),
    'run 7 days ago is due');

my @t = PVE::K8s::Templates::targets_in_use({
    a => { 'k8s-version' => '1.36', workers => 2 },
    b => { 'k8s-version' => '1.36', 'cp-arch' => 'arm64', workers => 1 },
    c => { 'k8s-version' => '1.35', workers => 1 },
});
is(join(',', map { "$_->{minor}/$_->{arch}" } @t),
    '1.35/amd64,1.36/amd64,1.36/arm64',
    'targets are unique minor/arch pairs of clusters in use');
is(scalar(PVE::K8s::Templates::targets_in_use({})), 0, 'no clusters, no targets');

my $s = PVE::K8s::Templates::empty_state();
PVE::K8s::Templates::record_build($s, '1.36', 'amd64', 5, 'routine', 100 * $day);
PVE::K8s::Templates::record_build($s, '1.36', 'amd64', 6, 'critical', 200 * $day);
my $r = PVE::K8s::Templates::remediation($s, '1.36', 'amd64', 4, 203 * $day);
ok($r->{pending}, 'node behind newer revisions is pending');
is($r->{severity}, 'critical', 'critical stamp drives the deadline');
is($r->{deadline}, 207 * $day, 'critical deadline is 7 days from the build');
ok(!$r->{overdue}, 'inside the window is not overdue');
ok(PVE::K8s::Templates::remediation($s, '1.36', 'amd64', 4, 208 * $day)->{overdue},
    'past the deadline is overdue');
$r = PVE::K8s::Templates::remediation($s, '1.36', 'amd64', 6, 999 * $day);
ok(!$r->{pending} && !$r->{overdue}, 'node on the newest revision is clean');
$r = PVE::K8s::Templates::remediation($s, '1.36', 'amd64', 5, 999 * $day);
ok($r->{overdue}, 'node one revision behind a critical build is overdue');

my $s2 = PVE::K8s::Templates::empty_state();
PVE::K8s::Templates::record_build($s2, '1.36', 'amd64', 5, 'routine', 100 * $day);
$r = PVE::K8s::Templates::remediation($s2, '1.36', 'amd64', 4, 999 * $day);
ok($r->{pending} && !$r->{overdue} && !defined $r->{deadline},
    'routine rebuild is pending but never overdue');
PVE::K8s::Templates::record_build($s2, '1.36', 'amd64', 6, 'high', 120 * $day);
is(PVE::K8s::Templates::remediation($s2, '1.36', 'amd64', 4, 121 * $day)->{deadline},
    150 * $day, 'high deadline is 30 days');
$r = PVE::K8s::Templates::remediation($s, '1.36', 'arm64', 1, 999 * $day);
ok(!$r->{pending}, 'other architectures are independent');

ok(!eval { PVE::K8s::Templates::record_build($s, '1.36', 'amd64', 7, 'urgent', 1); 1 },
    'unknown severity is rejected');

is(join(',', PVE::K8s::Templates::prune_plan([1, 2, 3, 4, 5], {}, 2)), '1,2,3',
    'keeps the newest two');
is(join(',', PVE::K8s::Templates::prune_plan([1, 2, 3, 4, 5], { 2 => 1 }, 2)), '1,3',
    'keeps an in-use older revision');
is(join(',', PVE::K8s::Templates::prune_plan([4], {}, 2)), '',
    'a single revision is never pruned');
is(join(',', PVE::K8s::Templates::prune_plan([], {}, 2)), '', 'nothing present');


# Provision glue: one target per minor/arch, paired with a cluster
# record, narrowable to a single arch.
require PVE::K8s::Provision;
my $ids = {
    a => { 'k8s-version' => '1.36', storage => 'ceph', workers => 1 },
    b => { 'k8s-version' => '1.36', 'cp-arch' => 'arm64', workers => 1,
        storage => 'other' },
};
my @all = PVE::K8s::Provision::rebuild_targets($ids);
is(join(',', map { "$_->{minor}/$_->{arch}" } @all), '1.36/amd64,1.36/arm64',
    'one build per minor/arch even when two clusters share a minor');
ok($all[0]{scfg}{storage}, 'each target carries a cluster record');
my @arm = PVE::K8s::Provision::rebuild_targets($ids, { arch => 'arm64' });
is(scalar @arm, 1, 'arch filter narrows the targets');
is(scalar(PVE::K8s::Provision::rebuild_targets($ids, { minor => '1.35' })), 0,
    'a minor no cluster uses is never built');
ok(!eval { PVE::K8s::Provision::rebuild_templates([], 'urgent'); 1 },
    'bad severity is rejected before any claim');

# Automatic adoption gating.
my $in = '00:00-23:59';
my $ready = { state => 'ready', 'maintenance-window' => $in,
    nodes => '[{"rev":4},{"rev":5}]' };
my $noon = 1700000000;
ok(PVE::K8s::Provision::adoption_window_open($ready, $noon), 'ready + open window');
ok(!PVE::K8s::Provision::adoption_window_open(
    { %$ready, 'maintenance-window' => undef }, $noon),
    'no window configured: never automatic');
ok(!PVE::K8s::Provision::adoption_window_open(
    { %$ready, state => 'rolling' }, $noon), 'only a ready cluster');
is(PVE::K8s::Provision::nodes_behind_rev($ready, 5), 1, 'one node behind r5');
is(PVE::K8s::Provision::nodes_behind_rev($ready, 4), 0, 'none behind r4');
is(PVE::K8s::Provision::nodes_behind_rev($ready, undef), 0, 'no template, nothing behind');
ok(PVE::K8s::Provision::adoption_due($ready, 5, $noon), 'behind and never checked: due');
my $recent = { %$ready, 'scaler-state' => qq({"adopt-at":@{[$noon - 600]}}) };
ok(!PVE::K8s::Provision::adoption_due($recent, 5, $noon),
    'behind: not retried within 15 minutes');
ok(PVE::K8s::Provision::adoption_due($recent, 5, $noon + 400),
    'behind: retried after 15 minutes');
my $clean = { state => 'ready', 'maintenance-window' => $in,
    nodes => '[{"rev":5}]', 'scaler-state' => qq({"adopt-at":@{[$noon - 3600]}}) };
ok(!PVE::K8s::Provision::adoption_due($clean, 5, $noon),
    'current: only a drift check every 6 hours');
ok(PVE::K8s::Provision::adoption_due($clean, 5, $noon + 21600),
    'current: drift check due after 6 hours');

done_testing;
