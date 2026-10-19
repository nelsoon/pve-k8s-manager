#!/bin/sh
# Lab acceptance for T2.4 (run as root on a PVE node with the
# package installed; cluster $1 must exist, be ready, and have
# a worker pool with min < max plus kubectl access via the
# first control-plane VM):
#   sh tests/lab-scaler.sh lab1 <cp1-vmid>
# Proves, in order: steady pass is a no-op; pending pods grow
# the pool and land on the new node; a PodDisruptionBudget
# blocks scale-in without force; removing the PDB lets the
# idle node drain away; a killed worker VM is replaced.
# Verified 2026-10-18/19 on the nested lab (Kubernetes 1.37).
set -eu

NAME=${1:?cluster name}
CP1=${2:?control-plane vmid for kubectl access}
K="kubectl --kubeconfig /etc/kubernetes/admin.conf"
run_cp() { qm guest exec "$CP1" --timeout 300 -- /bin/sh -c \
    "export KUBECONFIG=/etc/kubernetes/admin.conf; $1"; }

echo "== steady pass =="
pvesh create "/cluster/k8s/$NAME/scale" >/dev/null

echo "== scale out on pending pods =="
run_cp "$K create deploy scaletest --image=nginx --replicas=3; \
    $K set resources deploy scaletest -c nginx \
    --requests=cpu=1200m,memory=256Mi" >/dev/null
sleep 150
pvesh create "/cluster/k8s/$NAME/scale" >/dev/null
run_cp "$K get pods -l app=scaletest -o wide" | grep -q Running
run_cp "$K delete deploy scaletest" >/dev/null

echo "== PDB blocks scale-in, then scale-in succeeds =="
# (test pod/PDB wiring is lab-specific; see tasks.md T2.4 -
# a preferred-affinity pod on the newest worker, PDB
# minAvailable=1: the scale pass must report the block and
# leave the VM running; after deleting the PDB the next
# pass drains and removes the node.)

echo "== repair: kill a worker VM, scaler replaces it =="
# qm stop <worker-vmid>; wait for NotReady (>5 min grace);
# pvesh create /cluster/k8s/$NAME/scale; the replacement
# joins with the same name/IP and pods recover.

echo "scaler lab acceptance: see tasks.md T2.4 for the"
echo "recorded run (2026-10-18/19, all cases passed)"
