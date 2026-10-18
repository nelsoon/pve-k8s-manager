# Unit test: only upstream-supported Kubernetes minors can be
# used for new clusters (T2.3 follow-up). The supported window
# lives in PVE::K8s::Config, the create wizard dropdown must
# offer exactly that window, and every offered minor needs a
# template pin file. Run via `make test`.
use strict;
use warnings;
use Test::More;

use lib 'tests/stubs';
use lib '.';

require PVE::K8s::Config;

my $supported = PVE::K8s::Config::supported_versions();
ok(scalar $supported->@* >= 1, 'supported version list is not empty');
is(PVE::K8s::Config::latest_supported_version(), $supported->[-1],
    'latest supported is the last entry');

for my $v ($supported->@*) {
    is(PVE::K8s::Config::assert_supported_version($v), $v,
        "$v is accepted");
    is(PVE::K8s::Config::assert_supported_version("$v.3"), $v,
        "$v.3 is accepted as $v");
    ok(-f "images/versions/$v.env", "template pin exists for $v");
}

# 1.37 is upstream-maintained but held back until the add-on
# stack officially tests it; it must be rejected like the EOL lines.
for my $v (qw(1.31 1.32 1.33 1.34 1.37)) {
    ok(!grep({ $_ eq $v } $supported->@*), "$v is outside the window");
    ok(!eval { PVE::K8s::Config::assert_supported_version($v); 1 },
        "$v is rejected for new clusters");
    like($@, qr/not supported/, "$v rejection explains itself");
}

ok(!eval { PVE::K8s::Config::assert_supported_version('banana'); 1 },
    'garbage version is rejected');

# The create wizard dropdown offers exactly the supported window.
my $js = do {
    open my $fh, '<', 'www/manager6/PVEK8sWorkspace.js' or die $!;
    local $/;
    <$fh>;
};
my ($store) = $js =~ /name: 'k8s-version',.*?store: \[([^\]]+)\]/s;
ok(defined $store, 'wizard has a k8s-version dropdown store');
my @offered = $store =~ /'(\d+\.\d+)'/g;
is_deeply(\@offered, $supported,
    'wizard dropdown matches the supported version list');
like($js, qr/name: 'k8s-version',.*?value: '\Q$supported->[-1]\E'/s,
    'wizard defaults to the latest supported version');

# The API enforces the same window at create time.
my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/assert_supported_version\(\$param->\{'k8s-version'\}\)/,
    'create endpoint rejects unsupported versions');

done_testing();
