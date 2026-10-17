# Integration with Proxmox VE (upstream-shaped)

This package is written the way an upstream pve-manager feature
is written. Until (if ever) it is merged, installing it requires
two one-line integration points in stock PVE files, applied by
the package's maintainer scripts in a real packaging pass
(T4.3). They are listed here so reviewers can see exactly what
would change upstream, where it becomes a non-issue.

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

Everything else is new files only: `PVE/K8s/Config.pm`,
`PVE/API2/Cluster/K8s.pm`, UI files, and this package's own
data. No existing behaviour is modified.

Note: `/etc/pve/k8s/` must exist before the first write
(pmxcfs writes a temp file next to `clusters.cfg`). With the
observed-files entry above, the basedir is expected to be
prepared by the cluster filesystem tooling; in the nested lab
it was created once by hand (`mkdir /etc/pve/k8s`) and the
API's create path could take care of this defensively in a
later task.
