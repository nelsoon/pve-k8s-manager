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

# The live-server check regresses while members are
# replaced (lab, 2026-10-28: a resume re-ran a finished
# apply and died in preflight), so completion is recorded
# and the record gates the resume.
ok($body =~ /upgrade-applied/,
    'roll path consults the recorded apply flag');
ok($src =~ /set_upgrade_applied\(\$name, \$kver\)/,
    'a finished apply is recorded for resumes');

open(my $cfh, '<', 'PVE/K8s/Config.pm') or die $!;
my $csrc = do { local $/; <$cfh> };
close($cfh);
ok($csrc =~ /'upgrade-applied' => \{\n\s+type => 'string'/,
    'cluster schema accepts the recorded apply flag');
ok($csrc =~ /'upgrade-applied' => \{ optional => 1 \}/,
    'update options accept the recorded apply flag');

done_testing();
