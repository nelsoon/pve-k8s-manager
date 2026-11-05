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
for my $field (qw(name k8s-version cp node-subnet gateway lb-range storage sdn-zone cp-arch)) {
    like($js, qr/name: '\Q$field\E'/, "create wizard has the $field field");
}
for my $field (qw(workers pools)) {
    unlike($js, qr/name: '\Q$field\E'/, "create wizard has no $field field");
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

# Specific clusters are selected in Proxmox's first/left
# resource panel and opened as PVE.k8s.Config. That page
# fixes the selected cluster and navigates VM-style: a
# stock pve-nav treelist (the PVE.panel.Config look) as
# second sidebar switching a card panel. The Datacenter
# view is only the cluster list with Create/Destroy.
like($js, qr/Ext\.define\('PVE\.k8s\.Config'/,
    'specific-cluster page is defined');
like($js, qr/layout: 'card'/,
    'cluster panels are cards switched by the menu');
like($js, qr/region: 'west'/,
    'second sidebar sits in the west region');
like($js, qr/ui: 'pve-nav'/,
    'second sidebar uses the stock pve-nav treelist style');
like($js, qr/header: false/,
    'no separate title header (single top bar, VM-page style)');
like($js, qr/baseCls: 'x-panel-header-text'/,
    'title lives inside the top toolbar as tbtext');
like($js, qr/Ext\.list\.Tree/,
    'second sidebar is a treelist like VM pages');
like($js, qr/fixedClusterName/,
    'resource-selected cluster is fixed in its page');
like($js, qr/interval: 30000/,
    'cluster view refreshes itself on a poll (no Reload button)');
like($js, qr/if \(!fixedClusterName\) \{\n            \/\/ Datacenter/,
    'Datacenter view is the list-only branch');
unlike($js, qr/tabPosition/,
    'no tab strip on the cluster page');
unlike($js, qr/'pool-min'/, 'create has no pool bounds fields');
unlike($js, qr/Worker Pools \(JSON/, 'create has no pools JSON field');
like($js, qr{/api2/json/storage},
    'create selects storage from existing storages');
like($js, qr{/api2/json/cluster/sdn/zones},
    'create selects the SDN zone from existing zones');
like($js, qr{'cp-arch'}, 'create offers control-plane architecture');
like($js, qr{method: 'PUT',\n                    params: \{ pools:},
    'node groups save through the pools update');
like($js, qr{Node Groups}, 'nodes view manages node groups');
unlike($js, qr/title: gettext\('Node Groups'\)/,
    'no blue title bar over the node groups grid');
unlike($js, qr/title: gettext\('Clusters'\)/,
    'no blue title bar over the cluster list');
like($js, qr/text: gettext\('More'\)/,
    'destroy sits under a More menu like a VM page');
like($js, qr/fa fa-check good/,
    'overview state carries the stock ready icon');
ok((grep { /header: false/ } split /\n/, $js) >= 8,
    'section panels render without header bars');
# this Ext build drops toolbar items sharing an itemId
# (only the last survives: Drain/Replace/Edit vanished);
# selection-scoped buttons use a marker property instead
unlike($js, qr/itemId: 'nodebtn'/, 'node buttons share no itemId');
unlike($js, qr/itemId: needsSel/, 'group buttons share no itemId');
like($js, qr/button\[nodebtn\]/, 'node buttons toggle via marker query');
like($js, qr/button\[groupbtn\]/, 'group buttons toggle via marker query');
for my $panel (qw(overview nodes workloads metrics addons
    events backups settings)) {
    like($js, qr/'\Q$panel\E'/, "tree offers the $panel panel");
}
like($js, qr|'/workloads'|,
    'workloads panel reads the workloads endpoint');
like($js, qr|'/metrics'|,
    'metrics panel reads the metrics endpoint');
like($js, qr|'/certificates'|,
    'overview shows certificate expiry');
like($api, qr/name => 'workloads'/, 'workloads endpoint exists');
like($api, qr/name => 'metrics'/, 'metrics endpoint exists');

done_testing();
