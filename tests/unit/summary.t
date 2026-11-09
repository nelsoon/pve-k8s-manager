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
like($js, qr/CartesianChart/, 'charts use the stock Ext chart type');
my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/; <$fh>;
};
like($prov, qr/Hour series for the Summary charts/,
    'metrics carry per-node hour series');
like($prov, qr/Cluster-average hour series/,
    'summary aggregates the series for charts');

done_testing();
