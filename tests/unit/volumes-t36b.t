# Unit test: T3.6b local-volume mobility decisions and
# PV/PVC transforms. The move itself is a storage content
# copy plus a delete/recreate of the (immutable) PV/PVC
# pair with the same names and disk name; only the zone
# in the handle and node affinity changes.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Scaler;
use PVE::K8s::Provision;

my $h = PVE::K8s::Scaler::csi_volume_handle(
    'pvek8s/pve1/local-zfs/vm-9999-pvc-abc');
is($h->{zone}, 'pve1', 'local handle zone is the PVE host');
is($h->{disk}, 'vm-9999-pvc-abc', 'disk name parsed');
my $shared = PVE::K8s::Scaler::csi_volume_handle(
    'pvek8s//cephfs/vm-9999-pvc-abc');
is($shared->{zone}, '', 'shared handle has empty zone');
ok(!PVE::K8s::Scaler::csi_volume_handle('bogus'),
    'a malformed handle is rejected');
ok(!PVE::K8s::Scaler::csi_volume_handle(undef),
    'an undef handle is rejected');

my $pv = {
    metadata => { name => 'pvc-abc', uid => 'u1',
        resourceVersion => '99',
        annotations => { 'pv.kubernetes.io/provisioned-by'
            => 'csi.proxmox.sinextra.dev' } },
    status => { phase => 'Bound' },
    spec => {
        claimRef => { kind => 'PersistentVolumeClaim',
            namespace => 'default', name => 'data', uid => 'u2' },
        csi => { driver => 'csi.proxmox.sinextra.dev',
            volumeHandle => 'pvek8s/pve1/local-zfs/vm-9999-pvc-abc' },
        nodeAffinity => { required => { nodeSelectorTerms => [] } },
    },
};
my $handle = PVE::K8s::Scaler::csi_volume_handle(
    $pv->{spec}{csi}{volumeHandle});
my $moved = PVE::K8s::Provision::moved_pv(
    $pv, $handle, 'pve3', 'default', 'data');
is($moved->{spec}{csi}{volumeHandle},
    'pvek8s/pve3/local-zfs/vm-9999-pvc-abc',
    'moved PV handle points at the target zone, same disk');
is($moved->{spec}{nodeAffinity}{required}
    {nodeSelectorTerms}[0]{matchExpressions}[1]{values}[0],
    'pve3', 'moved PV node affinity follows the target');
is($moved->{spec}{claimRef}{name}, 'data',
    'moved PV stays reserved for its claim');
ok(!$moved->{status} && !$moved->{metadata}{uid},
    'moved PV drops status and server-side metadata');
is($pv->{spec}{csi}{volumeHandle},
    'pvek8s/pve1/local-zfs/vm-9999-pvc-abc',
    'the original PV hash is not mutated');

my $pvc = {
    metadata => { name => 'data', uid => 'u3',
        annotations => { 'pv.kubernetes.io/bind-completed' => 'yes' } },
    status => { phase => 'Bound', capacity => { storage => '2Gi' } },
    spec => { volumeName => 'pvc-abc',
        resources => { requests => { storage => '1Gi' } } },
};
my $mpvc = PVE::K8s::Provision::moved_pvc($pvc);
is($mpvc->{spec}{volumeName}, 'pvc-abc',
    'moved PVC keeps its PV binding by name');
is($mpvc->{spec}{resources}{requests}{storage}, '2Gi',
    'moved PVC requests the bound capacity');
ok(!$mpvc->{status}, 'moved PVC drops status');

# Stuck-volume decision: pod Pending, its PV zoned pve1,
# no schedulable node on pve1, one Ready node on pve3.
my $pod = {
    metadata => { name => 'db-0', namespace => 'default' },
    status => { phase => 'Pending' },
    spec => { volumes => [
        { persistentVolumeClaim => { claimName => 'data' } } ] },
};
my %pvs = ('pvc-abc' => { zone => 'pve1',
    claim => 'default/data' });
my $stuck = PVE::K8s::Scaler::stuck_local_volumes(
    [$pod], \%pvs, [
        { name => 'w1', pvehost => 'pve1',
          ready => 1, schedulable => 0 },
        { name => 'w2', pvehost => 'pve3',
          ready => 1, schedulable => 1 },
    ]);
is(scalar $stuck->@*, 1, 'a stranded local volume is detected');
is($stuck->[0]{targets}[0]{pvehost}, 'pve3',
    'the Ready node elsewhere is the move target');

my $fine = PVE::K8s::Scaler::stuck_local_volumes(
    [$pod], \%pvs, [
        { name => 'w1', pvehost => 'pve1',
          ready => 1, schedulable => 1 },
    ]);
is(scalar $fine->@*, 0,
    'a schedulable node on the zone means not stuck');

my $shared_stuck = PVE::K8s::Scaler::stuck_local_volumes(
    [$pod], { 'pvc-x' => { zone => '',
        claim => 'default/data' } }, []);
is(scalar $shared_stuck->@*, 0,
    'shared volumes are never stuck');

my $running = { %$pod, status => { phase => 'Running' },
    spec => { %{$pod->{spec}}, nodeName => 'w1' } };
is(scalar PVE::K8s::Scaler::stuck_local_volumes(
    [$running], \%pvs, [])->@*, 0,
    'running pods are not candidates');

is(PVE::K8s::Provision::extract_task_upid(
        "DEBUG: COPY x\nUPID:pve2:0013C020:01CDBD4A:6ADC8984:"
        . "imgcopy::root\@pam:DEBUG: starting worker\n"),
    'UPID:pve2:0013C020:01CDBD4A:6ADC8984:imgcopy::root@pam:',
    'a UPID glued to DEBUG chatter is cleaned');
is(PVE::K8s::Provision::extract_task_upid('no task here'),
    undef, 'no UPID in output yields undef');

ok(defined &PVE::K8s::Provision::guest_push_file,
    'guest_push_file is a package sub (visible to earlier callers)');
ok(defined &PVE::K8s::Provision::local_pvs,
    'local_pvs is a package sub (visible to earlier callers)');
ok(defined &PVE::K8s::Provision::kubectl_apply_json,
    'kubectl_apply_json is a package sub');

my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};
like($prov, qr/sub move_local_pvc/, 'the move operation exists');
like($prov, qr/--target_node/, 'disk copy targets the new host');
like($prov, qr/persistentVolumeReclaimPolicy.*Retain/,
    'reclaim policy is pinned to Retain before PV delete');
like($prov, qr/stuck_local_volumes/,
    'the reconcile loop watches for stuck local volumes');
like($prov, qr/delete pvc -n \$ns \$pvcname.*--ignore-not-found/s,
    'PVC delete tolerates the controller removing it first');

my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/volumes\/move/, 'API exposes the volume move');

done_testing();
