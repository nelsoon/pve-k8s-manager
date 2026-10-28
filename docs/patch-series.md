# Patch series for a future pve-devel submission

Prepared so the feature can be posted to pve-devel as a
reviewable series instead of one large change. Order is
bottom-up; each patch builds on the previous ones. Until
acceptance, the same points are applied at install time by
`debian/integrate.pl` (see INTEGRATION.md) — upstream, they
are simply part of the tree.

1. **pve-cluster: observe `k8s/clusters.cfg`**
   One line in the observed-files registry of
   `PVE/Cluster.pm`, plus the `/etc/pve/k8s/` basedir.
   No behaviour change for existing files.

2. **pve-manager: `PVE/K8s/*` orchestration modules**
   New files only: cluster config handling, provisioning,
   surge rolling replacement, upgrades, scaler decisions.
   Pure helpers are unit-tested (`tests/unit/`).

3. **pve-manager: `/cluster/k8s` API2 endpoints**
   `PVE/API2/Cluster/K8s.pm` (new file) plus its two-line
   registration in `PVE/API2/Cluster.pm`. Endpoints follow
   the existing API conventions (worker tasks for long
   operations: `k8sprovision`, `k8sroll`, `k8supgrade`,
   `k8sscale`).

4. **pve-manager: Datacenter Kubernetes UI**
   `www/manager6/PVEK8sWorkspace.js` (new file), one view
   entry in the Datacenter view list, one script tag in
   `index.html.tpl`. The UI is a thin client of the API.

5. **pve-manager: tools and units**
   `tools/pve-k8s-scaler`, `tools/pve-k8s-backup`, and their
   systemd service/timer units; the VRF sysctl drop-in.

6. **docs: administrator guide**
   `docs/pve-k8s.adoc` added to the documentation tree.

Signing/licensing follows the Proxmox contributor process
(CLA, AGPL-3.0-or-later headers already in every file).
