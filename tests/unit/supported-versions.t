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
my ($store) = $js =~ /supportedVersions: \[([^\]]+)\]/s;
ok(defined $store, 'create dialog declares the creatable minors');
like($js, qr/name: 'k8s-version',.*?store: versions,/s,
    'the k8s-version dropdown offers exactly that list');
my @offered = $store =~ /'(\d+\.\d+)'/g;
is_deeply(\@offered, $supported,
    'wizard dropdown matches the supported version list');
like($js, qr/let latest = versions\[versions\.length - 1\];.*?name: 'k8s-version',.*?value: latest,/s,
    'wizard defaults to the latest supported version');

# The API enforces the same window at create time.
my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/assert_supported_version\(\$param->\{'k8s-version'\},\s+allow_eol => delete \$param->\{'allow-eol'\}\);/,
    'create endpoint rejects unsupported versions (EOL only when allowed)');

# Upstream support dates: every creatable minor has them, the UI
# shows the same end-of-life dates.
my %dates = do { no warnings "once"; %PVE::K8s::Config::VERSION_DATES };
for my $v ($supported->@*) {
    ok($dates{$v} && $dates{$v}{eol} gt $dates{$v}{maintenance},
        "$v has maintenance and end-of-life dates");
}
my ($eolmap) = $js =~ /versionEol: \{([^}]+)\}/;
my %ui = ($eolmap // '') =~ /'(\d+\.\d+)': '([\d-]+)'/g;
is_deeply(\%ui, { map { $_ => $dates{$_}{eol} } keys %dates },
    'the create dialog shows the same end-of-life dates');

my $vs = \&PVE::K8s::Config::version_support;
require Time::Local;
my $t = sub { Time::Local::timegm(0, 0, 12, $_[2], $_[1] - 1, $_[0]) };
is($vs->('1.35', $t->(2026, 11, 13))->{status}, 'supported', '1.35 in Nov 2026: supported');
is($vs->('1.35.9', $t->(2026, 12, 28))->{status}, 'maintenance', 'patch versions count as their minor');
is($vs->('v1.35', $t->(2027, 2, 27))->{days}, 0, 'less than a day left');
is($vs->('1.35', $t->(2027, 2, 28))->{status}, 'eol', 'end of life on the date');
is($vs->('1.20', $t->(2027, 1, 1))->{status}, 'unknown', 'no dates: unknown, not eol');
is($vs->(undef)->{status}, 'unknown', 'no version: unknown');

my $later = $t->(2027, 3, 1);
ok(!eval { PVE::K8s::Config::assert_supported_version('1.35', now => $later); 1 },
    'an end-of-life minor is refused for new clusters');
like($@, qr/end of life on 2027-02-28/, 'and the refusal names the date');
is(PVE::K8s::Config::assert_supported_version('1.35', now => $later, allow_eol => 1),
    '1.35', 'unless allowed explicitly');
is(PVE::K8s::Config::assert_supported_version('1.36', now => $later), '1.36',
    'a minor still in support is unaffected');

done_testing();
