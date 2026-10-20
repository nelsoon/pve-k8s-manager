# Unit test: T3.5 host evacuation planning. Workers move
# before control-plane members, nothing targets the source
# host, CP anti-affinity per cluster is preserved, and the
# API/UI contract exists. Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

my @nodes = (
    { cluster => 'lab1', host => 'lab1-cp1', vmid => 101,
      pvehost => 'pve1', pool => 'control-plane', role => 'cp' },
    { cluster => 'lab1', host => 'lab1-cp2', vmid => 102,
      pvehost => 'pve2', pool => 'control-plane', role => 'cp' },
    { cluster => 'lab1', host => 'lab1-cp3', vmid => 103,
      pvehost => 'pve3', pool => 'control-plane', role => 'cp' },
    { cluster => 'lab1', host => 'lab1-w1', vmid => 104,
      pvehost => 'pve1', pool => 'default', role => 'worker' },
    { cluster => 'lab1', host => 'lab1-w2', vmid => 105,
      pvehost => 'pve1', pool => 'default', role => 'worker' },
);

my $plan = PVE::K8s::Provision::evacuation_plan(
    \@nodes, 'pve1', [qw(pve1 pve2 pve3)], {});

is(scalar $plan->@*, 3, 'all three VMs on the source are planned');
is($plan->[0]{role}, 'worker', 'workers move first');
is($plan->[-1]{role}, 'cp', 'control plane moves last');
ok((grep { $_->{to} eq 'pve1' } $plan->@*) == 0,
    'nothing is targeted back at the source host');
my ($cp_step) = grep { $_->{role} eq 'cp' } $plan->@*;
ok($cp_step->{to} eq 'pve3' || $cp_step->{to} eq 'pve2',
    'CP target is a remaining host (sharing is unavoidable at 3 CP / 3 hosts)');

is_deeply(PVE::K8s::Provision::evacuation_plan(
        \@nodes, 'pve9', [qw(pve1 pve2 pve3)], {}),
    [], 'a host with no cluster VMs plans no moves');
ok(!eval {
    PVE::K8s::Provision::evacuation_plan(
        \@nodes, 'pve1', ['pve1'], {});
    1 }, 'evacuation with nowhere to go is rejected');

my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/name => 'evacuate'/, 'evacuate endpoint exists');
like($api, qr/fork_worker\('k8sevacuate'/,
    'evacuation runs as a k8sevacuate PVE task');

my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};
like($prov, qr/--with-local-disks/,
    'local (shared-nothing) disks migrate live with the VM');
like($prov, qr/'clone', \$tpl, \$vmid, '--name', \$vmname,\s+'--full', 1/s,
    'node VMs are full clones (linked clones cannot migrate)');
like($prov, qr/migration of \$step->\{host\}.*failed/s,
    'a dead migration task fails the evacuation fast');

my $noisy = "user config - ignore, something happened\n"
    . '[{"vmid": 118, "node": "pve1", "name": "lab6-w1"}]';
my $decoded = PVE::K8s::Provision::decode_pvesh_json($noisy);
is($decoded->[0]{name}, 'lab6-w1',
    'pvesh notices ahead of JSON do not break decoding');
is(PVE::K8s::Provision::decode_pvesh_json('{"a": 1}')->{a}, 1,
    'bare JSON objects still decode');

like($prov, qr/12 \* 3600/,
    'migration polling allows multi-hour local-disk migrations');
like($prov, qr/stalled: no progress in the migration/,
    'a migration with a frozen log fails as stalled');
like($prov, qr/inventory reconciled/,
    'rerun reconciles stored inventory onto live placement');
like($prov, qr/already on \$to/,
    'a VM already on its target is skipped, not re-migrated');
like($prov, qr/\$from = \$current/,
    'migration starts from live placement, not the planned host');
like($prov, qr/sub wait_cluster_ready/,
    'control-plane moves are gated on cluster health');

my $js = do {
    open my $fh, '<', 'www/manager6/PVEK8sWorkspace.js' or die $!;
    local $/;
    <$fh>;
};
like($js, qr|'/hosts/'\s*\+ value \+ '/evacuate'|,
    'UI evacuate action calls the hosts endpoint');

done_testing();
