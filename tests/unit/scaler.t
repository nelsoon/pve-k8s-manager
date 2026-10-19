# Unit test: the autoscaler scheduling simulator (T2.4).
# Pure functions over Kubernetes API shapes; the scaler must
# never act on a naive pending count. Run via `make test`.
use strict;
use warnings;
use Test::More;

use lib 'tests/stubs';
use lib '.';

require PVE::K8s::Scaler;
require PVE::K8s::Config;

# quantities
is(PVE::K8s::Scaler::parse_cpu('500m'), 500, 'cpu milli parsed');
is(PVE::K8s::Scaler::parse_cpu('2'), 2000, 'cpu cores parsed');
is(PVE::K8s::Scaler::parse_mem('512Mi'), 512 * 1024 * 1024,
    'memory parsed');
is(PVE::K8s::Scaler::parse_mem('1Gi'), 1024**3, 'Gi parsed');

sub pod {
    my (%a) = @_;
    return {
        metadata => { name => $a{name} // 'p', namespace => 'default',
            labels => $a{labels} // { app => 'x' },
            ($a{owner} ? (ownerReferences => [{ kind => $a{owner} }]) : ()),
            creationTimestamp => $a{created} // '2026-01-01T00:00:00Z' },
        spec => {
            containers => [{ name => 'c', resources => { requests => {
                cpu => $a{cpu} // '500m',
                memory => $a{mem} // '512Mi' } } }],
            ($a{selector} ? (nodeSelector => $a{selector}) : ()),
            ($a{tolerations} ? (tolerations => $a{tolerations}) : ()),
            ($a{affinity} ? (affinity => $a{affinity}) : ()),
            ($a{node} ? (nodeName => $a{node}) : ()),
        },
        status => { phase => $a{phase} // 'Pending',
            conditions => $a{conditions} // [] },
    };
}

my $big_pool = { name => 'big', labels => 'size=big',
    taints => 'dedicated=big:NoSchedule', min => 1, max => 4, size => 1 };
my $plain_pool = { name => 'default', min => 1, max => 3, size => 1 };
my $tmpl = { cpu => 4000, mem => 8 * 1024**3 };
my $unsched = [{ type => 'PodScheduled', status => 'False',
    reason => 'Unschedulable' }];

# label-selected pod only grows the matching pool
my $big_pod = pod(selector => { size => 'big' },
    tolerations => [{ key => 'dedicated', operator => 'Equal',
        value => 'big', effect => 'NoSchedule' }],
    conditions => $unsched);
is(PVE::K8s::Scaler::nodes_needed([], [$big_pod], $big_pool, 3, $tmpl),
    1, 'label-selected pod grows the matching pool');
is(PVE::K8s::Scaler::nodes_needed([], [$big_pod], $plain_pool, 3, $tmpl),
    0, 'label-selected pod does not grow the plain pool');

# required nodeAffinity is honoured the same way
my $aff_terms = [{ matchExpressions => [
    { key => 'size', operator => 'In', values => ['big'] }] }];
my $aff_pod = pod(affinity => { nodeAffinity => {
    requiredDuringSchedulingIgnoredDuringExecution => {
        nodeSelectorTerms => $aff_terms } } },
    tolerations => [{ key => 'dedicated', operator => 'Equal',
        value => 'big', effect => 'NoSchedule' }],
    conditions => $unsched);
is(PVE::K8s::Scaler::nodes_needed([], [$aff_pod], $big_pool, 3, $tmpl),
    1, 'required nodeAffinity pod grows the matching pool');
is(PVE::K8s::Scaler::nodes_needed([], [$aff_pod], $plain_pool, 3, $tmpl),
    0, 'required nodeAffinity pod ignores the plain pool');

# without the toleration a tainted pool must not grow
my $no_tol = pod(selector => { size => 'big' }, conditions => $unsched);
is(PVE::K8s::Scaler::nodes_needed([], [$no_tol], $big_pool, 3, $tmpl),
    0, 'pod without toleration does not grow the tainted pool');

# oversized pod: message case, not nodes
my $huge = pod(cpu => '64', conditions => $unsched);
is(PVE::K8s::Scaler::nodes_needed([], [$huge], $plain_pool, 3, $tmpl),
    0, 'oversized pod yields no nodes');

# max bounds growth
my @many = map { pod(name => "p$_", conditions => $unsched) } 1 .. 20;
is(PVE::K8s::Scaler::nodes_needed([], \@many, $plain_pool, 2, $tmpl),
    2, 'growth stops at the room given (pool max)');

# required anti-affinity needs a second node for the twin pod
my $aa = { podAntiAffinity => {
    requiredDuringSchedulingIgnoredDuringExecution => [{
        topologyKey => 'kubernetes.io/hostname',
        labelSelector => { matchLabels => { app => 'x' } } }] } };
my @twins = map { pod(name => "t$_", affinity => $aa,
    conditions => $unsched) } 1 .. 2;
is(PVE::K8s::Scaler::nodes_needed([], \@twins, $plain_pool, 3, $tmpl),
    2, 'required anti-affinity grows two nodes for twin pods');

# non-scheduling pending reasons never grow anything
is(PVE::K8s::Scaler::schedulable_pending(
    [pod(phase => 'Running', node => 'n1')])->@*, 0,
    'running pods are not pending work');
is(PVE::K8s::Scaler::schedulable_pending(
    [pod(owner => 'DaemonSet', conditions => $unsched)])->@*, 0,
    'DaemonSet pods are not pending work');

# scale-in: idle node whose pods fit elsewhere is a candidate
my $busy = PVE::K8s::Scaler::make_node('busy',
    PVE::K8s::Scaler::pool_node_labels($plain_pool), [], 4000, 8 * 1024**3);
my $idle = PVE::K8s::Scaler::make_node('idle',
    PVE::K8s::Scaler::pool_node_labels($plain_pool), [], 4000, 8 * 1024**3);
PVE::K8s::Scaler::place_pods([$busy],
    [pod(name => 'a', cpu => '1500m'), pod(name => 'b', cpu => '1500m')]);
PVE::K8s::Scaler::place_pods([$idle], [pod(name => 'c')]);
my $cands = PVE::K8s::Scaler::scale_in_candidates([$busy, $idle], 0.5);
is_deeply($cands, ['idle'], 'low-utilisation node is a scale-in candidate');

# pool min/max parsing (T2.4 config)
my $pools = PVE::K8s::Config::parse_pools(
    '[{"name":"default","size":1,"min":1,"max":4}]', 2);
is($pools->[0]{max}, 4, 'pool max parsed');
my $pinned = PVE::K8s::Config::parse_pools(
    '[{"name":"default","size":2}]', 2);
is($pinned->[0]{min}, 2, 'absent min pins the pool at size');
ok(!eval {
    PVE::K8s::Config::parse_pools(
        '[{"name":"default","size":3,"min":1,"max":2}]', 2); 1 },
    'size above max is rejected');


# scale-in drain is time-boxed and PDB-blocked drains leave
# the node uncordoned, never force-drained (lab finding).
my $provsrc = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};
like($provsrc, qr/timeout 240 kubectl .*drain \$host/s,
    'scale-in drain is time-boxed in the guest');
like($provsrc, qr/drain of \$host blocked \(likely a /,
    'blocked drain is reported, not forced');

done_testing();
