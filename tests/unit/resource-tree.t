# Unit test: Kubernetes clusters as datacenter-wide Proxmox
# resources for the first/left resource panel.
# Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Config;

my $entries = PVE::K8s::Config::resource_entries({
    ids => {
        zeta => { state => 'ready' },
        alpha => {},
    },
});

is_deeply($entries, [
    {
        id => 'k8s/alpha',
        type => 'k8s',
        name => 'alpha',
        k8s => 'alpha',
        status => 'unknown',
    },
    {
        id => 'k8s/zeta',
        type => 'k8s',
        name => 'zeta',
        k8s => 'zeta',
        status => 'ready',
    },
], 'clusters become sorted datacenter-wide k8s resources');

ok(!exists $entries->[0]{node},
    'a Kubernetes cluster has no owning PVE node');
ok(!exists $entries->[0]{vmid},
    'a Kubernetes cluster has no VMID');
is_deeply(PVE::K8s::Config::resource_entries(undef), [],
    'missing config yields no resources');
is_deeply(PVE::K8s::Config::resource_entries({}), [],
    'empty config yields no resources');

my $integrate = do {
    open my $fh, '<', 'debian/integrate.pl' or die $!;
    local $/;
    <$fh>;
};
like($integrate, qr/PVE::K8s::Config::resource_entries/,
    'stock resources endpoint is extended with k8s entries');
like($integrate, qr/case 'k8s': return 5;/,
    'resource tree ordering knows the k8s type');
like($integrate, qr/k8s: 'pveK8sConfig'/,
    'workspace routes k8s resources to the cluster page xtype');

done_testing();
