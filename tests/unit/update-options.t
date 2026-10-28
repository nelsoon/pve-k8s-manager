# Unit tests: maintenance-window validation shared by the
# create schema and the PUT update endpoint (S3 scenario
# narrows and opens the window around a roll). Run via
# `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

is(PVE::K8s::Provision::assert_maintenance_window('00:00-23:59'),
    '00:00-23:59', 'full-day window accepted');
is(PVE::K8s::Provision::assert_maintenance_window('02:00-04:30'),
    '02:00-04:30', 'night window accepted');
is(PVE::K8s::Provision::assert_maintenance_window('22:00-02:00'),
    '22:00-02:00', 'overnight window accepted');

ok(!eval {
    PVE::K8s::Provision::assert_maintenance_window('anytime'); 1
}, 'free text rejected');
ok(!eval {
    PVE::K8s::Provision::assert_maintenance_window('2:00-04:30'); 1
}, 'single-digit hour rejected');
ok(!eval {
    PVE::K8s::Provision::assert_maintenance_window('24:00-01:00'); 1
}, 'hour 24 rejected');
ok(!eval {
    PVE::K8s::Provision::assert_maintenance_window('02:60-04:30'); 1
}, 'minute 60 rejected');

done_testing();
