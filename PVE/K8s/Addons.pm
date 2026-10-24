# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Addons;

use strict;
use warnings;

# In-cluster add-ons (T1.5). Versions are pinned here and only
# here; upgrades bump these pins and re-apply, never hand-edits
# inside the cluster. Install commands run on the first
# control-plane node via the guest agent.

# Cilium 1.20.x is e2e-tested upstream up to Kubernetes 1.36;
# 1.37 support lands in Cilium 1.21 (pre-release at pin time),
# so 1.37 clusters rely on Kubernetes backward compatibility
# until 1.21 is stable - proven in the lab before release.
our $CILIUM_VERSION = '1.20.3';
our $HELM_VERSION = '3.16.3';
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
EOF
}

my sub helm_ensure_cmd {
    return sprintf(<<'EOF', $HELM_VERSION);
if [ ! -x /usr/local/bin/helm ]; then
    curl -fsSL -o /tmp/helm.tgz https://get.helm.sh/helm-v%s-linux-amd64.tar.gz
    tar -xzf /tmp/helm.tgz -C /tmp
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
    rm -rf /tmp/helm.tgz /tmp/linux-amd64
fi
EOF
}

# Experimental channel: Cilium 1.20's Gateway controller
# requires TLSRoutes, BackendTLSPolicies and ReferenceGrant
# v1, which the standard channel does not ship.
our $GATEWAY_API_VERSION = '1.5.0';

sub cilium_install_cmd {
    my ($kubeconfig, $vip) = @_;

    # Single-quoted heredoc + sprintf: an interpolating heredoc
    # strips backslash-newline continuations, which once made
    # helm run without its namespace/values arguments.
    my @args = (helm_ensure_cmd(), $kubeconfig,
        $GATEWAY_API_VERSION, cilium_values_yaml($vip),
        $CILIUM_VERSION);
    return sprintf(<<'EOF', @args);
%s
export KUBECONFIG=%s
# Gateway API CRDs are not part of the Cilium chart; install
# them first or the Gateway resources cannot be created.
GW=https://github.com/kubernetes-sigs/gateway-api/releases/download/v%s/experimental-install.yaml
kubectl apply -f $GW
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

our $CSI_VERSION = '0.20.0';
our $CSI_CHART_VERSION = '0.5.12';

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
our $NFS_CSI_VERSION = '4.11.0';

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
our $CEPH_CSI_VERSION = '3.18.1';

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
  pool: ${fs}_data
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

    return sprintf(<<'EOF', $HELM_VERSION, $kubeconfig, $values_yaml, $CSI_CHART_VERSION);
if [ ! -x /usr/local/bin/helm ]; then
    curl -fsSL -o /tmp/helm.tgz https://get.helm.sh/helm-v%s-linux-amd64.tar.gz
    tar -xzf /tmp/helm.tgz -C /tmp
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
    rm -rf /tmp/helm.tgz /tmp/linux-amd64
fi
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

our $CERTMANAGER_VERSION = '1.18.2';

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

our $EXTDNS_VERSION = '0.20.0';
our $EXTDNS_CHART_VERSION = '1.20.1';

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

    $api_key =~ /\A[A-Za-z0-9._~+\/=-]+\z/
        or die "invalid PowerDNS api key characters\n";
    my @args = (helm_ensure_cmd(), $kubeconfig, $api_key,
        $values_yaml, $EXTDNS_CHART_VERSION);
    return sprintf(<<'EOF', @args);
%s
export KUBECONFIG=%s
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-dns create secret generic external-dns-pdns \
    --from-literal=api-key=%s --dry-run=client -o yaml | kubectl apply -f -
cat > /root/external-dns-values.yaml <<'VALUES'
%sVALUES
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
helm repo update external-dns >/dev/null
helm upgrade -i external-dns external-dns/external-dns \
    --version %s -n external-dns -f /root/external-dns-values.yaml
kubectl -n external-dns rollout status deploy/external-dns --timeout=300s
EOF
}

1;
