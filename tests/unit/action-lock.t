# Unit tests: per-cluster action mutual exclusion. A slow
# provision was started twice from the UI and two workers
# raced the same cluster. Identical repeats coalesce to the
# live task; different mutations are refused while one runs;
# a dead worker's claim goes stale so provision can resume.
# Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

my $now = 1_700_000_000;
my $live = {
    key => 'provision', task => 'k8sprovision',
    upid => 'UPID:pve1:00000001:00000002:6553F100:k8sprovision:ui1:root@pam:',
    node => 'pve1', started => $now - 60, at => $now - 10,
};

is(PVE::K8s::Provision::cluster_action_decision($live, 'provision', $now),
    'coalesce', 'identical live action coalesces to the running task');
is(PVE::K8s::Provision::cluster_action_decision($live, 'roll', $now),
    'busy', 'a different mutation is refused while one runs');
is(PVE::K8s::Provision::cluster_action_decision(undef, 'provision', $now),
    'start', 'no recorded action starts');
is(PVE::K8s::Provision::cluster_action_decision(
        { $live->%*, at => $now - 7200 }, 'roll', $now),
    'start', 'a claim with no heartbeat for two hours is stale');
is(PVE::K8s::Provision::cluster_action_decision(
        { $live->%*, key => 'upgrade:1.36' }, 'upgrade:1.35', $now),
    'busy', 'upgrade to a different target does not coalesce');

my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/; <$fh>;
};
my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/; <$fh>;
};
my $cfg = do {
    open my $fh, '<', 'PVE/K8s/Config.pm' or die $!;
    local $/; <$fh>;
};

like($cfg, qr/'action-state'/, 'cluster config records the live action');
like($prov, qr/sub claim_cluster_action/,
    'provisioner claims actions atomically under the config lock');
like($prov, qr/sub run_cluster_action/,
    'workers run under the claimed action');
like($prov, qr/heartbeat/i, 'long actions heartbeat their claim');
ok((grep { /fork_cluster_worker\(/ } split /\n/, $api) >= 14,
    'every mutating task endpoint goes through the action guard');
unlike($api, qr/fork_worker\('k8s/,
    'no mutating endpoint forks a worker directly any more');
like($api, qr/already running/,
    'busy and coalesced responses name the running action');

done_testing();
