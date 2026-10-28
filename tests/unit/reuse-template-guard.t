# Unit + static tests: template VMs are never reuse
# candidates. A resumed provision once repurposed a
# template VM as a worker (lab, 2026-10-27), destroying
# the host's template cache. The classifier is unit-tested;
# a static check pins the call site inside create_node_vm
# so the guard cannot be silently dropped. Run via
# `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

is(PVE::K8s::Provision::config_is_template(
    "name: k8s-node-1.35-r1\ntemplate: 1\n"), 1,
    'flagged template config detected');
is(PVE::K8s::Provision::config_is_template(
    "name: t41-w1\nnet0: virtio=AA:BB:CC:DD:EE:FF,bridge=k8st41\n"), 0,
    'plain node config is not a template');
is(PVE::K8s::Provision::config_is_template(''), 0,
    'unreadable config fails open to old behavior');

my $file = 'PVE/K8s/Provision.pm';
open(my $fh, '<', $file) or die "open $file: $!\n";
my $src = do { local $/; <$fh> };
close($fh);

my ($body) = $src =~ /^sub create_node_vm \{(.*?)^(?:my\s+)?sub /ms;
ok(defined $body && $body =~ /config_is_template/,
    'create_node_vm consults the template guard');

done_testing();
