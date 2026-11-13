# Unit test: T3.3 add-on catalog and opt-in install commands.
# Cilium ingress/Gateway ships with the CNI; cert-manager and
# external-dns stay "unconfigured" until enabled. Run via
# `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Addons;
require PVE::K8s::Provision;

# --- cert-manager issuers
my $ca = PVE::K8s::Addons::certmanager_issuer_yaml({});
like($ca, qr/kind: ClusterIssuer\nmetadata: \{name: selfsigned\}/,
    'default issuer chain starts from a self-signed issuer');
like($ca, qr/metadata: \{name: pve-k8s-ca\}/,
    'default ClusterIssuer is the internal CA (pve-k8s-ca)');
like($ca, qr/ca: \{secretName: pve-k8s-ca\}/,
    'CA issuer signs from the CA secret');

my $acme = PVE::K8s::Addons::certmanager_issuer_yaml(
    { issuer => 'acme', email => 'ops@example.com' });
like($acme, qr/email: ops\@example\.com/,
    'ACME issuer carries the account email');
like($acme, qr/ingress: \{ingressClassName: cilium\}/,
    'ACME HTTP-01 solver uses the Cilium ingress class');
ok(!eval { PVE::K8s::Addons::certmanager_issuer_yaml(
        { issuer => 'acme' }); 1 },
    'ACME issuer without an email is rejected');
ok(!eval { PVE::K8s::Addons::certmanager_issuer_yaml(
        { issuer => 'bogus' }); 1 },
    'unknown issuer types are rejected');

my $cm_cmd = PVE::K8s::Addons::certmanager_install_cmd(
    '/etc/kubernetes/admin.conf', $ca);
like($cm_cmd, qr{cert-manager/releases/download/v\d+\.\d+\.\d+/cert-manager\.yaml},
    'cert-manager installs from the pinned upstream manifest');
like($cm_cmd, qr/rollout status deploy\/cert-manager-webhook/,
    'install waits for the cert-manager webhook');

# --- external-dns
my $dns_values = PVE::K8s::Addons::external_dns_values_yaml(
    'lab1', { 'pdns-url' => 'http://dns.example.com:8081/api/v1/servers/localhost',
        zone => 'example.com' });
like($dns_values, qr/name: pdns/, 'external-dns uses the pdns provider');
like($dns_values, qr/domainFilters: \["example\.com"\]/,
    'external-dns is scoped to the configured zone');
like($dns_values, qr/txtOwnerId: "pve-k8s-lab1"/,
    'TXT registry ownership is per-cluster');
like($dns_values, qr/sources: \[ingress, gateway-httproute\]/,
    'external-dns watches Ingress and Gateway HTTPRoutes');
ok(!eval { PVE::K8s::Addons::external_dns_values_yaml(
        'lab1', { zone => 'example.com' }); 1 },
    'external-dns without a pdns-url is rejected');
ok(!eval { PVE::K8s::Addons::external_dns_values_yaml(
        'lab1', { 'pdns-url' => 'http://x', provider => 'route53' }); 1 },
    'non-pdns providers are rejected for now');

my $dns_cmd = PVE::K8s::Addons::external_dns_install_cmd(
    '/etc/kubernetes/admin.conf', $dns_values, 'pdnskey123');
like($dns_cmd, qr/secret generic external-dns-pdns/,
    'the PowerDNS key is stored in an in-cluster Secret');
is(scalar(() = $dns_cmd =~ /pdnskey123/g), 1,
    'the PowerDNS key appears exactly once (the Secret creation)');
ok(!eval { PVE::K8s::Addons::external_dns_install_cmd(
        '/etc/kubernetes/admin.conf', $dns_values, 'bad;key'); 1 },
    'shell-unsafe PowerDNS keys are rejected');

