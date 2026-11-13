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

# Fast summary paths (pure pieces).
my $order = PVE::K8s::Provision::cp_read_order([
    { role => 'cp', host => 'cp1', pvehost => 'a' },
    { role => 'worker', host => 'w1', pvehost => 'b' },
    { role => 'cp', host => 'cp2', pvehost => 'b' },
    { role => 'cp', host => 'cp3', pvehost => 'c' },
], 'b');
is_deeply([map { $_->{host} } @$order], [qw(cp2 cp1 cp3)],
    'reads try the control plane on this host first (no ssh hop)');
my @files = PVE::K8s::Provision::cluster_state_files('c1');
ok((grep { m{/api-c1\.token$} } @files) && (grep { m{/summary-c1\.json$} } @files)
    && (grep { m{/certs-c1\.json$} } @files),
    'a deleted cluster takes its token and cached reads with it');
open my $pf, '<', 'PVE/K8s/Provision.pm' or die $!;
my $src = do { local $/; <$pf> };
like($src, qr/unlink grep \{ -e \} cluster_state_files\(\$name\)/, 'delete removes them');
like($src, qr/unlink cert_cache_path\(\$name\);\n\s+set_state\(\$name, 'ready'\);/,
    'a roll drops the certificate cache (new control planes, new certificates)');
unlike(($src =~ /(sub summary_cluster \{.*?\n\}\n)/s)[0], qr/ha-manager|cluster_template_lists\(\)|cert_expiry\(\$name\)/,
    'the summary spawns no ha-manager, no per-host qm list and no uncached kubeadm exec');

open my $sc, '<', 'tools/pve-k8s-scaler' or die $!;
my $scaler = do { local $/; <$sc> };
like($scaler, qr/warm_read_caches\(\$name\)/, 'the timer keeps token and certificates warm');
like($src, qr/\$now - \$st\[9\] > 2400/, 'the token is re-issued before readers would (50 min)');

# Scale-in cooldown: minutes in the record, seconds for the scaler.
my $sc = {};
$apply->($sc, { 'scale-in-cooldown' => 30 });
is($sc->{'scale-in-cooldown'}, 30, 'the scale-in cooldown is stored in minutes');
is(PVE::K8s::Provision::scale_in_cooldown_seconds($sc), 1800, 'the scaler gets seconds');
eval { $apply->($sc, { 'scale-in-cooldown' => 0 }) };
like($@, qr/1\.\.1440 minutes/, 'a zero cooldown is refused');
is($sc->{'scale-in-cooldown'}, 30, 'a refused value changes nothing');
$apply->($sc, { delete => ['scale-in-cooldown'] });
ok(!exists $sc->{'scale-in-cooldown'}, 'the cooldown can be cleared');
is(PVE::K8s::Provision::scale_in_cooldown_seconds($sc), undef,
    'unset: the scaler uses its own default');
open my $pf, '<', 'PVE/K8s/Provision.pm' or die $!;
my $prov = do { local $/; <$pf> };
like($prov, qr/scale_in_allowed\(\s*\$sstate, \$now, scale_in_cooldown_seconds\(\$scfg\)\)/,
    'the scaler pass uses the converted cooldown');

done_testing;
