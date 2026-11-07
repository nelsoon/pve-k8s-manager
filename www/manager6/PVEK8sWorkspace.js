// Copyright (C) 2026 pve-k8s contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
// Datacenter -> Kubernetes (T1.6): cluster list/health, create
// wizard and provision-with-task-progress, in pve-manager style.
// The REST API stays the contract; this panel is a thin client.

Ext.define('PVE.dc.K8sCreateWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcK8sCreateWindow',

    title: gettext('Create Kubernetes Cluster'),
    modal: true,
    width: 520,
    layout: 'fit',

    // callback fired after create + provision task was started
    onDone: undefined,

    initComponent: function() {
        let me = this;

        let form = Ext.create('Ext.form.Panel', {
            bodyPadding: 10,
            border: false,
            fieldDefaults: {
                labelWidth: 160,
                anchor: '100%',
            },
            items: [
                {
                    xtype: 'fieldset',
                    title: gettext('Basics'),
                    collapsible: false,
                    defaults: { anchor: '100%', labelWidth: 160 },
                    items: [
                        {
                            xtype: 'textfield',
                            name: 'name',
                            fieldLabel: gettext('Name'),
                            emptyText: 'c1',
                            allowBlank: false,
                        },
                        {
                            xtype: 'combobox',
                            name: 'k8s-version',
                            fieldLabel: gettext('Kubernetes Version'),
                            // add-on-tested minors only; keep in sync
                            // with PVE::K8s::Config supported list
                            store: ['1.35', '1.36'],
                            value: '1.36',
                            editable: false,
                            allowBlank: false,
                        },
                        {
                            xtype: 'combobox',
                            name: 'cp',
                            fieldLabel: gettext('Control Plane Nodes'),
                            store: [1, 3, 5],
                            value: 3,
                            editable: false,
                        },
                        {
                            // select from existing storages,
                            // never free text
                            xtype: 'combobox',
                            name: 'storage',
                            fieldLabel: gettext('Storage'),
                            store: Ext.create('Ext.data.Store', {
                                fields: ['storage', 'shared'],
                                proxy: {
                                    type: 'proxmox',
                                    url: '/api2/json/storage',
                                },
                                autoLoad: true,
                            }),
                            displayField: 'storage',
                            valueField: 'storage',
                            queryMode: 'local',
                            editable: false,
                            emptyText: gettext('Proxmox storage for node disks'),
                        },
                        {
                            xtype: 'combobox',
                            name: 'storage-profile',
                            fieldLabel: gettext('Storage Profile'),
                            store: [
                                ['shared', gettext('Shared (Ceph)')],
                                ['local', gettext('Local disks')],
                            ],
                            value: 'shared',
                            editable: false,
                        },
                        {
                            // HA is refused by the backend when
                            // the disk storage is not shared;
                            // the submit handler checks first
                            // so the user hears it here, not
                            // mid-provision
                            xtype: 'combobox',
                            name: 'cp-policy',
                            fieldLabel: gettext('Control Plane Failure Policy'),
                            store: [
                                ['replace', gettext('Replace (plugin rebuilds)')],
                                ['ha', gettext('HA (Proxmox reboots VM)')],
                            ],
                            value: 'replace',
                            editable: false,
                        },
                        {
                            // select from existing SDN zones
                            xtype: 'combobox',
                            name: 'sdn-zone',
                            fieldLabel: gettext('SDN Zone'),
                            store: Ext.create('Ext.data.Store', {
                                fields: ['zone'],
                                proxy: {
                                    type: 'proxmox',
                                    url: '/api2/json/cluster/sdn/zones',
                                },
                                autoLoad: true,
                            }),
                            displayField: 'zone',
                            valueField: 'zone',
                            queryMode: 'local',
                            editable: false,
                            emptyText: gettext('dedicated VNet mode (with Public Subnet)'),
                        },
                        {
                            xtype: 'displayfield',
                            value: gettext('A default worker group '
                                + '(2 nodes) is created with the cluster. '
                                + 'Add, edit or remove worker groups later '
                                + 'under Nodes.'),
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: gettext('Advanced (network, architecture)'),
                    collapsible: true,
                    collapsed: true,
                    defaults: { anchor: '100%', labelWidth: 160 },
                    items: [
                        {
                            xtype: 'textfield',
                            name: 'public-subnet',
                            fieldLabel: gettext('Public Subnet (LB/VIP)'),
                            emptyText: '192.168.212.0/24',
                        },
                        {
                            xtype: 'textfield',
                            name: 'node-subnet',
                            fieldLabel: gettext('SDN Node Subnet'),
                            emptyText: '192.168.200.0/24',
                        },
                        {
                            xtype: 'textfield',
                            name: 'gateway',
                            fieldLabel: gettext('Gateway'),
                            emptyText: '192.168.200.1',
                        },
                        {
                            xtype: 'textfield',
                            name: 'lb-range',
                            fieldLabel: gettext('LoadBalancer Range'),
                            emptyText: '192.168.200.100-192.168.200.120',
                        },
                        {
                            xtype: 'textfield',
                            name: 'builder-ip',
                            fieldLabel: gettext('Template Builder IP'),
                            emptyText: gettext('free IP; plugin builds a missing template itself'),
                        },
                        {
                            xtype: 'combobox',
                            name: 'cp-arch',
                            fieldLabel: gettext('Control Plane Architecture'),
                            store: ['amd64', 'arm64'],
                            value: 'amd64',
                            editable: false,
                        },
                    ],
                },
            ],
        });

        Ext.apply(me, {
            items: [form],
            buttons: [
                {
                    text: gettext('Create and Provision'),
                    handler: function() {
                        if (!form.isValid()) {
                            return;
                        }
                        let values = form.getValues();
                        // optional fields: omit blanks entirely
                        Object.keys(values).forEach(function(key) {
                            if (values[key] === '') {
                                delete values[key];
                            }
                        });
                        if (values['cp-policy'] === 'ha') {
                            let sc = form.down('[name=storage]');
                            let rec = sc && sc.getStore()
                                ? sc.getStore().findRecord(
                                    'storage', sc.getValue())
                                : null;
                            if (!rec || !rec.get('shared')) {
                                Ext.Msg.alert(gettext('Error'),
                                    gettext('HA needs shared storage '
                                    + 'for the control-plane disks. '
                                    + 'Pick a shared storage or the '
                                    + 'Replace policy.'));
                                return;
                            }
                        }
                        // worker groups are managed after
                        // creation, under Nodes; the backend
                        // default (one group of 2) applies
                        me.setLoading(true);
                        Proxmox.Utils.API2Request({
                            url: '/cluster/k8s',
                            method: 'POST',
                            params: values,
                            failure: function(response) {
                                me.setLoading(false);
                                Ext.Msg.alert(gettext('Error'),
                                    Proxmox.Utils.extractRequestError(response, true));
                            },
                            success: function() {
                                Proxmox.Utils.API2Request({
                                    url: '/cluster/k8s/' + values.name + '/provision',
                                    method: 'POST',
                                    failure: function(response) {
                                        me.setLoading(false);
                                        Ext.Msg.alert(gettext('Error'),
                                            Proxmox.Utils.extractRequestError(response, true));
                                    },
                                    success: function(response) {
                                        me.setLoading(false);
                                        let upid = response.result.data;
                                        if (upid) {
                                            Ext.create('Proxmox.window.TaskViewer', {
                                                upid: upid,
                                            }).show();
                                        }
                                        if (me.onDone) {
                                            me.onDone();
                                        }
                                        me.close();
                                    },
                                });
                            },
                        });
                    },
                },
                {
                    text: gettext('Cancel'),
                    handler: function() {
                        me.close();
                    },
                },
            ],
        });

        me.callParent();
    },
});


// Kubernetes views. At Datacenter level the entry is just
// the cluster list with Create/Destroy; all detail lives
// on each cluster's own page (PVE.k8s.Config, opened from
// the left resource panel), which navigates VM-style with
// a stock pve-nav treelist as its second sidebar.
Ext.define('PVE.dc.K8sView', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveDcK8sView',

    title: gettext('Kubernetes'),
    // no separate title header: like a VM page
    // (PVE.panel.Config), the title lives inside the
    // single top toolbar as a tbtext
    header: false,

    // Set when the view is opened for one resource-tree
    // cluster (PVE.k8s.Config); then the selector is hidden
    // and the selected cluster is fixed.
    fixedClusterName: undefined,
    pveSelNode: undefined,

    initComponent: function() {
        let me = this;
        let fixedClusterName = me.fixedClusterName;
        if (!fixedClusterName && me.pveSelNode && me.pveSelNode.data
            && me.pveSelNode.data.type === 'k8s') {
            fixedClusterName = me.pveSelNode.data.name
                || me.pveSelNode.data.k8s;
        }
        me.fixedClusterName = fixedClusterName;
        if (fixedClusterName) {
            me.title = gettext('Kubernetes') + ': ' + fixedClusterName;
        }

        let api = function(opts) {
            Proxmox.Utils.API2Request(Ext.apply({
                failure: function(response) {
                    Ext.Msg.alert(gettext('Error'),
                        Proxmox.Utils.extractRequestError(response, true));
                },
            }, opts));
        };
        let task = function(upid) {
            if (upid) {
                Ext.create('Proxmox.window.TaskViewer', {
                    upid: upid,
                }).show();
            }
        };
        let confirmDo = function(title, msg, url, params) {
            Ext.Msg.confirm(title, msg, function(answer) {
                if (answer !== 'yes') {
                    return;
                }
                api({
                    url: url, method: 'POST', params: params || {},
                    success: function(r) {
                        task(r.result.data); me.reloadClusters();
                    },
                });
            });
        };

        let clusterStore = Ext.create('Ext.data.Store', {
            fields: ['name', 'state', 'k8s-version', 'template-rev',
                'cp', 'workers', 'node-subnet', 'gateway', 'lb-range',
                'storage', 'sdn-zone', 'public-subnet',
                'maintenance-window', 'pools', 'action-state',
                'storage-profile', 'cp-policy', 'scaler-state'],
            proxy: { type: 'proxmox', url: '/api2/json/cluster/k8s' },
        });

        let panels = {};   // clusterName:panelKey -> component

        let grid = function(fields, url, columns, tbar) {
            return Ext.create('Ext.grid.Panel', {
                header: false,
                border: false,
                store: Ext.create('Ext.data.Store', {
                    fields: fields,
                    proxy: { type: 'proxmox', url: url },
                    autoLoad: true,
                }),
                columns: columns,
                tbar: tbar || [],
            });
        };

        let overviewPanel = function(rec) {
            let name = rec.name;
            let poolsText = '';
            try {
                let groups = Ext.decode(rec.pools || 'null');
                if (groups) {
                    poolsText = groups.map(function(gr) {
                        let s = gr.name + ': ' + gr.size
                            + gettext(' nodes');
                        if (gr.min !== undefined || gr.max !== undefined) {
                            s += ' (min ' + (gr.min !== undefined ? gr.min : gr.size)
                                + ', max ' + (gr.max !== undefined ? gr.max : gr.size) + ')';
                        }
                        if (gr.arch) { s += ', ' + gr.arch; }
                        return s;
                    }).join('; ');
                }
            } catch (e) {
                poolsText = rec.pools || '';
            }
            let actionText = '';
            try {
                let act = Ext.decode(rec['action-state'] || 'null');
                if (act && act.key) {
                    actionText = act.key + (act.node
                        ? ' on ' + act.node : '');
                }
            } catch (e) { /* recorded by the backend */ }
            let parkedText = '';
            try {
                let ss = Ext.decode(rec['scaler-state'] || 'null');
                if (ss && ss.parked) { parkedText = ss.parked; }
            } catch (e) { /* recorded by the backend */ }
            let rows = [
                ['Name', name],
                ['State', rec.state || ''],
                ['Running Action', actionText],
                ['Storage Profile', rec['storage-profile'] || ''],
                ['CP Failure Policy', rec['cp-policy'] || 'replace'],
                ['Parked (awaiting placement)', parkedText],
                ['Kubernetes', rec['k8s-version'] || ''],
                ['Template Rev', rec['template-rev'] || ''],
                ['Control Plane', rec.cp || ''],
                ['Workers', rec.workers || ''],
                ['Node Subnet', rec['node-subnet'] || ''],
                ['Gateway', rec.gateway || ''],
                ['SDN Zone', rec['sdn-zone'] || ''],
                ['Public Subnet', rec['public-subnet'] || ''],
                ['LB Range', rec['lb-range'] || ''],
                ['Storage', rec.storage || ''],
                ['Maintenance Window', rec['maintenance-window'] || ''],
                ['Node Groups', poolsText],
            ].filter(function(row) {
                return row[1] !== '' && row[1] !== undefined;
            });
            let certInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Certificates'),
                value: gettext('loading...'),
                labelWidth: 160,
            });
            api({
                url: '/cluster/k8s/' + name + '/certificates',
                method: 'GET',
                success: function(r) {
                    let worst = 'ok';
                    let soon = '';
                    (r.result.data || []).forEach(function(c) {
                        if (c.level === 'critical') { worst = 'critical'; }
                        else if (c.level === 'warning' && worst === 'ok') {
                            worst = 'warning';
                        }
                        if (c.level !== 'ok' && !soon) {
                            soon = c.certificate + ' (' + c.residual + ')';
                        }
                    });
                    certInfo.setValue(worst === 'ok'
                        ? gettext('ok')
                        : Ext.String.format(gettext('{0}: next {1}'),
                            worst, soon));
                },
                failure: function() {
                    certInfo.setValue(gettext('unknown'));
                },
            });
            let act = function(label, icon, fn) {
                return {
                    text: label, iconCls: icon,
                    handler: function() { fn(name); },
                };
            };
            return Ext.create('Ext.panel.Panel', {
                header: false,
                border: false,
                bodyPadding: 10,
                scrollable: true,
                tbar: [
                    act(gettext('Provision'), 'fa fa-fw fa-play', function(n) {
                        api({
                            url: '/cluster/k8s/' + n + '/provision',
                            method: 'POST',
                            success: function(r) {
                                task(r.result.data); me.reloadClusters();
                            },
                        });
                    }),
                    act(gettext('Roll'), 'fa fa-fw fa-refresh', function(n) {
                        confirmDo(gettext('Roll'),
                            Ext.String.format(gettext(
                                'Roll cluster {0} onto the latest node image?'), n),
                            '/cluster/k8s/' + n + '/roll', { force: 1 });
                    }),
                    act(gettext('Scale'), 'fa fa-fw fa-arrows-alt', function(n) {
                        api({
                            url: '/cluster/k8s/' + n + '/scale',
                            method: 'POST',
                            success: function(r) {
                                task(r.result.data); me.reloadClusters();
                            },
                        });
                    }),
                    act(gettext('Upgrade'), 'fa fa-fw fa-arrow-circle-up', function(n) {
                        Ext.Msg.prompt(gettext('Upgrade Kubernetes'),
                            gettext('Target version (one minor up, e.g. 1.36):'),
                            function(answer, value) {
                                if (answer !== 'ok' || !value) { return; }
                                api({
                                    url: '/cluster/k8s/' + n + '/upgrade',
                                    method: 'POST',
                                    params: { to: value, force: 1 },
                                    success: function(r) {
                                        task(r.result.data); me.reloadClusters();
                                    },
                                });
                            });
                    }),
                    act(gettext('Start VMs'), 'fa fa-fw fa-play-circle', function(n) {
                        api({
                            url: '/cluster/k8s/' + n + '/power',
                            method: 'POST',
                            params: { action: 'start' },
                            success: function(r) {
                                task(r.result.data);
                            },
                        });
                    }),
                    act(gettext('Stop VMs'), 'fa fa-fw fa-stop', function(n) {
                        Ext.Msg.confirm(gettext('Stop VMs'),
                            Ext.String.format(gettext(
                                'Stop all node VMs of {0} (workers first)?'), n),
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                api({
                                    url: '/cluster/k8s/' + n + '/power',
                                    method: 'POST',
                                    params: { action: 'stop' },
                                    success: function(r) {
                                        task(r.result.data);
                                    },
                                });
                            });
                    }),
                    act(gettext('Kubeconfig'), 'fa fa-fw fa-key', function(n) {
                        api({
                            url: '/cluster/k8s/' + n + '/kubeconfig',
                            method: 'GET',
                            success: function(r) {
                                let data = r.result.data;
                                let win = Ext.create('Ext.window.Window', {
                                    title: Ext.String.format(gettext(
                                        'Kubeconfig for {0} ({1})'),
                                        n, data.expires),
                                    width: 680, height: 420, layout: 'fit',
                                    items: [{
                                        xtype: 'textarea',
                                        value: data.kubeconfig,
                                        readOnly: true,
                                    }],
                                    buttons: [{
                                        text: gettext('Download'),
                                        handler: function() {
                                            let blob = new Blob(
                                                [data.kubeconfig],
                                                { type: 'text/yaml' });
                                            let a = document.createElement('a');
                                            a.href = URL.createObjectURL(blob);
                                            a.download = name + '.kubeconfig';
                                            a.click();
                                            URL.revokeObjectURL(a.href);
                                        },
                                    }],
                                });
                                win.show();
                            },
                        });
                    }),
                ],
                items: [{
                    xtype: 'form',
                    border: false,
                    items: rows.map(function(row) {
                        let value = Ext.htmlEncode(String(row[1]));
                        if (row[0] === 'State') {
                            // stock state icon, like the
                            // cluster list renders it
                            let icon = row[1] === 'ready'
                                ? 'fa fa-check good'
                                : 'fa fa-exclamation-triangle warning';
                            value = '<i class="' + icon + '"></i> '
                                + value;
                        }
                        return {
                            xtype: 'displayfield',
                            fieldLabel: row[0],
                            value: value,
                            labelWidth: 160,
                        };
                    }).concat([certInfo]),
                }],
            });
        };

        let nodesPanel = function(name) {
            let store = Ext.create('Ext.data.Store', {
                fields: ['name', 'pool', 'pvehost', 'vmid', 'ip', 'rev'],
            });
            let g;
            let nodeAct = function(action, label, extra, confirmText) {
                return {
                    text: label,
                    disabled: true,
                    // a shared marker property, NOT itemId:
                    // this Ext build drops toolbar items that
                    // share an itemId (only the last survives,
                    // which ate Drain and Replace)
                    nodebtn: true,
                    handler: function() {
                        let sel = g.getSelection();
                        if (!sel || !sel.length) { return; }
                        let node = sel[0].data.name;
                        Ext.Msg.confirm(gettext('Confirm'),
                            Ext.String.format(confirmText
                                || gettext('{0} node {1}?'), label, node),
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                api({
                                    url: '/cluster/k8s/' + name + '/nodes/' + node + action,
                                    method: 'POST',
                                    params: extra || {},
                                    success: function(r) {
                                        task(r.result.data);
                                    },
                                });
                            });
                    },
                };
            };
            g = Ext.create('Ext.grid.Panel', {
                border: false,
                store: store,
                columns: [
                    { text: gettext('Node'), dataIndex: 'name', flex: 1 },
                    { text: gettext('Pool'), dataIndex: 'pool', flex: 1 },
                    { text: gettext('PVE Host'), dataIndex: 'pvehost', flex: 1 },
                    { text: 'VMID', dataIndex: 'vmid', width: 70 },
                    { text: 'IP', dataIndex: 'ip', flex: 1 },
                    { text: gettext('Image Rev'), dataIndex: 'rev', width: 80 },
                ],
                tbar: [
                    nodeAct('/drain', gettext('Drain')),
                    nodeAct('/replace', gettext('Replace')),
                    nodeAct('/force-retire', gettext('Force Retire'),
                        { force: 1, replace: 1 },
                        gettext('Force-retire DEAD node {1}? Only if its VM '
                            + 'is powered off or lost. A replacement will '
                            + 'be provisioned.')),
                    {
                        text: gettext('Reload'),
                        handler: function() { loadNodes(); },
                    },
                    {
                        text: gettext('Evacuate Host'),
                        iconCls: 'fa fa-fw fa-sign-out',
                        handler: function() {
                            Ext.Msg.prompt(gettext('Evacuate PVE Host'),
                                gettext('Host to empty by live-migrating all '
                                    + 'managed cluster VMs off it:'),
                                function(answer, value) {
                                    if (answer !== 'ok' || !value) { return; }
                                    api({
                                        url: '/cluster/k8s/' + name
                                            + '/hosts/' + value + '/evacuate',
                                        method: 'POST',
                                        success: function(r) {
                                            task(r.result.data);
                                        },
                                    });
                                });
                        },
                    },
                ],
                listeners: {
                    selectionchange: function(model, selected) {
                        let dis = !selected || !selected.length;
                        g.query('button[nodebtn]').forEach(function(b) {
                            b.setDisabled(dis);
                        });
                    },
                },
            });
            // --- node groups (pools): create/edit/delete
            // over the same record; saving stores the new
            // groups and converges membership to them.
            let groupStore = Ext.create('Ext.data.Store', {
                fields: ['name', 'size', 'min', 'max', 'labels',
                    'taints', 'hosts', 'storage', 'arch', 'policy',
                    'count'],
            });
            let groupsGrid;
            let currentGroups = function() {
                return groupStore.getRange().map(function(r) {
                    let d = {
                        name: r.data.name,
                        size: r.data.size, min: r.data.min,
                        max: r.data.max,
                    };
                    ['labels', 'taints', 'hosts', 'storage', 'arch',
                        'policy'].forEach(function(k) {
                            if (r.data[k]) { d[k] = r.data[k]; }
                        });
                    return d;
                });
            };
            let saveGroups = function(groups) {
                api({
                    url: '/cluster/k8s/' + name, method: 'PUT',
                    params: { pools: Ext.encode(groups) },
                    success: function() {
                        // converge membership to the declared
                        // group sizes: provision adds missing
                        // nodes and drains+retires excess ones.
                        // (The scaler only reacts to pending
                        // pods / idle nodes between min and
                        // max - it does not enforce Nodes.)
                        api({
                            url: '/cluster/k8s/' + name + '/provision',
                            method: 'POST',
                            success: function(r) {
                                task(r.result.data);
                                loadNodes();
                            },
                        });
                    },
                });
            };
            let groupWindow = function(existing) {
                let isNew = !existing;
                let win;
                let gform = Ext.create('Ext.form.Panel', {
                    bodyPadding: 10, border: false,
                    fieldDefaults: { labelWidth: 130, anchor: '100%' },
                    items: [
                        {
                            xtype: 'textfield', name: 'name',
                            fieldLabel: gettext('Name'),
                            value: existing ? existing.name : '',
                            readOnly: !isNew, allowBlank: false,
                        },
                        {
                            xtype: 'numberfield', name: 'size',
                            fieldLabel: gettext('Nodes'),
                            value: existing ? existing.size : 2,
                            minValue: 0, maxValue: 50, allowBlank: false,
                        },
                        {
                            xtype: 'numberfield', name: 'min',
                            fieldLabel: gettext('Min (scaler)'),
                            value: existing ? existing.min : 1,
                            minValue: 0, maxValue: 50, allowBlank: false,
                        },
                        {
                            xtype: 'numberfield', name: 'max',
                            fieldLabel: gettext('Max (scaler)'),
                            value: existing ? existing.max : 3,
                            minValue: 0, maxValue: 50, allowBlank: false,
                        },
                        {
                            xtype: 'combobox', name: 'arch',
                            fieldLabel: gettext('Architecture'),
                            store: ['', 'amd64', 'arm64'],
                            value: existing ? (existing.arch || '') : '',
                            editable: false,
                        },
                        {
                            xtype: 'textfield', name: 'labels',
                            fieldLabel: gettext('Labels'),
                            value: existing ? (existing.labels || '') : '',
                            emptyText: 'key=value,...',
                        },
                        {
                            xtype: 'textfield', name: 'taints',
                            fieldLabel: gettext('Taints'),
                            value: existing ? (existing.taints || '') : '',
                            emptyText: 'key=value:NoSchedule,...',
                        },
                        {
                            xtype: 'textfield', name: 'hosts',
                            fieldLabel: gettext('PVE Hosts'),
                            value: existing ? (existing.hosts || '') : '',
                            emptyText: gettext('any (comma-separated to pin)'),
                        },
                        {
                            xtype: 'textfield', name: 'storage',
                            fieldLabel: gettext('Storage'),
                            value: existing ? (existing.storage || '') : '',
                            emptyText: gettext('cluster default'),
                        },
                        {
                            // HA is refused by the backend
                            // unless this group's storage (and
                            // the pod storage) is shared
                            xtype: 'combobox', name: 'policy',
                            fieldLabel: gettext('Failure Policy'),
                            store: [
                                ['replace', gettext('Replace')],
                                ['ha', gettext('HA (shared storage only)')],
                            ],
                            value: existing
                                ? (existing.policy || 'replace')
                                : 'replace',
                            editable: false,
                        },
                    ],
                });
                win = Ext.create('Ext.window.Window', {
                    title: isNew ? gettext('Create Node Group')
                        : gettext('Edit Node Group'),
                    modal: true, width: 460, layout: 'fit',
                    items: [gform],
                    buttons: [
                        {
                            text: gettext('Save'),
                            handler: function() {
                                if (!gform.isValid()) { return; }
                                let v = gform.getValues();
                                if (!(v.min <= v.size && v.size <= v.max)) {
                                    Ext.Msg.alert(gettext('Error'),
                                        gettext('Min <= Nodes <= Max required'));
                                    return;
                                }
                                let entry = {
                                    name: v.name,
                                    size: parseInt(v.size, 10),
                                    min: parseInt(v.min, 10),
                                    max: parseInt(v.max, 10),
                                };
                                ['labels', 'taints', 'hosts',
                                    'storage', 'arch', 'policy']
                                    .forEach(function(k) {
                                        if (v[k]) { entry[k] = v[k]; }
                                    });
                                let groups = currentGroups().filter(
                                    function(gr) {
                                        return gr.name !== entry.name;
                                    });
                                groups.push(entry);
                                win.close();
                                saveGroups(groups);
                            },
                        },
                        {
                            text: gettext('Cancel'),
                            handler: function() { win.close(); },
                        },
                    ],
                });
                win.show();
            };
            let groupBtn = function(text, fn, needsSel) {
                return {
                    text: text,
                    disabled: !!needsSel,
                    groupbtn: !!needsSel,
                    handler: function() {
                        let sel = groupsGrid.getSelection();
                        fn(sel && sel.length ? sel[0].data : null);
                    },
                };
            };
            groupsGrid = Ext.create('Ext.grid.Panel', {
                header: false,
                height: 190,
                border: false,
                store: groupStore,
                columns: [
                    { text: gettext('Group'), dataIndex: 'name', flex: 1 },
                    { text: gettext('Nodes'), dataIndex: 'size', width: 60 },
                    { text: gettext('Current'), dataIndex: 'count', width: 70 },
                    { text: 'Min', dataIndex: 'min', width: 50 },
                    { text: 'Max', dataIndex: 'max', width: 50 },
                    { text: gettext('Arch'), dataIndex: 'arch', width: 70 },
                    { text: gettext('Labels'), dataIndex: 'labels', flex: 1 },
                    { text: gettext('Taints'), dataIndex: 'taints', flex: 1 },
                    { text: gettext('Hosts'), dataIndex: 'hosts', flex: 1 },
                    { text: gettext('Storage'), dataIndex: 'storage', flex: 1 },
                    { text: gettext('Policy'), dataIndex: 'policy', width: 70 },
                ],
                tbar: [
                    groupBtn(gettext('Create'), function() {
                        groupWindow(null);
                    }),
                    groupBtn(gettext('Edit'), function(data) {
                        if (data) { groupWindow(data); }
                    }, true),
                    groupBtn(gettext('Delete'), function(data) {
                        if (!data) { return; }
                        Ext.Msg.confirm(gettext('Confirm'),
                            Ext.String.format(gettext(
                                'Delete node group {0}? Its nodes are '
                                + 'drained and retired on save.'), data.name),
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                saveGroups(currentGroups().filter(
                                    function(gr) {
                                        return gr.name !== data.name;
                                    }));
                            });
                    }, true),
                ],
                listeners: {
                    selectionchange: function(model, selected) {
                        let dis = !selected || !selected.length;
                        groupsGrid.query('button[groupbtn]').forEach(function(b) {
                            b.setDisabled(dis);
                        });
                    },
                },
            });

            let loadNodes = function() {
                api({
                    url: '/cluster/k8s/' + name, method: 'GET',
                    success: function(r) {
                        let rec = r.result.data || {};
                        let nodes = Ext.decode(rec.nodes || '[]');
                        store.loadData(nodes);
                        let groups;
                        try {
                            groups = Ext.decode(rec.pools || 'null');
                        } catch (e) {
                            groups = null;
                        }
                        if (!groups) {
                            let size = parseInt(rec.workers, 10) || 2;
                            groups = [{
                                name: 'default', size: size,
                                min: size, max: size,
                            }];
                        }
                        let counts = {};
                        nodes.forEach(function(n) {
                            counts[n.pool] = (counts[n.pool] || 0) + 1;
                        });
                        groups.forEach(function(gr) {
                            gr.count = counts[gr.name] || 0;
                            if (gr.min === undefined) { gr.min = gr.size; }
                            if (gr.max === undefined) { gr.max = gr.size; }
                        });
                        groupStore.loadData(groups);
                    },
                });
            };
            loadNodes();
            return Ext.create('Ext.panel.Panel', {
                header: false,
                layout: { type: 'vbox', align: 'stretch' },
                border: false,
                items: [groupsGrid, Ext.apply(g, { flex: 1 })],
            });
        };

        let workloadsPanel = function(name) {
            let mk = function(fields, columns) {
                return {
                    xtype: 'grid',
                    border: false,
                    store: Ext.create('Ext.data.Store', { fields: fields }),
                    columns: columns,
                };
            };
            let tabs = Ext.create('Ext.tab.Panel', {
                header: false,
                border: false,
                items: [
                    Ext.apply(mk(
                        ['name', 'namespace', 'ready', 'uptodate', 'available'],
                        [
                            { text: gettext('Deployment'), dataIndex: 'name', flex: 1 },
                            { text: gettext('Namespace'), dataIndex: 'namespace', flex: 1 },
                            { text: gettext('Ready'), dataIndex: 'ready', width: 80 },
                            { text: gettext('Up-to-date'), dataIndex: 'uptodate', width: 100 },
                            { text: gettext('Available'), dataIndex: 'available', width: 100 },
                        ]), { title: gettext('Deployments') }),
                    Ext.apply(mk(
                        ['name', 'namespace', 'ready', 'status', 'restarts', 'node'],
                        [
                            { text: gettext('Pod'), dataIndex: 'name', flex: 1 },
                            { text: gettext('Namespace'), dataIndex: 'namespace', flex: 1 },
                            { text: gettext('Ready'), dataIndex: 'ready', width: 80 },
                            { text: gettext('Status'), dataIndex: 'status', width: 110 },
                            { text: gettext('Restarts'), dataIndex: 'restarts', width: 90 },
                            { text: gettext('Node'), dataIndex: 'node', flex: 1 },
                        ]), { title: gettext('Pods') }),
                    Ext.apply(mk(
                        ['name', 'namespace', 'type', 'clusterip', 'externalip', 'ports'],
                        [
                            { text: gettext('Service'), dataIndex: 'name', flex: 1 },
                            { text: gettext('Namespace'), dataIndex: 'namespace', flex: 1 },
                            { text: gettext('Type'), dataIndex: 'type', width: 120 },
                            { text: 'ClusterIP', dataIndex: 'clusterip', width: 120 },
                            { text: gettext('External IP'), dataIndex: 'externalip', width: 130 },
                            { text: gettext('Ports'), dataIndex: 'ports', flex: 1 },
                        ]), { title: gettext('Services') }),
                ],
            });
            api({
                url: '/cluster/k8s/' + name + '/workloads', method: 'GET',
                success: function(r) {
                    let d = r.result.data || {};
                    tabs.items.getAt(0).getStore().loadData(d.deployments || []);
                    tabs.items.getAt(1).getStore().loadData(d.pods || []);
                    tabs.items.getAt(2).getStore().loadData(d.services || []);
                },
            });
            return tabs;
        };

        let metricsPanel = function(name) {
            let nodeGrid = Ext.create('Ext.grid.Panel', {
                title: gettext('Node VMs (PVE)'),
                border: false,
                store: Ext.create('Ext.data.Store', {
                    fields: ['name', 'cpu', 'mem', 'maxmem'],
                }),
                columns: [
                    { text: gettext('Node'), dataIndex: 'name', flex: 1 },
                    {
                        text: gettext('CPU'),
                        dataIndex: 'cpu', width: 110,
                        renderer: function(v) {
                            return v === undefined || v === null
                                ? '–' : (v * 100).toFixed(1) + ' %';
                        },
                    },
                    {
                        text: gettext('Memory'),
                        dataIndex: 'mem', flex: 1,
                        renderer: function(v, meta, rec) {
                            if (v === undefined || v === null
                                || !rec.data.maxmem) {
                                return '–';
                            }
                            return (v / 1073741824).toFixed(1) + ' / '
                                + (rec.data.maxmem / 1073741824).toFixed(1)
                                + ' GiB';
                        },
                    },
                ],
            });
            let podGrid = Ext.create('Ext.grid.Panel', {
                title: gettext('Pods (metrics-server)'),
                border: false,
                store: Ext.create('Ext.data.Store', {
                    fields: ['namespace', 'name', 'cpu_m', 'mem_mi'],
                }),
                columns: [
                    { text: gettext('Namespace'), dataIndex: 'namespace', flex: 1 },
                    { text: gettext('Pod'), dataIndex: 'name', flex: 1 },
                    {
                        text: gettext('CPU (m)'),
                        dataIndex: 'cpu_m', width: 100,
                    },
                    {
                        text: gettext('Memory (MiB)'),
                        dataIndex: 'mem_mi', width: 130,
                    },
                ],
            });
            let note = Ext.create('Ext.form.field.Display', {
                value: '',
            });
            let enableBtn = {
                text: gettext('Enable metrics-server'),
                iconCls: 'fa fa-fw fa-line-chart',
                hidden: true,
                handler: function() {
                    api({
                        url: '/cluster/k8s/' + name
                            + '/addons/metrics-server/enable',
                        method: 'POST',
                        success: function(r) {
                            task(r.result.data);
                        },
                    });
                },
            };
            let panel = Ext.create('Ext.panel.Panel', {
                header: false,
                border: false,
                layout: { type: 'vbox', align: 'stretch' },
                tbar: [enableBtn],
                items: [
                    Ext.apply(nodeGrid, { height: 200 }),
                    note,
                    Ext.apply(podGrid, { flex: 1 }),
                ],
            });
            api({
                url: '/cluster/k8s/' + name + '/metrics', method: 'GET',
                success: function(r) {
                    let d = r.result.data || {};
                    nodeGrid.getStore().loadData(d.nodes || []);
                    podGrid.getStore().loadData(d.pods || []);
                    if (!d.metrics_server) {
                        enableBtn.show();
                        note.setValue(gettext('Pod metrics need the '
                            + 'metrics-server add-on.'));
                    }
                },
            });
            return panel;
        };

        let addonsPanel = function(name) {
            let store = Ext.create('Ext.data.Store', {
                fields: ['name', 'status', 'mustdeploy', 'summary'],
                proxy: {
                    type: 'proxmox',
                    url: '/api2/json/cluster/k8s/' + name + '/addons',
                },
                autoLoad: true,
            });
            let configure = function(addon) {
                let items = [];
                if (addon === 'cert-manager') {
                    items = [
                        {
                            xtype: 'combobox', name: 'issuer',
                            fieldLabel: gettext('Issuer'),
                            store: ['ca', 'acme'], value: 'ca',
                            editable: false, allowBlank: false,
                        },
                        {
                            xtype: 'textfield', name: 'email',
                            fieldLabel: gettext('ACME Email'),
                            emptyText: gettext('only for the acme issuer'),
                        },
                    ];
                } else if (addon === 'external-dns') {
                    items = [
                        {
                            xtype: 'textfield', name: 'pdns-url',
                            fieldLabel: gettext('PowerDNS API URL'),
                            emptyText: 'http://dns.example.com:8081/api/v1/servers/localhost',
                            allowBlank: false,
                        },
                        {
                            xtype: 'textfield', name: 'zone',
                            fieldLabel: gettext('Zone'),
                            emptyText: 'example.com', allowBlank: false,
                        },
                        {
                            xtype: 'textfield', name: 'pdns-api-key',
                            fieldLabel: gettext('PowerDNS API Key'),
                            inputType: 'password', allowBlank: false,
                        },
                    ];
                }
                if (!items.length) {
                    api({
                        url: '/cluster/k8s/' + name + '/addons/' + addon + '/enable',
                        method: 'POST',
                        success: function(r) {
                            task(r.result.data); store.load();
                        },
                    });
                    return;
                }
                let formWin = Ext.create('Ext.window.Window', {
                    title: Ext.String.format(gettext('Configure {0}'), addon),
                    modal: true, width: 560, layout: 'fit',
                    items: [{
                        xtype: 'form', bodyPadding: 10, border: false,
                        fieldDefaults: { labelWidth: 170, anchor: '100%' },
                        items: items,
                        buttons: [{
                            text: gettext('Enable'),
                            handler: function() {
                                let form = formWin.down('form').getForm();
                                if (!form.isValid()) { return; }
                                api({
                                    url: '/cluster/k8s/' + name + '/addons/'
                                        + addon + '/enable',
                                    method: 'POST',
                                    params: form.getValues(),
                                    success: function(r) {
                                        formWin.close(); store.load();
                                        task(r.result.data);
                                    },
                                });
                            },
                        }, {
                            text: gettext('Cancel'),
                            handler: function() { formWin.close(); },
                        }],
                    }],
                });
                formWin.show();
            };
            let selectedAddon = null;
            let enableBtn = Ext.create('Ext.button.Button', {
                text: gettext('Configure / Enable'),
                iconCls: 'fa fa-fw fa-cog',
                disabled: true,
                handler: function() {
                    if (selectedAddon) { configure(selectedAddon); }
                },
            });
            let disableBtn = Ext.create('Ext.button.Button', {
                text: gettext('Disable'),
                iconCls: 'fa fa-fw fa-ban',
                disabled: true,
                handler: function() {
                    let sel = g.getSelection();
                    if (!sel || !sel.length) { return; }
                    let addon = sel[0].data.name;
                    api({
                        url: '/cluster/k8s/' + name + '/addons/'
                            + addon + '/disable',
                        method: 'POST',
                        success: function(r) {
                            task(r.result.data); store.load();
                        },
                    });
                },
            });
            let g = Ext.create('Ext.grid.Panel', {
                header: false,
                border: false,
                store: store,
                tbar: [enableBtn, disableBtn],
                columns: [
                    { text: gettext('Add-on'), dataIndex: 'name', width: 160 },
                    { text: gettext('Status'), dataIndex: 'status', width: 130 },
                    {
                        text: gettext('Recommended'),
                        dataIndex: 'mustdeploy', width: 120,
                        renderer: function(v) {
                            return v ? gettext('Yes') : '';
                        },
                    },
                    { text: gettext('Description'), dataIndex: 'summary', flex: 1 },
                ],
                listeners: {
                    selectionchange: function(model, selected) {
                        let rec = selected && selected[0];
                        selectedAddon = rec ? rec.data.name : null;
                        enableBtn.setDisabled(!rec
                            || (rec.data.name !== 'cert-manager'
                                && rec.data.name !== 'external-dns'
                                && rec.data.name !== 'metrics-server'));
                        disableBtn.setDisabled(!rec
                            || rec.data.name !== 'metrics-server'
                            || rec.data.status !== 'configured');
                    },
                },
            });
            return g;
        };

        let eventsPanel = function(name) {
            return grid(
                ['time', 'type', 'reason', 'object', 'message'],
                '/api2/json/cluster/k8s/' + name + '/events',
                [
                    { text: gettext('Time'), dataIndex: 'time', width: 170 },
                    { text: gettext('Type'), dataIndex: 'type', width: 80 },
                    { text: gettext('Reason'), dataIndex: 'reason', width: 130 },
                    { text: gettext('Object'), dataIndex: 'object', width: 160 },
                    { text: gettext('Message'), dataIndex: 'message', flex: 1 },
                ]);
        };

        let backupsPanel = function(name) {
            let g = grid(
                ['file', 'size', 'mtime'],
                '/api2/json/cluster/k8s/' + name + '/backups',
                [
                    { text: gettext('File'), dataIndex: 'file', flex: 1 },
                    {
                        text: gettext('Size'),
                        dataIndex: 'size', width: 110,
                        renderer: function(v) {
                            return v
                                ? (v / 1048576).toFixed(1) + ' MiB' : '';
                        },
                    },
                    {
                        text: gettext('Modified'),
                        dataIndex: 'mtime', width: 170,
                        renderer: function(v) {
                            return v
                                ? Ext.Date.format(new Date(v * 1000),
                                    'Y-m-d H:i:s') : '';
                        },
                    },
                ], [
                    {
                        text: gettext('Backup Now'),
                        iconCls: 'fa fa-fw fa-save',
                        handler: function() {
                            api({
                                url: '/cluster/k8s/' + name + '/backup',
                                method: 'POST',
                                success: function(r) {
                                    task(r.result.data);
                                    g.getStore().load();
                                },
                            });
                        },
                    },
                    {
                        text: gettext('Restore'),
                        iconCls: 'fa fa-fw fa-undo',
                        handler: function() {
                            let sel = g.getSelection();
                            let file = sel && sel.length
                                ? sel[0].data.file : null;
                            if (!file) {
                                Ext.Msg.alert(gettext('Restore'),
                                    gettext('Select a backup file first.'));
                                return;
                            }
                            Ext.Msg.confirm(gettext('Restore etcd'),
                                Ext.String.format(gettext(
                                    'Roll back ALL cluster data to {0}?'),
                                    file),
                                function(answer) {
                                    if (answer !== 'yes') { return; }
                                    api({
                                        url: '/cluster/k8s/' + name + '/restore',
                                        method: 'POST',
                                        params: { backup: file, force: 1 },
                                        success: function(r) {
                                            task(r.result.data);
                                        },
                                    });
                                });
                        },
                    },
                ]);
            return g;
        };

        let settingsPanel = function(rec) {
            let name = rec.name;
            let form = Ext.create('Ext.form.Panel', {
                border: false,
                fieldDefaults: { labelWidth: 200, anchor: '100%' },
                items: [
                    {
                        xtype: 'textfield',
                        name: 'maintenance-window',
                        fieldLabel: gettext('Maintenance Window'),
                        value: rec['maintenance-window'] || '',
                        emptyText: 'HH:MM-HH:MM (empty = always)',
                    },
                    {
                        xtype: 'numberfield',
                        name: 'backup-retention',
                        fieldLabel: gettext('Backup Retention'),
                        value: rec['backup-retention'] || '',
                        minValue: 1, maxValue: 100,
                        emptyText: gettext('etcd backups to keep'),
                    },
                    {
                        xtype: 'combobox',
                        name: 'cp-policy',
                        fieldLabel: gettext('Control Plane Failure Policy'),
                        store: [
                            ['replace', gettext('Replace (plugin rebuilds)')],
                            ['ha', gettext('HA (Proxmox reboots VM)')],
                        ],
                        value: rec['cp-policy'] || 'replace',
                        editable: false,
                    },
                    {
                        xtype: 'combobox',
                        name: 'storage-profile',
                        fieldLabel: gettext('Storage Profile'),
                        store: [
                            ['shared', gettext('Shared (Ceph)')],
                            ['local', gettext('Local disks')],
                        ],
                        value: rec['storage-profile'] || '',
                        editable: false,
                    },
                    {
                        xtype: 'textfield',
                        name: 'description',
                        fieldLabel: gettext('Description'),
                        value: rec.description || '',
                    },
                ],
                buttons: [{
                    text: gettext('Save'),
                    handler: function() {
                        if (!form.isValid()) { return; }
                        let values = form.getValues();
                        let params = {};
                        Object.keys(values).forEach(function(k) {
                            if (values[k] !== '') {
                                params[k] = values[k];
                            }
                        });
                        if (!Object.keys(params).length) { return; }
                        api({
                            url: '/cluster/k8s/' + name, method: 'PUT',
                            params: params,
                            success: function() {
                                Ext.Msg.alert(gettext('Settings'),
                                    gettext('Saved.'));
                                me.reloadClusters();
                            },
                        });
                    },
                }],
            });
            let infoKeys = ['state', 'k8s-version', 'cp', 'workers',
                'node-subnet', 'public-subnet', 'sdn-zone', 'sdn-vnet',
                'storage', 'template-rev', 'cp-arch'];
            let info = infoKeys.filter(function(k) {
                return rec[k] !== undefined && rec[k] !== '';
            }).map(function(k) {
                return {
                    xtype: 'displayfield',
                    fieldLabel: k,
                    value: Ext.htmlEncode(String(rec[k])),
                    labelWidth: 200,
                };
            });
            return Ext.create('Ext.panel.Panel', {
                header: false,
                border: false, bodyPadding: 10, scrollable: true,
                items: [
                    {
                        xtype: 'fieldset',
                        title: gettext('Cluster Settings'),
                        items: [form],
                    },
                    {
                        xtype: 'fieldset',
                        title: gettext('Details (read-only)'),
                        items: [{
                            xtype: 'form', border: false, items: info,
                        }],
                    },
                ],
            });
        };

        // The "Clusters" grid is card 0; the selected
        // cluster's panels are sibling cards switched by
        // the west menu tree. The selector sits in this
        // view's own toolbar (the SDN-view pattern).
        let outer;
        let menu;
        let navList;
        let navStore;
        let panelFor = function(clusterName, key, rec) {
            let id = clusterName + ':' + key;
            if (panels[id]) { return panels[id]; }
            let p;
            if (key === 'overview') { p = overviewPanel(rec); }
            else if (key === 'nodes') { p = nodesPanel(clusterName); }
            else if (key === 'workloads') { p = workloadsPanel(clusterName); }
            else if (key === 'metrics') { p = metricsPanel(clusterName); }
            else if (key === 'addons') { p = addonsPanel(clusterName); }
            else if (key === 'events') { p = eventsPanel(clusterName); }
            else if (key === 'backups') { p = backupsPanel(clusterName); }
            else { p = settingsPanel(rec); }
            p.itemId = id;
            panels[id] = p;
            return p;
        };

        // Second-sidebar navigation, VM-style: a menu tree
        // in the west region switches the card in the center.
        // (The cluster itself lives in the first, stock,
        // resource panel; this is the page's own menu, like
        // a VM's Summary/Console/Hardware list.)
        let setActivePanel = function(key) {
            me.activePanelKey = key;
            let target = outer.items.findBy(function(c) {
                return c.panelKey === key;
            });
            if (target) {
                outer.getLayout().setActiveItem(target);
                let node = navStore.getNodeById('k8snav-' + key);
                if (node && navList.getSelection() !== node) {
                    me._navSync = true;
                    navList.setSelection(node);
                    me._navSync = false;
                }
            }
        };

        let setMenu = function(defs) {
            let children = [];
            (defs || []).forEach(function(d) {
                children.push({
                    id: 'k8snav-' + d[0], text: d[1],
                    panelKey: d[0], leaf: true, iconCls: d[2],
                });
            });
            navStore.setRootNode({ expanded: true, children: children });
        };

        let showCluster = function(name, force) {
            if (!force && me.currentCluster === name && outer
                && outer.items.getCount() > 1) {
                return;
            }
            me.currentCluster = name;
            let rec = me.clusterIndex[name] || {};
            let defs = [
                ['overview', gettext('Overview'), 'fa fa-info-circle'],
                ['nodes', gettext('Nodes'), 'fa fa-server'],
                ['workloads', gettext('Workloads'), 'fa fa-cubes'],
                ['metrics', gettext('Metrics'), 'fa fa-line-chart'],
                ['addons', gettext('Add-ons'), 'fa fa-puzzle-piece'],
                ['events', gettext('Events'), 'fa fa-list'],
                ['backups', gettext('Backups'), 'fa fa-archive'],
                ['settings', gettext('Settings'), 'fa fa-cog'],
            ];
            let activeKey = me.activePanelKey || 'overview';
            // drop previous cluster panels, keep the grid (index 0)
            while (outer.items.getCount() > 1) {
                outer.remove(outer.items.getAt(1), false);
            }
            if (force) {
                defs.forEach(function(d) {
                    delete panels[name + ':' + d[0]];
                });
            }
            defs.forEach(function(d) {
                let p = panelFor(name, d[0], rec);
                p.title = d[1];
                p.panelKey = d[0];
                outer.add(p);
            });
            setMenu(defs);
            let keep = defs.some(function(d) { return d[0] === activeKey; })
                ? activeKey : 'overview';
            setActivePanel(keep);
            destroyBtn.setDisabled(false);
            if (fixedClusterName) {
                let title = gettext('Kubernetes') + ': ' + name;
                me.setTitle(title);
                let tt = me.down('#k8s-title');
                if (tt) {
                    tt.setText(Ext.htmlEncode(title));
                }
            }
        };

        let selector = Ext.create('Ext.form.field.ComboBox', {
            fieldLabel: gettext('Cluster'),
            labelWidth: 60,
            width: 320,
            store: Ext.create('Ext.data.Store', {
                fields: ['name', 'label'],
            }),
            displayField: 'label',
            valueField: 'name',
            editable: false,
            hidden: !!fixedClusterName,
            listeners: {
                change: function(field, value) {
                    if (value) { showCluster(value); }
                },
            },
        });

        let destroyBtn = Ext.create('Ext.button.Button', {
            text: gettext('Destroy'),
            iconCls: 'fa fa-fw fa-trash-o',
            disabled: true,
            handler: function() {
                let name = me.currentCluster;
                if (!name) { return; }
                Ext.Msg.confirm(gettext('Confirm'),
                    Ext.String.format(gettext(
                        'Delete cluster {0} and all its VMs?'), name),
                    function(answer) {
                        if (answer !== 'yes') { return; }
                        api({
                            url: '/cluster/k8s/' + name,
                            method: 'DELETE',
                            success: function(r) {
                                task(r.result.data);
                                me.currentCluster = null;
                                if (fixedClusterName && me.workspace) {
                                    me.workspace.selectById('root');
                                } else {
                                    me.reloadClusters();
                                }
                            },
                        });
                    });
            },
        });

        let home = Ext.create('Ext.grid.Panel', {
            header: false,
            itemId: 'k8s-home',
            hidden: !!fixedClusterName,
            border: false,
            store: clusterStore,
            columns: [
                { text: gettext('Name'), dataIndex: 'name', flex: 2 },
                {
                    text: gettext('State'), dataIndex: 'state', flex: 1,
                    renderer: function(value) {
                        if (value === 'ready') {
                            return '<i class="fa fa-check good"></i> ' + value;
                        }
                        return value || Proxmox.Utils.unknownText;
                    },
                },
                { text: gettext('Version'), dataIndex: 'k8s-version', width: 90 },
                { text: gettext('Image Rev'), dataIndex: 'template-rev', width: 90 },
                { text: gettext('Control Plane'), dataIndex: 'cp', width: 110 },
                { text: gettext('Workers'), dataIndex: 'workers', width: 90 },
                { text: gettext('Node Subnet'), dataIndex: 'node-subnet', flex: 2 },
                { text: gettext('Storage'), dataIndex: 'storage', flex: 1 },
            ],
            listeners: {
                itemdblclick: function(view, rec) {
                    // cluster details live on the cluster's
                    // own page (left resource panel), not here
                    if (me.workspace && me.workspace.selectById) {
                        me.workspace.selectById('k8s/' + rec.data.name);
                    }
                },
            },
        });

        // Stock VM-page navigation style: a treelist with
        // the pve-nav UI in a left toolbar strip, exactly
        // like PVE.panel.Config builds it.
        navStore = Ext.create('Ext.data.TreeStore', {
            fields: ['panelKey'],
            root: { expanded: true, children: [] },
        });
        navList = Ext.create('Ext.list.Tree', {
            ui: 'pve-nav',
            expanderOnly: true,
            expanderFirst: false,
            animation: false,
            store: navStore,
            listeners: {
                selectionchange: function(treelist, node) {
                    if (!me._navSync && node && node.data.panelKey) {
                        setActivePanel(node.data.panelKey);
                    }
                },
            },
        });
        menu = Ext.create('Ext.panel.Panel', {
            region: 'west',
            width: 200,
            split: false,
            border: false,
            cls: 'pve-toolbar-bg',
            layout: 'fit',
            items: [navList],
        });

        outer = Ext.create('Ext.panel.Panel', {
            region: 'center',
            layout: 'card',
            border: false,
            items: [home],
        });

        let navWrap = Ext.create('Ext.panel.Panel', {
            layout: 'border',
            border: false,
            items: [menu, outer],
        });

        me.clusterIndex = {};
        me.currentCluster = fixedClusterName || null;
        me.reloadClusters = function(force) {
            clusterStore.load({
                callback: function(records) {
                    me.clusterIndex = {};
                    let rows = (records || []).map(function(r) {
                        me.clusterIndex[r.data.name] = r.data;
                        return {
                            name: r.data.name,
                            label: r.data.name + (r.data.state
                                ? ' (' + r.data.state + ')' : ''),
                        };
                    });
                    let store = selector.getStore();
                    store.loadData(rows);
                    if (fixedClusterName
                        && !me.clusterIndex[fixedClusterName]) {
                        me.currentCluster = null;
                        destroyBtn.setDisabled(true);
                        while (outer.items.getCount() > 1) {
                            outer.remove(outer.items.getAt(1), false);
                        }
                        setMenu([]);
                        if (me.workspace) {
                            me.workspace.selectById('root');
                        }
                        return;
                    }
                    let keep = me.currentCluster
                        && me.clusterIndex[me.currentCluster];
                    if (keep) {
                        selector.setValue(me.currentCluster, false);
                        showCluster(me.currentCluster, force);
                    } else if (rows.length) {
                        selector.setValue(rows[0].name);
                    } else {
                        me.currentCluster = null;
                        destroyBtn.setDisabled(true);
                        while (outer.items.getCount() > 1) {
                            outer.remove(outer.items.getAt(1), false);
                        }
                        setMenu([]);
                        setActivePanel('clusters');
                    }
                },
            });
        };

        if (!fixedClusterName) {
            // Datacenter -> Kubernetes: just the cluster
            // list with Create/Destroy. Every detail lives
            // on the cluster's own page, opened from the
            // left resource panel (double-click a row to
            // jump there).
            let listDestroy = Ext.create('Ext.button.Button', {
                text: gettext('Destroy'),
                iconCls: 'fa fa-fw fa-trash-o',
                disabled: true,
                handler: function() {
                    let sel = home.getSelection();
                    if (!sel || !sel.length) { return; }
                    let name = sel[0].data.name;
                    Ext.Msg.confirm(gettext('Confirm'),
                        Ext.String.format(gettext(
                            'Delete cluster {0} and all its VMs?'), name),
                        function(answer) {
                            if (answer !== 'yes') { return; }
                            api({
                                url: '/cluster/k8s/' + name,
                                method: 'DELETE',
                                success: function(r) {
                                    task(r.result.data);
                                    clusterStore.load();
                                },
                            });
                        });
                },
            });
            home.getSelectionModel().on('selectionchange',
                function(sm, selected) {
                    listDestroy.setDisabled(!selected || !selected.length);
                });
            me.reloadClusters = function() {
                clusterStore.load();
            };
            Ext.apply(me, {
                layout: { type: 'vbox', align: 'stretch' },
                items: [{
                    xtype: 'toolbar',
                    items: [
                        {
                            text: gettext('Create'),
                            iconCls: 'fa fa-fw fa-plus-circle',
                            handler: function() {
                                Ext.create('PVE.dc.K8sCreateWindow', {
                                    onDone: function() {
                                        clusterStore.load();
                                    },
                                }).show();
                            },
                        },
                        listDestroy,
                        '->',
                        {
                            text: gettext('Reload'),
                            iconCls: 'fa fa-fw fa-refresh',
                            handler: function() { clusterStore.load(); },
                        },
                    ],
                }, Ext.apply(home, { flex: 1 })],
                listeners: {
                    afterrender: function() {
                        clusterStore.load();
                        me.pollTask = Ext.util.TaskManager.start({
                            run: function() { clusterStore.load(); },
                            interval: 30000,
                        });
                    },
                    beforedestroy: function() {
                        if (me.pollTask) {
                            Ext.util.TaskManager.stop(me.pollTask);
                        }
                    },
                },
            });
            me.callParent();
            return;
        }

        Ext.apply(me, {
            layout: { type: 'vbox', align: 'stretch' },
            items: [{
                // one single top bar, VM-page style: title
                // text on the left, actions on the right
                xtype: 'toolbar',
                items: [
                    {
                        xtype: 'tbtext',
                        itemId: 'k8s-title',
                        text: Ext.htmlEncode(me.title),
                        baseCls: 'x-panel-header-text',
                    },
                    '->',
                    {
                        // Destroy lives under More, like a
                        // VM page's Remove - not one click
                        // away in the top bar
                        text: gettext('More'),
                        iconCls: 'fa fa-fw fa-bars',
                        menu: [destroyBtn],
                    },
                ],
            }, Ext.apply(navWrap, { flex: 1 })],
            listeners: {
                afterrender: function() {
                    me.reloadClusters();
                    me.pollTask = Ext.util.TaskManager.start({
                        run: function() { me.reloadClusters(); },
                        interval: 30000,
                    });
                },
                beforedestroy: function() {
                    if (me.pollTask) {
                        Ext.util.TaskManager.stop(me.pollTask);
                    }
                },
            },
        });

        me.callParent();
    },
});

// Specific-cluster page opened from the first/left Proxmox
// resource panel. The resource tree has already selected the
// cluster, so this view fixes that selection and presents the
// same panels behind a VM-style second-sidebar menu, without
// a selector.
Ext.define('PVE.k8s.Config', {
    extend: 'PVE.dc.K8sView',
    alias: 'widget.pveK8sConfig',

    initComponent: function() {
        let me = this;
        if (!me.fixedClusterName && me.pveSelNode && me.pveSelNode.data) {
            me.fixedClusterName = me.pveSelNode.data.name
                || me.pveSelNode.data.k8s;
        }
        me.callParent();
    },
});
