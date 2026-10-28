# Unit tests: provision converge (T2.1/T2.4 hardening). The
# stored inventory is authoritative on an existing cluster:
# canonical names are only for fresh creates. Without this,
# any provision on a rolled cluster recreates rolled-away
# control-plane names as fresh VMs that kubeadm-init a
# forked CA (lab zombie t41-cp1 stole the VIP). Run via
# `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

my $pools = [{ name => 'default', size => 2, min => 1, max => 3,
    labels => 'team=a', taints => '', hosts => '', storage => '' }];
my $desired = [
    { host => 't41-cp1', role => 'cp', pool => 'control-plane',
        ip => '192.168.206.60', idx => 1 },
    { host => 't41-cp2', role => 'cp', pool => 'control-plane',
        ip => '192.168.206.61', idx => 2 },
    { host => 't41-cp3', role => 'cp', pool => 'control-plane',
        ip => '192.168.206.62', idx => 3 },
    { host => 't41-w1', role => 'worker', pool => 'default',
        ip => '192.168.206.70', idx => 1 },
    { host => 't41-w2', role => 'worker', pool => 'default',
        ip => '192.168.206.71', idx => 2 },
];

sub rec {
    my ($name, $pool, $ip, $rev) = @_;
    return { name => $name, pool => $pool, ip => $ip,
        vmid => '100', pvehost => 'pve1', rev => $rev };
}

# 1. rolled record survives untouched: no canonical
# control-plane names recreated, no appends, no retires
{
    my ($keep, $retire) = PVE::K8s::Provision::converge_nodes(
        [rec('t41-cp4', 'control-plane', '.63', 2),
         rec('t41-cp5', 'control-plane', '.64', 2),
         rec('t41-cp6', 'control-plane', '.65', 2),
         rec('t41-w1', 'default', '.70', 1),
         rec('t41-w2', 'default', '.71', 1)],
        $desired, $pools, 3);
    is(scalar @$keep, 5, 'rolled record kept whole');
    is(scalar @$retire, 0, 'nothing retired');
    ok(!grep({ $_->{host} =~ /^t41-cp[123]$/ } @$keep),
        'no zombie canonical control-plane names');
    is($keep->[0]{role}, 'cp', 'control plane stays first');
    is($keep->[0]{rev}, 2, 'record rev preserved');
    is($keep->[3]{labels}, 'team=a', 'pool labels refreshed');
}

# 2. repair shortfall: dropped w2 recreated canonical
{
    my ($keep, $retire) = PVE::K8s::Provision::converge_nodes(
        [rec('t41-w1', 'default', '.70', 2)],
        $desired, $pools, 3);
    my @names = map { $_->{host} } @$keep;
    ok(grep({ $_ eq 't41-w2' } @names),
        'missing pool member appended');
    is(scalar @$retire, 0, 'nothing retired');
}

# 3. scale-in stale record: highest index retired
{
    my $small = [{ name => 'default', size => 1, min => 1, max => 3,
        labels => '', taints => '', hosts => '', storage => '' }];
    my ($keep, $retire) = PVE::K8s::Provision::converge_nodes(
        [rec('t41-w1', 'default', '.70', 2),
         rec('t41-w2', 'default', '.71', 2)],
        $desired, $small, 3);
    my @w = grep { $_->{role} eq 'worker' } @$keep;
    is($w[0]{host}, 't41-w1', 'lowest index kept');
    is($retire->[0]{host}, 't41-w2', 'highest index retired');
}

# 4. removed pool retires all its nodes
{
    my ($keep, $retire) = PVE::K8s::Provision::converge_nodes(
        [rec('t41-w1', 'default', '.70', 2),
         rec('t41-gpu1', 'gpu', '.80', 2)],
        $desired, $pools, 3);
    ok(grep({ $_->{host} eq 't41-gpu1' } @$retire),
        'vanished pool node retired');
    ok(!grep({ $_->{host} eq 't41-gpu1' } @$keep),
        'vanished pool node not kept');
}

# 5. control-plane shortfall appends smallest free canonical
{
    my ($keep, $retire) = PVE::K8s::Provision::converge_nodes(
        [rec('t41-cp4', 'control-plane', '.63', 2)],
        $desired, $pools, 3);
    my @cp = map { $_->{host} }
        grep { $_->{role} eq 'cp' } @$keep;
    is_deeply(\@cp, ['t41-cp4', 't41-cp1', 't41-cp2'],
        'shortfall filled with smallest free canonical names');
    is(scalar @$retire, 0, 'nothing retired');
}

# 6. rolled worker names are not duplicated by canonical ones
{
    my ($keep, $retire) = PVE::K8s::Provision::converge_nodes(
        [rec('t41-cp4', 'control-plane', '.63', 2),
         rec('t41-cp5', 'control-plane', '.64', 2),
         rec('t41-cp6', 'control-plane', '.65', 2),
         rec('t41-w3', 'default', '.72', 2),
         rec('t41-w4', 'default', '.73', 2)],
        $desired, $pools, 3);
    is(scalar @$keep, 5, 'full pool of rolled workers kept');
    ok(!grep({ $_->{host} eq 't41-w1' } @$keep),
        'canonical worker names not resurrected');
}

done_testing();
