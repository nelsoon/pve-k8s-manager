# Cluster settings: options can be cleared again (PVE `delete`
# semantics) and HA on local storage is refused on update just as it is
# on create. Pure: no lock, no pmxcfs.
use strict;
use warnings;
use Test::More;
use PVE::K8s::Provision;

my $apply = \&PVE::K8s::Provision::apply_cluster_options;

my $c = { 'maintenance-window' => '03:00-03:30', description => 'x',
    'backup-retention' => 7, 'cp-policy' => 'ha', 'storage-profile' => 'shared' };
$apply->($c, { delete => ['maintenance-window'] });
ok(!exists $c->{'maintenance-window'}, 'the maintenance window can be cleared');
is($c->{description}, 'x', 'other settings are untouched');

$apply->($c, { delete => ['description', 'backup-retention'] });
ok(!exists $c->{description} && !exists $c->{'backup-retention'}, 'several settings clear at once');

eval { $apply->($c, { delete => ['cp-policy'] }) };
like($@, qr/cannot clear 'cp-policy'/, 'only clearable settings can be cleared');
is($c->{'cp-policy'}, 'ha', 'a refused clear changes nothing');

# set and clear in one call
$apply->($c, { 'maintenance-window' => '01:00-02:00' });
is($c->{'maintenance-window'}, '01:00-02:00', 'a window can be set again');

# HA needs shared storage, as on create
my $local = { 'cp-policy' => 'replace', 'storage-profile' => 'local' };
eval { $apply->($local, { 'cp-policy' => 'ha' }) };
like($@, qr/needs the shared storage profile/, 'HA on local storage is refused on update');
is($local->{'cp-policy'}, 'replace', 'a refused change leaves the record untouched');
my $shared = { 'cp-policy' => 'replace', 'storage-profile' => 'shared' };
$apply->($shared, { 'cp-policy' => 'ha' });
is($shared->{'cp-policy'}, 'ha', 'HA on shared storage is fine');
eval { $apply->($shared, { 'storage-profile' => 'local' }) };
like($@, qr/needs the shared storage profile/, 'moving an HA cluster to local storage is refused too');

# unrelated edits never trip the HA check on an existing odd record
my $odd = { 'cp-policy' => 'ha', 'storage-profile' => 'local' };
$apply->($odd, { description => 'edited' });
is($odd->{description}, 'edited', 'editing the description does not re-judge an old record');

done_testing;
