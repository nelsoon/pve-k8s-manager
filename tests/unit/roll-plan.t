# Unit + static tests: a roll never grows a pool past
# spec+1 and converges downwards after interrupted runs.
# Repeated runs planned from a stale record alone surged
# one replacement per resume and never retired the old
# nodes (lab, 2026-10-27: 8 control-plane nodes against a
# spec of 3, etcd at 6 members). roll_plan counts live
# current members per pool: behind nodes surge only while
# the pool is short of spec, otherwise they retire with no
# replacement; excess current members retire last.
# Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

sub cp { return { host => "c-cp$_[0]", pool => 'control-plane',
    current => $_[1] } }
sub wk { return { host => "c-w$_[0]", pool => 'default',
    current => $_[1] } }

my $spec3 = { 'control-plane' => 3 };

my $plan = PVE::K8s::Provision::roll_plan(
    [cp(1, 0), cp(2, 0), cp(3, 0)], $spec3);
is($plan->{'c-cp1'}, 'surge', 'fresh 3-CP roll surges the first');
is($plan->{'c-cp3'}, 'surge', 'fresh 3-CP roll surges the last');

# The lab failure: 3 current replacements already joined,
# 2 old nodes still in the record behind them.
$plan = PVE::K8s::Provision::roll_plan(
    [cp(5, 0), cp(6, 0), cp(7, 1), cp(9, 1), cp(10, 1)], $spec3);
is($plan->{'c-cp5'}, 'retire-only',
    'covered old CP retires without a surge');
is($plan->{'c-cp6'}, 'retire-only',
    'second covered old CP retires without a surge');
ok(!exists $plan->{'c-cp7'}, 'current members are left alone');

# One short of spec: first behind node surges, rest retire.
$plan = PVE::K8s::Provision::roll_plan(
    [cp(5, 0), cp(6, 0), cp(7, 1), cp(9, 1)], $spec3);
is($plan->{'c-cp5'}, 'surge', 'short pool surges once');
is($plan->{'c-cp6'}, 'retire-only', 'then retires without surging');

# Excess current members retire too (no even/oversized etcd).
$plan = PVE::K8s::Provision::roll_plan(
    [cp(7, 1), cp(9, 1), cp(10, 1), cp(11, 1)], $spec3);
is($plan->{'c-cp11'}, 'retire-only',
    'excess current CP retires, highest index first');
ok(!exists $plan->{'c-cp9'}, 'in-spec current CPs stay');

# Pools plan independently: workers do not consume CP slots.
$plan = PVE::K8s::Provision::roll_plan(
    [cp(1, 0), wk(1, 0), wk(2, 0), wk(3, 1)],
    { 'control-plane' => 3, default => 2 });
is($plan->{'c-cp1'}, 'surge', 'CP pool plans on its own count');
is($plan->{'c-w1'}, 'surge', 'worker pool short: surge');
is($plan->{'c-w2'}, 'retire-only', 'worker pool covered: retire');

# Pool sizing drift: edited node-group must converge by
# replacement (nodes are never resized in place).
my %want = (cpu => 4, memory => 8096);
ok(!PVE::K8s::Provision::size_drift(\%want, 4, 8096),
    'matching cores/memory is not drift');
ok(PVE::K8s::Provision::size_drift(\%want, 2, 4096),
    'pool edit 8GB/4c over 4GB/2c node is drift');
ok(PVE::K8s::Provision::size_drift(\%want, 4, 4096)
    || PVE::K8s::Provision::size_drift(\%want, 2, 8096),
    'either dimension alone is drift');
ok(!PVE::K8s::Provision::size_drift(undef, 2, 4096),
    'no pool def: never drift');
ok(!PVE::K8s::Provision::size_drift({}, 2, 4096),
    'empty pool def: never drift');
ok(!PVE::K8s::Provision::size_drift(
    { cpu => 0, memory => 0 }, 2, 4096),
    'zero def: never drift');

