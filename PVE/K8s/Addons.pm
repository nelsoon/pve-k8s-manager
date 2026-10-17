# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Addons;

use strict;
use warnings;

# In-cluster add-ons (T1.5). Versions are pinned here and only
# here; upgrades bump these pins and re-apply, never hand-edits
# inside the cluster. Install commands run on the first
# control-plane node via the guest agent.

our $CILIUM_VERSION = '1.16.6';
our $HELM_VERSION = '3.16.3';
our $POD_CIDR = '10.244.0.0/16';

sub cilium_values_yaml {
    my ($vip) = @_;

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
envoy:
  enabled: false
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

sub cilium_install_cmd {
    my ($kubeconfig, $vip) = @_;

    # Single-quoted heredoc + sprintf: an interpolating heredoc
    # strips backslash-newline continuations, which once made
    # helm run without its namespace/values arguments.
    my @args = (helm_ensure_cmd(), $kubeconfig,
        cilium_values_yaml($vip), $CILIUM_VERSION);
    return sprintf(<<'EOF', @args);
%s
export KUBECONFIG=%s
cat > /root/cilium-values.yaml <<'VALUES'
%s
VALUES
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade -i cilium cilium/cilium --version %s \
    -n kube-system -f /root/cilium-values.yaml
kubectl -n kube-system delete ds kube-proxy --ignore-not-found
kubectl -n kube-system rollout status ds/cilium --timeout=600s
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=300s
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

    return <<EOF;
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata: {name: default}
spec:
  blocks:
  - start: "$start"
    stop: "$stop"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: default}
spec:
  interfaces: [eth0]
  loadBalancerIPs: true
EOF
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

1;
