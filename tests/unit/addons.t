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
like($api, qr/pattern => '\^\(cert-manager\|external-dns\|metrics-server\)\$'/,
    'only cert-manager, external-dns, metrics-server enable');

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

done_testing();
