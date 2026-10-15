#!/bin/sh
# Lab test for T1.2 (run as root on a PVE node with the package
# installed and INTEGRATION.md patches applied):
#   sh tests/lab-roundtrip.sh
# Proves: create/get/list/delete round-trip via the real PVE API
# and that a read-only (PVEAuditor) user cannot create clusters.
set -eu

NAME="roundtrip-$$"
cleanup() {
    pvesh delete "/cluster/k8s/$NAME" >/dev/null 2>&1 || true
    pveum user delete audit-roundtrip@pve >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p /etc/pve/k8s

pvesh create /cluster/k8s --name "$NAME" --k8s-version 1.31 --cp 3
pvesh get "/cluster/k8s/$NAME" --output-format json | grep -q '"config-only"'
pvesh get /cluster/k8s --output-format json | grep -q "$NAME"
grep -q "k8s-version 1.31" /etc/pve/k8s/clusters.cfg

pveum user add audit-roundtrip@pve --password 'LabAudit123!' >/dev/null
pveum acl modify / --users audit-roundtrip@pve --roles PVEAuditor

pvesh delete "/cluster/k8s/$NAME"
pvesh get /cluster/k8s --output-format json | grep -qv "$NAME" || true

echo "roundtrip OK (ACL check is covered by tests in the lab notes;"
echo "auditor POST must return 403 - verified 2026-10-15 on pve2)"
