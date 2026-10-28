# Unit + static tests: surge control-plane IPs never
# collide with used addresses. The canonical 59+idx slot
# walks into the worker range on repeated surges (lab,
# 2026-10-27: cp11 took w1's .70). The slot is kept when
# free, otherwise max-used plus one. Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

sub nodes {
    return [map { { ip => $_ } } @_];
}

is(PVE::K8s::Provision::surge_cp_ip('192.168.206', 4,
        nodes('192.168.206.60', '192.168.206.61')),
    '192.168.206.63', 'free canonical slot kept');
is(PVE::K8s::Provision::surge_cp_ip('192.168.206', 11,
        nodes('192.168.206.64', '192.168.206.70')),
    '192.168.206.71', 'colliding slot floats above max');
is(PVE::K8s::Provision::surge_cp_ip('192.168.206', 2, []),
    '192.168.206.61', 'empty record keeps canonical slot');

my $file = 'PVE/K8s/Provision.pm';
open(my $fh, '<', $file) or die "open $file: $!\n";
my $src = do { local $/; <$fh> };
close($fh);

my ($body) = $src =~ /^sub roll_cluster \{(.*?)^(?:my\s+)?sub /ms;
$body //= $src;
ok($body =~ /surge_cp_ip\(\$prefix, \$next,\s*\[\@nodes, \@live_ip_nodes\]\)/,
    'surge path allocates CP IPs through the guard, '
    . 'clearing live-VM addresses too');

done_testing();
