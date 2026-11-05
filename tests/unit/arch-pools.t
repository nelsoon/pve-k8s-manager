# Unit tests: multi-arch node groups (T5.4) and the
# pools-update path for node-group editing (T5.3).
# Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Config;
use PVE::K8s::Provision;
use PVE::K8s::Scaler;

my $pools = PVE::K8s::Config::parse_pools(
    '[{"name":"default","size":2},'
    . '{"name":"arm","size":1,"arch":"arm64"}]', 9);
is($pools->[1]{arch}, 'arm64', 'pool arch carried');
ok(!eval {
    PVE::K8s::Config::parse_pools(
        '[{"name":"x","size":1,"arch":"ppc64"}]', 1); 1
}, 'unknown pool arch is rejected');

is(PVE::K8s::Provision::normalize_arch("x86_64\n"), 'amd64',
    'x86_64 maps to amd64');
is(PVE::K8s::Provision::normalize_arch("aarch64\n"), 'arm64',
    'aarch64 maps to arm64');
is(PVE::K8s::Provision::normalize_arch('sparc'), undef,
    'unknown uname maps to undef');

is(PVE::K8s::Provision::template_name_for('1.36', 2, 'amd64'),
    'k8s-node-1.36-r2', 'amd64 template keeps legacy name');
is(PVE::K8s::Provision::template_name_for('1.36', 2, 'arm64'),
    'k8s-node-1.36-r2-arm64', 'arm64 template is suffixed');
is(PVE::K8s::Provision::template_name_for('1.36', 2, undef),
    'k8s-node-1.36-r2', 'unset arch keeps legacy name');

my $list = join("\n",
    ' 100 k8s-node-1.36-r1 running',
    ' 101 k8s-node-1.36-r2 running',
    ' 102 k8s-node-1.36-r1-arm64 running',
    ' 103 k8s-node-1.36-r3-arm64 running');
my ($id, $rev) = PVE::K8s::Provision::find_template_in_list(
    $list, '1.36');
is($id, 101, 'amd64 lookup ignores arm64 templates');
is($rev, 2, 'amd64 lookup takes highest amd64 rev');
($id, $rev) = PVE::K8s::Provision::find_template_in_list(
    $list, '1.36', 'arm64');
is($id, 103, 'arm64 lookup finds arm64 templates');
is($rev, 3, 'arm64 lookup takes highest arm64 rev');

my $labels = PVE::K8s::Scaler::pool_node_labels(
    { name => 'arm', arch => 'arm64' });
is($labels->{'kubernetes.io/arch'}, 'arm64',
    'simulated group nodes carry the arch label');
$labels = PVE::K8s::Scaler::pool_node_labels({ name => 'default' });
ok(!exists $labels->{'kubernetes.io/arch'},
    'unpinned groups simulate without an arch label');

my $api = do {
    open(my $fh, '<', 'PVE/API2/Cluster/K8s.pm') or die $!;
    local $/;
    <$fh>;
};
like($api, qr{pools => \{\n                type => 'string',\n                optional => 1,\n                description => "Worker node groups},
    'cluster update accepts pools (node groups)');
like($api, qr{'cp-arch' => \{\n                type => 'string',\n                pattern => '\^\(amd64\|arm64\)\$'},
    'create accepts cp-arch');

my $src = do {
    open(my $fh, '<', 'PVE/K8s/Provision.pm') or die $!;
    local $/;
    <$fh>;
};
like($src, qr{set_cluster_options.*?opts->\{pools\}}s,
    'set_cluster_options stores validated pools');
unlike($src, qr{linux/amd64/kubeadm},
    'kubeadm download is not hardcoded to amd64');

my $addons = do {
    open(my $fh, '<', 'PVE/K8s/Addons.pm') or die $!;
    local $/;
    <$fh>;
};
unlike($addons, qr{linux-amd64},
    'helm download is not hardcoded to amd64');
like($addons, qr{HA=\$\(uname -m\)},
    'helm arch derives from the guest arch');

done_testing();
