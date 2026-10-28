# Unit tests: kube-vip leader-election tuning. The static
# pod manifest must carry relaxed lease timings so a slow
# API (loaded hosts, slow etcd commits) does not make the
# holder fail renewal and flap the VIP in a crash loop
# (lab, 2026-10-27). Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

my $yaml = PVE::K8s::Provision::kube_vip_manifest(
    '192.168.205.59', 'eth0');

like($yaml, qr/\{name: vip_leaseduration, value: "30"\}/,
    'lease duration relaxed to 30s');
like($yaml, qr/\{name: vip_renewdeadline, value: "20"\}/,
    'renew deadline relaxed to 20s');
like($yaml, qr/\{name: vip_retryperiod, value: "4"\}/,
    'retry period relaxed to 4s');
like($yaml, qr/\{name: address, value: "192\.168\.205\.59"\}/,
    'VIP address still rendered');

done_testing();
