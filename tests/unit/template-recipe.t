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
like($recipe, qr/containerd\.io=2\.\*/, 'recipe installs containerd 2.x (1.7 is end of life)');
unlike($recipe, qr/^  - containerd$/m, 'not the Debian 1.7 package');
like($recipe, qr/^  - kubelet kubeadm kubectl|apt-get install -y kubelet kubeadm kubectl/,
    'recipe installs kubelet/kubeadm/kubectl');
like($recipe, qr/conntrack: \$\(conntrack --version/,
    'build report verifies conntrack so a bad image is caught at build time');
like($recipe, qr/containerd config default > \/etc\/containerd\/config\.toml/,
    'containerd config starts from the version defaults');
like($recipe, qr/SystemdCgroup = true/,
    'containerd config uses the systemd cgroup driver to match kubelet');
unlike($recipe, qr/bin_dirs\\\?|\( \*bin_dir = /,
    'the sed never touches the image verifier bin_dir (blocks every pull)');
like($recipe, qr/\/opt\/cni\/bin/,
    'containerd pins the CNI bin dir (Cilium installs there)');
like($recipe, qr/certs\.d/, 'containerd reads registry mirrors from certs.d (Spegel)');
like($recipe, qr/discard_unpacked_layers = false/,
    'unpacked layers are kept so a node can serve them (Spegel)');
like($recipe, qr/config images list.*pause/s,
    'the sandbox image is the one kubeadm expects');
like($recipe, qr/systemctl mask apt-daily\.service/,
    'immutable nodes never run apt-daily (replaced, not upgraded)');

my $versions = do {
    open my $fh, '<', 'images/versions.env' or die $!;
    local $/; <$fh>;
};
like($versions, qr/debian-13-genericcloud-amd64/,
    'node image is Debian 13 (bookworm kernel cannot mount CephFS, P13)');
unlike($versions, qr/bookworm/,
    'no bookworm image remains pinned');

done_testing();
