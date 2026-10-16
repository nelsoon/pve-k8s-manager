# Unit test: the immutable node image recipe must install every
# tool kubeadm preflight requires (conntrack was missing once and
# kubeadm init failed on first boot) and report it in the build
# report consumed by build-template.sh. Run via `make test`.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $tmpl = "$Bin/../../images/cloud-init/user-data.tmpl";
open(my $fh, '<', $tmpl) or die "open $tmpl: $!";
my $recipe = do { local $/; <$fh> };
close($fh);

like($recipe, qr/^  - conntrack$/m,
    'recipe installs conntrack (kubeadm preflight requirement)');
like($recipe, qr/^  - containerd$/m, 'recipe installs containerd');
like($recipe, qr/^  - kubelet kubeadm kubectl|apt-get install -y kubelet kubeadm kubectl/,
    'recipe installs kubelet/kubeadm/kubectl');
like($recipe, qr/conntrack: \$\(conntrack --version/,
    'build report verifies conntrack so a bad image is caught at build time');
like($recipe, qr/default_runtime_name = "runc"/,
    'containerd config sets a default runtime or pod sandboxes cannot start');
like($recipe, qr/runtime_type = "io\.containerd\.runc\.v2"/,
    'containerd config defines the runc runtime type');
like($recipe, qr/SystemdCgroup = true/,
    'containerd config uses the systemd cgroup driver to match kubelet');

done_testing();
