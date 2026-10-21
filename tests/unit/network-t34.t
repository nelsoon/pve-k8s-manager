# Unit test: T3.4 re-spec wiring. Dedicated per-cluster
# VNets live in a tenant EVPN zone (internal node subnet +
# public LB/VIP subnet), are created before node VMs and
# removed on delete, and node VMs attach to the dedicated
# bridge instead of the template's shared one. The pvesh
# SDN call shapes are asserted here; end-to-end SDN proof
# is the delayed nested-lab test. Run via `make test`.
use strict;
use warnings;
use Test::More;

my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};

like($prov, qr/sub ensure_cluster_vnet/,
    'dedicated VNet lifecycle helper exists');
like($prov, qr/is type .* not evpn/s,
    'a non-EVPN zone is rejected for dedicated VNets');
like($prov, qr/'create', '\/cluster\/sdn\/vnets'/,
    'the VNet is created through the SDN API');
like($prov, qr/vnets\/\$vnet\/subnets/,
    'internal and public subnets are created in the VNet');
like($prov, qr/'set', '\/cluster\/sdn'/,
    'SDN changes are applied');
like($prov, qr/sub remove_cluster_vnet/,
    'VNet teardown helper exists');
like($prov, qr/remove_cluster_vnet\(\$name, \$scfg\)/,
    'cluster delete removes the dedicated VNet');
like($prov, qr/bridge => \$bridge/,
    'provisioning passes the dedicated bridge to node creation');
like($prov, qr/bridge => cluster_bridge\(\$scfg\)/,
    'roll and restore reuse the recorded dedicated bridge');
like($prov, qr/virtio=\$mac,bridge=\$bridge/,
    'cloned VMs are re-attached from the template bridge to the dedicated VNet');
like($prov, qr/PVE::K8s::Config::vip_for\(\$scfg\)/,
    'apiserver VIP comes from the shared subnet helper');
unlike($prov, qr/cilium_bgp|lb-mode/,
    'no Cilium BGP or lb-mode remains in provisioning');

my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/'sdn-zone' => \{/, 'create accepts an SDN zone');
like($api, qr/'public-subnet' => \{/, 'create accepts a public subnet');
unlike($api, qr/bgp-peer|lb-mode/,
    'create no longer accepts Cilium BGP settings');

done_testing();
