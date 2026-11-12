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
for my $field (qw(name k8s-version cp node-subnet public-subnet gateway lb-range storage resilience sdn-zone cp-arch)) {
    like($js, qr/name: '\Q$field\E'/, "create wizard has the $field field");
}
like($js, qr/name: 'storage-profile'/,
    'bundle still submits the storage profile');
like($js, qr/name: 'cp-policy'/,
    'bundle still submits the CP policy');
like($js, qr/delete values\.resilience/,
    'resilience preset itself is never submitted');
for my $field (qw(workers pools)) {
    unlike($js, qr/name: '\Q$field\E'/, "create wizard has no $field field");
}
like($js, qr|'/cluster/k8s/' \+ encodeURIComponent\(name\) \+ '/provision'|,
    'create provisions the cluster it just created');
like($js, qr/Proxmox\.window\.TaskViewer/,
    'provisioning progress is shown as a PVE task');
like($js, qr/dataIndex: 'state'/, 'grid shows cluster health/state');
unlike($js, qr/flannel/i, 'no reference to the removed Flannel bootstrap');

my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/fork_cluster_worker\('k8sprovision'/,
    'provision endpoint runs as a k8sprovision PVE task (UPID)');
like($js, qr/Ext\.create\('Proxmox\.window\.SafeDestroy'.*?url: '\/cluster\/k8s\/' \+ encodeURIComponent\(name\)/s,
    'destroy deletes through the REST API behind the stock type-the-name dialog');
unlike($js, qr/Delete cluster \{0\} and all its VMs\?/,
    'no plain yes/no box guards cluster destruction');
like($api, qr/fork_cluster_worker\('k8sdelete'/,
    'delete endpoint runs as a k8sdelete PVE task (UPID)');


# T2.5 day-2 ops: kubeconfig, events, per-node drain/replace
like($api, qr/fork_cluster_worker\('k8snodedrain'/,
    'node drain endpoint runs as a k8snodedrain task');
like($api, qr/fork_cluster_worker\('k8snodereplace'/,
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
like($api, qr/fork_cluster_worker\('k8snodeforceretire'/,
    'force-retire endpoint runs as a k8snodeforceretire task');
like($api, qr/fork_cluster_worker\('k8sbackup'/,
    'backup endpoint runs as a k8sbackup task');
like($api, qr/fork_cluster_worker\('k8srestore'/,
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
like($js, qr/xtype: 'pveStorageSelector',\s+name: 'storage',\s+fieldLabel: gettext\('Storage'\),\s+clusterView: true/,
    'create selects storage with the stock storage selector');
like($js, qr{/api2/json/cluster/sdn/zones},
    'create selects the SDN zone from existing zones');
like($js, qr{'cp-arch'}, 'create offers control-plane architecture');
like($js, qr{method: 'PUT',\n                    params: \{ pools:},
    'node groups save through the pools update');
like($js, qr{url: '/cluster/k8s/' \+ name \+ '/provision',\n                            method: 'POST'},
    'group save converges membership via provision');
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

# UI polish step 1: the stock create dialog with one visible field.
like($js, qr/Ext\.define\('PVE\.dc\.K8sCreateWindow', \{\s+extend: 'Proxmox\.window\.Edit'/,
    'create is a stock Proxmox.window.Edit');
like($js, qr/Ext\.create\('Proxmox\.panel\.InputPanel'/,
    'create uses the stock InputPanel (Advanced checkbox included)');
my ($create) = $js =~ /(Ext\.define\('PVE\.dc\.K8sCreateWindow'.*?\n\}\);)/s;
my ($main) = $create =~ /column1: \[(.*?)\n            \],\n            columnB/s;
my @shown = $main =~ /name: '([a-z-]+)'/g;
is_deeply(\@shown, [qw(name public-subnet sdn-zone)],
    'only the name and the optional network fields are in the default view');
like($create, qr/advancedColumn1/, 'every other setting sits under Advanced');
like($create, qr/This creates/, 'a summary line shows what the defaults will create');
like($create, qr/No shared storage is configured/,
    'the HA restriction is explained only when it applies');
like($api, qr/'k8s-version' => \{[^}]*optional => 1/s,
    'k8s-version is optional through the API (default: newest supported)');

# Step 3: node group editor on the stock window; autoscale is one checkbox.
like($js, qr/Ext\.define\('PVE\.dc\.K8sGroupWindow', \{\s+extend: 'Proxmox\.window\.Edit'/,
    'node group editor is a stock Proxmox.window.Edit');
like($js, qr/name: 'autoscale'/, 'autoscale is a single checkbox');
like($js, qr/let min = autoscale \? parseInt\(v\.min, 10\) : size;/,
    'without autoscale min and max equal the node count');
my ($grp) = $js =~ /(Ext\.define\('PVE\.dc\.K8sGroupWindow'.*?\n\}\);)/s;
is(scalar(() = $grp =~ /autoSelect: false/g), 2,
    'stock selectors in the group editor do not auto-pick the first entry');

# Step 4: upgrade shows the pre-flight; rebuild-template is reachable.
like($js, qr/Ext\.define\('PVE\.dc\.K8sUpgradeWindow', \{\s+extend: 'Proxmox\.window\.Edit'/,
    'upgrade is a stock Edit window');
like($js, qr{/upgrade-check'}, 'upgrade reads the pre-flight before running');
like($js, qr/Resolve the blocking checks first/, 'blocking checks disable the Upgrade button');
like($js, qr/submitValue: false/, 'gate and acknowledgement are never sent to the API');
unlike($js, qr/Target version \(one minor up/,
    'the target version is no longer typed by hand');
like($js, qr{/rebuild-template'}, 'the image can be rebuilt from the UI');
like($js, qr/name: 'severity'/, 'rebuild asks for the reason (severity)');

# Step 5: Settings is a stock ObjectGrid with per-row editing and `delete`.
like($js, qr/Ext\.define\('PVE\.dc\.K8sSettings', \{\s+extend: 'Proxmox\.grid\.ObjectGrid'/,
    'settings are a stock ObjectGrid');
my $nd = () = $js =~ /deleteEmpty: true/g;
ok($nd >= 3, 'settings that can be set can be cleared (deleteEmpty)');
unlike($js, qr/Details \(read-only\)/, 'no second read-only block next to the settings');
like($api, qr/delete => \{/, 'the update API accepts delete');

# Overview columns stay balanced.
my ($hc) = $js =~ /itemId: 'healthCol',\s+items: \[(.*?)\]/s;
my ($oc) = $js =~ /itemId: 'opsCol',\s+items: \[(.*?)\]/s;
my @hc = $hc =~ /(\w+Info)/g;
my @oc = $oc =~ /(\w+Info)/g;
is(scalar @hc, scalar @oc, 'overview columns have the same number of rows');

done_testing();
