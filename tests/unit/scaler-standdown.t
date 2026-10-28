# Unit + static tests: the scaler stands down unless the
# cluster is ready. A pass during upgrade churn removed a
# 13-minute-old worker that was only transiently idle
# (lab, 2026-10-27). Rolls, upgrades and provisions
# converge membership themselves. Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

is(PVE::K8s::Provision::scaler_may_act('ready'), 1,
    'scaler acts on a ready cluster');
is(PVE::K8s::Provision::scaler_may_act('rolling'), 0,
    'scaler stands down while rolling');
is(PVE::K8s::Provision::scaler_may_act('provisioning'), 0,
    'scaler stands down while provisioning');
is(PVE::K8s::Provision::scaler_may_act(undef), 0,
    'scaler stands down on unknown state');

my $file = 'PVE/K8s/Provision.pm';
open(my $fh, '<', $file) or die "open $file: $!\n";
my $src = do { local $/; <$fh> };
close($fh);

my ($body) = $src =~ /^sub scale_reconcile \{(.*?)^(?:my\s+)?sub /ms;
ok(defined $body && $body =~ /scaler_may_act/,
    'scale_reconcile consults the stand-down gate');

done_testing();
