# Unit + static tests: a resumed upgrade skips kubeadm
# upgrade apply when the live control plane is already at
# the target. Every resume re-ran the disruptive apply
# against a slow API until a transient reset killed it
# (lab, 2026-10-27). Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

is(PVE::K8s::Provision::upgrade_apply_needed('v1.36.5', 'v1.36.5'),
    0, 'exact match skips the re-apply');
is(PVE::K8s::Provision::upgrade_apply_needed('v1.35.9', 'v1.36.5'),
    1, 'older live version still applies');
is(PVE::K8s::Provision::upgrade_apply_needed('v1.36.4', 'v1.36.5'),
    1, 'older patch still applies');
is(PVE::K8s::Provision::upgrade_apply_needed('', 'v1.36.5'),
    1, 'unreadable live version fails open to apply');
is(PVE::K8s::Provision::upgrade_apply_needed(undef, 'v1.36.5'),
    1, 'undef live version fails open to apply');

is(PVE::K8s::Provision::server_git_version(
        '{"serverVersion":{"gitVersion":"v1.36.5"}}'),
    'v1.36.5', 'server version parsed from kubectl json');
is(PVE::K8s::Provision::server_git_version(
        'error: --output must be \'yaml\' or \'json\''),
    '', 'kubectl error text yields empty version');
is(PVE::K8s::Provision::server_git_version(''),
    '', 'empty output yields empty version');

my $file = 'PVE/K8s/Provision.pm';
open(my $fh, '<', $file) or die "open $file: $!\n";
my $src = do { local $/; <$fh> };
close($fh);

my ($body) = $src =~ /^sub roll_cluster \{(.*?)^(?:my\s+)?sub /ms;
ok(defined $body && $body =~ /upgrade_apply_needed/,
    'roll path consults the apply-needed guard');

done_testing();
