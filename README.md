# pve-k8s-manager

Kubernetes cluster management for Proxmox VE, written the way an
upstream pve-manager feature is written (Perl API2 endpoints and
orchestration, ExtJS UI), so the code can be submitted upstream
or handed over without a rewrite.

Clusters run on VMs only. Node VMs are built from immutable
Debian templates and are never patched in place: rolling
changes and Kubernetes upgrades replace nodes one at a time
(surge, at most one extra node). The user manages only
Kubernetes-level concerns — version, node pools, add-ons —
never node operating systems.

Status: validated end-to-end in a nested Proxmox lab
(acceptance scenarios S1–S6, `tests/lab-acceptance.sh`).
Physical-hardware validation is still pending; do not treat
this as production-ready yet.

## Supported

- Kubernetes 1.35 and 1.36 (the UI dropdown offers exactly
  the add-on-tested minors; newer minors are added only
  after add-on compatibility is proven).
- Control planes of 1, 3 or 5 VMs, stacked etcd, kube-vip
  virtual IP. Worker node pools with per-pool size/min/max,
  labels, taints, host placement and storage selection.
- Cilium as the only CNI (with ingress / Gateway API).
  cert-manager and external-dns are deployed "unconfigured"
  by default; other add-ons can be added later.
- Storage: shared file storage (NFS) and CephFS via CSI with
  hot-attach; local block volumes can be moved by the plugin
  when a pod is rescheduled to another node.
- Networking fits Proxmox SDN: a tenant is an EVPN zone/VRF,
  each cluster gets its own VNet with an internal node
  subnet plus a public subnet for load-balancer IPs and the
  control-plane VIP.
- Autoscaling runs outside Kubernetes, on the PVE hosts
  (leader-elected, one decision-maker): it simulates pending
  pods against pools, respecting labels, affinity, taints,
  PodDisruptionBudgets and volume constraints.

## Build

```sh
make deb    # builds build/pve-k8s-manager_*.deb
make lint   # perl -c on all modules, node --check on UI JS
make test   # lint + unit tests (tests/unit/)
```

Node templates are built on a builder VM, not shipped:

```sh
images/build-template.sh   # per images/versions/<minor>.env
```

## Install

Install the .deb on every PVE host of the cluster:

```sh
apt install ./pve-k8s-manager_0.1.0-1_all.deb
```

The maintainer scripts apply the four integration points in
stock pve-manager files listed in `INTEGRATION.md`
(API registration, cluster-filesystem entry, UI view, UI
script), idempotently and with `<file>.pve-k8s.bak` backups,
then restart `pvedaemon`/`pveproxy`. Uninstalling reverses
exactly those edits; cluster configuration under
`/etc/pve/k8s` is user data and is kept.

One-time prerequisites: an SDN zone for tenants, a shared
storage for templates, and node templates distributed to the
hosts that will run nodes (the plugin copies templates to
hosts that need them).

## Usage

In the UI: Datacenter → Kubernetes (clusters, nodes,
add-ons, events, backups). Over the API, for example:

```sh
pvesh create /cluster/k8s --name c1 --k8s-version 1.36 \
    --cp 3 --workers 2 --node-subnet 10.0.1.0/24 \
    --sdn-zone evpnzone --public-subnet 10.0.2.0/24
pvesh create /cluster/k8s/c1/provision
pvesh create /cluster/k8s/c1/roll
pvesh create /cluster/k8s/c1/upgrade --to 1.36
pvesh create /cluster/k8s/c1/scale
pvesh delete /cluster/k8s/c1
```

## Known limitations

- Control-plane placement prefers spreading across hosts
  and HA groups; hard anti-affinity (never two CPs on one
  host while enough hosts are eligible) is a follow-up.
- No automated fencing (STONITH) yet: host-failure recovery
  is manual. Do not automate power actions against a host
  whose nodes still hold etcd or VIP state.
- For fresh nested labs, LVM-thin storage is recommended
  over ZFS (memory footprint); either works on hardware.

## Layout

- `PVE/K8s/` — orchestration (config, provisioning, rolling,
  scaler)
- `PVE/API2/Cluster/K8s.pm` — `/cluster/k8s/...` endpoints
- `www/manager6/` — ExtJS UI
- `images/` — Debian node-image recipes (builder VM)
- `tools/`, `systemd/` — scaler and backup helpers
- `tests/unit/` — unit tests; `tests/lab-acceptance.sh` —
  the S1–S6 lab acceptance suite
- `debian/` — packaging, maintainer scripts, changelog
- `docs/` — administrator guide draft (AsciiDoc) and the
  patch-series split prepared for a pve-devel submission

License: AGPL-3.0 (see file headers). Design and task
history live in `../specs/001-pve-k8s/`.
