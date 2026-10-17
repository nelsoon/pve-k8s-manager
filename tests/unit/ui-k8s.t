# Unit test: the Datacenter -> Kubernetes panel (T1.6) stays a
# thin client of the REST API: grid over /cluster/k8s, a create
# wizard that creates then provisions, and provisioning shown
# as a PVE task. Run via `make test`.
use strict;
use warnings;
use Test::More;

my $js = do {
    open my $fh, '<', 'www/manager6/PVEK8sWorkspace.js' or die $!;
    local $/;
    <$fh>;
};

like($js, qr/Ext\.define\('PVE\.dc\.K8sView'/,
    'Kubernetes view is defined in the Datacenter namespace');
like($js, qr/alias: 'widget\.pveDcK8sView'/,
    'view registers the pveDcK8sView xtype used by the dc.Config tab');
like($js, qr|url: '/api2/json/cluster/k8s'|,
    'grid reads the cluster list from the REST API');
for my $field (qw(name k8s-version cp workers node-subnet gateway lb-range storage)) {
    like($js, qr/name: '\Q$field\E'/, "create wizard has the $field field");
}
like($js, qr|url: '/cluster/k8s/' \+ values\.name \+ '/provision'|,
    'wizard provisions the cluster it just created');
like($js, qr/Proxmox\.window\.TaskViewer/,
    'provisioning progress is shown as a PVE task');
like($js, qr/dataIndex: 'state'/, 'grid shows cluster health/state');
unlike($js, qr/flannel/i, 'no reference to the removed Flannel bootstrap');

my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/fork_worker\('k8sprovision'/,
    'provision endpoint runs as a k8sprovision PVE task (UPID)');

done_testing();
