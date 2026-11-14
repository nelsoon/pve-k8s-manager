# Remote PVE nodes are reached by the cluster's address for the node,
# not by name: a node's /etc/hosts need not list its peers.
use strict;
use warnings;
use Test::More;
use PVE::K8s::Provision;

my $ssh = PVE::K8s::Provision->can('ssh_argv');

# no PVE::Cluster here: falls back to the name
is_deeply($ssh->('cloud3', 'qm list'),
    ['ssh', '-o', 'BatchMode=yes', 'cloud3', 'qm list'], 'name fallback');

# with the cluster module present, its address wins
{
    no warnings 'once';
    local $INC{'PVE/Cluster.pm'} = 1;
    local *PVE::Cluster::remote_node_ip = sub { $_[0] eq 'cloud3' ? '10.0.2.53' : undef };
    is($ssh->('cloud3', 'qm list')->[3], '10.0.2.53', 'cluster address used');
    is($ssh->('other', 'x')->[3], 'other', 'unknown node keeps its name');
}

done_testing;
