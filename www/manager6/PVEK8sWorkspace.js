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
                    xtype: 'textfield',
                    name: 'name',
                    fieldLabel: gettext('Name'),
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
                    xtype: 'numberfield',
                    name: 'workers',
                    fieldLabel: gettext('Worker Nodes'),
                    value: 2,
                    minValue: 0,
                    maxValue: 50,
                },
                {
                    xtype: 'textarea',
                    name: 'pools',
                    fieldLabel: gettext('Worker Pools (JSON)'),
                    emptyText: '[{"name":"default","size":2}]',
                    height: 60,
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
                    name: 'storage',
                    fieldLabel: gettext('Storage'),
                    emptyText: gettext('Proxmox storage for node disks'),
                },
                {
                    xtype: 'textfield',
                    name: 'sdn-zone',
                    fieldLabel: gettext('SDN EVPN Zone'),
                    emptyText: gettext('dedicated VNet mode (with Public Subnet)'),
                },
                {
                    xtype: 'textfield',
                    name: 'public-subnet',
                    fieldLabel: gettext('Public Subnet (LB/VIP)'),
                    emptyText: '192.168.212.0/24',
                },
                {
                    xtype: 'combobox',
                    name: 'file-backend',
                    fieldLabel: gettext('Shared-File (RWX) Backend'),
                    store: ['', 'nfs'],
                    value: '',
                    editable: false,
                },
                {
                    xtype: 'textfield',
                    name: 'file-server',
                    fieldLabel: gettext('NFS Server'),
                    emptyText: gettext('only for Shared-File nfs'),
                },
                {
                    xtype: 'textfield',
                    name: 'file-share',
                    fieldLabel: gettext('NFS Export Path'),
                    emptyText: '/srv/k8s',
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


// Kubernetes workspace: SDN-style subtree. The Kubernetes
// entry sits at Datacenter level next to SDN/Ceph; inside,
// a left tree lists clusters, and each cluster expands to
// its panels (Overview, Nodes, Workloads, Metrics, Add-ons,
// Events, Backups, Settings). Create/Destroy live on the
// Clusters root and on each cluster node. Read-only
// workload/metrics panels; actions reuse the same API.
Ext.define('PVE.dc.K8sView', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveDcK8sView',

    title: gettext('Kubernetes'),
    layout: 'border',

    initComponent: function() {
        let me = this;

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
                        task(r.result.data); me.reloadTree();
                    },
                });
            });
        };

        let clusterStore = Ext.create('Ext.data.Store', {
            fields: ['name', 'state', 'k8s-version', 'template-rev',
                'cp', 'workers', 'node-subnet', 'gateway', 'lb-range',
                'storage', 'sdn-zone', 'public-subnet',
                'maintenance-window', 'pools'],
            proxy: { type: 'proxmox', url: '/api2/json/cluster/k8s' },
        });

        let panels = {};   // clusterName:panelKey -> component
        let center;

        let grid = function(fields, url, columns, tbar) {
            return Ext.create('Ext.grid.Panel', {
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
            let rows = [
                ['Name', name],
                ['State', rec.state || ''],
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
                ['Pools', rec.pools || ''],
            ];
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
                border: false,
                bodyPadding: 10,
                scrollable: true,
                tbar: [
                    act(gettext('Provision'), 'fa fa-fw fa-play', function(n) {
                        api({
                            url: '/cluster/k8s/' + n + '/provision',
                            method: 'POST',
                            success: function(r) {
                                task(r.result.data); me.reloadTree();
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
                                task(r.result.data); me.reloadTree();
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
                                        task(r.result.data); me.reloadTree();
                                    },
                                });
                            });
                    }),
                    act(gettext('Power'), 'fa fa-fw fa-power-off', function(n) {
                        Ext.Msg.confirm(gettext('Power'),
                            Ext.String.format(gettext(
                                'Start all node VMs of {0}? (No = stop workers-first)'), n),
                            function(answer) {
                                api({
                                    url: '/cluster/k8s/' + n + '/power',
                                    method: 'POST',
                                    params: {
                                        action: answer === 'yes'
                                            ? 'start' : 'stop',
                                    },
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
                    '-',
                    act(gettext('Destroy'), 'fa fa-fw fa-trash-o', function(n) {
                        Ext.Msg.confirm(gettext('Confirm'),
                            Ext.String.format(gettext(
                                'Delete cluster {0} and all its VMs?'), n),
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                api({
                                    url: '/cluster/k8s/' + n,
                                    method: 'DELETE',
                                    success: function(r) {
                                        task(r.result.data); me.reloadTree();
                                    },
                                });
                            });
                    }),
                ],
                items: [{
                    xtype: 'form',
                    border: false,
                    items: rows.map(function(row) {
                        return {
                            xtype: 'displayfield',
                            fieldLabel: row[0],
                            value: Ext.htmlEncode(String(row[1])),
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
                    itemId: 'nodebtn',
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
                ],
                listeners: {
                    selectionchange: function(model, selected) {
                        let dis = !selected || !selected.length;
                        g.query('#nodebtn').forEach(function(b) {
                            b.setDisabled(dis);
                        });
                    },
                },
            });
            let loadNodes = function() {
                api({
                    url: '/cluster/k8s/' + name, method: 'GET',
                    success: function(r) {
                        store.loadData(Ext.decode(
                            r.result.data.nodes || '[]'));
                    },
                });
            };
            loadNodes();
            return g;
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
                ]);
            return g;
        };

        let settingsPanel = function(rec) {
            let skip = { name: 1, nodes: 1, addons: 1 };
            let items = Object.keys(rec).filter(function(k) {
                return !skip[k] && typeof rec[k] !== 'object';
            }).sort().map(function(k) {
                return {
                    xtype: 'displayfield',
                    fieldLabel: k,
                    value: Ext.htmlEncode(String(rec[k])),
                    labelWidth: 200,
                };
            });
            return Ext.create('Ext.panel.Panel', {
                border: false, bodyPadding: 10, scrollable: true,
                items: [{ xtype: 'form', border: false, items: items }],
            });
        };

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
            center.add(p);
            return p;
        };

        let treeStore = Ext.create('Ext.data.TreeStore', {
            root: {
                text: gettext('Clusters'),
                expanded: true,
                children: [],
            },
        });
        let tree = Ext.create('Ext.tree.Panel', {
            region: 'west',
            width: 280,
            split: true,
            rootVisible: true,
            store: treeStore,
            tbar: [
                {
                    text: gettext('Create'),
                    iconCls: 'fa fa-fw fa-plus-circle',
                    handler: function() {
                        Ext.create('PVE.dc.K8sCreateWindow', {
                            onDone: function() { me.reloadTree(); },
                        }).show();
                    },
                },
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-fw fa-refresh',
                    handler: function() { me.reloadTree(); },
                },
            ],
            listeners: {
                selectionchange: function(model, selected) {
                    let node = selected && selected[0];
                    if (!node) { return; }
                    let d = node.data;
                    if (d.panelKey && d.clusterName) {
                        let rec = me.clusterIndex[d.clusterName] || {};
                        center.getLayout().setActiveItem(
                            panelFor(d.clusterName, d.panelKey, rec));
                    } else if (d.clusterName && !d.panelKey) {
                        let rec = me.clusterIndex[d.clusterName] || {};
                        center.getLayout().setActiveItem(
                            panelFor(d.clusterName, 'overview', rec));
                    } else {
                        center.getLayout().setActiveItem('k8s-home');
                    }
                },
            },
        });

        let home = Ext.create('Ext.grid.Panel', {
            itemId: 'k8s-home',
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
                    let node = tree.getRootNode().findChild(
                        'clusterName', rec.data.name, false);
                    if (node) { tree.getSelectionModel().select(node); }
                },
            },
        });

        center = Ext.create('Ext.panel.Panel', {
            region: 'center',
            layout: 'card',
            border: false,
            items: [home],
        });

        me.clusterIndex = {};
        me.reloadTree = function(keepSelection) {
            clusterStore.load({
                callback: function(records) {
                    me.clusterIndex = {};
                    let children = (records || []).map(function(r) {
                        me.clusterIndex[r.data.name] = r.data;
                        let leaf = function(text, key, icon) {
                            return {
                                text: text, leaf: true,
                                iconCls: icon,
                                clusterName: r.data.name, panelKey: key,
                            };
                        };
                        return {
                            text: r.data.name
                                + (r.data.state
                                    ? ' (' + r.data.state + ')' : ''),
                            expanded: false,
                            iconCls: 'fa fa-fw fa-cubes',
                            clusterName: r.data.name,
                            children: [
                                leaf(gettext('Overview'), 'overview',
                                    'fa fa-fw fa-info-circle'),
                                leaf(gettext('Nodes'), 'nodes',
                                    'fa fa-fw fa-server'),
                                leaf(gettext('Workloads'), 'workloads',
                                    'fa fa-fw fa-th'),
                                leaf(gettext('Metrics'), 'metrics',
                                    'fa fa-fw fa-line-chart'),
                                leaf(gettext('Add-ons'), 'addons',
                                    'fa fa-fw fa-puzzle-piece'),
                                leaf(gettext('Events'), 'events',
                                    'fa fa-fw fa-list'),
                                leaf(gettext('Backups'), 'backups',
                                    'fa fa-fw fa-save'),
                                leaf(gettext('Settings'), 'settings',
                                    'fa fa-fw fa-cog'),
                            ],
                        };
                    });
                    let selPath = null;
                    let sel = tree.getSelectionModel().getSelection()[0];
                    if (keepSelection && sel) {
                        selPath = sel.getPath('text');
                    }
                    treeStore.setRootNode({
                        text: gettext('Clusters'),
                        expanded: true,
                        children: children,
                    });
                    if (selPath) {
                        tree.selectPath(selPath, 'text', '/', function() {});
                    }
                    if (!center.getLayout().getActiveItem()) {
                        center.getLayout().setActiveItem('k8s-home');
                    }
                },
            });
        };

        Ext.apply(me, {
            items: [tree, center],
            listeners: {
                afterrender: function() {
                    me.reloadTree();
                    me.pollTask = Ext.util.TaskManager.start({
                        run: function() { me.reloadTree(true); },
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
