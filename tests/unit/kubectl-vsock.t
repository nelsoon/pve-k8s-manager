# kubectl over vsock: the kubectl command lines pve-k8s runs, as
# Kubernetes API requests (kubectl_api_plan), and the kubectl-shaped
# output rebuilt from the API answers. Pure parts plus wiring.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use PVE::K8s::Provision;

my $P = 'PVE::K8s::Provision';
my $plan = $P->can('kubectl_api_plan');
my $path = sub { my $p = $plan->($_[0]) or return undef; $p->{reqs}[0]{path} };

# reads
is($path->('get nodes --no-headers'), '/api/v1/nodes', 'node list (text)');
is($plan->('get nodes --no-headers')->{out}, 'nodes-text', 'rendered like kubectl');
is($path->('get nodes -o json'), '/api/v1/nodes', 'node list (json)');
is($plan->('version -o json')->{out}, 'version', 'version');
is($path->('version -o json'), '/version', 'from /version');
is($path->('get pods -A -o json'), '/api/v1/pods', 'all pods');
is($path->('get pdb -A -o json'), '/apis/policy/v1/poddisruptionbudgets', 'all PDBs');
is($path->('get pv -o json'), '/api/v1/persistentvolumes', 'all PVs');
is($path->('get pv pvc-1a2b.x -o json'), '/api/v1/persistentvolumes/pvc-1a2b.x', 'one PV');
is($path->('get pvc -n web data-0 -o json'),
    '/api/v1/namespaces/web/persistentvolumeclaims/data-0', 'one PVC (namespace, name)');
is($path->('get pods -n web -o json'), '/api/v1/namespaces/web/pods', 'pods of a namespace');
is($path->('get volumeattachments -o json'), '/apis/storage.k8s.io/v1/volumeattachments',
    'volume attachments');
is($path->('get deployments -A -o json'), '/apis/apps/v1/deployments', 'all Deployments');
is($path->('get daemonsets -A -o json'), '/apis/apps/v1/daemonsets', 'all DaemonSets');
is($path->('get crd httproutes.gateway.networking.k8s.io -o json'),
    '/apis/apiextensions.k8s.io/v1/customresourcedefinitions/httproutes.gateway.networking.k8s.io',
    'one CRD');
is($path->('-n kube-system get daemonset cilium -o json'),
    '/apis/apps/v1/namespaces/kube-system/daemonsets/cilium', 'one DaemonSet');
my $ev = $plan->('get events -A --sort-by=.lastTimestamp -o json');
is($ev->{reqs}[0]{path}, '/api/v1/events', 'events');
is($ev->{sort}, 'lastTimestamp', 'sorted like --sort-by');

# writes
my $c = $plan->('cordon local-w1');
is_deeply([$c->{reqs}[0]{method}, $c->{reqs}[0]{path}, $c->{reqs}[0]{type}],
    ['PATCH', '/api/v1/nodes/local-w1', 'application/merge-patch+json'], 'cordon: merge patch');
ok($c->{reqs}[0]{body}{spec}{unschedulable}, 'cordon sets unschedulable');
ok(!$plan->('uncordon local-w1')->{reqs}[0]{body}{spec}{unschedulable}, 'uncordon clears it');
is(JSON::PP->new->canonical->encode($plan->('uncordon local-w1')->{reqs}[0]{body}),
    '{"spec":{"unschedulable":false}}', 'as a JSON false, not a missing key');
my $d = $plan->('delete node local-w2');
is_deeply([$d->{reqs}[0]{method}, $d->{reqs}[0]{path}], ['DELETE', '/api/v1/nodes/local-w2'],
    'delete node');
ok(!(grep { $_ == 404 } $d->{reqs}[0]{ok}->@*), 'a missing node is an error, as with kubectl');
my $l = $plan->('label nodes local-w1 pve-k8s.proxmox.com/pool=default '
    . 'topology.pve-k8s.proxmox.com/site=cloud1 tier=web --overwrite');
is_deeply($l->{reqs}[0]{body}{metadata}{labels}, {
    'pve-k8s.proxmox.com/pool' => 'default',
    'topology.pve-k8s.proxmox.com/site' => 'cloud1', tier => 'web' }, 'labels');
ok($plan->('label node local-cp1 a=b --overwrite'), '"label node" too');
is($plan->('label nodes local-w1 bad-key- --overwrite'), undef,
    'anything but key=value goes to kubectl');
