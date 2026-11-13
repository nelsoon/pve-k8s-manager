# Scaler decisions that keep it from acting on guesses:
# DaemonSet overhead, pool sizing, least-waste pool choice, host
# capacity, scale-in cooldown and two-pass confirmation.
use strict;
use warnings;
use Test::More;
use PVE::K8s::Scaler;

my $S = 'PVE::K8s::Scaler';
my $GiB = 1024**3;

sub ds_pod { return { metadata => { ownerReferences => [{ kind => 'DaemonSet' }] },
    spec => { containers => [{ resources => { requests => { cpu => '100m', memory => '128Mi' } } }] } } }
sub node { my ($pool, $cpu, $mem, @pods) = @_;
    my $n = $S->can('make_node')->("n-$pool", { 'pve-k8s.proxmox.com/pool' => $pool }, [], $cpu, $mem);
    push $n->{pods}->@*, @pods; return $n }

my $o = PVE::K8s::Scaler::daemonset_overhead([
    node('control-plane', 4000, 4 * $GiB, ds_pod()),
    node('default', 2000, 4 * $GiB, ds_pod(), ds_pod()),
]);
is($o->{cpu}, 200, 'DaemonSet cpu counted on the first worker, not the control plane');
is($o->{mem}, 256 * 1048576, 'DaemonSet memory counted');
is(PVE::K8s::Scaler::daemonset_overhead([node('default', 1, 1)])->{cpu}, 0,
    'no DaemonSet pods: no overhead');

my $t = PVE::K8s::Scaler::pool_template({ name => 'gpu', cpu => 8, memory => 16384 }, [], $o);
is($t->{cpu}, 8000, 'empty pool sized from its definition (scale from zero)');
is($t->{mem}, int(16384 * 1048576 * 0.9), 'allocatable is 90% of VM memory');
is($t->{source}, 'pool definition', 'source is reported');
is($t->{overhead_cpu}, 200, 'overhead carried into the template');
$t = PVE::K8s::Scaler::pool_template({ name => 'default', cpu => 8, memory => 16384 },
    [node('default', 3000, 7 * $GiB)], $o);
is($t->{cpu}, 3000, 'a live node of the pool wins over the definition');
is(PVE::K8s::Scaler::pool_template({ name => 'x' }, [], undef)->{source}, 'default size',
    'no information: conservative default');

# A simulated node starts with DaemonSet overhead already used.
my $pod = { metadata => {}, spec => { containers => [
    { resources => { requests => { cpu => '1900m', memory => '1Gi' } } }] },
    status => { phase => 'Pending' } };
my $pool = { name => 'default', size => 1, max => 3 };
is(PVE::K8s::Scaler::nodes_needed([], [$pod], $pool, 2,
    { cpu => 2000, mem => 4 * $GiB }), 1, 'empty simulated node fits the pod');
is(PVE::K8s::Scaler::nodes_needed([], [$pod], $pool, 2,
    { cpu => 2000, mem => 4 * $GiB, overhead_cpu => 200, overhead_mem => 0 }), 0,
    'with DaemonSet overhead the same node cannot host it');

my $pick = PVE::K8s::Scaler::choose_pool([
    { pool => { name => 'big' }, needed => 1, cpu => 8000, mem => 32 * $GiB },
    { pool => { name => 'small' }, needed => 1, cpu => 2000, mem => 4 * $GiB },
    { pool => { name => 'small2' }, needed => 1, cpu => 2000, mem => 4 * $GiB },
]);
is($pick->{pool}{name}, 'small', 'least added capacity wins, ties keep config order');
is(PVE::K8s::Scaler::choose_pool([]), undef, 'no candidates');

my $hosts = [
    { node => 'a', status => 'online', maxmem => 16 * $GiB, mem => 10 * $GiB },
    { node => 'b', status => 'online', maxmem => 16 * $GiB, mem => 2 * $GiB },
    { node => 'c', status => 'offline', maxmem => 64 * $GiB, mem => 0 },
];
is(PVE::K8s::Scaler::host_capacity($hosts, { memory => 4096 }), 1 + 3,
    'free memory per online host after a 1 GiB reserve');
is(PVE::K8s::Scaler::host_capacity($hosts, { memory => 4096, hosts => 'a' }), 1,
    'limited to the pool hosts');
is(PVE::K8s::Scaler::host_capacity($hosts, { memory => 32768 }), 0,
    'no host can take a node that big');
is(PVE::K8s::Scaler::host_capacity($hosts, { memory => 4096, hosts => 'c' }), 0,
    'offline hosts never count');

ok(!$S->can('scale_in_allowed')->({ 'last-action' => 1000 }, 1300), 'cooldown holds at 5 minutes');
ok($S->can('scale_in_allowed')->({ 'last-action' => 1000 }, 1600), 'cooldown over after 10 minutes');
ok($S->can('scale_in_allowed')->({}, 1700000000), 'no previous action: allowed');
ok(!$S->can('scale_in_allowed')->({ 'last-action' => 1000 }, 1100, 300), 'custom cooldown respected');

my ($ok, $rec) = PVE::K8s::Scaler::confirm_scale_in({}, 'w3', 1000);
ok(!$ok && $rec->{count} == 1, 'first sighting is not enough');
($ok, $rec) = PVE::K8s::Scaler::confirm_scale_in({ 'scale-in-candidate' => $rec }, 'w3', 1180);
ok($ok && $rec->{count} == 2, 'second consecutive pass confirms');
($ok, $rec) = PVE::K8s::Scaler::confirm_scale_in({ 'scale-in-candidate' => $rec }, 'w4', 1360);
ok(!$ok && $rec->{count} == 1, 'a different node starts over');
($ok) = PVE::K8s::Scaler::confirm_scale_in(
    { 'scale-in-candidate' => { host => 'w4', count => 1, at => 1000 } }, 'w4', 5000);
