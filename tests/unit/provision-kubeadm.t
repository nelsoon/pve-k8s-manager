# Unit test: the kubeadm init runcmd must not pass the bare
# Kubernetes minor (e.g. v1.31) as kubernetesVersion - kubeadm
# rejects it. The full version comes from the template's kubeadm
# binary at boot. Run via `make test`.
use strict;
use warnings;
use Test::More;

use PVE::K8s::Provision;

my $runcmd = PVE::K8s::Provision::kubeadm_init_runcmd('192.168.200.59');

like($runcmd, qr/kubeadm version -o short/,
    'full kubeadm version is resolved on the node at boot');
like($runcmd, qr/kubernetesVersion: \$KVER/,
    'kubernetesVersion uses the resolved full version');
unlike($runcmd, qr/kubernetesVersion: v\d+\.\d+\s*$/m,
    'kubernetesVersion is never a bare minor version');
like($runcmd, qr/controlPlaneEndpoint: "192\.168\.200\.59:6443"/,
    'control plane endpoint is the VIP');
like($runcmd, qr/kubeadm init /,
    'runcmd runs kubeadm init');
unlike($runcmd, qr/kubeadm init [^\n]*--timeout/,
    'kubeadm init has no --timeout flag in this kubeadm version');
unlike($runcmd, qr/^\s*timeouts:/m,
    'kubeadm config carries no invalid timeouts field (strict decoding rejects it)');
unlike($runcmd, qr/flannel/,
    'CNI is not applied from cloud-init (VIP may not be up yet)');
like($runcmd, qr/heartbeat-interval, value: "500"/,
    'etcd heartbeat is tuned for slower (e.g. nested/shared) storage');
like($runcmd, qr/election-timeout, value: "5000"/,
    'etcd election timeout is tuned for slower (e.g. nested/shared) storage');

my $completion = PVE::K8s::Provision::init_completion_cmd();
for my $phase (qw(upload-config bootstrap-token kubelet-finalize addon)) {
    like($completion, qr/kubeadm init phase \Q$phase\E/,
        "provisioner completes the kubeadm $phase phase itself");
}
my $upload = PVE::K8s::Provision::init_upload_config_cmd();
like($upload, qr/kubeadm init phase upload-config kubeadm /,
    'admin binding is created first, before phases that need the node object');
unlike($upload, qr/upload-config kubelet/,
    'upload-config kubelet waits until cp1 has registered via the VIP');
like($upload, qr/name: kubeadm:cluster-admins/,
    'provisioner creates the kubeadm:cluster-admins binding a full init would');
like($upload, qr/name: cluster-admin/,
    'the binding maps the admin cert group to cluster-admin');
like($completion, qr/local-super-admin\.conf apply .*flannel/,
    'provisioner applies the bootstrap CNI with the local super-admin kubeconfig');
like($completion, qr/--kubeconfig \/root\/local-super-admin\.conf/,
    'kubeadm phases use the local API endpoint, not the not-yet-up VIP');

ok(PVE::K8s::Provision::exec_pending({ pid => 42, exited => 0 }),
    'a pid-only guest exec result is pending, not failed');
ok(!PVE::K8s::Provision::exec_pending({ pid => 42, exited => 1, exitcode => 0 }),
    'an exited guest exec result is complete');
ok(!PVE::K8s::Provision::exec_pending({ exitcode => 0 }),
    'a synchronous guest exec result is complete');

is(PVE::K8s::Provision::join_endpoint_cmd(
        'kubeadm join 192.168.200.59:6443 --token abc', '192.168.200.60:6443'),
    'kubeadm join 192.168.200.60:6443 --token abc',
    'join discovery is pointed at a stable control-plane address, not the VIP');

my $base = 'kubeadm join 192.168.200.59:6443 --token abc';
is(PVE::K8s::Provision::join_command($base, 'deadbeef', 0), $base,
    'worker join is the plain kubeadm join command');
is(PVE::K8s::Provision::join_command($base, 'deadbeef', 1),
    "$base --control-plane --certificate-key deadbeef",
    'control-plane join adds --control-plane and the certificate key');

# kube-vip v0.8.4 exits fatally ("no features are enabled") unless
# control-plane mode is requested with its cp_enable env var.
my $vip = PVE::K8s::Provision::kube_vip_manifest('192.168.200.59', 'eth0');
like($vip, qr/name: cp_enable, value: "true"/,
    'kube-vip manifest enables control-plane mode (cp_enable)');
like($vip, qr/name: address, value: "192\.168\.200\.59"/,
    'kube-vip manifest carries the VIP');
unlike($vip, qr/enableControlPlane/,
    'kube-vip manifest does not use the unrecognised enableControlPlane var');
like($vip, qr/hostPath: \{path: \/etc\/kubernetes\/admin\.conf, type: File\}/,
    'kube-vip kubeconfig hostPath is type File so kubelet cannot create a directory there first');

done_testing();
