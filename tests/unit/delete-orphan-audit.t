# Unit tests: `qm list` parsing behind the delete orphan
# audit (T4.1 lab find). /cluster/resources can silently
# omit VMs on a host whose status view is stale, so delete
# cross-checks every host's own `qm list`; this parser is
# what that cross-check feeds on. Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

my $out = <<'EOF';
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 t41-cp1              stopped    3072              20.00 0
       101 k8s-node-1.35-r2     stopped    4096              20.00 0
       104 t41-cp3              running    3072              20.00 123456
EOF

my $vms = PVE::K8s::Provision::parse_qm_list($out);
is_deeply($vms, {
    't41-cp1' => 100,
    'k8s-node-1.35-r2' => 101,
    't41-cp3' => 104,
}, 'qm list parses vmid by name, header skipped');

is_deeply(PVE::K8s::Provision::parse_qm_list(''),
    {}, 'empty output parses empty');
is_deeply(PVE::K8s::Provision::parse_qm_list(undef),
    {}, 'undef output parses empty');

my $cluster_only = {
    map { $_ => $vms->{$_} }
    grep { /^\Qt41\E-/ } keys $vms->%*
};
is_deeply($cluster_only, { 't41-cp1' => 100, 't41-cp3' => 104 },
    'cluster prefix filter keeps node VMs, drops templates');

done_testing();
