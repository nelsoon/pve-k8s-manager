# Unit tests: roll/provision target-revision floor and
# surge-name allocation (T2.2 hardening). A resume on a
# host that missed the newest template copy must never
# roll nodes backwards, and a resumed roll must not reuse
# a surge leftover's name. Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

# wanted_roll_rev(record_rev, local_rev, upgrading)
is(PVE::K8s::Provision::wanted_roll_rev(2, 1, 0), 2,
    'record floor wins over stale local copy');
is(PVE::K8s::Provision::wanted_roll_rev(2, 2, 0), 2,
    'matching revs stay');
is(PVE::K8s::Provision::wanted_roll_rev(2, 3, 0), 3,
    'newer local template raises the target');
is(PVE::K8s::Provision::wanted_roll_rev(undef, 2, 0), 2,
    'fresh provision uses the local template');
is(PVE::K8s::Provision::wanted_roll_rev(undef, -1, 0), -1,
    'nothing anywhere stays a loud failure downstream');
is(PVE::K8s::Provision::wanted_roll_rev(5, 1, 1), 1,
    'upgrade ignores the old line floor');
is(PVE::K8s::Provision::wanted_roll_rev(undef, 1, 1), 1,
    'upgrade uses the new line template');

# next_free_index(stem, taken, start)
is(PVE::K8s::Provision::next_free_index(
        't41-cp', { 't41-cp4' => 1 }, 6), 6,
    'free index kept');
is(PVE::K8s::Provision::next_free_index(
        't41-cp', { 't41-cp6' => 1 }, 6), 7,
    'surge leftover name skipped');
is(PVE::K8s::Provision::next_free_index(
        't41-w', { 't41-w3' => 1, 't41-w4' => 1 }, 3), 5,
    'consecutive taken names skipped');
is(PVE::K8s::Provision::next_free_index('t41-w', {}, 3), 3,
    'empty taken map keeps start');

# taken_names(nodes, joined): record names plus joined
# members are taken; unjoined leftover VMs stay reusable.
# (An earlier composition nested the maps and died
# dereferencing VM-name strings; this also locks the fix.)
my $taken = PVE::K8s::Provision::taken_names(
    [{ host => 't41-cp3' }, { host => 't41-w1' }],
    { 't41-cp3' => 1, 't41-cp8' => 1 });
ok($taken->{'t41-cp3'} && $taken->{'t41-w1'},
    'record node names taken');
ok($taken->{'t41-cp8'}, 'joined leftover name taken');
ok(!$taken->{'t41-w3'}, 'unjoined leftover name reusable');
ok(!$taken->{'t41-cp9'}, 'untaken name free');
is(PVE::K8s::Provision::next_free_index('t41-cp', $taken, 8), 9,
    'taken map composes with index allocation');

done_testing();