ok(!$ok, 'a stale sighting does not count');

# S10.3 PDB awareness.
sub pod { my ($ns, $labels, $kind) = @_; return { metadata => { namespace => $ns, labels => $labels,
    ownerReferences => $kind ? [{ kind => $kind }] : [] } } }
sub pdb { my ($ns, $name, $sel, $allowed) = @_; return { metadata => { namespace => $ns, name => $name },
    spec => { selector => $sel }, status => { disruptionsAllowed => $allowed } } }
my $web = pod('prod', { app => 'web' });
is_deeply(PVE::K8s::Scaler::pdb_blockers([$web],
    [pdb('prod', 'web', { matchLabels => { app => 'web' } }, 0)]), ['prod/web'],
    'a PDB with no disruptions left blocks the drain');
is_deeply(PVE::K8s::Scaler::pdb_blockers([$web],
    [pdb('prod', 'web', { matchLabels => { app => 'web' } }, 1)]), [],
    'a PDB with budget left does not block');
is_deeply(PVE::K8s::Scaler::pdb_blockers([$web],
    [pdb('other', 'web', { matchLabels => { app => 'web' } }, 0)]), [],
    'a PDB in another namespace does not apply');
is_deeply(PVE::K8s::Scaler::pdb_blockers([pod('prod', { app => 'web' }, 'DaemonSet')],
    [pdb('prod', 'web', { matchLabels => { app => 'web' } }, 0)]), [],
    'DaemonSet pods are ignored (drain skips them)');
is_deeply(PVE::K8s::Scaler::pdb_blockers([$web],
    [pdb('prod', 'x', { matchExpressions => [{ key => 'app', operator => 'In', values => ['web', 'api'] }] }, 0)]),
    ['prod/x'], 'matchExpressions In selects the pod');
is_deeply(PVE::K8s::Scaler::pdb_blockers([$web],
    [pdb('prod', 'x', { matchExpressions => [{ key => 'app', operator => 'NotIn', values => ['web'] }] }, 0)]),
    [], 'matchExpressions NotIn excludes the pod');
is_deeply(PVE::K8s::Scaler::pdb_blockers([$web], [pdb('prod', 'x', {}, 0)]), [],
    'an empty selector is not treated as matching');

# S10.12 scheduler reason.
is(PVE::K8s::Scaler::scheduling_reason({ status => { conditions => [
    { type => 'PodScheduled', status => 'False',
      message => "0/3 nodes are available:  3 Insufficient cpu." }] } }),
    '0/3 nodes are available: 3 Insufficient cpu.', 'scheduler message surfaced, whitespace folded');
is(PVE::K8s::Scaler::scheduling_reason({}), '', 'no condition, no reason');

# S10.11 verify by outcome.
my $orec = { pool => 'default', at => 1000, uids => ['a', 'b'] };
is(PVE::K8s::Scaler::verify_outcome(undef, [], 5000), 'none', 'nothing recorded');
is(PVE::K8s::Scaler::verify_outcome($orec, ['a'], 1300), 'waiting', 'too early to judge');
is(PVE::K8s::Scaler::verify_outcome($orec, ['a'], 2000), 'failed', 'a pod is still pending: simulation disagreed');
is(PVE::K8s::Scaler::verify_outcome($orec, ['zzz'], 2000), 'ok', 'the pods scheduled');
is(PVE::K8s::Scaler::backoff_seconds(0), 3600, 'first backoff is one hour');
is(PVE::K8s::Scaler::backoff_seconds(2), 14400, 'doubles each time');
is(PVE::K8s::Scaler::backoff_seconds(9), 28800, 'capped at eight hours');
ok(PVE::K8s::Scaler::pool_backed_off({ 'pool-backoff' => { default => { until => 3000 } } }, 'default', 2000),
    'backed off until the deadline');
ok(!PVE::K8s::Scaler::pool_backed_off({ 'pool-backoff' => { default => { until => 3000 } } }, 'default', 3000),
    'back in service after the deadline');
ok(!PVE::K8s::Scaler::pool_backed_off({}, 'default', 1), 'no record: not backed off');

# Scale-in must be reachable: after a scale-out live == size.
open my $pf2, '<', 'PVE/K8s/Provision.pm' or die $!;
my $prov2 = do { local $/; <$pf2> };
like($prov2, qr/next if \$live < \$pool->\{size\};/, 'scale-in guard is the strict comparison');

# Scale-in and roll both wait for the VM to be stopped before destroying it.
like($prov2, qr/sub stop_vm_and_wait/, 'one stop-and-wait helper exists');
my $uses = () = $prov2 =~ /stop_vm_and_wait\(\$(?:vhost|svhost), \$(?:vmid|svmid)\)/g;
is($uses, 2, 'roll and scale-in both use it');
unlike($prov2, qr/eval \{ qm_on\(\$svhost, 'stop', \$svmid\) \};/, 'scale-in no longer destroys right after an async stop');

# U4: both automatic repair paths record themselves (the Summary shows them).
open my $pf, '<', 'PVE/K8s/Provision.pm' or die $!;
my $prov = do { local $/; <$pf> };
my $recs = () = $prov =~ /record_repair\(\$name, \$node->\{host\}, '(?:control-plane|worker)'/g;
is($recs, 3, 'control-plane, dead-worker and problem-worker repairs are all recorded');
like($prov, qr/\$out->\{repairs\} = \$rstate->\{repairs\}/, 'the Summary carries the repairs');

done_testing;
