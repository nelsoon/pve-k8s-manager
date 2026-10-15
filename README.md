# pve-k8s-manager

Kubernetes cluster management for Proxmox VE, built in Proxmox's
own stack (Perl API/orchestration, ExtJS UI) so the code can be
submitted upstream or handed over without a rewrite.

Status: Increment 0 — repo skeleton only. No product behaviour yet.
Design lives in `../specs/001-pve-k8s/` (spec.md, plan.md, tasks.md).

## Layout

- `PVE/K8s/` — orchestration modules (config, provisioning, rolling)
- `PVE/API2/K8s/` — PVE API2 endpoints (`/cluster/k8s/...`)
- `www/manager6/` — ExtJS UI panels (pve-manager conventions)
- `images/` — Debian node-image recipes (builder-VM builds)
- `addons/` — pinned in-cluster add-on charts (Cilium, CSI, CCM, ...)
- `debian/` — Debian packaging; installable on existing PVE

## Build / check

```sh
make deb    # builds build/pve-k8s-manager_*.deb
make lint   # perl -c on all modules, node --check on all UI JS
make test   # lint + package content sanity
```

License: AGPL-3.0 (see file headers). Contributions are intended
to be submittable upstream; see CONTRIBUTING.md for the CLA note.
