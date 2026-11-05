# Integration with Proxmox VE (upstream-shaped)

This package is written the way an upstream pve-manager feature
is written. Until (if ever) it is merged, installing it requires
the integration points below in stock PVE files. They are
applied by the package's maintainer scripts
(`debian/integrate.pl`, embedded into postinst/postrm):
idempotently, with `<file>.pve-k8s.bak` backups, skipped with
a warning when an anchor no longer matches, and removed again
on uninstall. They are listed here so reviewers can see
exactly what would change upstream, where it becomes a
non-issue.

1. API registration — in `PVE/API2/Cluster.pm`, alongside the
   other Cluster children:

   ```perl
   use PVE::API2::Cluster::K8s;
   # ...
   __PACKAGE__->register_method({
       subclass => "PVE::API2::Cluster::K8s",
       path => 'k8s',
   });
   ```

2. Cluster-filesystem file registry — in `PVE/Cluster.pm`, in
   the observed-files hash:

   ```perl
   'k8s/clusters.cfg' => 1,
   ```

3. UI tab — in `PVE.dc.Config` (`pvemanagerlib.js`), inside
   the `caps.dc['Sys.Audit']` block, alongside the other
   Datacenter views:

   ```js
   {
       xtype: 'pveDcK8sView',
       title: gettext('Kubernetes'),
       iconCls: 'fa fa-cubes',
       itemId: 'k8s',
   },
   ```

4. UI script — `index.html.tpl` loads
   `/pve2/js/PVEK8sWorkspace.js` after `pvemanagerlib.js`
   (upstream, the file would simply be part of the manager's
   concatenated JS).

5. Resource index — in the `resources` endpoint of
   `PVE/API2/Cluster.pm`, return one datacenter-wide entry
   per managed Kubernetes cluster for users with
   `Sys.Audit` on `/cluster`:

   ```perl
   {
       id => "k8s/$name",
       type => 'k8s',
       name => $name,
       k8s => $name,
       status => $state,
   }
   ```

   The endpoint's type enums and return schema also learn
   the `k8s` type. A Kubernetes cluster has no owning PVE
   node and no VMID.

6. Resource-tree type — in `PVE.tree.ResourceTree`
   (`pvemanagerlib.js`), add a `k8s` type default (Kubernetes
   label and cubes icon) and its type ordering.

7. Workspace routing — in `PVE.StdWorkspace`
   (`pvemanagerlib.js`), route resource type `k8s` to
   `PVE.k8s.Config`, the cluster's own page (stock pve-nav
   treelist as second sidebar).

8. Task descriptions — in `PVE.Utils`
   (`pvemanagerlib.js`), register `[subject, verb]`
   descriptions for the `k8s*` task types, so the task log
   reads "Kubernetes Cluster ui1 - Start VMs" instead of
   the raw type `k8spowerstart`.

Everything else is new files only: `PVE/K8s/Config.pm`,
`PVE/API2/Cluster/K8s.pm`, UI files, and this package's own
data. Existing behaviour is unchanged apart from the
additional resource type above.

Note: `/etc/pve/k8s/` must exist before the first write
(pmxcfs writes a temp file next to `clusters.cfg`). The
observed-files entry above lets the cluster filesystem
tooling prepare the basedir; postinst also creates it
defensively.
