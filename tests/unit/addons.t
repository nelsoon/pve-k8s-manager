# Unit test: T3.3 add-on catalog and opt-in install commands.
# Cilium ingress/Gateway ships with the CNI; cert-manager and
# external-dns stay "unconfigured" until enabled. Run via
# `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Addons;

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
like($api, qr/fork_worker\('k8saddon'/,
    'addon enable runs as a k8saddon PVE task');
like($api, qr/pattern => '\^\(cert-manager\|external-dns\)\$'/,
    'only cert-manager and external-dns can be enabled');

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
    'k8stenantl', 'VNet ids are short and bridge-safe');

my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};
like($prov, qr/sub pve_api_url/, 'PVE API URL helper exists');
is(scalar(() = $prov =~ /pve_api_url\(\$gateway\)/g), 2,
    'CCM and CSI both use the host API address, not the gateway');
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

done_testing();
