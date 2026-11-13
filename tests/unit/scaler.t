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

# node-problem-detector conditions that trigger a replacement
{
    my $np = \&PVE::K8s::Scaler::node_problem;
    is($np->([{ type => 'Ready', status => 'True' }]), undef, 'healthy node: none');
    is($np->([{ type => 'KernelDeadlock', status => 'False' }]), undef, 'condition False: none');
    my $p = $np->([{ type => 'Ready', status => 'True' },
        { type => 'ReadonlyFilesystem', status => 'True',
          lastTransitionTime => '2026-11-13T10:00:00Z', message => 'ro remount' }]);
    is($p->{type}, 'ReadonlyFilesystem', 'read-only file system found');
    is($p->{since}, '2026-11-13T10:00:00Z', 'with the time it started');
    is($np->([{ type => 'FrequentDockerRestart', status => 'True' }]), undef,
        'other conditions are not acted on');
    is($np->(undef), undef, 'no conditions: none');
}

my $src = do { local $/; open my $fh, '<', 'PVE/K8s/Provision.pm' or die; <$fh> };
like($src, qr/next if \$since < \$PROBLEM_GRACE;\s+if \(\$not_ready\) \{/,
    'problem nodes wait out the grace and never while another node is down');
like($src, qr/control plane \$node->\{host\} reports/, 'control planes are only reported');
like($src, qr/replace_node\(\$name, \$node->\{host\}\);\s+#[^\n]*\n\s+run_descheduler\(\$name, \$cp, 'repair'\);/,
    'a replaced node is drained first (replace_node), then pods rebalance');
like($src, qr/delete \$_\[0\]->\{'scale-out'\} \}\);\s+#[^\n]*\n\s+#[^\n]*\n\s+run_descheduler\(\$name, \$cp, 'scaleout'\);/,
    'the descheduler runs after a scale-out only once its pods are placed');
like($src, qr/rolled: all nodes on \$version r\$want_rev\\n";\s+run_descheduler\(\$name, \$cp1, 'roll'\);/,
    'and after a roll');
like($src, qr/return 0 if time\(\) - \(\$state->\{'descheduled-at'\} \/\/ 0\) < \$DESCHEDULE_COOLDOWN;/,
    'at most every cooldown');

# Hard topology spread (DoNotSchedule) on hostname and zone
{
    my $S = 'PVE::K8s::Scaler';
    my $spread = sub { my ($key, %o) = @_;
        my $p = pod(name => $o{name} // 'w', labels => { app => 'web' }, cpu => '100m', mem => '64Mi');
        $p->{spec}{topologySpreadConstraints} = [{ maxSkew => 1, topologyKey => $key,
            whenUnsatisfiable => $o{when} // 'DoNotSchedule',
            labelSelector => { matchLabels => { app => 'web' } } }];
        $p };
    my $node = sub { my ($n, $zone) = @_;
        PVE::K8s::Scaler::make_node($n, { 'kubernetes.io/hostname' => $n,
            ($zone ? ('topology.kubernetes.io/zone' => $zone) : ()) }, [], 4000, 8 * 1024**3) };
    my @n = ($node->('a', 'h1'), $node->('b', 'h2'));
    my ($placed, $un) = PVE::K8s::Scaler::place_pods(\@n,
        [map { $spread->('kubernetes.io/hostname', name => "w$_") } 1 .. 4]);
    is(scalar @$placed, 4, 'hostname spread: 4 replicas fit on 2 nodes, 2 each');
    is(scalar $n[0]{pods}->@*, 2, 'evenly');
    my @one = ($node->('a', 'h1'));
    push $one[0]{pods}->@*, $spread->('kubernetes.io/hostname', name => 'old');
    my @two = ($node->('a', 'h1'), $node->('b', 'h2'));
    push $two[0]{pods}->@*, $spread->('kubernetes.io/hostname', name => 'old1'),
        $spread->('kubernetes.io/hostname', name => 'old2');
    ($placed) = PVE::K8s::Scaler::place_pods(\@two,
        [$spread->('kubernetes.io/hostname', name => 'new')]);
    is($placed->[0] && scalar $two[1]{pods}->@*, 1, 'skew forces the emptier node');
    my $full = [$node->('a', 'h1'), $node->('b', 'h2')];
    $full->[1]{used_cpu} = 4000;
    push $full->[0]{pods}->@*, $spread->('kubernetes.io/hostname', name => 'o1');
    ($placed, $un) = PVE::K8s::Scaler::place_pods($full,
        [$spread->('kubernetes.io/hostname', name => 'n1')]);
    is(scalar @$un, 1, 'the only domain with room would break maxSkew: unplaced');
    is(PVE::K8s::Scaler::nodes_needed($full, $un, { name => 'default' }, 2,
        { cpu => 4000, mem => 8 * 1024**3 }), 1,
        'one new node (its own hostname domain) places it: scale out');
    ($placed, $un) = PVE::K8s::Scaler::place_pods([$node->('a', 'h1'), $node->('b', 'h2')],
        [map { $spread->('kubernetes.io/hostname', name => "s$_", when => 'ScheduleAnyway') } 1 .. 3]);
    is(scalar @$placed, 3, 'soft spread is not enforced');
    my $zfull = [$node->('a', 'h1'), $node->('b', 'h2')];
    $zfull->[1]{used_cpu} = 4000;
    push $zfull->[0]{pods}->@*, $spread->('topology.kubernetes.io/zone', name => 'z0');
    ($placed, $un) = PVE::K8s::Scaler::place_pods($zfull,
        [$spread->('topology.kubernetes.io/zone', name => 'z1')]);
    is(scalar @$un, 1, 'zone spread blocked like the scheduler would');
    is(PVE::K8s::Scaler::nodes_needed($zfull, $un, { name => 'default' }, 2,
        { cpu => 4000, mem => 8 * 1024**3 }), 0,
        'a new node has no known zone: no blind scale-out for zone spread');
    my $other = pod(name => 'o', labels => { app => 'web' });
    $other->{metadata}{namespace} = 'other';
    my $ns = [$node->('a', 'h1'), $node->('b', 'h2')];
    $ns->[1]{used_cpu} = 4000;
    push $ns->[0]{pods}->@*, $other;
    ($placed) = PVE::K8s::Scaler::place_pods($ns, [$spread->('kubernetes.io/hostname')]);
    is(scalar @$placed, 1, 'pods of other namespaces do not count');
}

like($src, qr/our \$PENDING_MIN_AGE = 30;/, 'pending pods wait 30 s, not 2 minutes');
like($src, qr/sub pending_watch \{[\s\S]*?k8s_read_fast\([\s\S]*?fieldSelector=status\.phase%3DPending[\s\S]*?return scale_cluster\(\$name\);/,
    'the watch does one vsock read and runs a pass only for waiting pods');
my $tool = do { local $/; open my $fh, '<', 'tools/pve-k8s-scaler' or die; <$fh> };
like($tool, qr/'--watch'[\s\S]*?pending_watch\(\$name\)/, 'scaler --watch mode');
my $timer = do { local $/; open my $fh, '<', 'systemd/pve-k8s-scaler-watch.timer' or die; <$fh> };
like($timer, qr/OnUnitActiveSec=30s\nAccuracySec=5s/, 'watch every 30 s, accurately');
my $post = do { local $/; open my $fh, '<', 'debian/postinst.tail' or die; <$fh> };
like($post, qr/pve-k8s-scaler-watch\.timer/, 'the watch is enabled on install');

done_testing();
