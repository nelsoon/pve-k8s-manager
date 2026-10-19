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
for my $field (qw(name k8s-version cp workers pools node-subnet gateway lb-range storage)) {
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
like($js, qr/method: 'DELETE'/,
    'grid Remove button deletes through the REST API');
like($api, qr/fork_worker\('k8sdelete'/,
    'delete endpoint runs as a k8sdelete PVE task (UPID)');


# T2.5 day-2 ops: kubeconfig, events, per-node drain/replace
like($api, qr/fork_worker\('k8snodedrain'/,
    'node drain endpoint runs as a k8snodedrain task');
like($api, qr/fork_worker\('k8snodereplace'/,
    'node replace endpoint runs as a k8snodereplace task');
like($api, qr/name => 'kubeconfig'/,
    'kubeconfig endpoint exists');
like($js, qr|'/kubeconfig'|,
    'UI fetches the kubeconfig from the REST API');
like($js, qr|'/events'|,
    'UI events view reads the events endpoint');
like($js, qr|'/nodes/' \+ node|,
    'UI node actions call the per-node endpoints');
like($js, qr/create token|a\.download = name \+ '\.kubeconfig'/,
    'UI offers the kubeconfig as a download');


# T2.6 force-retire and T3.1 backup/restore endpoints
like($api, qr/fork_worker\('k8snodeforceretire'/,
    'force-retire endpoint runs as a k8snodeforceretire task');
like($api, qr/fork_worker\('k8sbackup'/,
    'backup endpoint runs as a k8sbackup task');
like($api, qr/fork_worker\('k8srestore'/,
    'restore endpoint runs as a k8srestore task');
like($js, qr|'/force-retire'|,
    'UI node actions include force-retire');
like($js, qr|'/backup'|,
    'UI has an etcd backup action');
like($js, qr|'/restore'|,
    'UI has an etcd restore action');
my $provsrc = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};
like($provsrc, qr/node \$host is Ready; use drain\/replace instead/,
    'force-retire refuses a healthy node');
like($provsrc, qr/etcdutl snapshot restore/,
    'restore uses etcdutl snapshot restore per member');

like($provsrc, qr/if \(!\$destroyed\) \{\n            my \$retired/,
    'ghost marker only kept when the destroy failed');

done_testing();
