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

# --- T3.4: LB BGP mode
use PVE::K8s::Config;

my $bgp_values = PVE::K8s::Addons::cilium_values_yaml('192.168.202.59', 1);
like($bgp_values, qr/bgpControlPlane:\n  enabled: true/,
    'BGP mode enables the Cilium BGP control plane');
my $l2_values = PVE::K8s::Addons::cilium_values_yaml('192.168.202.59', 0);
unlike($l2_values, qr/bgpControlPlane/,
    'L2 mode leaves the BGP control plane off');

my $pool_l2 = PVE::K8s::Addons::lb_pool_yaml(
    '192.168.202.100-192.168.202.120', 'l2');
like($pool_l2, qr/CiliumL2AnnouncementPolicy/,
    'L2 mode announces the pool by ARP');
my $pool_bgp = PVE::K8s::Addons::lb_pool_yaml(
    '192.168.202.100-192.168.202.120', 'bgp');
like($pool_bgp, qr/CiliumLoadBalancerIPPool/,
    'BGP mode still allocates from the LB pool');
unlike($pool_bgp, qr/CiliumL2AnnouncementPolicy/,
    'BGP mode does not double-announce by L2');

my $bgp_yaml = PVE::K8s::Addons::cilium_bgp_yaml({
    'bgp-peer-address' => '192.168.202.254',
    'bgp-peer-asn' => 65001,
    'bgp-local-asn' => 65002,
});
like($bgp_yaml, qr/kind: CiliumBGPClusterConfig/,
    'BGP cluster config is generated');
like($bgp_yaml, qr/localASN: 65002/, 'local ASN is the cluster ASN');
like($bgp_yaml, qr/peerAddress: "192\.168\.202\.254"/,
    'peers point at the router address');
like($bgp_yaml, qr/peerASN: 65001/, 'peer ASN is the router ASN');
like($bgp_yaml, qr/addresses: \[LoadBalancerIP\]/,
    'advertisements cover LoadBalancer IPs');
ok(!eval { PVE::K8s::Addons::cilium_bgp_yaml({}); 1 },
    'BGP objects without peer config are rejected');

is(PVE::K8s::Config::assert_bgp_config({}), 'l2',
    'no lb-mode defaults to l2');
is(PVE::K8s::Config::assert_bgp_config({
        'lb-mode' => 'bgp', 'bgp-peer-address' => '192.168.202.254',
        'bgp-peer-asn' => 65001, 'bgp-local-asn' => 65002 }), 'bgp',
    'a complete BGP config validates');
ok(!eval { PVE::K8s::Config::assert_bgp_config(
        { 'lb-mode' => 'bgp' }); 1 },
    'BGP mode without a peer is rejected at create time');
ok(!eval { PVE::K8s::Config::assert_bgp_config(
        { 'lb-mode' => 'bgp', 'bgp-peer-address' => 'router',
            'bgp-peer-asn' => 65001, 'bgp-local-asn' => 65002 }); 1 },
    'a non-IP BGP peer address is rejected');
ok(!eval { PVE::K8s::Config::assert_bgp_config(
        { 'lb-mode' => 'bgp', 'bgp-peer-address' => '10.0.0.1',
            'bgp-peer-asn' => 0, 'bgp-local-asn' => 65002 }); 1 },
    'ASN 0 is rejected');

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

like($js, qr/name: 'lb-mode'/, 'wizard has the LB mode field');
like($js, qr/name: 'bgp-peer-address'/,
    'wizard has the BGP router address field');
like($api, qr/assert_bgp_config/,
    'create validates the BGP config eagerly');

done_testing();