# Regression: a Roll must re-sync HA registration, or replacement
# workers silently lose live-migration on planned host shutdown.
open my $psrc, '<', 'PVE/K8s/Provision.pm' or die $!;
my $code = do { local $/; <$psrc> };
my ($roll) = $code =~ /^sub roll_cluster \{(.*?)^\}/ms;
my $n = () = ($roll // '') =~ /sync_ha_resources\(/g;
ok($n >= 3, 'roll_cluster syncs HA per node, at the end and when current');

my $dp = { cpu => 4, memory => 8096, disk => 50,
    device_profile => 'gpu1' };
ok(!PVE::K8s::Provision::size_drift($dp, 4, 8096, 60 * 1024, 'gpu1'),
    'larger live disk and matching device is not drift');
ok(PVE::K8s::Provision::size_drift($dp, 4, 8096, 32 * 1024, 'gpu1'),
    'live disk smaller than pool is drift');
ok(PVE::K8s::Provision::size_drift($dp, 4, 8096, 50 * 1024, ''),
    'missing device is drift');
ok(PVE::K8s::Provision::size_drift(
    { cpu => 4, memory => 8096 }, 4, 8096, undef, 'gpu1'),
    'unwanted device is drift');
ok(!PVE::K8s::Provision::size_drift($dp, 4, 8096, undef, undef),
    'unknown disk/device is never drift');
my @l = PVE::K8s::Provision::live_size(
    "cores: 2\nmemory: 4096\nscsi0: local:vm-1-disk-0,size=32G\n"
    . "hostpci0: mapping=gpu1,pcie=1\n");
is("@l[2,3]", '32768 gpu1', 'live_size reads disk MiB and device');

my ($lc, $lm) = PVE::K8s::Provision::live_size(
    "boot: order=scsi0\ncores: 2\nmemory: 4096\n\n"
    . "[snap1]\ncores: 9\nmemory: 9999\n");
is("$lc/$lm", '2/4096', 'live_size reads top-level, anchored');
my @none = PVE::K8s::Provision::live_size("vcpus: 3\n");
ok(!defined $none[0] && !defined $none[1], 'no false match on vcpus');

my $good = PVE::K8s::Provision::live_node_items(
    '{"items":[{"metadata":{"name":"c-cp7"},'
    . '"status":{"nodeInfo":{"kubeletVersion":"v1.36.5"},'
    . '"addresses":[{"type":"InternalIP",'
    . '"address":"192.168.206.64"}]}}]}');
is(scalar $good->@*, 1, 'NodeList-shaped payload yields its nodes');
is(PVE::K8s::Provision::live_node_items('[1,2]')->@*, 0,
    'top-level array yields no nodes');
is(PVE::K8s::Provision::live_node_items('"oops"')->@*, 0,
    'top-level string yields no nodes');
is(PVE::K8s::Provision::live_node_items('not json')->@*, 0,
    'garbage yields no nodes');
is(PVE::K8s::Provision::live_node_items('{"items":{}}')->@*, 0,
    'non-array items yields no nodes');
is(PVE::K8s::Provision::live_node_items(
    '{"items":["c-cp7",{}]}')->@*, 1,
    'non-hash elements are filtered out');

my $file = 'PVE/K8s/Provision.pm';
open(my $fh, '<', $file) or die "open $file: $!\n";
my $src = do { local $/; <$fh> };
close($fh);

my ($body) = $src =~ /^sub roll_cluster \{(.*?)^(?:my\s+)?sub /ms;
$body //= $src;
like($body, qr/adopted live member/,
    'roll adopts live members into the record before planning');
like($body, qr/roll_plan\(\\\@nodes, \\\%desired\)/,
    'roll plans replacements with roll_plan');
like($body, qr/'retire-only'/,
    'roll executes the retire-only branch');
like($body, qr/live_kubelet/,
    'upgrade currency compares live kubelet versions');
like($src, qr/sub etcd_snapshot_any/,
    'snapshot tries every CP instead of one fixed node');
like($body, qr/etcd_snapshot_any\(\\\@nodes\)/,
    'roll snapshots through any serving member');
like($src, qr/grep \{ \$_->\{current\} \} \@cands/,
    'etcd removal prefers a current member as endpoint');
like($body, qr{/readyz},
    'ops control-plane node must prove VIP API reachability');
like($body, qr/not usable, /,
    'unusable ops candidate falls through to the next CP');
like($body, qr/\(\$_->\{ip\} \/\/ ''\)/,
    'worker surge-IP scan tolerates nodes without an IP yet');
like($src, qr/my \$cp1_ip = \$cp1->\{ip\} \/\/ \$vip/,
    'ops probe falls back to the VIP for an IP-less node');

done_testing();
