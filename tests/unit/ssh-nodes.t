# Remote PVE nodes are reached by the cluster's address for the node,
# not by name: a node's /etc/hosts need not list its peers.
use strict;
use warnings;
use Test::More;
use PVE::K8s::Provision;

my $ssh = PVE::K8s::Provision->can('ssh_argv');

# no PVE::Cluster here: falls back to the name
is_deeply($ssh->('cloud3', 'qm list'),
    ['ssh', '-o', 'BatchMode=yes', '-o', 'HostKeyAlias=cloud3', 'cloud3', 'qm list'],
    'name fallback');

# with the cluster module present, its address wins
{
    no warnings 'once';
    local $INC{'PVE/Cluster.pm'} = 1;
    local *PVE::Cluster::remote_node_ip = sub { $_[0] eq 'cloud3' ? '10.0.2.53' : undef };
    is($ssh->('cloud3', 'qm list')->[5], '10.0.2.53', 'cluster address used');
    is($ssh->('other', 'x')->[5], 'other', 'unknown node keeps its name');
}

# flat-mode node subnet must be on the host
my $on = PVE::K8s::Provision->can('node_subnet_on_host');
my $ipo = "2: vmbr0    inet 10.0.2.51/24 brd 10.0.2.255 scope global vmbr0\n";
ok($on->('10.0.2', $ipo), 'LAN subnet is on the host');
ok(!$on->('10.10.1', $ipo), 'unrouted subnet is not');
ok(!$on->('10.0', "inet 10.0.20.5/24\n"), 'prefix match is exact');

done_testing;
