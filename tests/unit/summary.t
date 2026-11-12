# Unit tests: Increment 7 Summary verdict and LB pool
# sizing (pure helpers behind GET /cluster/k8s/{name}/summary).
# Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

is(PVE::K8s::Provision::summary_health('ready', 3, 3, 5, 5),
    'ok', 'all ready is ok');
is(PVE::K8s::Provision::summary_health('ready', 3, 3, 4, 5),
    'degraded', 'a missing node degrades');
is(PVE::K8s::Provision::summary_health('ready', 3, 2, 4, 5),
    'degraded', 'quorum held but CP short degrades');
is(PVE::K8s::Provision::summary_health('ready', 3, 1, 3, 5),
    'down', 'lost etcd quorum is down');
is(PVE::K8s::Provision::summary_health('ready', 1, 1, 2, 2),
    'ok', 'single CP healthy');
is(PVE::K8s::Provision::summary_health('provisioning', 3, 0, 0, 5),
    'provisioning', 'non-ready state passes through');
is(PVE::K8s::Provision::summary_health('ready', 3, undef, undef, undef),
    'unknown', 'no live data is unknown, not ok');

is(PVE::K8s::Provision::lb_pool_size(
        { 'lb-range' => '192.168.3.100-192.168.3.120' }),
    21, 'explicit LB range sized');
is(PVE::K8s::Provision::lb_pool_size(
        { 'public-subnet' => '192.168.3.0/24' }),
    21, 'public subnet defaults to the .100-.120 pool');
is(PVE::K8s::Provision::lb_pool_size({}), 0,
    'no public addressing means no LB pool');

is(PVE::K8s::Provision::worst_cert_days(
        [{ days => 364 }, { days => 90 }, { days => undef }]),
    90, 'worst leaf cert wins, CA rows ignored');
is(PVE::K8s::Provision::worst_cert_days([{ days => undef }]),
    undef, 'CA-only data has no cert_days');
is(PVE::K8s::Provision::worst_cert_days([]), undef,
    'no cert data has no cert_days');

my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/; <$fh>;
};
like($api, qr/name => 'summary'/,
    'summary endpoint registered');
my $js = do {
    open my $fh, '<', 'www/manager6/PVEK8sWorkspace.js' or die $!;
    local $/; <$fh>;
};
like($js, qr{/summary'}, 'overview fetches the summary aggregate');
like($js, qr/summaryChart/, 'overview renders capacity charts');
like($js, qr/Proxmox\.widget\.RRDChart/, 'charts use the stock RRD chart widget');
like($js, qr/timeout: 120000/, 'summary request outlives the slow aggregate read');
unlike($js, qr/title: gettext\('Node CPU \(last hour\)'\)/,
    'charts are not nested in a second titled card');
like($js, qr/Proxmox\.panel\.GaugeWidget/, 'resources use the stock gauge widget');
like($js, qr/updateColumns/, 'summary uses the stock responsive column layout');
like($js, qr/checkIcon\(s\.cp_ready >= s\.cp/,
    'health rows carry per-check status icons');
like($js, qr/title: gettext\('Overview'\)/,
    'top card is an Overview, host-Summary style');
like($js, qr/Node VMs CPU \(cluster average %\)/,
    'chart title says node-VM cluster average');
unlike($js, qr/title: gettext\('Details'\)/,
    'no Details card duplicating Settings');
like($js, qr/CPU Cores/, 'node group editor exposes CPU sizing');
like($js, qr/Device Profile \(GPU\)/,
    'node group editor exposes the device profile');
like($js, qr|/cluster/mapping/pci|,
    'device profile is picked from PCI mappings, not typed');
like($js, qr/multiSelect: true/,
    'PVE hosts are picked from a multi-select');
my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/; <$fh>;
};
like($prov, qr/Hour series for the Summary charts/,
    'metrics carry per-node hour series');
like($prov, qr/Cluster-average hour series/,
    'summary aggregates the series for charts');
like($prov, qr/metrics_cluster\(\$name, \{ light => 1 \}\)/,
    'summary uses the light metrics path (no pod top)');
like($prov, qr/in parallel: sequential/,
    'node RRD fetches run in parallel');
like($prov, qr/get pods,services -A/,
    'summary reads pods and services in one kubectl call');
like($prov, qr/sub kubectl_json_batch|kubectl_json_batch/,
    'kubectl reads batch behind one guest exec');
like($prov, qr/PVE::RRD::create_rrd_data/,
    'node RRD is read in-process, no ssh/pvesh spawn');
like($prov, qr/SUMMARY_CACHE_TTL = 60/,
    'summary aggregate is cached for 60s');
like($prov, qr/`qm stop` returns\s+# before the guest has finished stopping/,
    'node removal waits for the stop before destroy');
like($prov, qr/map \{ kubectl_cmd\("\$_ -o json"\) \}/,
    'every batched segment carries the kubectl prefix');
like($prov, qr/summary_cache_write\(\$name, \$out\) if \$out->\{live\}/,
    'degraded summaries are not cached');
like($prov, qr/sub k8s_api_get/,
    'reads can go over the vsock API transport');
like($prov, qr/Stop is async; wait for it so the destroy/,
    'cluster delete waits for stop before destroy');
like($prov, qr/the builder boots with DHCP/,
    'template auto-build uses DHCP when no builder IP is set');
like($prov, qr/alongside a static builder IP/,
    'template build still accepts a pinned static IP');
like($prov, qr/vhost-vsock-pci,id=vsock0/,
    'control planes receive a vsock device at create');
like($prov, qr/sub ensure_vsock_proxy/,
    'provision installs the in-guest vsock proxy');
my $vtool = do {
    open my $fh, '<', 'tools/pve-k8s-vsock-get' or die $!;
    local $/; <$fh>;
};
like($vtool, qr/AF_VSOCK is family 40|family 40/,
    'vsock client speaks AF_VSOCK');
my $makefile = do {
    open my $fh, '<', 'Makefile' or die $!;
    local $/; <$fh>;
};
like($makefile, qr/tools\/pve-k8s-vsock-get/,
    'vsock client ships in the deb');

done_testing();