# --- API + UI contract
my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/name => 'addons'/, 'addons list endpoint exists');
like($api, qr/name => 'addon_enable'/, 'addon enable endpoint exists');
like($api, qr/fork_cluster_worker\('k8saddonenable'/,
    'addon enable runs as a k8saddonenable PVE task');
like($api, qr/fork_cluster_worker\('k8saddondisable'/,
    'addon disable runs as a k8saddondisable PVE task');
like($api, qr/k8spowerstart|k8spowerstop/,
    'power task type carries the action for the task log');
like($api, qr/die "add-on '\$addon' is not one you enable\\n"\s+if \$e->\{tier\} !~ \/\^\(\?:optional\|default\)\$\/;/,
    'enable takes the optional and default add-ons only');
like($api, qr/PVE::K8s::Addons::addon_options\(\$e, \\%opts\) if \$e->\{install\};/,
    'settings are checked before the task starts');
for my $e (grep { $_->{tier} eq 'default' } PVE::K8s::Addons::catalog()) {
    ok(PVE::K8s::Provision::simple_addon_cmds($e->{name}, '/k', '1.36'),
        "default add-on $e->{name} has install and delete commands");
}
like(PVE::K8s::Addons::npd_install_cmd('/k', '1.36'),
    qr{node-problem-detector:v1\.36\.1\n}, 'node-problem-detector follows the minor');
like(PVE::K8s::Addons::descheduler_install_cmd('/k', '1.37'),
    qr/--version 0\.37\.0 \\\n.*--set kind=CronJob --set suspend=true/s,
    'descheduler follows the minor, installed suspended');
like(PVE::K8s::Addons::descheduler_run_cmd('/k', 'roll-1'),
    qr/create job --from=cronjob\/descheduler descheduler-roll-1/, 'pve-k8s runs it on demand');
ok(!eval { PVE::K8s::Addons::descheduler_run_cmd('/k', 'x; rm'); 1 }, 'job tag is checked');
like(PVE::K8s::Addons::snapshot_controller_install_cmd('/k'),
    qr/snapshot-controller\):v\[0-9\.\]\+#\\1:v8\.7\.0#/, 'snapshot-controller image pinned');
unlike(PVE::K8s::Addons::snapshot_controller_delete_cmd('/k'), qr/crd/i,
    'turning snapshots off keeps the CRDs (and the snapshots)');
like(PVE::K8s::Addons::cilium_values_yaml('10.0.0.5'),
    qr/hubble:\n  enabled: true\n  relay:\n    enabled: true/, 'Hubble relay on with Cilium');

my $cfgpm = do {
    open my $fh, '<', 'PVE/K8s/Config.pm' or die $!;
    local $/;
    <$fh>;
};
like($cfgpm, qr/^\s+addons => \{\s*$/m,
    'addons is a declared section-config property (else writes drop)');
like($cfgpm, qr/addons => \{ optional => 1 \}/,
    'addons is a writable option on existing clusters');

my $js = do {
    open my $fh, '<', 'www/manager6/PVEK8sWorkspace.js' or die $!;
    local $/;
    <$fh>;
};
like($js, qr|'/addons'|,
    'UI add-ons window reads the addons endpoint');
like($js, qr|'/addons/' \+ addon \+ '/enable'|,
    'UI enables add-ons through the enable endpoint');
like($js, qr/value: 'ca'/,
    'cert-manager configuration opens with the internal CA pre-selected');
like($js, qr/inputType: 'password'/,
    'the PowerDNS API key field is a password input');

# --- T3.4 re-spec: LB reachability is SDN's job; Cilium
# only announces by L2 inside the VNet, never BGP.
use PVE::K8s::Config;

my $l2_values = PVE::K8s::Addons::cilium_values_yaml('192.168.202.59');
unlike($l2_values, qr/bgpControlPlane/,
    'Cilium BGP control plane is never enabled');
like($l2_values, qr/l2announcements:\n  enabled: true/,
    'L2 announcements stay enabled');
ok(!PVE::K8s::Addons->can('cilium_bgp_yaml'),
    'Cilium BGP object generation is removed');

my $pool_l2 = PVE::K8s::Addons::lb_pool_yaml(
    '192.168.202.100-192.168.202.120');
like($pool_l2, qr/CiliumL2AnnouncementPolicy/,
    'the pool is always announced by L2/ARP');

is(PVE::K8s::Config::assert_network_config({}), 'shared',
    'no SDN settings means the shared pre-made VNet');
is(PVE::K8s::Config::assert_network_config({
        'sdn-zone' => 'tenant1',
        'node-subnet' => '192.168.202.0/24',
        'public-subnet' => '192.168.212.0/24' }), 'dedicated',
    'a dedicated EVPN VNet config validates');
ok(!eval { PVE::K8s::Config::assert_network_config(
        { 'lb-mode' => 'bgp' }); 1 },
    'lb-mode bgp is rejected (removed by the T3.4 re-spec)');
ok(!eval { PVE::K8s::Config::assert_network_config(
        { 'sdn-zone' => 'tenant1' }); 1 },
    'sdn-zone without public-subnet is rejected');
ok(!eval { PVE::K8s::Config::assert_network_config(
        { 'public-subnet' => '192.168.212.0/24' }); 1 },
    'public-subnet without sdn-zone is rejected');
ok(!eval { PVE::K8s::Config::assert_network_config({
        'sdn-zone' => 'tenant1',
        'node-subnet' => '192.168.202.0/24',
        'public-subnet' => '192.168.202.0/24' }); 1 },
    'public-subnet equal to node-subnet is rejected');

is(PVE::K8s::Config::vip_for(
        { 'node-subnet' => '192.168.202.0/24' }),
    '192.168.202.59', 'legacy VIP sits on the node subnet');
is(PVE::K8s::Config::vip_for({
        'node-subnet' => '192.168.202.0/24',
        'public-subnet' => '192.168.212.0/24' }),
    '192.168.212.59', 'dedicated VIP sits on the public subnet');
is(PVE::K8s::Config::cluster_vnet_name('Tenant Lab 6!'),
    'k8stenan', 'VNet ids fit the PVE 8-char limit');
is(PVE::K8s::Config::cluster_vnet_name('uitest'),
    'k8suites', 'long cluster names truncate to 8 chars');

my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};
like($prov, qr/sub pve_api_url/, 'PVE API URL helper exists');
is(scalar(() = $prov =~ /pve_api_url\(\$gateway, \$scfg->\{'sdn-zone'\}/g), 2,
    'CCM and CSI both pass the dedicated-mode flag to the API URL helper');
like($prov, qr/return "https:\/\/\$gateway:8006\/api2\/json" if \$dedicated/,
    'dedicated mode reaches the API via the anycast gateway SVI');
unlike($prov, qr/"https:\/\/\$gateway:8006\/api2\/json",\n\s+\$token_id/,
    'the gateway IP is no longer the API endpoint for add-ons');

like($js, qr/name: 'sdn-zone'/,
    'wizard has the SDN EVPN zone field');
like($js, qr/name: 'public-subnet'/,
    'wizard has the public subnet field');
unlike($js, qr/name: 'bgp-peer-address'/,
    'wizard no longer offers Cilium BGP settings');
like($api, qr/assert_network_config/,
    'create validates the network config eagerly');

# Cilium per Kubernetes minor, its running version, upgrade steps.
{
    my $A = 'PVE::K8s::Addons';
    is($A->can('cilium_running_version')->({ spec => { template => { spec => {
        containers => [{ image => 'quay.io/cilium/cilium:v1.20.4@sha256:abc' }] } } } }),
        '1.20.4', 'running Cilium read from the agent image');
    is($A->can('cilium_running_version')->({ spec => { template => { spec => {
        containers => [{ image => 'quay.io/cilium/cilium:v1.21.0-pre.4' }] } } } }),
        '1.21.0-pre.4', 'pre-release tags too');
    is($A->can('cilium_running_version')->(undef), undef, 'no DaemonSet: unknown');
    my $step = $A->can('cilium_step');
    is($step->('1.20.4', '1.20.4'), 'none', 'same version: nothing');
    is($step->(undef, '1.21.0'), 'none', 'unknown running version: nothing');
    is($step->('1.20.3', '1.20.4'), 'upgrade', 'a patch');
    is($step->('1.20.4', '1.21.0-pre.4'), 'upgrade', 'one minor, pre-release target');
    is($step->('1.21.0-pre.4', '1.21.0'), 'upgrade', 'pre-release to its release');
    ok(!eval { $step->('1.19.9', '1.21.0'); 1 }, 'two minors refused');
    like($@, qr/one minor at a time/, 'and says why');
    ok(!eval { $step->('1.21.0', '1.20.4'); 1 }, 'no downgrade');
    my $cmd = $A->can('cilium_install_cmd')->('/k', '10.0.0.5', '1.37');
    like($cmd, qr/--version 1\.21\.0-pre\.4 /, '1.37 installs the Cilium pre-release');
    like($A->can('cilium_install_cmd')->('/k', '10.0.0.5', '1.36'),
        qr/--version \Q$PVE::K8s::Addons::CILIUM_VERSION\E /, '1.36 the stable pin');
    like($cmd, qr{kubectl apply --server-side --force-conflicts -f \$GW},
        'Gateway API CRDs applied server-side');
    like($cmd, qr{gateway-api/releases/download/v1\.6\.3/experimental-install\.yaml},
        'Gateway API v1.6.3 (what Cilium documents)');
}

# Add-on manager: catalog, running versions, rows, update plan.
{
    my $A = 'PVE::K8s::Addons';
    my $iv = $A->can('image_version');
    is($iv->('quay.io/cilium/cilium:v1.20.4@sha256:abc', 'cilium'), '1.20.4', 'tag with digest');
    is($iv->('registry.k8s.io/metrics-server/metrics-server:v0.9.1'), '0.9.1', 'plain tag');
    is($iv->('quay.io/cilium/cilium-ci:v1.21.0-pre.4', 'cilium'), '1.21.0-pre.4', '-ci image, pre-release');
    is($iv->('quay.io/cilium/operator-generic:v1.20.4', 'cilium'), undef, 'another image name');
    is($iv->('registry:5000/x/y:latest'), undef, 'no version tag');
    is($iv->('busybox'), undef, 'no tag at all');

    my $dep = sub { my ($ns, $n, @img) = @_;
        { metadata => { namespace => $ns, name => $n },
          spec => { template => { spec => { containers => [map { { image => $_ } } @img] } } } } };
    my $lists = {
        daemonset => { items => [$dep->('kube-system', 'cilium', 'quay.io/cilium/cilium:v1.20.3@sha256:1')] },
        deployment => { items => [
            $dep->('kube-system', 'proxmox-cloud-controller-manager',
                'ghcr.io/sergelogvinov/proxmox-cloud-controller-manager:v0.16.1'),
            $dep->('csi-proxmox', 'proxmox-csi-plugin-controller',
                'registry.k8s.io/sig-storage/csi-attacher:v4.8.0',
                'ghcr.io/sergelogvinov/proxmox-csi-controller:v0.20.0'),
            $dep->('kube-system', 'metrics-server', 'registry.k8s.io/metrics-server/metrics-server:v0.9.1'),
            $dep->('kube-system', 'csi-nfs-controller', 'registry.k8s.io/sig-storage/nfsplugin:v4.13.6'),
            $dep->('cert-manager', 'cert-manager', 'quay.io/jetstack/cert-manager-controller:weird'),
        ] },
        crd => { items => [{ metadata => { namespace => undef,
            name => 'httproutes.gateway.networking.k8s.io',
            annotations => { 'gateway.networking.k8s.io/bundle-version' => 'v1.5.1' } } }] },
    };
    my $live = $A->can('probe_versions')->($lists, 'nfs');
    is($live->{cilium}, '1.20.3', 'cilium from its DaemonSet');
    is($live->{'gateway-api'}, '1.5.1', 'Gateway API from the CRD bundle annotation');
    is($live->{'proxmox-csi'}, '0.20.0', 'the matching container, not a sidecar');
    is($live->{'shared-file'}, '4.13.6', 'NFS driver for an nfs file tier');
    is($live->{'cert-manager'}, 'unknown', 'present but unreadable tag: unknown');
    ok(!exists $live->{'external-dns'}, 'absent: not installed');
    is($A->can('probe_versions')->({ cronjob => { items => [{
        metadata => { namespace => 'kube-system', name => 'descheduler' },
        spec => { jobTemplate => { spec => { template => { spec => { containers => [
            { image => 'registry.k8s.io/descheduler/descheduler:v0.36.0' }] } } } } } }] } },
        undef)->{descheduler}, '0.36.0', 'a CronJob image is read through its job template');
    is($A->can('probe_versions')->($lists, 'cephfs')->{'shared-file'}, undef,
        'CephFS tier looks for the CephFS driver');

    my $rows = $A->can('addon_rows')->('1.36',
        { 'cert-manager' => { issuer => 'ca' } }, $live, 'nfs');
    my %r = map { $_->{name} => $_ } $rows->@*;
    is($r{cilium}{update}, 1, 'cilium behind its pin: update');
    is($r{'metrics-server'}{update}, 0, 'at its pin: no update');
    is($r{'cert-manager'}{update}, 0, 'unknown running version: no blind update');
    is($r{'external-dns'}{status}, 'available', 'optional, not installed: available');
    is($r{'proxmox-ccm'}{status}, 'installed', 'core installed');
    ok($r{'external-dns'}{configurable}, 'add-ons with settings are configurable');
    is($r{'cert-manager'}{config}{issuer}, 'ca', 'stored settings shown');
    is($A->can('addon_rows')->('1.36', {}, $live, undef)->[4]{name}, 'metrics-server',
        'no file tier: no shared-file row');
    is($A->can('addon_rows')->('1.37', {}, $live, 'nfs')->[0]{pinned}, '1.21.0-pre.4',
        'pins follow the Kubernetes minor');
    is($A->can('addon_rows')->('1.36', { 'metrics-server' => { disabled => 1 } },
        { cilium => '1.20.4' }, undef)->[4]{status}, 'disabled', 'turned off stays off');
    is($A->can('addon_rows')->('1.36', {}, undef, undef)->[0]{status}, 'unknown',
        'cluster not readable: unknown, no update offered');

    my $todo = PVE::K8s::Provision::addons_to_update(
        $A->can('addon_rows')->('1.36', {}, $live, 'nfs'));
    is_deeply([map { $_->{name} } $todo->@*], ['cilium', 'proxmox-csi'],
        'update plan: behind entries, catalog order (cilium first)');
    ok($todo->[0]{core}, 'cilium is core');
    my $todo37 = PVE::K8s::Provision::addons_to_update(
        $A->can('addon_rows')->('1.36', {}, { %$live, cilium => '1.20.4' }, 'nfs'));
    is_deeply([map { $_->{name} } $todo37->@*], ['cilium', 'proxmox-csi'],
        'gateway-api behind is updated through cilium, once');

    my @names = map { $_->{name} } $A->can('catalog')->();
    is($names[0], 'cilium', 'cilium updates first');
    for my $e ($A->can('catalog')->()) {
        ok(defined $e->{version}->('1.36', 'nfs'), "$e->{name} has a pin");
        ok($e->{probe}, "$e->{name} has a probe");
    }
}

$prov = do { local $/; open my $fh, "<", "PVE/K8s/Provision.pm" or die; <$fh> };
like($prov, qr/update_addons\(\$name, minor => \$to\);\n\s+return roll_cluster\(/,
    'an upgrade updates add-ons before the roll');
like($prov, qr/for my \$node \(\$o\{update\} \? \(\) : \$nodes->\@\*\)/,
    'an add-on update does not re-taint initialised nodes');
like($api, qr/path => '\{name\}\/addons\/\{addon\}\/update',[\s\S]*?Sys\.Modify/,
    'per add-on update needs Sys.Modify');
like($api, qr/path => '\{name\}\/addon-updates',[\s\S]*?Sys\.Modify/,
    'update all needs Sys.Modify');

# Opt-in catalog: settings, commands
{
    my $A = 'PVE::K8s::Addons';
    my $v = $A->can('catalog_entry')->('velero');
    my ($all, $store) = $A->can('addon_options')->($v, { 's3-url' => 'https://s3:7480',
        bucket => 'b', 'access-key' => 'AK', 'secret-key' => 'SK' });
    is($all->{region}, 'default', 'defaults filled in');
    is($all->{'secret-key'}, 'SK', 'secrets reach the install');
    ok(!exists $store->{'secret-key'} && !exists $store->{'access-key'},
        'secrets are never stored');
    ok(!eval { $A->can('addon_options')->($v, { bucket => 'b' }); 1 }, 'required setting missing');
    like($@, qr/needs 's3-url'/, 'names it');
    ok(!eval { $A->can('addon_options')->($v, { nope => 1 }); 1 }, 'unknown setting refused');
    my $o = $A->can('catalog_entry')->('observability');
    ok(!eval { $A->can('addon_options')->($o, { retention => 0 }); 1 }, 'int range checked');
    ok(!eval { $A->can('addon_options')->($o, { ha => 'yes' }); 1 }, 'bool checked');
    ok(!eval { $A->can('addon_options')->($v, { 's3-url' => "a\nb", bucket => 'b',
        'access-key' => 'x', 'secret-key' => 'y' }); 1 }, 'control characters refused');
    is(($A->can('addon_options')->($o, { ha => 'true' }))[0]{ha}, 1, 'true means 1');

    my $single = $A->can('observability_values_yaml')->();
    like($single, qr/vmsingle:\n  enabled: true/, 'single: VMSingle');
    like($single, qr/vlsingle:\n  enabled: true/, 'logs on by default');
    unlike($single, qr/vtsingle/, 'traces off by default');
    like($single, qr/kubeProxy:\n  enabled: false/, 'no kube-proxy target (Cilium replaces it)');
    my $ha = $A->can('observability_values_yaml')->(ha => 1, traces => 1, retention => 30);
    like($ha, qr/vmcluster:\n  enabled: true\n  spec:\n    retentionPeriod: "30d"\n    replicationFactor: 2/,
        'HA: metrics cluster, replication factor 2');
    like($ha, qr/vlcluster:\n  enabled: true/, 'HA: logs on a cluster');
    like($ha, qr/vtsingle:\n  enabled: true/, 'traces when asked (single)');

    my $vel = $A->can('velero_install_cmd')->('/k', '1.36', { 's3-url' => 'https://s3:7480',
        bucket => 'b', region => 'default', 'access-key' => 'AK', 'secret-key' => 'S/K' });
    like($vel, qr/create secret generic velero-s3/, 'credentials go into a cluster Secret');
    like($vel, qr/existingSecret: velero-s3/, 'the chart uses that Secret');
    like($vel, qr/velero\.io\/csi-volumesnapshot-class: "true"/, 'a snapshot class for Proxmox CSI');
    unlike($A->can('velero_install_cmd')->('/k', '1.36', { 's3-url' => 'https://s3:7480',
        bucket => 'b', region => 'default' }), qr/create secret/, 'an update keeps the Secret');
    ok(!eval { $A->can('velero_install_cmd')->('/k', '1.36', { 's3-url' => 'https://s3',
        bucket => 'b', 'access-key' => "x'y", 'secret-key' => 'z' }); 1 }, 'quoted key refused');
    ok(!eval { $A->can('velero_install_cmd')->('/k', '1.36', { 's3-url' => 'ftp://x',
        bucket => 'b' }); 1 }, 'non-http S3 URL refused');

    like($A->can('flux_install_cmd')->('/k', '1.36', {}), qr/annotate deploy source-controller\s+\\\n\s+pve-k8s\.proxmox\.com\/version=/,
        'Flux records its release version');
    unlike($A->can('flux_install_cmd')->('/k', '1.36', {}), qr/flagger/, 'no Flagger unless asked');
    like($A->can('flux_install_cmd')->('/k', '1.36', { flagger => 1 }),
        qr/--set meshProvider=gatewayapi:v1/, 'Flagger drives the Gateway API');
    like($A->can('chart_install_cmd')->('kyverno', '/k', { ha => 1 }),
        qr/admissionController\.replicas=3/, 'Kyverno HA: 3 admission controllers');
    like($A->can('chart_install_cmd')->('kyverno', '/k', {}),
        qr/admissionController\.replicas=1/, 'otherwise 1');
    for my $n (qw(headlamp tetragon keda kyverno observability velero flux)) {
        my $e = $A->can('catalog_entry')->($n);
        ok($e->{install} && $e->{delete}, "$n can be enabled and removed");
    }
    my $live = $A->can('probe_versions')->({ deployment => { items => [{
        metadata => { namespace => 'flux-system', name => 'source-controller',
            annotations => { 'pve-k8s.proxmox.com/version' => '2.10.0' } },
        spec => { template => { spec => { containers => [{ image => 'ghcr.io/fluxcd/source-controller:v1.10.1' }] } } } }] } });
    is($live->{flux}, '2.10.0', 'Flux version read from the annotation, not the image');
}

# Application backups (Velero)
{
    my $P = 'PVE::K8s::Provision';
    my $rows = $P->can('app_backup_rows')->({ items => [
        { metadata => { name => 'a', creationTimestamp => '2026-11-01T00:00:00Z',
            labels => { 'pve-k8s.proxmox.com/reason' => 'pre-upgrade' } },
          status => { phase => 'Completed', progress => { itemsBackedUp => 42 } } },
        { metadata => { name => 'b', creationTimestamp => '2026-11-02T00:00:00Z' },
          status => { phase => 'PartiallyFailed', errors => 1 } },
        { metadata => { name => 'c', creationTimestamp => '2026-11-03T00:00:00Z' } },
    ] });
    is_deeply([map { $_->{name} } @$rows], [qw(c b a)], 'newest first');
    is($rows->[0]{phase}, 'New', 'no status yet: New');
    is($rows->[2]{items}, 42, 'items backed up');
    is($rows->[2]{reason}, 'pre-upgrade', 'why it was taken');
    is($P->can('velero_name')->('pre-upgrade-1.37', 1731500000), 'pre-upgrade-1-37-1731500000',
        'object names are DNS labels');
    is(length($P->can('velero_name')->('restore-' . ('x' x 80), 1)), 63, 'and at most 63 long');
    my $b = $P->can('app_backup_object')->('n', 'manual');
    is_deeply($b->{spec}{includedNamespaces}, ['*'], 'every namespace');
    ok($b->{spec}{snapshotMoveData}, 'volume data moved to the bucket');
    is($b->{spec}{ttl}, '720h0m0s', 'kept 30 days');
    ok(!$P->can('velero_enabled')->({}), 'no record: not enabled');
    ok($P->can('velero_enabled')->({ addons => '{"velero":{"bucket":"b"}}' }), 'record: enabled');
}
like($prov, qr/app_backup\(\$name, reason => 'pre-upgrade', prefix => "pre-upgrade-\$to",\s+wait => 1\) if velero_enabled\(\$scfg\);\s+#[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n\s+update_addons\(/,
    'with Velero, the upgrade backs up first, then add-ons, then the roll');
like($prov, qr/die "Velero backup \$bname \$st->\{phase\}"/, 'a failed backup stops it');
like($api, qr/path => '\{name\}\/app-backups\/\{backup\}\/restore',[\s\S]*?Sys\.Modify/,
    'restore needs Sys.Modify');

# Pod traffic encryption (WireGuard)
like(PVE::K8s::Addons::cilium_values_yaml('10.0.0.5', 'wireguard'),
    qr/encryption:\n  enabled: true\n  type: wireguard\n/, 'WireGuard on request');
unlike(PVE::K8s::Addons::cilium_values_yaml('10.0.0.5', 'off'), qr/encryption:/, 'off: nothing');
unlike(PVE::K8s::Addons::cilium_values_yaml('10.0.0.5'), qr/encryption:/, 'default off');
like(PVE::K8s::Addons::cilium_install_cmd('/k', '10.0.0.5', '1.36', 'wireguard'),
    qr/type: wireguard/, 'install carries it');
like($prov, qr/cilium_install_cmd\(\s*\$kc, PVE::K8s::Config::vip_for\(\$scfg\), \$minor, \$scfg->\{encryption\}\)/,
    'a Cilium update keeps the setting');
like($prov, qr/'\/root\/local-super-admin\.conf', \$vip, \$k8s_minor, \$enc\)\) if \$fresh;/,
    'and so does the first install');
like($prov, qr/sub set_encryption \{[\s\S]*?update_addon\(\$name, 'cilium'\);/,
    'changing it re-applies Cilium');
ok(!eval { PVE::K8s::Provision::set_encryption('x', 'ipsec'); 1 }, 'only off or wireguard');
like($api, qr/path => '\{name\}\/encryption',[\s\S]*?Sys\.Modify/, 'needs Sys.Modify');

done_testing();
