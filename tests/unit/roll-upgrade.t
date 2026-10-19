# Unit tests: maintenance window logic and the one-minor
# upgrade skew gate (T2.2/T2.3). Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

# 2026-10-17 12:00 local-ish epoch is host-dependent; use a
# fixed localtime by constructing from localtime components
my $noon = do {
    my @lt = localtime();
    $lt[2] = 12; $lt[1] = 0; $lt[0] = 0;
    require POSIX;
    POSIX::mktime(@lt);
};
ok(PVE::K8s::Provision::in_maintenance_window('09:00-17:00', $noon),
    'midday is inside a 09:00-17:00 window');
ok(!PVE::K8s::Provision::in_maintenance_window('02:00-04:00', $noon),
    'midday is outside a 02:00-04:00 window');
ok(PVE::K8s::Provision::in_maintenance_window('22:00-13:00', $noon),
    'overnight window wraps past midnight');
ok(PVE::K8s::Provision::in_maintenance_window(undef, $noon),
    'no window means always allowed');

is(PVE::K8s::Provision::assert_minor_upgrade('1.31', '1.32'), '1.32',
    'one minor up is allowed');
is(PVE::K8s::Provision::assert_minor_upgrade('1.31', '1.32.2'), '1.32',
    'a patch-qualified target is read as its minor');
ok(!eval { PVE::K8s::Provision::assert_minor_upgrade('1.31', '1.33'); 1 },
    'a two-minor jump is blocked');
ok(!eval { PVE::K8s::Provision::assert_minor_upgrade('1.31', '1.31'); 1 },
    'same version is not an upgrade');
ok(!eval { PVE::K8s::Provision::assert_minor_upgrade('1.31', '1.30'); 1 },
    'a downgrade is blocked');

my $api = do { open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!; local $/; <$fh> };
like($api, qr/fork_worker\('k8sroll'/, 'roll endpoint runs as a k8sroll task');
like($api, qr/fork_worker\('k8supgrade'/, 'upgrade endpoint runs as a k8supgrade task');

# etcd operations must not depend on crictl (absent from
# current Kubernetes images); they run via ctr instead.
my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};
unlike($prov, qr/crictl (?:ps|exec)/, 'etcd operations do not shell out to crictl');
like($prov, qr/ctr -n k8s\.io run --rm --net-host/,
    'etcdctl runs as a one-off ctr container');
like($prov, qr/assert_cluster_hosts_online\(\$name, \$scfg\)/,
    'provision checks the cluster hosts before running');
like($prov, qr/they host nodes of cluster/,
    'only hosts carrying its nodes block provisioning');
like($prov, qr/placement will skip them/,
    'other offline hosts are skipped, not fatal');
like($api, qr/fork_worker\('k8sscale'/,
    'scale endpoint runs as a k8sscale task');

done_testing();
