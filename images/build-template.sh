#!/bin/sh
# Build an immutable Kubernetes node template on a Proxmox node.
# Runs as root on the PVE node. See README.md in this directory.
#
# Required env (or flags):
#   BUILDER_IP   static IP for the throwaway builder VM, e.g. 192.168.200.50
#   BUILDER_GW   gateway for the builder VM, e.g. 192.168.200.1
# Optional:
#   --storage <id>   storage for the template disk (default local-zfs)
#   --vmid <id>      VMID to use for builder/template (default 9000)
#   --bridge <id>    bridge for the builder VM (default vmbr0)
set -eu
cd "$(dirname "$0")"
. ./versions.env

STORAGE=local-zfs
VMID=9000
BRIDGE=vmbr0
K8S_VERSION=${K8S_VERSION:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --storage) STORAGE=$2; shift 2 ;;
        --vmid) VMID=$2; shift 2 ;;
        --bridge) BRIDGE=$2; shift 2 ;;
        --k8s-version) K8S_VERSION=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$K8S_VERSION" ] || { echo "set --k8s-version <minor> (see versions/)" >&2; exit 2; }
[ -f "versions/$K8S_VERSION.env" ] || { echo "no pin file versions/$K8S_VERSION.env" >&2; exit 2; }
. "versions/$K8S_VERSION.env"

: "${BUILDER_IP:?set BUILDER_IP (static IP for the builder VM)}"
: "${BUILDER_GW:?set BUILDER_GW (gateway for the builder VM)}"

CACHE_DIR=/var/lib/vz/template/cache
IMAGE=$CACHE_DIR/$DEBIAN_IMAGE_NAME
NAME="k8s-node-$K8S_MINOR-r$IMAGE_REVISION"

mkdir -p "$CACHE_DIR" /var/lib/vz/snippets
if [ ! -f "$IMAGE" ]; then
    echo "downloading $DEBIAN_IMAGE_URL"
    wget -q -O "$IMAGE.tmp" "$DEBIAN_IMAGE_URL"
    mv "$IMAGE.tmp" "$IMAGE"
fi
SHA256=$(sha256sum "$IMAGE" | cut -d' ' -f1)
GIT_SHA=$(git -C .. rev-parse --short HEAD 2>/dev/null || echo nogit)
echo "image sha256: $SHA256"
echo "building template $NAME (vmid $VMID) on storage $STORAGE"

pvesm set local --content iso,backup,vztmpl,snippets 2>/dev/null || true

sed -e "s|__K8S_MINOR__|$K8S_MINOR|g" -e "s|__K8S_REPO__|$K8S_REPO|g" \
    cloud-init/user-data.tmpl > /var/lib/vz/snippets/k8s-node-user-data.yaml

cleanup_builder() {
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" >/dev/null 2>&1 || true
}
trap cleanup_builder INT TERM

qm create "$VMID" --name "$NAME" --memory "$TEMPLATE_MEMORY" \
    --cores "$TEMPLATE_CORES" --cpu host \
    --net0 "virtio,bridge=$BRIDGE" \
    --scsihw virtio-scsi-single \
    --scsi0 "$STORAGE:0,import-from=$IMAGE" \
    --boot order=scsi0 --agent enabled=1 \
    --ide2 "$STORAGE:cloudinit" \
    --cicustom "user=local:snippets/k8s-node-user-data.yaml" \
    --ipconfig0 "ip=$BUILDER_IP/24,gw=$BUILDER_GW" \
    --nameserver "${BUILDER_DNS:-1.1.1.1}" \
    --serial0 socket --vga serial0 >/dev/null

qm resize "$VMID" scsi0 "$TEMPLATE_DISK" >/dev/null || true
qm start "$VMID" >/dev/null
# From here on the VM contains build progress; never destroy it
# from a signal trap (a killed build script once destroyed a
# finished image this way). Cleanup is a manual decision.
trap - INT TERM
echo "builder VM $VMID started; waiting for guest agent..."

i=0
while [ $i -lt 80 ]; do
    qm agent "$VMID" ping >/dev/null 2>&1 && break
    i=$((i + 1))
    sleep 15
done
[ $i -lt 80 ] || { echo "guest agent never came up" >&2; exit 1; }

echo "waiting for cloud-init to finish (image report file)..."
# Note: do not use `cloud-init status --wait` here - the recipe
# runs `cloud-init clean`, after which status reports "not run"
# and --wait can block forever. The report file is the signal.
i=0
while [ $i -lt 120 ]; do
    if qm guest exec "$VMID" --timeout 60 -- /bin/sh -c \
        'cat /var/log/k8s-image-report.txt' \
        > /tmp/k8s-build-report.$$.json 2>/dev/null \
        && grep -q 'kubeadm:' /tmp/k8s-build-report.$$.json; then
        break
    fi
    i=$((i + 1))
    sleep 15
done
grep -o '"exitcode" : [0-9]*' /tmp/k8s-build-report.$$.json || true
cat /tmp/k8s-build-report.$$.json | grep -o 'kubeadm: [^\\"]*' || true
grep -q 'kubeadm: v' /tmp/k8s-build-report.$$.json \
    || { echo "image report missing kubeadm; build is bad" >&2; exit 1; }
grep -q 'MISSING' /tmp/k8s-build-report.$$.json \
    && { echo "image report has MISSING components" >&2; exit 1; }
rm -f /tmp/k8s-build-report.$$.json

qm shutdown "$VMID" >/dev/null
i=0
while [ $i -lt 40 ]; do
    status=$(qm status "$VMID" | awk '{print $2}')
    [ "$status" = "stopped" ] && break
    i=$((i + 1))
    sleep 10
done
[ "$status" = "stopped" ] || { echo "builder did not stop in time" >&2; exit 1; }

# The template must not inherit the builder's cloud-init data or IP.
qm set "$VMID" --delete cicustom,ipconfig0,nameserver >/dev/null

qm set "$VMID" --description "k8s node template
k8s-version: $K8S_MINOR
image-revision: $IMAGE_REVISION
source-sha256: $SHA256
recipe-git: $GIT_SHA" >/dev/null

qm template "$VMID" >/dev/null
trap - INT TERM
echo "template ready: $NAME (vmid $VMID)"
qm config "$VMID" | grep -E '^(name|template|description):' || true