is($plan->('label nodes local-w1 a=b'), undef, 'without --overwrite: kubectl');
my $pp = $plan->(q{patch pv pvc-9 --type merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'});
is($pp->{reqs}[0]{path}, '/api/v1/persistentvolumes/pvc-9', 'patch pv');
is($pp->{reqs}[0]{body}{spec}{persistentVolumeReclaimPolicy}, 'Retain', 'with its patch');
my $dp = $plan->('delete pvc -n web data-0 --ignore-not-found --wait=true');
is($dp->{reqs}[0]{method}, 'DELETE', 'delete pvc');
ok((grep { $_ == 404 } $dp->{reqs}[0]{ok}->@*), '--ignore-not-found');
is($dp->{wait_gone}, '/api/v1/namespaces/web/persistentvolumeclaims/data-0', '--wait=true');
is($plan->('delete pv pvc-9 --ignore-not-found --wait=true')->{wait_gone},
    '/api/v1/persistentvolumes/pvc-9', 'delete pv waits too');

# left to kubectl
for my $args ('drain local-w1 --ignore-daemonsets --delete-emptydir-data --force --timeout=240s',
    'taint nodes local-w1 a=b:NoSchedule --overwrite', 'apply -f /tmp/move.json',
    'get nodes', 'get pv Bad_Name -o json',
    'get pods -n web;rm -rf / -o json', 'cordon local-w1; reboot') {
    is($plan->($args), undef, "kubectl: $args");
}

# every path a plan sends must pass the helper's own path check
my $vg = do { local $/; open my $f, '<', 'tools/pve-k8s-vsock-get' or die; <$f> };
my ($allow) = $vg =~ /\(\$_->\{path\} \/\/ ''\) !~ m\{(.+?)\}\n/;
ok($allow, 'helper path check found');
my $allow_re = qr/$allow/;
for my $args ('get nodes --no-headers', 'version -o json', 'get pods -A -o json',
    'get pdb -A -o json', 'get events -A --sort-by=.lastTimestamp -o json',
    'cordon a', 'delete node a', 'label nodes a b=c --overwrite',
    'get pvc -n a b -o json', 'delete pv a --ignore-not-found --wait=true') {
    my $p = $plan->($args);
    ok(!(grep { $_->{path} !~ $allow_re } $p->{reqs}->@*), "helper accepts: $args");
}
ok('/etc/passwd' !~ $allow_re && '/apisx' !~ $allow_re && '/versions' !~ $allow_re,
    'and nothing outside the API');

# kubectl-shaped output
my $nodes = { items => [
    { metadata => { name => 'local-cp1', labels => { 'node-role.kubernetes.io/control-plane' => '' } },
      status => { conditions => [{ type => 'Ready', status => 'True' }],
          nodeInfo => { kubeletVersion => 'v1.36.6' } } },
    { metadata => { name => 'local-w1', labels => {} }, spec => { unschedulable => JSON::PP::true },
      status => { conditions => [{ type => 'Ready', status => 'True' }] } },
    { metadata => { name => 'local-w2' },
      status => { conditions => [{ type => 'Ready', status => 'Unknown' }] } },
] };
my $txt = $P->can('nodes_text')->($nodes);
like($txt, qr/^local-cp1\s+Ready\s+control-plane\s+\S+\s+v1\.36\.6$/m, 'ready control plane');
like($txt, qr/^local-w1\s+Ready,SchedulingDisabled\s+<none>/m, 'cordoned worker');
like($txt, qr/^local-w2\s+NotReady\s/m, 'not ready');
is(scalar(() = $txt =~ /\n/g), 3, 'one line per node, no header');
# what the callers match
ok($txt =~ /^\Qlocal-cp1\E\s+Ready/m, 'wait_node_ready matches');
is(scalar(() = $txt =~ /^\S+\s+Ready\b/gm), 2, 'restore counts Ready nodes');
is($P->can('nodes_text')->({}), '', 'empty list');

my $s = $P->can('sort_items_by')->({ items => [
    { lastTimestamp => '2026-11-13T02:00:00Z', n => 2 },
    { eventTime => '2026-11-13T01:00:00.000000Z', n => 1 },
    { lastTimestamp => '2026-11-13T03:00:00Z', n => 3 },
    { metadata => {}, n => 0 } ] }, 'lastTimestamp');
is_deeply([map { $_->{n} } $s->{items}->@*], [0, 1, 2, 3], 'events oldest first, undated first');

my $v = PVE::K8s::Provision::server_git_version(
    JSON::PP->new->encode({ serverVersion => { gitVersion => 'v1.36.6' } }));
is($v, 'v1.36.6', 'version text reads like kubectl version -o json');

# top pods from the metrics API, read back by the existing parser
my $tp = $plan->('top pods -A --no-headers');
is($tp->{reqs}[0]{path}, '/apis/metrics.k8s.io/v1beta1/pods', 'top pods: metrics API');
my $q = $P->can('k8s_quantity');
is($q->('250m'), 0.25, 'millicores');
is($q->('1500000n'), 0.0015, 'nanocores');
is($q->('2'), 2, 'cores');
is($q->('20Mi'), 20 * 1024**2, 'Mi');
is($q->('1G'), 1e9, 'decimal G');
is($q->('junk'), 0, 'unparsable is 0');
my $top = $P->can('top_pods_text')->({ items => [
    { metadata => { namespace => 'kube-system', name => 'coredns-1' },
      containers => [{ usage => { cpu => '1500000n', memory => '20480Ki' } }] },
    { metadata => { namespace => 'web', name => 'app-0' },
      containers => [{ usage => { cpu => '100m', memory => '64Mi' } },
          { usage => { cpu => '2m', memory => '1536Ki' } }] },
] });
like($top, qr/^kube-system\s+coredns-1\s+2m\s+20Mi$/m, 'CPU rounded up, like kubectl');
like($top, qr/^web\s+app-0\s+102m\s+65Mi$/m, 'containers summed, memory rounded down');
is_deeply(PVE::K8s::Provision::parse_top_pods($top),
    [{ namespace => 'kube-system', name => 'coredns-1', cpu_m => 2, mem_mi => 20 },
     { namespace => 'web', name => 'app-0', cpu_m => 102, mem_mi => 65 }],
    'the metrics panel parser reads it');

# moved PV/PVC: server-side apply instead of kubectl apply
my $ar = $P->can('apply_request');
my $pvr = $ar->({ apiVersion => 'v1', kind => 'PersistentVolume', metadata => { name => 'pvc-9' } });
is($pvr->{path}, '/api/v1/persistentvolumes/pvc-9?fieldManager=pve-k8s&force=true', 'PV path');
is($pvr->{type}, 'application/apply-patch+yaml', 'server-side apply (creates or updates)');
is($ar->({ kind => 'PersistentVolumeClaim', metadata => { name => 'data-0', namespace => 'web' } })->{path},
    '/api/v1/namespaces/web/persistentvolumeclaims/data-0?fieldManager=pve-k8s&force=true', 'PVC path');
is($ar->({ kind => 'Deployment', metadata => { name => 'x' } }), undef, 'other kinds: kubectl');
is($ar->({ kind => 'PersistentVolume', metadata => { name => '../x' } }), undef, 'bad names: kubectl');
is($ar->({ kind => 'PersistentVolumeClaim', metadata => { name => 'a' } }), undef, 'PVC needs a namespace');

# wiring
my $src = do { local $/; open my $f, '<', 'PVE/K8s/Provision.pm' or die; <$f> };
like($src, qr/if \(my \$plan = kubectl_api_plan\(\$args\)\) \{\n\s+my \$r = kubectl_api_run\(\$cp, \$plan\);\n\s+return kubectl_api_text\(\$plan, \$r->\{data\}\) if \$r;\n\s+\}\n\s+return guest_exec/,
    'kubectl_on: vsock first, guest exec otherwise');
like($src, qr/kubectl_api_plan\("\$args -o json"\)/, 'kubectl_json too');
is(scalar(() = $src =~ /cluster => \$name,\n\s+host => \$host,/g), 2,
    'nodes know their cluster (load_nodes and the scaler)');
like($src, qr/# vsock first \(no guest exec spent on the probe\), as in ops_cp/,
    'the scaler probes over vsock first');
like($src, qr/return undef if !\$name \|\| \$MINTING\{\$name\};/,
    'no vsock while minting the token that vsock needs');
like($src, qr/local \$MINTING\{\$name\} = 1;\n\s+my \$kc = kubeconfig_cluster/, 'minting is marked');
like($src, qr/VSOCK_SKIP\{\$name\} = \$now \+ \$VSOCK_SKIP_SECONDS/,
    'no credentials: vsock skipped for a while, cluster-wide');
like($src, qr/VSOCK_SKIP\{"vm:\$cp->\{vmid\}"\} = \$now/, 'dead channel: that VM only');
like($src, qr/kubectl_api_run\(\$candidate, \{ reqs => \[\{ method => 'GET',\n\s+path => '\/version' \}\] \}\)/,
    'ops_cp probes over vsock first');

like($src, qr/if \(my \$req = apply_request\(\$obj\)\) \{\n\s+return '' if kubectl_api_run/,
    'kubectl_apply_json: vsock first');

done_testing;
