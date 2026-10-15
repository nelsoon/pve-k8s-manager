# Node images

Immutable Debian templates for Kubernetes nodes. One template
per Kubernetes version x image revision; nodes are only ever
cloned from these, never patched in place (spec: Locked
Decisions).

## Contents

- `versions.env` — shared pinned inputs (Debian cloud image,
  template sizing). Per-Kubernetes-version pins (minor line,
  package repo, image revision) live in `versions/<minor>.env`;
  several versions can exist side by side. Builds are
  reproducible from these pins plus this repo's git SHA.
- `cloud-init/user-data.tmpl` — first-boot customisation applied
  to the pristine Debian cloud image inside the builder VM:
  containerd, kubelet/kubeadm/kubectl (held), qemu-guest-agent,
  kernel modules/sysctls for Kubernetes, SSH server removed.
- `build-template.sh` — runs on a Proxmox node: creates the
  builder VM from the cloud image, waits for cloud-init to
  finish, verifies versions, stamps the template with source
  checksum + recipe git SHA + revision, converts it to a
  template, and removes the builder VM.

## Usage (on a PVE node, as root)

```sh
cd images
./build-template.sh --k8s-version 1.31 --storage local-zfs --vmid 9000
```

The resulting template is named `k8s-node-<k8s-version>-r<rev>`.
