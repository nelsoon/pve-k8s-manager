# Pre-upgrade check: the pure parts.
use strict;
use warnings;
use Test::More;
require PVE::K8s::Provision;

my $metrics = join "\n",
    'apiserver_requested_deprecated_apis{group="policy",removed_release="1.25",resource="podsecuritypolicies",subresource="",version="v1beta1"} 1',
    'apiserver_requested_deprecated_apis{group="flowcontrol.apiserver.k8s.io",removed_release="1.32",resource="flowschemas",subresource="",version="v1beta3"} 1',
    'apiserver_requested_deprecated_apis{group="x.io",removed_release="1.40",resource="things",subresource="",version="v1"} 1',
    'apiserver_requested_deprecated_apis{group="old.io",removed_release="1.30",resource="gone",subresource="",version="v1"} 0',
    'apiserver_request_total{} 5';
my $dep = PVE::K8s::Provision::deprecated_apis_removed_by($metrics, '1.36');
is(scalar @$dep, 2, 'only APIs removed by the target and still requested');
like($dep->[0], qr{flowcontrol}, 'API name reported');
like(join(' ', @$dep), qr/removed in 1\.25/, 'removal release reported');
is(scalar @{ PVE::K8s::Provision::deprecated_apis_removed_by($metrics, '1.20') }, 0,
    'nothing removed yet for an older target');
is(scalar @{ PVE::K8s::Provision::deprecated_apis_removed_by('', '1.36') }, 0, 'empty metrics');
is(scalar @{ PVE::K8s::Provision::deprecated_apis_removed_by($metrics, undef) }, 0, 'no target');

my $s = PVE::K8s::Provision::upgrade_check_summary([
    { id => 'a', level => 'ok' }, { id => 'b', level => 'warn' }]);
ok($s->{ok} && $s->{warnings} == 1 && $s->{blockers} == 0, 'warnings do not block');
$s = PVE::K8s::Provision::upgrade_check_summary([
    { id => 'a', level => 'block' }, { id => 'b', level => 'warn' }]);
ok(!$s->{ok} && $s->{blockers} == 1, 'a blocker makes the upgrade not ok');

my $GiB = 1024**3;
ok(PVE::K8s::Provision::surge_headroom_ok(
    [{ node => 'a', status => 'online', maxmem => 8 * $GiB, mem => 2 * $GiB }], 3072),
    'a host with room for the surge node');
ok(!PVE::K8s::Provision::surge_headroom_ok(
    [{ node => 'a', status => 'online', maxmem => 8 * $GiB, mem => 6 * $GiB },
     { node => 'b', status => 'offline', maxmem => 64 * $GiB, mem => 0 }], 3072),
    'tight host, offline host: no headroom');

# A target that is not one minor ahead blocks before any cluster read.
{
    no warnings 'redefine';
    local *PVE::K8s::Config::config = sub {
        return { ids => { c => { 'k8s-version' => '1.35', state => 'ready' } } } };
    my $r = PVE::K8s::Provision::upgrade_check('c', '1.37');
    ok(!$r->{ok}, 'skipping a minor blocks');
    is($r->{checks}[0]{id}, 'version-skew', 'reported as version-skew');
}

done_testing;
