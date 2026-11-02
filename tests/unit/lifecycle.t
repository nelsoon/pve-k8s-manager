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

done_testing();
