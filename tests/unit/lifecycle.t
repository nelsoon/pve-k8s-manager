# Lifecycle additions: certificate expiry parsing, cluster
# power ordering, plugin template build wiring.
# Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

my $sample = <<'EOF';
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Nov 01, 2027 03:46 UTC   364d            ca                      no
apiserver                  Nov 01, 2027 03:46 UTC   364d            ca                      no
etcd-peer                  Dec 05, 2026 03:46 UTC   20d             etcd-ca                 no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Nov 01, 2035 03:46 UTC   3285d           no
etcd-ca                 Nov 01, 2035 03:46 UTC   3285d           no
EOF

my $rows = PVE::K8s::Provision::parse_cert_expiration($sample);
is($rows->@*, 5, 'all cert and CA rows parsed');
is($rows->[0]{certificate}, 'admin.conf', 'cert name parsed');
is($rows->[0]{days}, 364, 'residual days parsed');
is($rows->[0]{level}, 'ok', 'a year out is ok');
is($rows->[2]{level}, 'critical', '20d out is critical');
is($rows->[3]{days}, 3285, 'CA residual parsed');
is(PVE::K8s::Provision::parse_cert_expiration('')->@*, 0,
    'empty output parses to no rows');
is(PVE::K8s::Provision::parse_cert_expiration(undef)->@*, 0,
    'undef output parses to no rows');

my $soon = PVE::K8s::Provision::parse_cert_expiration(
    "apiserver  Jan 15, 2027 03:46 UTC  45d  ca  no\n");
is($soon->[0]{level}, 'warning', '45d out is warning');

my @nodes = (
    { host => 'c-w1', role => 'worker' },
    { host => 'c-cp1', role => 'cp' },
    { host => 'c-w2', role => 'worker' },
    { host => 'c-cp2', role => 'cp' },
);
my $start = PVE::K8s::Provision::power_order(\@nodes, 'start');
is(join(',', map { $_->{host} } $start->@*), 'c-cp1,c-cp2,c-w1,c-w2',
    'power start is control-plane first');
my $stop = PVE::K8s::Provision::power_order(\@nodes, 'stop');
is(join(',', map { $_->{host} } $stop->@*), 'c-w1,c-w2,c-cp1,c-cp2',
    'power stop is workers first');

# Static wiring: endpoints exist and join tokens are minted
# fresh per attempt (never stored in the record).
my $src = do {
    open(my $fh, '<', 'PVE/K8s/Provision.pm') or die $!;
    local $/; <$fh>;
};
like($src, qr/sub build_template/, 'plugin builds templates');
like($src, qr/assert_supported_version/, 'build is version-gated');
like($src, qr/kubeadm token create --print-join-command/,
    'join token minted fresh at join time');
like($src, qr/sub cert_expiry/, 'cert expiry live path exists');

my $api = do {
    open(my $fh, '<', 'PVE/API2/Cluster/K8s.pm') or die $!;
    local $/; <$fh>;
};
like($api, qr{path => '\{name\}/certificates'},
    'certificates endpoint registered');
like($api, qr{path => '\{name\}/power'},
    'power endpoint registered');
like($api, qr{'builder-ip'},
    'create accepts builder-ip for self-built templates');
like($src, qr/no template for \$version; building one/,
    'provision builds a missing template itself');
my $cfg = do {
    open(my $fh, '<', 'PVE/K8s/Config.pm') or die $!;
    local $/; <$fh>;
};
like($cfg, qr{'builder-ip' => \{\s*type => 'string'},
    'cluster schema accepts builder-ip');

my $deps = PVE::K8s::Provision::deployment_rows({
    items => [{
        metadata => { name => 'web', namespace => 'app' },
        spec => { replicas => 3 },
        status => { readyReplicas => 2, updatedReplicas => 3,
            availableReplicas => 2 },
    }],
});
is($deps->[0]{ready}, '2/3', 'deployment ready ratio built');
is($deps->[0]{uptodate}, 3, 'deployment uptodate count');

my $pods = PVE::K8s::Provision::pod_rows({
    items => [{
        metadata => { name => 'web-x', namespace => 'app' },
        spec => { nodeName => 'c-w1' },
        status => { phase => 'Running', containerStatuses => [
            { ready => 1, restartCount => 2 },
            { ready => JSON::PP::false, restartCount => 1 },
        ] },
    }],
});
is($pods->[0]{ready}, '1/2', 'pod ready ratio counts containers');
is($pods->[0]{restarts}, 3, 'pod restarts sum containers');

my $svcs = PVE::K8s::Provision::service_rows({
    items => [{
        metadata => { name => 'web', namespace => 'app' },
        spec => { type => 'LoadBalancer',
            clusterIP => '10.96.0.5',
            ports => [{ port => 80, nodePort => 30080 }] },
        status => { loadBalancer =>
            { ingress => [{ ip => '10.0.0.9' }] } },
    }, {
        metadata => { name => 'db', namespace => 'app' },
        spec => { clusterIP => '10.96.0.6',
            ports => [{ port => 5432 }] },
    }],
});
is($svcs->[0]{externalip}, '10.0.0.9', 'LB external IP surfaced');
is($svcs->[0]{ports}, '80:30080', 'service ports with nodePort');
is($svcs->[1]{type}, 'ClusterIP', 'service type defaults');

my $top = PVE::K8s::Provision::parse_top_pods(
    "default web-abc 12m 128Mi\n"
    . "kube-system big-xyz 1500m 1Gi\n"
    . "not a metrics line\n");
is($top->@*, 2, 'top pods parses metric lines only');
is($top->[0]{cpu_m}, 12, 'top pods CPU millicores');
is($top->[1]{mem_mi}, 1024, 'top pods Gi converts to Mi');

like($api, qr{path => '\{name\}/workloads'},
    'workloads endpoint registered');
like($api, qr{path => '\{name\}/metrics'},
    'metrics endpoint registered');
like($api, qr{addons/\{addon\}/disable'},
    'addon disable endpoint registered');
like($src, qr/sub disable_addon/, 'disable_addon exists');
like($src, qr/metrics-server/, 'metrics-server addon wired');

done_testing();
