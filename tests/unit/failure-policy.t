# Unit tests: Increment 6 failure policies. Per group
# (control plane, worker pools) the policy is HA or Replace.
# HA is only honourable when the VM disk storage is shared
# (worker pools: pod PV storage too) - a point HA restart on
# a local disk lands the service in error, proven live on
# PVE 9.2. Replace registers the VM with restarts disabled
# so Proxmox still live-migrates it on planned shutdown.
# Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Config;
use PVE::K8s::Provision;

# --- pool policy validation (parse_pools) ------------------
my $pools = PVE::K8s::Config::parse_pools(
    '[{"name":"gpu","size":1,"policy":"ha"}]', 2);
is($pools->[0]{policy}, 'ha', 'pool policy ha accepted');
$pools = PVE::K8s::Config::parse_pools(
    '[{"name":"gpu","size":1}]', 2);
is($pools->[0]{policy} // 'replace', 'replace',
    'pool policy defaults to replace');
ok(!eval {
    PVE::K8s::Config::parse_pools(
        '[{"name":"gpu","size":1,"policy":"magic"}]', 2); 1
}, 'unknown pool policy rejected');

# --- HA gating ----------------------------------------------
ok(PVE::K8s::Provision::ha_allowed(1, 1, 0),
    'CP HA allowed when its disk storage is shared');
ok(!PVE::K8s::Provision::ha_allowed(1, 0, 1),
    'CP HA refused on local disk storage');
ok(PVE::K8s::Provision::ha_allowed(0, 1, 1),
    'worker HA allowed when VM and PV storage are shared');
ok(!PVE::K8s::Provision::ha_allowed(0, 1, 0),
    'worker HA refused when PV storage is local');
ok(!PVE::K8s::Provision::ha_allowed(0, 0, 1),
    'worker HA refused when VM storage is local');

# --- HA grace period for the scaler -------------------------
cmp_ok(PVE::K8s::Provision::repair_grace('ha'), '>',
    PVE::K8s::Provision::repair_grace('replace'),
    'HA pools get a longer repair grace than Replace pools');
cmp_ok(PVE::K8s::Provision::repair_grace('replace'), '>=', 300,
    'Replace grace keeps the historic 300s floor');

is(PVE::K8s::Provision::default_gateway_from_routes(
        "default via 10.0.2.1 dev vmbr0 proto kernel onlink\n"
        . "10.0.2.0/24 dev vmbr0 proto kernel scope link\n"),
    '10.0.2.1', 'builder gateway parsed from host routes');
is(PVE::K8s::Provision::default_gateway_from_routes(
        "10.0.2.0/24 dev vmbr0 proto kernel scope link\n"),
    undef, 'no default route yields undef');

# --- wiring (source-level) ----------------------------------
my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/; <$fh>;
};
like($prov, qr/sub sync_ha_resources/,
    'provision syncs HA resources for node VMs');
like($prov, qr/max_relocate/,
    'Replace mode registers VMs with restarts disabled');
like($prov, qr/shutdown_policy=migrate|shutdown_policy.*migrate/,
    'sync ensures the migrate shutdown policy');
like($prov, qr/sync_ha_resources\(\$name/,
    'provision calls the HA sync');
my $cfg = do {
    open my $fh, '<', 'PVE/K8s/Config.pm' or die $!;
    local $/; <$fh>;
};
like($cfg, qr/'cp-policy'/, 'cluster config carries cp-policy');
like($cfg, qr/'storage-profile'/,
    'cluster config carries storage-profile');
like($prov, qr/cp-repair: replacing dead CP/,
    'scaler replaces a confirmed-dead CP');
like($prov, qr/etcd quorum is not healthy/,
    'CP replacement refuses without quorum');
like($prov, qr/record_retired_ghost/,
    'undestroyable CP VMs are recorded as retired ghosts');

my $js = do {
    open my $fh, '<', 'www/manager6/PVEK8sWorkspace.js' or die $!;
    local $/; <$fh>;
};
like($js, qr/name: 'storage-profile'/,
    'create form has the storage profile selector');
like($js, qr/name: 'cp-policy'/,
    'create/settings carry the CP failure policy');
like($js, qr/HA needs shared storage/,
    'create refuses HA on non-shared storage up front');
like($js, qr/name: 'policy',\n\s+fieldLabel: gettext\('Failure Policy'\)/,
    'node group editor has a failure policy');
like($js, qr/Parked \(awaiting placement\)/,
    'overview surfaces a parked pool');
like($prov, qr/template_storage_shared\(\$canon_id\)/,
    'shared-storage templates are cloned centrally, not copied per host');
like($prov, qr/'--target', \$target/,
    'shared template clones run on the template host with --target');
# T4.2 (user direction): the central shared template is
# HA-registered in state stopped so Proxmox relocates its
# config when the owner host dies; qm clone then runs on
# the new owner as before. No hand-rolled clone.
like($prov, qr/sub ensure_template_ha/,
    'template HA registration exists');
like($prov, qr/'--state', 'stopped'/,
    'template registered stopped (relocate, never start)');
like($prov, qr/ensure_template_ha\(\$canon_id\)/,
    'shared central template gets HA cover at clone time');
like($prov, qr/sub drop_template_ha/,
    'template HA unregistration exists');
like($prov, qr/HA has not relocated it yet/,
    'dead owner without relocation dies with a clear message');
unlike($prov, qr/manual_clone_shared/,
    'no hand-rolled rbd clone path');
# T4.2 companion fixes: the offline-host guard and the
# scale-in gate both read LIVE state, not records.
like($prov, qr/Locations come from the LIVE inventory/,
    'offline-host guard uses live VM locations');
like($prov, qr/Never scale in at or below the desired size/,
    'scaler never scales in at or below desired size');
like($prov, qr/any_tpl_rev/,
    'provision looks for the template cluster-wide');
like($prov, qr/not visible on any/,
    'recorded-but-invisible template dies clearly, no rebuild');
like($prov, qr/pmxcfs copy is readable from every host/,
    'shared-storage check works from a peer host');
like($prov, qr/resource-affinity/,
    'CP VMs get a negative-affinity HA rule');
like($prov, qr|/cluster/ha/rules/k8s-|,
    'cluster deletion removes the affinity rule');

done_testing();
