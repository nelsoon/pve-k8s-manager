# Unit test: T3.6a shared-file (RWX) tier wiring. NFS
# first: config validates eagerly, the class points at
# the admin export, the driver installer is pinned, the
# provisioner probes reachability before installing and
# records the block storage's shared flag for steering
# warnings. CephFS stays reserved/rejected until its
# step lands. Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Config;
use PVE::K8s::Addons;

is(PVE::K8s::Config::assert_file_config({}), undef,
    'no file backend is allowed (tier is opt-in)');
is(PVE::K8s::Config::assert_file_config({
        'file-backend' => 'nfs',
        'file-server' => '192.168.200.11',
        'file-share' => '/srv/k8s' }), 'nfs',
    'a complete NFS config validates');
ok(!eval { PVE::K8s::Config::assert_file_config(
        { 'file-backend' => 'nfs' }); 1 },
    'NFS without server/share is rejected');
ok(!eval { PVE::K8s::Config::assert_file_config({
        'file-backend' => 'nfs', 'file-server' => 'nas.local',
        'file-share' => '/srv/k8s' }); 1 },
    'a non-IPv4 NFS server is rejected');
ok(!eval { PVE::K8s::Config::assert_file_config({
        'file-backend' => 'nfs', 'file-server' => '10.0.0.9',
        'file-share' => 'relative/path' }); 1 },
    'a relative export path is rejected');
ok(!eval { PVE::K8s::Config::assert_file_config(
        { 'file-backend' => 'cephfs' }); 1 },
    'cephfs is rejected until its T3.6a step lands');

my $class = PVE::K8s::Addons::shared_file_class_yaml({
    'file-server' => '192.168.200.11',
    'file-share' => '/srv/k8s' });
like($class, qr/name: shared-file/, 'class is named shared-file');
like($class, qr/provisioner: nfs\.csi\.k8s\.io/,
    'class uses the NFS CSI driver');
like($class, qr/server: 192\.168\.200\.11/,
    'class points at the admin NFS server');
like($class, qr/share: \/srv\/k8s/,
    'class points at the admin export');
ok(!eval { PVE::K8s::Addons::shared_file_class_yaml({}); 1 },
    'class generation without server/share dies');

my $install = PVE::K8s::Addons::nfs_csi_install_cmd(
    '/root/kc', { 'file-server' => '192.168.200.11',
                  'file-share' => '/srv/k8s' });
like($install, qr/csi-driver-nfs/, 'installer deploys csi-driver-nfs');
like($install, qr/--version \Q$PVE::K8s::Addons::NFS_CSI_VERSION\E/,
    'driver chart version is pinned');

my $prov = do {
    open my $fh, '<', 'PVE/K8s/Provision.pm' or die $!;
    local $/;
    <$fh>;
};
like($prov, qr|/dev/tcp/\$server/2049|,
    'provision probes NFS reachability from a node first');
like($prov, qr/Shared-file tier installed/,
    'provision installs the file tier after the probe');
like($prov, qr/storage-shared/,
    'provision records the block storage shared flag');
like($prov, qr/shared-block volumes will pin pods/,
    'node-local storage raises the pinning warning');

my $api = do {
    open my $fh, '<', 'PVE/API2/Cluster/K8s.pm' or die $!;
    local $/;
    <$fh>;
};
like($api, qr/assert_file_config/,
    'create validates the file config eagerly');
like($api, qr/'file-backend' => \{/, 'create accepts file-backend');

my $js = do {
    open my $fh, '<', 'www/manager6/PVEK8sWorkspace.js' or die $!;
    local $/;
    <$fh>;
};
like($js, qr/name: 'file-backend'/, 'wizard has the file backend field');
like($js, qr/name: 'file-share'/, 'wizard has the NFS export field');

# Schema consistency: every key the section config
# offers in options() must have a propertyList entry, or
# PVE::SectionConfig dies at load on real hosts and takes
# pvedaemon with it (T3.6a lab proof, first attempt -
# the host-side schema check the stubs cannot do for us,
# so do it against the real class data here).
my $plist = PVE::K8s::Config->private->{propertyList};
my @missing = grep { !exists $plist->{$_} }
    keys PVE::K8s::Config->options->%*;
is_deeply([sort @missing], [],
    'every options() key has a propertyList definition')
    or diag "missing property definitions: @missing";

done_testing();
