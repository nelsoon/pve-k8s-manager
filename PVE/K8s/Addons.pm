# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Addons;

use strict;
use warnings;

# In-cluster add-ons (T1.5). Versions are pinned here and only
# here; upgrades bump these pins and re-apply, never hand-edits
# inside the cluster. Install commands run on the first
# control-plane node via the guest agent.

# Cilium 1.20.x is e2e-tested upstream up to Kubernetes 1.36.
# Kubernetes 1.37 is tested only by Cilium 1.21, still a
# pre-release: 1.37 clusters get that pre-release (a preview,
# see PVE::K8s::Config %PREVIEW_VERSIONS) until 1.21.0 is out;
# then $CILIUM_VERSION moves to 1.21.x and the map empties.
our $CILIUM_VERSION = '1.20.4';
our %CILIUM_FOR_MINOR = ('1.37' => '1.21.0-pre.4');

# The Cilium version a cluster on Kubernetes $minor runs.
sub cilium_version_for {
    my ($minor) = @_;

    ($minor) = ($minor // '') =~ /^v?(\d+\.\d+)/;
    return $CILIUM_FOR_MINOR{$minor // ''} // $CILIUM_VERSION;
}

# Pure: "1.20.4" from the cilium DaemonSet's agent image
# (quay.io/cilium/cilium:v1.20.4@sha256:...), or undef.
sub cilium_running_version {
    my ($ds) = @_;

    for my $c (((((($ds // {})->{spec} // {})->{template} // {})
            ->{spec} // {})->{containers} // [])->@*) {
        my ($v) = ($c->{image} // '') =~ m{/cilium(?:-ci)?:v([0-9][0-9A-Za-z.+-]*?)(?:@|$)};
        return $v if defined $v;
    }
    return undef;
}

# Pure: what moving Cilium from $have to $want means: 'none',
# 'upgrade', or a refusal. Cilium supports one minor at a time
# and no downgrades.
sub cilium_step {
    my ($have, $want) = @_;

    return 'none' if !defined $have || $have eq $want;
    my ($hm, $hn) = $have =~ /^(\d+)\.(\d+)/;
    my ($wm, $wn) = $want =~ /^(\d+)\.(\d+)/;
    die "cannot read Cilium version '$have'\n" if !defined $hn;
    my $gap = ($wm - $hm) * 100 + ($wn - $hn);
    return 'upgrade' if $gap == 0 || $gap == 1;
    die "Cilium $have -> $want skips a minor; upgrade Cilium one minor "
        . "at a time first\n" if $gap > 1;
    die "Cilium $have is newer than $want; pve-k8s does not downgrade it\n";
}
our $HELM_VERSION = '4.3.2';
our $POD_CIDR = '10.244.0.0/16';

sub cilium_values_yaml {
    my ($vip) = @_;

    # T3.4 re-spec: no Cilium BGP, ever. External
    # reachability of LoadBalancer IPs is a Proxmox SDN
    # property (EVPN fabric or BGP controller + exit
    # nodes); Cilium only announces the IPs by L2 inside
    # the cluster VNet. Datapath stays overlay (tunnel):
    # native routing stays a measured physical-phase
    # option, not a default.
    return <<EOF;
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList: ["$POD_CIDR"]
kubeProxyReplacement: true
k8sServiceHost: "$vip"
k8sServicePort: 6443
l2announcements:
  enabled: true
# T3.3: Cilium is the only add-on installed by default, and
# its ingress controller + Gateway API are part of the same
# install (Envoy DaemonSet included) - no ingress-nginx.
ingressController:
  enabled: true
  loadbalancerMode: shared
  default: true
gatewayAPI:
  enabled: true
envoy:
  enabled: true
# Hubble: pod-to-pod flow visibility (relay + UI, ClusterIP)
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
EOF
}

# Installs the pinned helm, and replaces any other version (an
# older cluster keeps the helm it was built with otherwise).
my sub helm_ensure_cmd {
    return sprintf(<<'EOF', $HELM_VERSION, $HELM_VERSION);
if [ "$(/usr/local/bin/helm version --template '{{.Version}}' 2>/dev/null)" != v%s ]; then
    HA=$(uname -m); [ "$HA" = aarch64 ] && HA=arm64 || HA=amd64
    curl -fsSL -o /tmp/helm.tgz https://get.helm.sh/helm-v%s-linux-$HA.tar.gz
    tar -xzf /tmp/helm.tgz -C /tmp
    install -m 0755 /tmp/linux-$HA/helm /usr/local/bin/helm
    rm -rf /tmp/helm.tgz /tmp/linux-$HA
fi
EOF
}

# The Gateway API CRDs Cilium's docs require (1.20.4 and
# 1.21.0-pre.4 both name v1.6.3). Experimental channel: a
# superset of standard, kept so clusters created with it are
# never downgraded to standard (that would drop stored
# versions). Applied server-side: the CRDs are too large for
# the client-side last-applied annotation.
our $GATEWAY_API_VERSION = '1.6.3';

sub cilium_install_cmd {
    my ($kubeconfig, $vip, $minor) = @_;

    # Single-quoted heredoc + sprintf: an interpolating heredoc
    # strips backslash-newline continuations, which once made
    # helm run without its namespace/values arguments.
    my @args = (helm_ensure_cmd(), $kubeconfig,
        $GATEWAY_API_VERSION, cilium_values_yaml($vip),
        cilium_version_for($minor));
    return sprintf(<<'EOF', @args);
%s
export KUBECONFIG=%s
# Gateway API CRDs are not part of the Cilium chart; install
# them first or the Gateway resources cannot be created.
GW=https://github.com/kubernetes-sigs/gateway-api/releases/download/v%s/experimental-install.yaml
kubectl apply --server-side --force-conflicts -f $GW
cat > /root/cilium-values.yaml <<'VALUES'
%s
VALUES
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade -i cilium cilium/cilium --version %s \
    -n kube-system -f /root/cilium-values.yaml
kubectl -n kube-system delete ds kube-proxy --ignore-not-found
kubectl -n kube-system rollout status ds/cilium --timeout=480s
EOF
}

our $CCM_VERSION = '0.16.1';
our $CCM_MANIFEST =
    "https://raw.githubusercontent.com/sergelogvinov/proxmox-cloud-controller-manager"
    . "/v$CCM_VERSION/docs/deploy/cloud-controller-manager.yml";

sub ccm_config_yaml {
    my ($url, $token_id, $token_secret, $region) = @_;

    return <<EOF;
clusters:
  - url: "$url"
    insecure: true
    token_id: "$token_id"
    token_secret: "$token_secret"
    region: "$region"
EOF
}

sub ccm_apply_cmd {
    my ($kubeconfig, $config_yaml) = @_;

    my $indented = $config_yaml;
    $indented =~ s/^/    /mg;
    chomp $indented;
    return <<"EOF";
export KUBECONFIG=$kubeconfig
kubectl apply -f - <<'SECRET'
apiVersion: v1
kind: Secret
metadata:
  name: proxmox-cloud-controller-manager
  namespace: kube-system
stringData:
  config.yaml: |
$indented
SECRET
kubectl apply -f $CCM_MANIFEST
kubectl -n kube-system rollout restart deploy/proxmox-cloud-controller-manager
kubectl -n kube-system rollout status deploy/proxmox-cloud-controller-manager --timeout=300s
EOF
}

our $CSI_VERSION = '0.22.0';
our $CSI_CHART_VERSION = '0.5.15';

sub csi_values_yaml {
    my ($url, $token_id, $token_secret, $region, $storage) = @_;

    return <<EOF;
config:
  clusters:
    - url: "$url"
      insecure: true
      token_id: "$token_id"
      token_secret: "$token_secret"
      region: "$region"
storageClass:
  - name: shared-block
    storage: $storage
    reclaimPolicy: Delete
  - name: local-block
    storage: $storage
    reclaimPolicy: Delete
EOF
}

# --- T3.6a: shared-file (RWX) tier over NFS -------------
# The driver mounts from each node straight to the NFS
# server; Proxmox is not in the data path. Per-PVC
# subdirectories under the export are created by the
# driver - nobody creates directories by hand. The export
# itself (and its no_root_squash tradeoff) stays a
# one-time admin task on the server.
our $NFS_CSI_VERSION = '4.13.6';

sub shared_file_class_yaml {
    my ($scfg) = @_;

    my ($server, $share) = $scfg->@{qw(file-server file-share)};
    die "shared-file class needs file-server and file-share\n"
        if !$server || !$share;
    return <<EOF;
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: shared-file
provisioner: nfs.csi.k8s.io
parameters:
  server: $server
  share: $share
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
EOF
}

sub nfs_csi_install_cmd {
    my ($kubeconfig, $scfg) = @_;

    my $class_yaml = shared_file_class_yaml($scfg);
    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, $NFS_CSI_VERSION, $class_yaml);
%s
export KUBECONFIG=%s
helm repo add csi-driver-nfs \
    https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts \
    >/dev/null 2>&1 || true
helm repo update csi-driver-nfs >/dev/null
helm upgrade -i -n kube-system csi-driver-nfs \
    csi-driver-nfs/csi-driver-nfs --version %s \
    --set storageClass.create=false
kubectl apply -f - <<'CLASS'
%sCLASS
kubectl -n kube-system rollout status \
    deploy/csi-nfs-controller --timeout=600s
EOF
}

# CephFS backend (T3.6a second step): hyper-converged
# only. The provisioner has already created the
# filesystem and a scoped CephX user through the
# PVE/Ceph APIs; here we only install ceph-csi and our
# own class. The CephX key lives solely in the
# in-cluster Secret, like every other add-on credential.
our $CEPH_CSI_VERSION = '3.18.2';

sub cephfs_class_yaml {
    my ($fsid, $fs) = @_;

    die "cephfs class needs a cluster fsid and fs name\n"
        if !$fsid || !$fs;
    return <<EOF;
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: shared-file
provisioner: cephfs.csi.ceph.com
parameters:
  clusterID: $fsid
  fsName: $fs
  pool: cephfs.${fs}.data
  mounter: fuse
  csi.storage.k8s.io/provisioner-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/provisioner-secret-namespace: kube-system
  csi.storage.k8s.io/controller-expand-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: kube-system
  csi.storage.k8s.io/node-stage-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/node-stage-secret-namespace: kube-system
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
}

sub cephfs_csi_install_cmd {
    my ($kubeconfig, $fsid, $fs, $mons, $user, $key) = @_;

    my $class_yaml = cephfs_class_yaml($fsid, $fs);
    my $mon_list = join ', ', map { "\"$_\"" } $mons->@*;
    my @args = (helm_ensure_cmd(), $kubeconfig, $fsid,
        $mon_list, $CEPH_CSI_VERSION, $user, $key, $class_yaml);
    return sprintf(<<'EOF', @args);
%s
export KUBECONFIG=%s
cat > /root/ceph-csi-cephfs-values.yaml <<'VALUES'
csiConfig:
  - clusterID: "%s"
    monitors: [%s]
    cephFS: {}
# The StorageClass selects FUSE mounts: current Ceph
# issues 32-byte CephX secrets and every guest kernel
# we tested (6.1 and 6.12) rejects them at mount time
# ("libceph: secret too big 32"). ceph-csi's bundled
# ceph-fuse (librados) handles them natively. OnDelete
# strategy is the chart's recommendation for FUSE.
nodeplugin:
  updateStrategy: OnDelete
# The chart default of 3 provisioner replicas with pod
# anti-affinity cannot schedule on small clusters (the
# common 1-2 worker case); the provisioner is
# leader-elected, so one replica is correct at v1 scale.
provisioner:
  replicaCount: 1
storageClass:
  create: false
VALUES
chmod 600 /root/ceph-csi-cephfs-values.yaml
helm repo add ceph-csi https://ceph.github.io/csi-charts \
    >/dev/null 2>&1 || true
helm repo update ceph-csi >/dev/null
helm upgrade -i -n kube-system ceph-csi-cephfs \
    ceph-csi/ceph-csi-cephfs --version %s \
    -f /root/ceph-csi-cephfs-values.yaml
kubectl -n kube-system create secret generic \
    csi-cephfs-secret \
    --from-literal=userID=%s --from-literal=userKey=%s \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<'CLASS'
%sCLASS
kubectl -n kube-system rollout status \
    deploy/ceph-csi-cephfs-provisioner --timeout=600s
EOF
}

# Mount + write + capacity probe for the NFS backend,
# run inside a node: the tier is only "installed" when a
# node can actually use the export (TCP reachability was
# already checked separately). Prints PROBE lines the
# provisioner parses: capacity and free bytes from df.
sub nfs_probe_cmd {
    my ($scfg) = @_;

    my ($server, $share) = $scfg->@{qw(file-server file-share)};
    return <<"EOF";
set -e
D=/mnt/pve-k8s-probe
mkdir -p \$D
mount -t nfs -o nfsvers=4.1 $server:$share \$D
echo pve-k8s-probe > \$D/.pve-k8s-probe
grep -q pve-k8s-probe \$D/.pve-k8s-probe
rm -f \$D/.pve-k8s-probe
df -B1 --output=size,avail \$D | tail -1 | \
    awk '{print "PROBE capacity=" \$1 " free=" \$2}'
umount \$D
rmdir \$D
EOF
}

sub csi_install_cmd {
    my ($kubeconfig, $values_yaml) = @_;

    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, $values_yaml, $CSI_CHART_VERSION);
%s
export KUBECONFIG=%s
cat > /root/proxmox-csi-values.yaml <<'VALUES'
%sVALUES
chmod 600 /root/proxmox-csi-values.yaml
helm upgrade -i -n csi-proxmox --create-namespace \
    -f /root/proxmox-csi-values.yaml \
    proxmox-csi-plugin \
    oci://ghcr.io/sergelogvinov/charts/proxmox-csi-plugin --version %s
kubectl patch storageclass shared-block \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl -n csi-proxmox rollout status deploy/proxmox-csi-plugin-controller --timeout=600s
EOF
}

sub lb_pool_yaml {
    my ($range) = @_;

    my ($start, $stop) = split /-/, ($range // '');
    my $ipv4 = qr/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
    die "invalid lb-range '$range' (want A.B.C.D-A.B.C.D)\n"
        if !$start || !$stop || $start !~ $ipv4 || $stop !~ $ipv4;

    my $yaml = <<EOF;
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata: {name: default}
spec:
  blocks:
  - start: "$start"
    stop: "$stop"
EOF
    # LB IPs are always announced by L2 inside the VNet
    # (T3.4 re-spec); how they leave the VRF is SDN's job.
    $yaml .= <<'EOF';
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: default}
spec:
  interfaces: [eth0]
  loadBalancerIPs: true
EOF
    return $yaml;
}

sub lb_apply_cmd {
    my ($kubeconfig, $pool_yaml) = @_;

    return <<"EOF";
export KUBECONFIG=$kubeconfig
kubectl apply -f - <<'POOL'
$pool_yaml
POOL
EOF
}

# --- T3.3 opt-in add-ons: listed as "unconfigured" until the
# user enables them (UI or API). cert-manager always opens
# its configuration; the internal-CA issuer is the default.

our $CERTMANAGER_VERSION = '1.21.3';

sub certmanager_issuer_yaml {
    my ($opts) = @_;

    my $issuer = $opts->{issuer} // 'ca';
    if ($issuer eq 'ca') {
        return <<'EOF';
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: selfsigned}
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: pve-k8s-ca, namespace: cert-manager}
spec:
  isCA: true
  commonName: pve-k8s-ca
  secretName: pve-k8s-ca
  issuerRef: {name: selfsigned, kind: ClusterIssuer}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: pve-k8s-ca}
spec:
  ca: {secretName: pve-k8s-ca}
EOF
    }
    if ($issuer eq 'acme') {
        my $email = $opts->{email}
            or die "ACME issuer needs an email address\n";
        my $server = $opts->{'acme-server'}
            // 'https://acme-v02.api.letsencrypt.org/directory';
        return <<EOF;
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: letsencrypt}
spec:
  acme:
    email: $email
    server: $server
    privateKeySecretRef: {name: letsencrypt-key}
    solvers:
    - http01:
        ingress: {ingressClassName: cilium}
EOF
    }
    die "unknown cert-manager issuer '$issuer' (want ca or acme)\n";
}

sub certmanager_install_cmd {
    my ($kubeconfig, $issuer_yaml) = @_;

    return sprintf(<<'EOF', $kubeconfig, $CERTMANAGER_VERSION, $issuer_yaml);
export KUBECONFIG=%s
CM=https://github.com/cert-manager/cert-manager/releases/download/v%s/cert-manager.yaml
kubectl apply -f $CM
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
kubectl apply -f - <<'ISSUER'
%sISSUER
kubectl wait clusterissuer --all --for=condition=Ready --timeout=300s || true
EOF
}

our $EXTDNS_VERSION = '0.23.0';
our $EXTDNS_CHART_VERSION = '1.23.0';

sub external_dns_values_yaml {
    my ($cluster, $opts) = @_;

    my $provider = $opts->{provider} // 'pdns';
    die "only the pdns external-dns provider is supported for now\n"
        if $provider ne 'pdns';
    my $url = $opts->{'pdns-url'}
        or die "external-dns needs a pdns-url\n";
    my $zone = $opts->{zone}
        or die "external-dns needs a zone (domain filter)\n";

    return <<EOF;
provider:
  name: pdns
sources: [ingress, gateway-httproute]
registry: txt
policy: sync
domainFilters: ["$zone"]
txtOwnerId: "pve-k8s-$cluster"
extraArgs:
  - --pdns-server=$url
env:
  - name: EXTERNAL_DNS_PDNS_API_KEY
    valueFrom:
      secretKeyRef: {name: external-dns-pdns, key: api-key}
EOF
}

sub external_dns_install_cmd {
    my ($kubeconfig, $values_yaml, $api_key) = @_;

    # no key: an update, the Secret made at enable time stays
    my $secret = '';
    if (defined $api_key) {
        $api_key =~ /\A[A-Za-z0-9._~+\/=-]+\z/
            or die "invalid PowerDNS api key characters\n";
        $secret = "kubectl -n external-dns create secret generic external-dns-pdns \\\n"
            . "    --from-literal=api-key=$api_key --dry-run=client -o yaml | kubectl apply -f -\n";
    }
    my @args = (helm_ensure_cmd(), $kubeconfig, $secret,
        $values_yaml, $EXTDNS_CHART_VERSION);
    return sprintf(<<'EOF', @args);
%s
export KUBECONFIG=%s
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
%scat > /root/external-dns-values.yaml <<'VALUES'
%sVALUES
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
helm repo update external-dns >/dev/null
helm upgrade -i external-dns external-dns/external-dns \
    --version %s -n external-dns -f /root/external-dns-values.yaml
kubectl -n external-dns rollout status deploy/external-dns --timeout=300s
EOF
}

# --- metrics-server: pod/node CPU+memory via the metrics
# API (kubectl top). kubeadm kubelets use a self-signed
# serving cert, so --kubelet-insecure-tls is required.
our $METRICS_SERVER_VERSION = '0.9.1';

sub metrics_server_install_cmd {
    my ($kubeconfig) = @_;

    return sprintf(<<'EOF', $kubeconfig, $METRICS_SERVER_VERSION);
export KUBECONFIG=%s
MS=https://github.com/kubernetes-sigs/metrics-server/releases/download/v%s/components.yaml
curl -fsSL $MS > /root/ms.yaml
sed -i 's|--kubelet-use-node-status-port|&\n        - --kubelet-insecure-tls|' /root/ms.yaml
kubectl apply -f /root/ms.yaml
kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s
EOF
}

sub metrics_server_delete_cmd {
    my ($kubeconfig) = @_;

    return sprintf(<<'EOF', $kubeconfig, $METRICS_SERVER_VERSION);
export KUBECONFIG=%s
MS=https://github.com/kubernetes-sigs/metrics-server/releases/download/v%s/components.yaml
curl -fsSL $MS > /root/ms.yaml
sed -i 's|--kubelet-use-node-status-port|&\n        - --kubelet-insecure-tls|' /root/ms.yaml
kubectl delete -f /root/ms.yaml --ignore-not-found
EOF
}

# --- default add-ons that help pve-k8s itself ---------------

# CSI snapshots: the VolumeSnapshot CRDs and the common
# snapshot-controller (both Proxmox CSI and ceph-csi take
# snapshots; Velero's data mover needs them).
our $SNAPSHOT_VERSION = '8.7.0';

sub snapshot_controller_install_cmd {
    my ($kubeconfig) = @_;

    my $base = 'https://raw.githubusercontent.com/kubernetes-csi/'
        . "external-snapshotter/v$SNAPSHOT_VERSION";
    my @crds = map { "$base/client/config/crd/$_.yaml" } (
        (map { "snapshot.storage.k8s.io_$_" }
            qw(volumesnapshotclasses volumesnapshotcontents volumesnapshots)),
        (map { "groupsnapshot.storage.k8s.io_$_" }
            qw(volumegroupsnapshotclasses volumegroupsnapshotcontents
                volumegroupsnapshots)));
    my $crd_lines = join '',
        map { "kubectl apply --server-side --force-conflicts -f $_\n" } @crds;
    my $dep = "$base/deploy/kubernetes/snapshot-controller";
    my $img = 'registry.k8s.io/sig-storage/snapshot-controller';
    # the release's manifest can name an older image: pin it
    return <<"EOF";
export KUBECONFIG=$kubeconfig
${crd_lines}kubectl apply -f $dep/rbac-snapshot-controller.yaml
curl -fsSL $dep/setup-snapshot-controller.yaml \\
    | sed -E 's#(image: $img):v[0-9.]+#\\1:v$SNAPSHOT_VERSION#' \\
    | kubectl apply -f -
kubectl -n kube-system rollout status deploy/snapshot-controller --timeout=300s
EOF
}

sub snapshot_controller_delete_cmd {
    my ($kubeconfig) = @_;

    # the CRDs stay: deleting them would delete every snapshot
    my $base = 'https://raw.githubusercontent.com/kubernetes-csi/'
        . "external-snapshotter/v$SNAPSHOT_VERSION";
    return <<"EOF";
export KUBECONFIG=$kubeconfig
kubectl -n kube-system delete deployment snapshot-controller --ignore-not-found
EOF
}

# node-problem-detector: kernel deadlocks and read-only file
# systems become node conditions (KernelDeadlock,
# ReadonlyFilesystem) that pve-k8s auto-repair acts on.
# Released per Kubernetes minor.
our %NPD_FOR_MINOR = ('1.35' => '1.35.4', '1.36' => '1.36.1', '1.37' => '1.37.0');

sub npd_version_for {
    my ($minor) = @_;

    ($minor) = ($minor // '') =~ /^v?(\d+\.\d+)/;
    return $NPD_FOR_MINOR{$minor // ''}
        // $NPD_FOR_MINOR{(sort { $a <=> $b } keys %NPD_FOR_MINOR)[-1]};
}

sub npd_install_cmd {
    my ($kubeconfig, $minor) = @_;

    my $v = npd_version_for($minor);
    # the image's own configs: kernel + read-only monitors
    return <<"EOF";
export KUBECONFIG=$kubeconfig
kubectl apply -f - <<'NPD'
apiVersion: v1
kind: ServiceAccount
metadata: {name: node-problem-detector, namespace: kube-system}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: pve-k8s-node-problem-detector}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-problem-detector
subjects:
- {kind: ServiceAccount, name: node-problem-detector, namespace: kube-system}
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-problem-detector
  namespace: kube-system
  labels: {app: node-problem-detector}
spec:
  selector:
    matchLabels: {app: node-problem-detector}
  template:
    metadata:
      labels: {app: node-problem-detector}
    spec:
      serviceAccountName: node-problem-detector
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
      containers:
      - name: node-problem-detector
        image: registry.k8s.io/node-problem-detector/node-problem-detector:v$v
        command:
        - /node-problem-detector
        - --logtostderr
        - --config.system-log-monitor=/config/kernel-monitor.json,/config/readonly-monitor.json
        securityContext: {privileged: true}
        env:
        - name: NODE_NAME
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        resources:
          requests: {cpu: 10m, memory: 40Mi}
          limits: {memory: 120Mi}
        volumeMounts:
        - {name: log, mountPath: /var/log, readOnly: true}
        - {name: kmsg, mountPath: /dev/kmsg, readOnly: true}
        - {name: localtime, mountPath: /etc/localtime, readOnly: true}
      volumes:
      - name: log
        hostPath: {path: /var/log/}
      - name: kmsg
        hostPath: {path: /dev/kmsg}
      - name: localtime
        hostPath: {path: /etc/localtime, type: FileOrCreate}
NPD
kubectl -n kube-system rollout status ds/node-problem-detector --timeout=300s
EOF
}

sub npd_delete_cmd {
    my ($kubeconfig) = @_;

    return <<"EOF";
export KUBECONFIG=$kubeconfig
kubectl -n kube-system delete daemonset node-problem-detector --ignore-not-found
kubectl delete clusterrolebinding pve-k8s-node-problem-detector --ignore-not-found
kubectl -n kube-system delete serviceaccount node-problem-detector --ignore-not-found
EOF
}

# Spegel: nodes serve the image layers they hold to each other
# (stateless; containerd falls back to the registry). Needs
# containerd config_path (node template), else it is inert.
our $SPEGEL_VERSION = '0.8.1';

sub spegel_install_cmd {
    my ($kubeconfig) = @_;

    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, $SPEGEL_VERSION);
%s
export KUBECONFIG=%s
helm upgrade -i spegel oci://ghcr.io/spegel-org/helm-charts/spegel \
    --version %s -n spegel --create-namespace
kubectl -n spegel rollout status ds/spegel --timeout=300s
EOF
}

sub spegel_delete_cmd {
    my ($kubeconfig) = @_;

    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig);
%s
export KUBECONFIG=%s
helm uninstall spegel -n spegel --ignore-not-found
EOF
}

# descheduler: installed suspended; pve-k8s runs it as a one-off
# Job after a roll or a scale-out (its own timer could evict pods
# into Pending and start the scaler). Released per minor.
our %DESCHEDULER_FOR_MINOR = ('1.35' => '0.35.1', '1.36' => '0.36.0', '1.37' => '0.37.0');

sub descheduler_version_for {
    my ($minor) = @_;

    ($minor) = ($minor // '') =~ /^v?(\d+\.\d+)/;
    return $DESCHEDULER_FOR_MINOR{$minor // ''}
        // $DESCHEDULER_FOR_MINOR{(sort { $a <=> $b } keys %DESCHEDULER_FOR_MINOR)[-1]};
}

sub descheduler_install_cmd {
    my ($kubeconfig, $minor) = @_;

    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, descheduler_version_for($minor));
%s
export KUBECONFIG=%s
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/ >/dev/null 2>&1 || true
helm repo update descheduler >/dev/null
helm upgrade -i descheduler descheduler/descheduler --version %s \
    -n kube-system --set kind=CronJob --set suspend=true \
    --set schedule='0 0 1 1 *'
EOF
}

# One run now, from the suspended CronJob.
sub descheduler_run_cmd {
    my ($kubeconfig, $tag) = @_;

    $tag =~ /^[a-z0-9-]{1,30}$/ or die "bad descheduler job tag\n";
    return "kubectl --kubeconfig $kubeconfig -n kube-system create job "
        . "--from=cronjob/descheduler descheduler-$tag\n";
}

sub descheduler_delete_cmd {
    my ($kubeconfig) = @_;

    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig);
%s
export KUBECONFIG=%s
helm uninstall descheduler -n kube-system --ignore-not-found
EOF
}

# --- opt-in add-ons (step 3) ----------------------------------
# Each takes its settings as %o (validated against the catalog
# entry's options); 'secret' options arrive only at enable time and
# are written into an in-cluster Secret, so an update (stored
# settings, no secrets) keeps that Secret.

my sub yq1 {
    my ($v) = @_;

    $v //= '';
    $v =~ s/(["\\])/\\$1/g;
    return "\"$v\"";
}

# Observability: VictoriaMetrics k8s stack (operator, vmagent,
# metrics store, vmalert, Alertmanager, Grafana, node-exporter,
# kube-state-metrics) plus VictoriaLogs with its collector and,
# as a preview, VictoriaTraces. HA: metrics as a cluster with
# replication factor 2; logs on 2 storage nodes (available, not
# replicated); traces stay single.
our $OBS_CHART_VERSION = '0.98.1';
our $OBS_VERSION = '1.156.0';

sub observability_values_yaml {
    my (%o) = @_;

    my $days = ($o{retention} // 14) . 'd';
    my $size = ($o{'storage-size'} // 20) . 'Gi';
    my $ha = $o{ha} ? 1 : 0;
    my $logs = $o{logs} // 1;
    my $traces = $o{traces} // 0;
    my $metrics = $ha ? <<EOF : <<EOF;
vmsingle:
  enabled: false
vmcluster:
  enabled: true
  spec:
    retentionPeriod: "$days"
    replicationFactor: 2
    vmstorage:
      replicaCount: 2
      storage:
        volumeClaimTemplate:
          spec:
            resources:
              requests:
                storage: $size
    vmselect:
      replicaCount: 2
    vminsert:
      replicaCount: 2
EOF
vmsingle:
  enabled: true
  spec:
    retentionPeriod: "$days"
    storage:
      resources:
        requests:
          storage: $size
EOF
    my $lg = !$logs ? '' : $ha ? <<EOF : <<EOF;
vlcluster:
  enabled: true
  spec:
    vlstorage:
      replicaCount: 2
      retentionPeriod: "$days"
    vlselect:
      replicaCount: 2
    vlinsert:
      replicaCount: 2
vlagent:
  enabled: true
EOF
vlsingle:
  enabled: true
  spec:
    retentionPeriod: "$days"
vlagent:
  enabled: true
EOF
    my $tr = !$traces ? '' : <<EOF;
vtsingle:
  enabled: true
  spec:
    retentionPeriod: "$days"
EOF
    # kubeadm binds scheduler, controller-manager and etcd metrics
    # to localhost, and Cilium replaces kube-proxy: no targets
    return <<EOF . $metrics . $lg . $tr;
fullnameOverride: vm
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false
grafana:
  enabled: true
EOF
}

sub observability_install_cmd {
    my ($kubeconfig, $minor, $o) = @_;

    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig,
%s
export KUBECONFIG=%s
cat > /root/observability-values.yaml <<'VALUES'
%sVALUES
helm repo add vm https://victoriametrics.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update vm >/dev/null
helm upgrade -i observability vm/victoria-metrics-k8s-stack --version %s \
    -n observability --create-namespace -f /root/observability-values.yaml
kubectl -n observability rollout status deploy/observability-grafana --timeout=600s || true
EOF
        observability_values_yaml(%{ $o // {} }), $OBS_CHART_VERSION);
}

sub observability_delete_cmd {
    my ($kubeconfig) = @_;

    # the volumes (metrics, logs, traces) are kept: delete the
    # namespace to drop the data too
    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig);
%s
export KUBECONFIG=%s
helm uninstall observability -n observability --ignore-not-found
EOF
}

# Velero: application backups to S3 (Ceph RGW, pve-s3, any S3),
# CSI snapshots moved to the bucket by the data mover (Kopia).
our $VELERO_CHART_VERSION = '12.2.5';
our $VELERO_VERSION = '1.18.2';
our $VELERO_AWS_PLUGIN = '1.14.4';

sub velero_values_yaml {
    my (%o) = @_;

    my $prefix = defined $o{prefix} && $o{prefix} ne ''
        ? "\n    prefix: " . yq1($o{prefix}) : '';
    return <<EOF;
initContainers:
- name: velero-plugin-for-aws
  image: velero/velero-plugin-for-aws:v$VELERO_AWS_PLUGIN
  volumeMounts:
  - {mountPath: /target, name: plugins}
credentials:
  useSecret: true
  existingSecret: velero-s3
deployNodeAgent: true
snapshotsEnabled: false
configuration:
  features: EnableCSI
  defaultSnapshotMoveData: true
  backupStorageLocation:
  - name: default
    provider: aws
    default: true
    bucket: @{[ yq1($o{bucket}) ]}$prefix
    config:
      region: @{[ yq1($o{region} // 'default') ]}
      s3ForcePathStyle: "true"
      s3Url: @{[ yq1($o{'s3-url'}) ]}
      checksumAlgorithm: ""
EOF
}

sub velero_install_cmd {
    my ($kubeconfig, $minor, $o) = @_;

    my %o = %{ $o // {} };
    die "velero needs s3-url and bucket\n" if !$o{'s3-url'} || !$o{bucket};
    die "s3-url must be an http(s) URL\n" if $o{'s3-url'} !~ m{^https?://[^\s'"]+$};
    my $secret = '';
    if (defined $o{'access-key'} || defined $o{'secret-key'}) {
        for my $k (qw(access-key secret-key)) {
            ($o{$k} // '') =~ m{^[A-Za-z0-9/+=._-]{1,200}$}
                or die "invalid $k characters\n";
        }
        $secret = "kubectl -n velero create secret generic velero-s3 "
            . "--from-literal=cloud=\"\$(printf '[default]\\naws_access_key_id=%s\\n"
            . "aws_secret_access_key=%s\\n' '$o{'access-key'}' '$o{'secret-key'}')\" "
            . "--dry-run=client -o yaml | kubectl apply -f -\n";
    }
    # a snapshot class Velero picks for Proxmox CSI volumes
    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, $secret,
%s
export KUBECONFIG=%s
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
%skubectl apply -f - <<'VSC'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: proxmox-velero
  labels: {velero.io/csi-volumesnapshot-class: "true"}
driver: csi.proxmox.sinextra.dev
deletionPolicy: Delete
VSC
cat > /root/velero-values.yaml <<'VALUES'
%sVALUES
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update vmware-tanzu >/dev/null
helm upgrade -i velero vmware-tanzu/velero --version %s -n velero \
    -f /root/velero-values.yaml
kubectl -n velero rollout status deploy/velero --timeout=600s
EOF
        velero_values_yaml(%o), $VELERO_CHART_VERSION);
}

sub velero_delete_cmd {
    my ($kubeconfig) = @_;

    # backups stay in the bucket
    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig);
%s
export KUBECONFIG=%s
helm uninstall velero -n velero --ignore-not-found
EOF
}

# Flux (GitOps controllers; point them at a repository yourself)
# and, optionally, Flagger for progressive delivery through the
# Gateway API (weights on the Cilium HTTPRoute).
our $FLUX_VERSION = '2.10.0';
our $FLAGGER_VERSION = '1.45.0';

sub flux_install_cmd {
    my ($kubeconfig, $minor, $o) = @_;

    my $flagger = '';
    if (($o // {})->{flagger}) {
        my $metrics = ($o // {})->{'metrics-url'} // 'http://vmsingle-vm.observability.svc:8428';
        $metrics =~ m{^https?://[A-Za-z0-9.:/_-]+$} or die "invalid metrics-url\n";
        $flagger = <<"EOF";
helm repo add flagger https://flagger.app >/dev/null 2>&1 || true
helm repo update flagger >/dev/null
helm upgrade -i flagger flagger/flagger --version $FLAGGER_VERSION \\
    -n flagger-system --create-namespace \\
    --set meshProvider=gatewayapi:v1 --set metricsServer=$metrics
EOF
    }
    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, $FLUX_VERSION, $FLUX_VERSION, $flagger);
%s
export KUBECONFIG=%s
kubectl apply --server-side --force-conflicts \
    -f https://github.com/fluxcd/flux2/releases/download/v%s/install.yaml
kubectl -n flux-system rollout status deploy/source-controller --timeout=600s
# Flux images carry controller versions: record the release
kubectl -n flux-system annotate deploy source-controller \
    pve-k8s.proxmox.com/version=%s --overwrite
%s
EOF
}

sub flux_delete_cmd {
    my ($kubeconfig) = @_;

    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, $FLUX_VERSION);
%s
export KUBECONFIG=%s
helm uninstall flagger -n flagger-system --ignore-not-found
kubectl delete -f https://github.com/fluxcd/flux2/releases/download/v%s/install.yaml \
    --ignore-not-found
EOF
}

# One Helm chart, no settings beyond a few --set: Headlamp, Tetragon,
# KEDA, Kyverno.
our %SIMPLE_CHARTS = (
    headlamp => { repo => 'https://kubernetes-sigs.github.io/headlamp/',
        chart => 'headlamp', version => '0.46.0', ns => 'headlamp' },
    tetragon => { repo => 'https://helm.cilium.io', alias => 'cilium',
        chart => 'tetragon', version => '1.8.0', ns => 'kube-system' },
    keda => { repo => 'https://kedacore.github.io/charts',
        chart => 'keda', version => '2.21.0', ns => 'keda' },
    kyverno => { repo => 'https://kyverno.github.io/kyverno/',
        chart => 'kyverno', version => '3.10.0', app => '1.20.0', ns => 'kyverno' },
);

sub chart_install_cmd {
    my ($addon, $kubeconfig, $o) = @_;

    my $c = $SIMPLE_CHARTS{$addon} or die "no chart for $addon\n";
    my $alias = $c->{alias} // $addon;
    my @set;
    if ($addon eq 'kyverno') {
        # one replica each on a small cluster; 3 admission
        # controllers with ha (the webhook must answer)
        my $n = ($o // {})->{ha} ? 3 : 1;
        push @set, "admissionController.replicas=$n",
            map { "$_.replicas=1" }
                qw(backgroundController cleanupController reportsController);
    }
    my $sets = join '', map { " \\\n    --set $_" } @set;
    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, $alias, $c->{repo},
%s
export KUBECONFIG=%s
helm repo add %s %s >/dev/null 2>&1 || true
helm repo update %s >/dev/null
helm upgrade -i %s %s/%s --version %s -n %s --create-namespace%s
EOF
        $alias, $addon, $alias, $c->{chart}, $c->{version}, $c->{ns}, $sets);
}

sub chart_delete_cmd {
    my ($addon, $kubeconfig) = @_;

    my $c = $SIMPLE_CHARTS{$addon} or die "no chart for $addon\n";
    return sprintf(<<'EOF', helm_ensure_cmd(), $kubeconfig, $addon, $c->{ns});
%s
export KUBECONFIG=%s
helm uninstall %s -n %s --ignore-not-found
EOF
}

# --- Add-on manager catalog ----------------------------------
# One entry per add-on pve-k8s manages. The manager (list,
# update, upgrade step) is driven by this table only:
#   tier     core (every cluster, no disable) | default (installed
#            by provision unless turned off) | optional (enabled
#            on request) | storage (follows the cluster's file tier)
#   version  the pinned version, or a code ref ($minor) for pins
#            that depend on the Kubernetes minor
#   probe    where the running version is read: a workload image
#            tag, or a CRD annotation
#   via      updated together with another entry (one command)
#   options  settings an enable/configure call takes; 'secret'
#            ones are never stored on pmxcfs. Generic for now: a
#            dedicated configuration panel can be added per add-on
#            later without changing the manager.
our @CATALOG = (
    { name => 'cilium', tier => 'core',
      title => 'Cilium (network, load balancer IPs, ingress, Gateway)',
      version => sub { cilium_version_for($_[0]) },
      probe => { kind => 'daemonset', ns => 'kube-system',
          name => 'cilium', image => 'cilium' } },
    { name => 'gateway-api', tier => 'core', via => 'cilium',
      title => 'Gateway API CRDs (experimental channel)',
      version => sub { $GATEWAY_API_VERSION },
      probe => { kind => 'crd', name => 'httproutes.gateway.networking.k8s.io',
          annotation => 'gateway.networking.k8s.io/bundle-version' } },
    { name => 'proxmox-ccm', tier => 'core',
      title => 'Proxmox cloud controller (node identity and topology)',
      version => sub { $CCM_VERSION },
      probe => { kind => 'deployment', ns => 'kube-system',
          name => 'proxmox-cloud-controller-manager' } },
    { name => 'proxmox-csi', tier => 'core',
      title => 'Proxmox CSI (shared-block and local-block volumes)',
      version => sub { $CSI_VERSION },
      probe => { kind => 'deployment', ns => 'csi-proxmox',
          name => 'proxmox-csi-plugin-controller', image => 'proxmox-csi-controller' } },
    { name => 'shared-file', tier => 'storage',
      title => 'Shared file volumes (class shared-file, NFS or CephFS)',
      version => sub { $_[1] && $_[1] eq 'cephfs' ? $CEPH_CSI_VERSION : $NFS_CSI_VERSION },
      probe => sub {
          $_[0] && $_[0] eq 'cephfs'
              ? { kind => 'deployment', ns => 'kube-system',
                  name => 'ceph-csi-cephfs-provisioner', image => 'cephcsi' }
              : { kind => 'deployment', ns => 'kube-system',
                  name => 'csi-nfs-controller', image => 'nfsplugin' } } },
    { name => 'metrics-server', tier => 'default',
      title => 'Pod and node CPU/memory metrics (kubectl top, Metrics tab)',
      version => sub { $METRICS_SERVER_VERSION },
      probe => { kind => 'deployment', ns => 'kube-system',
          name => 'metrics-server' } },
    { name => 'snapshot-controller', tier => 'default',
      title => 'Volume snapshots (VolumeSnapshot CRDs and controller)',
      version => sub { $SNAPSHOT_VERSION },
      probe => { kind => 'deployment', ns => 'kube-system',
          name => 'snapshot-controller' } },
    { name => 'node-problem-detector', tier => 'default',
      title => 'Reports kernel and file system faults as node conditions (feeds auto-repair)',
      version => sub { npd_version_for($_[0]) },
      probe => { kind => 'daemonset', ns => 'kube-system',
          name => 'node-problem-detector' } },
    { name => 'spegel', tier => 'default',
      title => 'Nodes share cached image layers (faster rolls, scale-out and repairs)',
      version => sub { $SPEGEL_VERSION },
      probe => { kind => 'daemonset', ns => 'spegel', name => 'spegel' } },
    { name => 'descheduler', tier => 'default',
      title => 'Rebalances pods; run by pve-k8s after rolls and scale-outs',
      version => sub { descheduler_version_for($_[0]) },
      probe => { kind => 'cronjob', ns => 'kube-system', name => 'descheduler' } },
    { name => 'cert-manager', tier => 'optional',
      title => 'TLS certificates (internal CA by default, ACME optional)',
      version => sub { $CERTMANAGER_VERSION },
      probe => { kind => 'deployment', ns => 'cert-manager',
          name => 'cert-manager', image => 'cert-manager-controller' },
      options => [
          { name => 'issuer', type => 'enum', values => ['ca', 'acme'], default => 'ca' },
          { name => 'email', type => 'string' },
          { name => 'acme-server', type => 'string' },
      ] },
    { name => 'external-dns', tier => 'optional',
      title => 'Publishes Ingress/Gateway hostnames to DNS (PowerDNS)',
      version => sub { $EXTDNS_VERSION },
      probe => { kind => 'deployment', ns => 'external-dns',
          name => 'external-dns' },
      options => [
          { name => 'provider', type => 'enum', values => ['pdns'], default => 'pdns' },
          { name => 'pdns-url', type => 'string', required => 1 },
          { name => 'pdns-api-key', type => 'string', required => 1, secret => 1 },
          { name => 'zone', type => 'string', required => 1 },
      ] },
    { name => 'observability', tier => 'optional',
      title => 'Metrics, logs and traces (VictoriaMetrics, VictoriaLogs, '
          . 'VictoriaTraces preview) with Grafana',
      version => sub { $OBS_VERSION },
      probe => { kind => 'deployment', ns => 'observability',
          name => 'vmagent-vm', image => 'vmagent' },
      install => \&observability_install_cmd, delete => \&observability_delete_cmd,
      options => [
          { name => 'retention', type => 'int', default => 14, min => 1, max => 3650,
            description => 'days to keep metrics, logs and traces' },
          { name => 'storage-size', type => 'int', default => 20, min => 5, max => 4096,
            description => 'GiB per metrics volume' },
          { name => 'logs', type => 'bool', default => 1 },
          { name => 'traces', type => 'bool', default => 0,
            description => 'VictoriaTraces (preview, pre-1.0)' },
          { name => 'ha', type => 'bool', default => 0,
            description => 'metrics replicated twice, logs on 2 nodes (3+ workers)' },
      ] },
    { name => 'velero', tier => 'optional',
      title => 'Application backups to S3 (volume snapshots moved to the bucket)',
      version => sub { $VELERO_VERSION },
      probe => { kind => 'deployment', ns => 'velero', name => 'velero' },
      install => \&velero_install_cmd, delete => \&velero_delete_cmd,
      options => [
          { name => 's3-url', type => 'string', required => 1,
            description => 'S3 endpoint, e.g. https://s3.example.com' },
          { name => 'bucket', type => 'string', required => 1 },
          { name => 'region', type => 'string', default => 'default' },
          { name => 'prefix', type => 'string' },
          { name => 'access-key', type => 'string', required => 1, secret => 1 },
          { name => 'secret-key', type => 'string', required => 1, secret => 1 },
      ] },
    { name => 'flux', tier => 'optional',
      title => 'GitOps controllers (Flux), optional progressive delivery (Flagger)',
      version => sub { $FLUX_VERSION },
      probe => { kind => 'deployment', ns => 'flux-system', name => 'source-controller',
          annotation => 'pve-k8s.proxmox.com/version' },
      install => \&flux_install_cmd, delete => \&flux_delete_cmd,
      options => [
          { name => 'flagger', type => 'bool', default => 0,
            description => 'canary releases through the Gateway API' },
          { name => 'metrics-url', type => 'string',
            description => 'Prometheus-compatible URL for Flagger analysis '
                . '(default: the observability add-on)' },
      ] },
    { name => 'headlamp', tier => 'optional',
      title => 'In-cluster web UI (kubectl port-forward -n headlamp svc/headlamp 8080:80)',
      version => sub { $SIMPLE_CHARTS{headlamp}{version} },
      probe => { kind => 'deployment', ns => 'headlamp', name => 'headlamp' },
      install => sub { chart_install_cmd('headlamp', $_[0], $_[2]) },
      delete => sub { chart_delete_cmd('headlamp', $_[0]) } },
    { name => 'tetragon', tier => 'optional',
      title => 'Runtime security observability and enforcement (eBPF)',
      version => sub { $SIMPLE_CHARTS{tetragon}{version} },
      probe => { kind => 'daemonset', ns => 'kube-system', name => 'tetragon' },
      install => sub { chart_install_cmd('tetragon', $_[0], $_[2]) },
      delete => sub { chart_delete_cmd('tetragon', $_[0]) } },
    { name => 'keda', tier => 'optional',
      title => 'Event-driven pod autoscaling (queues, streams, schedules)',
      version => sub { $SIMPLE_CHARTS{keda}{version} },
      probe => { kind => 'deployment', ns => 'keda', name => 'keda-operator', image => 'keda' },
      install => sub { chart_install_cmd('keda', $_[0], $_[2]) },
      delete => sub { chart_delete_cmd('keda', $_[0]) } },
    { name => 'kyverno', tier => 'optional',
      title => 'Policy engine (validate, mutate, generate, verify images)',
      version => sub { $SIMPLE_CHARTS{kyverno}{app} },
      probe => { kind => 'deployment', ns => 'kyverno',
          name => 'kyverno-admission-controller', image => 'kyverno' },
      install => sub { chart_install_cmd('kyverno', $_[0], $_[2]) },
      delete => sub { chart_delete_cmd('kyverno', $_[0]) },
      options => [
          { name => 'ha', type => 'bool', default => 0,
            description => '3 admission controllers instead of 1' },
      ] },
);

# Pure: check settings against a catalog entry's options. Returns
# (all settings with defaults, the ones to store: no secrets).
# Unknown keys, missing required ones and bad values die.
sub addon_options {
    my ($e, $in) = @_;

    my %spec = map { $_->{name} => $_ } (($e // {})->{options} // [])->@*;
    for my $k (sort keys %{ $in // {} }) {
        die "add-on '$e->{name}' has no setting '$k'\n" if !$spec{$k};
    }
    my (%all, %store);
    for my $o ((($e // {})->{options} // [])->@*) {
        my $v = ($in // {})->{$o->{name}};
        $v = $o->{default} if !defined $v || $v eq '';
        if (!defined $v || $v eq '') {
            die "add-on '$e->{name}' needs '$o->{name}'\n" if $o->{required};
            next;
        }
        my $t = $o->{type} // 'string';
        if ($t eq 'bool') {
            $v =~ /^(?:0|1|true|false)$/ or die "'$o->{name}' must be 0 or 1\n";
            $v = $v =~ /^(?:1|true)$/ ? 1 : 0;
        } elsif ($t eq 'int') {
            $v =~ /^\d+$/ or die "'$o->{name}' must be a whole number\n";
            die "'$o->{name}' must be between $o->{min} and $o->{max}\n"
                if (defined $o->{min} && $v < $o->{min})
                    || (defined $o->{max} && $v > $o->{max});
            $v += 0;
        } elsif ($t eq 'enum') {
            die "'$o->{name}' must be one of " . join(', ', $o->{values}->@*) . "\n"
                if !grep { $_ eq $v } $o->{values}->@*;
        } else {
            die "'$o->{name}' is too long or has control characters\n"
                if length($v) > 512 || $v =~ /[\x00-\x1f]/;
        }
        $all{$o->{name}} = $v;
        $store{$o->{name}} = $v if !$o->{secret};
    }
    return (\%all, \%store);
}

# Update order: what others depend on first.
sub catalog { return @CATALOG }

sub catalog_entry {
    my ($name) = @_;

    my ($e) = grep { $_->{name} eq ($name // '') } @CATALOG;
    return $e;
}

# The version pve-k8s pins for an add-on on Kubernetes $minor
# ($backend: the cluster's file backend, for shared-file).
sub addon_version_for {
    my ($name, $minor, $backend) = @_;

    my $e = catalog_entry($name) or return undef;
    return $e->{version}->($minor, $backend);
}

# Pure: "1.20.4" from an image reference
# (registry/path/name:v1.20.4@sha256:...), optionally only when the
# image name matches.
sub image_version {
    my ($image, $want) = @_;

    my ($path, $tag) = ($image // '') =~ m{^([^@]+?):([^:/@]+)(?:@.*)?$}
        or return undef;
    if (defined $want) {
        my ($base) = $path =~ m{([^/]+)$};
        return undef if ($base // '') ne $want && ($base // '') ne "$want-ci";
    }
    my ($v) = $tag =~ /^v?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$/;
    return $v;
}

# Pure: running versions of every catalog entry, from the cluster's
# Deployments, DaemonSets and CRDs (lists as the API returns them).
# Missing workloads are absent from the result (not installed).
sub probe_versions {
    my ($lists, $backend) = @_;

    my %idx;
    for my $kind (qw(deployment daemonset cronjob crd)) {
        for my $o ((($lists->{$kind} // {})->{items} // [])->@*) {
            my $m = $o->{metadata} // {};
            $idx{$kind}{($m->{namespace} // '') . '/' . ($m->{name} // '')} = $o;
        }
    }
    my %v;
    for my $e (@CATALOG) {
        my $p = ref $e->{probe} eq 'CODE' ? $e->{probe}->($backend) : $e->{probe};
        my $o = $idx{$p->{kind}}{($p->{ns} // '') . '/' . $p->{name}} or next;
        my $ver;
        if ($p->{annotation}) {
            ($ver) = ((($o->{metadata} // {})->{annotations} // {})
                ->{$p->{annotation}} // '') =~ /^v?(\d+\.\d+\.\d+)/;
        } else {
            my $want = $p->{image} // $p->{name};
            my $spec = $o->{spec} // {};
            $spec = (($spec->{jobTemplate} // {})->{spec} // {}) if $p->{kind} eq 'cronjob';
            for my $c (((((($spec)->{template} // {})->{spec} // {})
                    ->{containers}) // [])->@*) {
                $ver = image_version($c->{image}, $want) and last;
            }
        }
        $v{$e->{name}} = $ver // 'unknown';
    }
    return \%v;
}

# Pure: the manager's rows. $state: the cluster's add-on records;
# $live: probe_versions() or undef when the cluster could not be
# read; $file_backend: the cluster's shared-file backend, if any.
sub addon_rows {
    my ($minor, $state, $live, $file_backend) = @_;

    my @rows;
    for my $e (@CATALOG) {
        my $n = $e->{name};
        next if $e->{tier} eq 'storage' && !$file_backend;
        my $rec = ($state // {})->{$n};
        my $pinned = $e->{version}->($minor, $file_backend);
        my $installed = $live ? $live->{$n} : undef;
        my $status;
        if (!$live) {
            $status = 'unknown';
        } elsif (defined $installed) {
            $status = 'installed';
        } elsif ($rec && $rec->{disabled}) {
            $status = 'disabled';
        } elsif ($e->{tier} eq 'optional') {
            $status = 'available';
        } else {
            $status = 'missing';
        }
        my $update = $status eq 'installed' && $installed ne 'unknown'
            && $installed ne $pinned ? 1 : 0;
        push @rows, {
            name => $n,
            title => $e->{title},
            tier => $e->{tier},
            status => $status,
            ($e->{via} ? (via => $e->{via}) : ()),
            pinned => $pinned,
            (defined $installed ? (installed => $installed) : ()),
            update => $update,
            configurable => $e->{options} ? 1 : 0,
            ($e->{options} ? (options => $e->{options}) : ()),
            removable => $e->{delete} ? 1 : 0,
            ($rec && !$rec->{disabled} ? (config => $rec) : ()),
        };
    }
    return \@rows;
}

1;
