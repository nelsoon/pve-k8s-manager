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
unlike($completion, qr/flannel/,
    'no Flannel anywhere: Cilium is the only v1 CNI');

use PVE::K8s::Addons;
my $cilium = PVE::K8s::Addons::cilium_install_cmd(
    '/root/local-super-admin.conf', '192.168.201.59');
like($cilium, qr/helm upgrade -i cilium cilium\/cilium --version \d+\.\d+\.\d+/,
    'Cilium is installed by Helm at a pinned version (values stay upgradable)');
like($cilium, qr/--version \d+\.\d+\.\d+ \\\n    -n kube-system -f \/root\/cilium-values\.yaml/,
    'helm keeps its namespace and values arguments (continued line intact)');
like($cilium, qr/clusterPoolIPv4PodCIDRList: \["10\.244\.0\.0\/16"\]/,
    'Cilium pod CIDR matches the kubeadm pod subnet');
like($cilium, qr/rollout status ds\/cilium/,
    'install waits for the Cilium daemonset via the API (no node DNS needed)');
unlike($cilium, qr/rollout status deploy\/cilium-operator/,
    'no operator rollout wait: at bootstrap only cp1 exists for its 2 replicas');
like($cilium, qr/envoy:\n  enabled: false/,
    'Envoy is off until the ingress/Gateway add-on needs L7');

my $ccm_config = PVE::K8s::Addons::ccm_config_yaml(
    'https://192.168.201.1:8006/api2/json', 'k8s-lab1@pve!ccm', 's3cret', 'pvek8s-lab');
like($ccm_config, qr/token_id: "k8s-lab1\@pve!ccm"/,
    'CCM config carries the scoped PVE token id');
like($ccm_config, qr/region: "pvek8s-lab"/,
    'CCM region is the Proxmox cluster name');
my $ccm_apply = PVE::K8s::Addons::ccm_apply_cmd('/etc/kubernetes/admin.conf', $ccm_config);
like($ccm_apply, qr/name: proxmox-cloud-controller-manager/,
    'CCM credentials land in the expected secret');
like($ccm_apply, qr|/proxmox-cloud-controller-manager/v\d+\.\d+\.\d+/docs/deploy/|,
    'CCM manifest is pinned to a release version');
like($ccm_apply, qr/^ +token_secret: "s3cret"$/m,
    'secret config is indented inside the block scalar');

my $csi_values = PVE::K8s::Addons::csi_values_yaml(
    'https://192.168.201.1:8006/api2/json', 'k8s-lab1-csi@pve!csi', 's3cret',
    'pvek8s-lab', 'local-zfs');
like($csi_values, qr/- name: shared-block\n    storage: local-zfs/,
    'CSI gets a shared-block class on the cluster storage');
like($csi_values, qr/- name: local-block/,
    'CSI gets a local-block class');
my $csi_cmd = PVE::K8s::Addons::csi_install_cmd(
    '/etc/kubernetes/admin.conf', $csi_values);
like($csi_cmd, qr/proxmox-csi-plugin --version \d+\.\d+\.\d+/,
    'CSI chart is installed at a pinned version');
like($csi_cmd, qr/storageclass\.kubernetes\.io\/is-default-class/,
    'shared-block becomes the default storage class');

like($cilium, qr/kubeProxyReplacement: true/,
    'Cilium replaces kube-proxy so LB L2 announcements work');
like($cilium, qr/k8sServiceHost: "192\.168\.201\.59"/,
    'Cilium agents reach the API on the VIP directly');
my $pool = PVE::K8s::Addons::lb_pool_yaml('192.168.201.100-192.168.201.120');
like($pool, qr/start: "192\.168\.201\.100"/, 'LB pool starts at the range start');
like($pool, qr/CiliumL2AnnouncementPolicy/, 'LB pool comes with an L2 announcement policy');
ok(!eval { PVE::K8s::Addons::lb_pool_yaml('bogus'); 1 },
    'an invalid lb-range is rejected');
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

my $userdata = PVE::K8s::Provision::node_userdata(
    hostname => 'lab1-cp1', role => 'cp', vip => '192.168.201.59', extra_runcmd => '');
like($userdata, qr{>> /etc/hosts},
    'userdata re-asserts the kubernetes hosts name after cloud-init regeneration');
like($userdata, qr{/etc/cloud/templates/hosts\.debian\.tmpl},
    'userdata persists the kubernetes name in the cloud-init hosts template');
like($userdata, qr/kubernetes\$' \/etc\/hosts/,
    'the grep end-anchor dollar survives heredoc interpolation literally');

# --- T3.2: etcd encryption at rest
like($runcmd, qr/encryption-provider-config, value: \/etc\/kubernetes\/enc\/enc\.yaml/,
    'apiserver gets the encryption provider config at init');
like($runcmd, qr/hostPath: \/etc\/kubernetes\/enc/,
    'encryption config dir is mounted into the apiserver');

my $enc = PVE::K8s::Provision::encryption_config_yaml(
    'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=');
like($enc, qr/kind: EncryptionConfiguration/,
    'encryption config is an EncryptionConfiguration');
like($enc, qr/resources: \["secrets"\]/,
    'encryption covers Secrets');
like($enc, qr/secret: AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=/,
    'encryption config carries the cluster key');
like($enc, qr/- identity: \{\}/,
    'identity fallback allows reading pre-encryption data');

my $cp_userdata = PVE::K8s::Provision::node_userdata(
    hostname => 'lab1-cp1', role => 'cp', vip => '192.168.201.59',
    enc_key => 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
    extra_runcmd => '');
like($cp_userdata, qr{path: /etc/kubernetes/enc/enc\.yaml},
    'CP userdata writes the EncryptionConfiguration');
like($cp_userdata, qr{permissions: '0600'},
    'EncryptionConfiguration is 0600 on the node');

my $worker_userdata = PVE::K8s::Provision::node_userdata(
    hostname => 'lab1-w1', role => 'worker', vip => '192.168.201.59',
    enc_key => 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
    extra_runcmd => '');
unlike($worker_userdata, qr{enc/enc\.yaml},
    'worker userdata never receives the encryption key');

is_deeply([PVE::K8s::Provision::cluster_vm_names('lab1', 3, 2)],
    [qw(lab1-cp1 lab1-cp2 lab1-cp3 lab1-w1 lab1-w2)],
    'delete targets exactly the cluster CP and worker VM names');

done_testing();
