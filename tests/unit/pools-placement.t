# Unit tests: worker pools parsing (T2.1) and the placement
# scorer (CP anti-affinity across HA groups/hosts, worker pool
# spread). Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Config;
use PVE::K8s::Provision;

is_deeply(PVE::K8s::Config::parse_pools(undef, 2),
    [{ name => 'default', size => 2 }],
    'absent pools means the legacy default pool');

my $pools = PVE::K8s::Config::parse_pools(
    '[{"name":"default","size":2},{"name":"big","size":1,'
    . '"labels":"size=big","taints":"dedicated=big:NoSchedule",'
    . '"hosts":"pve1,pve2","device-profile":"gpu-future"}]', 9);
is(scalar $pools->@*, 2, 'two pools parse');
is($pools->[1]{labels}, 'size=big', 'pool labels carried');
is($pools->[1]{'device-profile'}, 'gpu-future',
    'device profile is carried (reserved, unused in v1)');

ok(!eval { PVE::K8s::Config::parse_pools('[{"name":"x"}]', 1); 1 },
    'pool without size is rejected');
ok(!eval { PVE::K8s::Config::parse_pools('[{"name":"a","size":1},{"name":"a","size":1}]', 1); 1 },
    'duplicate pool names are rejected');
ok(!eval { PVE::K8s::Config::parse_pools('not json', 1); 1 },
    'invalid JSON is rejected');

# CP placement: distinct hosts first
my %counts;
my @hosts = qw(pve1 pve2 pve3);
my @picked;
for (1 .. 3) {
    my $host = PVE::K8s::Provision::choose_host(\@hosts, {}, \%counts, 'cp');
    push @picked, $host;
    $counts{"cp:$host"}++;
    $counts{"cp-group:$host"}++;
    $counts{"total:$host"}++;
}
is_deeply([sort @picked], [qw(pve1 pve2 pve3)],
    'three CP nodes spread over three hosts');

# CP placement: HA groups beat individual hosts
%counts = ();
my $group_of = { pve1 => 'site-a', pve2 => 'site-a', pve3 => 'site-b' };
my $first = PVE::K8s::Provision::choose_host(\@hosts, $group_of, \%counts, 'cp');
$counts{"cp:$first"}++; $counts{"cp-group:$group_of->{$first}"}++; $counts{"total:$first"}++;
my $second = PVE::K8s::Provision::choose_host(\@hosts, $group_of, \%counts, 'cp');
is($group_of->{$second} ne $group_of->{$first}, 1,
    'second CP goes to the other HA group (site) first');

# Worker placement: spread own pool
%counts = ();
my %pool_counts;
my @worker_picks;
for (1 .. 3) {
    my %merged = (%counts, map { ("pool:$_" => $pool_counts{$_} // 0) } @hosts);
    my $host = PVE::K8s::Provision::choose_host(\@hosts, {}, \%merged, 'worker');
    push @worker_picks, $host;
    $pool_counts{$host}++;
    $counts{"total:$host"}++;
}
is_deeply([sort @worker_picks], [qw(pve1 pve2 pve3)],
    'three workers of one pool spread over three hosts');

my ($tpl_id, $tpl_rev) = PVE::K8s::Provision::find_template_in_list(
    " 9001 k8s-node-1.31-r3 stopped\n 9003 k8s-node-1.31-r5 stopped\n", '1.31');
is($tpl_id, 9003, 'highest template revision wins');

done_testing();
