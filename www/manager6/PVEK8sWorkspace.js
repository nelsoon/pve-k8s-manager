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

Ext.define('PVE.dc.K8sView', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.pveDcK8sView',

    title: gettext('Kubernetes'),
    stateful: true,
    stateId: 'grid-dc-k8s',

    initComponent: function() {
        let me = this;

        let store = Ext.create('Ext.data.Store', {
            fields: ['name', 'state', 'k8s-version', 'template-rev', 'cp', 'workers',
                'node-subnet', 'gateway', 'lb-range', 'storage'],
            proxy: {
                type: 'proxmox',
                url: '/api2/json/cluster/k8s',
            },
            autoLoad: true,
        });

        let provisionBtn = Ext.create('Ext.button.Button', {
            text: gettext('Provision'),
            iconCls: 'fa fa-fw fa-play',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Proxmox.Utils.API2Request({
                    url: '/cluster/k8s/' + name + '/provision',
                    method: 'POST',
                    failure: function(response) {
                        Ext.Msg.alert(gettext('Error'),
                            Proxmox.Utils.extractRequestError(response, true));
                    },
                    success: function(response) {
                        let upid = response.result.data;
                        if (upid) {
                            Ext.create('Proxmox.window.TaskViewer', {
                                upid: upid,
                            }).show();
                        }
                        store.load();
                    },
                });
            },
        });

        let removeBtn = Ext.create('Ext.button.Button', {
            text: gettext('Remove'),
            iconCls: 'fa fa-fw fa-trash-o',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Ext.Msg.confirm(
                    gettext('Confirm'),
                    Ext.String.format(
                        gettext('Delete cluster {0} and all its VMs?'), name),
                    function(answer) {
                        if (answer !== 'yes') {
                            return;
                        }
                        Proxmox.Utils.API2Request({
                            url: '/cluster/k8s/' + name,
                            method: 'DELETE',
                            failure: function(response) {
                                Ext.Msg.alert(gettext('Error'),
                                    Proxmox.Utils.extractRequestError(response, true));
                            },
                            success: function(response) {
                                let upid = response.result.data;
                                if (upid) {
                                    Ext.create('Proxmox.window.TaskViewer', {
                                        upid: upid,
                                    }).show();
                                }
                                store.load();
                            },
                        });
                    });
            },
        });

        let rollBtn = Ext.create('Ext.button.Button', {
            text: gettext('Roll'),
            iconCls: 'fa fa-fw fa-refresh',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Ext.Msg.confirm(
                    gettext('Confirm'),
                    Ext.String.format(
                        gettext('Roll cluster {0} onto the latest node image?'), name),
                    function(answer) {
                        if (answer !== 'yes') {
                            return;
                        }
                        Proxmox.Utils.API2Request({
                            url: '/cluster/k8s/' + name + '/roll',
                            method: 'POST',
                            params: { force: 1 },
                            failure: function(response) {
                                Ext.Msg.alert(gettext('Error'),
                                    Proxmox.Utils.extractRequestError(response, true));
                            },
                            success: function(response) {
                                let upid = response.result.data;
                                if (upid) {
                                    Ext.create('Proxmox.window.TaskViewer', {
                                        upid: upid,
                                    }).show();
                                }
                                store.load();
                            },
                        });
                    });
            },
        });

        let scaleBtn = Ext.create('Ext.button.Button', {
            text: gettext('Scale'),
            iconCls: 'fa fa-fw fa-arrows-alt',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Proxmox.Utils.API2Request({
                    url: '/cluster/k8s/' + name + '/scale',
                    method: 'POST',
                    failure: function(response) {
                        Ext.Msg.alert(gettext('Error'),
                            Proxmox.Utils.extractRequestError(response, true));
                    },
                    success: function(response) {
                        let upid = response.result.data;
                        if (upid) {
                            Ext.create('Proxmox.window.TaskViewer', {
                                upid: upid,
                            }).show();
                        }
                        store.load();
                    },
                });
            },
        });

        let upgradeBtn = Ext.create('Ext.button.Button', {
            text: gettext('Upgrade'),
            iconCls: 'fa fa-fw fa-arrow-circle-up',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Ext.Msg.prompt(
                    gettext('Upgrade Kubernetes'),
                    gettext('Target version (one minor up, e.g. 1.36):'),
                    function(answer, value) {
                        if (answer !== 'ok' || !value) {
                            return;
                        }
                        Proxmox.Utils.API2Request({
                            url: '/cluster/k8s/' + name + '/upgrade',
                            method: 'POST',
                            params: { to: value, force: 1 },
                            failure: function(response) {
                                Ext.Msg.alert(gettext('Error'),
                                    Proxmox.Utils.extractRequestError(response, true));
                            },
                            success: function(response) {
                                let upid = response.result.data;
                                if (upid) {
                                    Ext.create('Proxmox.window.TaskViewer', {
                                        upid: upid,
                                    }).show();
                                }
                                store.load();
                            },
                        });
                    });
            },
        });

        let nodesBtn = Ext.create('Ext.button.Button', {
            text: gettext('Nodes'),
            iconCls: 'fa fa-fw fa-server',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                let nodeStore = Ext.create('Ext.data.Store', {
                    fields: ['name', 'pool', 'pvehost', 'vmid', 'ip', 'rev'],
                });
                let grid = Ext.create('Ext.grid.Panel', {
                    store: nodeStore,
                    columns: [
                        { text: gettext('Node'), dataIndex: 'name', flex: 1 },
                        { text: gettext('Pool'), dataIndex: 'pool', flex: 1 },
                        { text: gettext('PVE Host'), dataIndex: 'pvehost', flex: 1 },
                        { text: 'VMID', dataIndex: 'vmid', width: 70 },
                        { text: 'IP', dataIndex: 'ip', flex: 1 },
                        { text: gettext('Image Rev'), dataIndex: 'rev', width: 80 },
                    ],
                });
                let act = function(action) {
                    let sel = grid.getSelection();
                    if (!sel || sel.length < 1) {
                        return;
                    }
                    let node = sel[0].data.name;
                    Ext.Msg.confirm(gettext('Confirm'),
                        Ext.String.format(gettext('{0} node {1}?'), action, node),
                        function(answer) {
                            if (answer !== 'yes') {
                                return;
                            }
                            Proxmox.Utils.API2Request({
                                url: '/cluster/k8s/' + name + '/nodes/' + node
                                    + '/' + action.toLowerCase(),
                                method: 'POST',
                                failure: function(response) {
                                    Ext.Msg.alert(gettext('Error'),
                                        Proxmox.Utils.extractRequestError(response, true));
                                },
                                success: function(response) {
                                    let upid = response.result.data;
                                    if (upid) {
                                        Ext.create('Proxmox.window.TaskViewer', {
                                            upid: upid,
                                        }).show();
                                    }
                                },
                            });
                        });
                };
                Ext.create('Ext.window.Window', {
                    title: Ext.String.format(gettext('Nodes of {0}'), name),
                    width: 640,
                    height: 360,
                    layout: 'fit',
                    items: [grid],
                    buttons: [
                        {
                            text: gettext('Drain'),
                            handler: function() { act('Drain'); },
                        },
                        {
                            text: gettext('Replace'),
                            handler: function() { act('Replace'); },
                        },
                        {
                            text: gettext('Force Retire'),
                            handler: function() {
                                let sel = grid.getSelection();
                                if (!sel || sel.length < 1) {
                                    return;
                                }
                                let node = sel[0].data.name;
                                Ext.Msg.confirm(gettext('Confirm'),
                                    Ext.String.format(gettext(
                                        'Force-retire DEAD node {0}? Only ' +
                                        'if its VM is powered off or lost. ' +
                                        'A replacement will be provisioned.'),
                                        node),
                                    function(answer) {
                                        if (answer !== 'yes') {
                                            return;
                                        }
                                        Proxmox.Utils.API2Request({
                                            url: '/cluster/k8s/' + name
                                                + '/nodes/' + node
                                                + '/force-retire',
                                            method: 'POST',
                                            params: { force: 1, replace: 1 },
                                            failure: function(response) {
                                                Ext.Msg.alert(gettext('Error'),
                                                    Proxmox.Utils.extractRequestError(response, true));
                                            },
                                            success: function(response) {
                                                let upid = response.result.data;
                                                if (upid) {
                                                    Ext.create('Proxmox.window.TaskViewer', {
                                                        upid: upid,
                                                    }).show();
                                                }
                                            },
                                        });
                                    });
                            },
                        },
                    ],
                }).show();
                Proxmox.Utils.API2Request({
                    url: '/cluster/k8s/' + name,
                    method: 'GET',
                    success: function(response) {
                        let nodes = Ext.decode(response.result.data.nodes || '[]');
                        nodeStore.loadData(nodes);
                    },
                });
            },
        });

        let kubeconfigBtn = Ext.create('Ext.button.Button', {
            text: gettext('Kubeconfig'),
            iconCls: 'fa fa-fw fa-key',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Proxmox.Utils.API2Request({
                    url: '/cluster/k8s/' + name + '/kubeconfig',
                    method: 'GET',
                    failure: function(response) {
                        Ext.Msg.alert(gettext('Error'),
                            Proxmox.Utils.extractRequestError(response, true));
                    },
                    success: function(response) {
                        let data = response.result.data;
                        let win = Ext.create('Ext.window.Window', {
                            title: Ext.String.format(
                                gettext('Kubeconfig for {0}'), name),
                            width: 680,
                            height: 420,
                            layout: 'fit',
                            items: [{
                                xtype: 'textarea',
                                value: data.kubeconfig,
                                readOnly: true,
                            }],
                            buttons: [{
                                text: gettext('Download'),
                                handler: function() {
                                    let blob = new Blob([data.kubeconfig],
                                        { type: 'text/yaml' });
                                    let a = document.createElement('a');
                                    a.href = URL.createObjectURL(blob);
                                    a.download = name + '.kubeconfig';
                                    a.click();
                                    URL.revokeObjectURL(a.href);
                                },
                            }],
                        });
                        win.setTitle(win.title + ' (' + data.expires + ')');
                        win.show();
                    },
                });
            },
        });

        let eventsBtn = Ext.create('Ext.button.Button', {
            text: gettext('Events'),
            iconCls: 'fa fa-fw fa-list',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Ext.create('Ext.window.Window', {
                    title: Ext.String.format(gettext('Events of {0}'), name),
                    width: 760,
                    height: 420,
                    layout: 'fit',
                    items: [{
                        xtype: 'grid',
                        store: Ext.create('Ext.data.Store', {
                            fields: ['time', 'type', 'reason', 'object', 'message'],
                            proxy: {
                                type: 'proxmox',
                                url: '/api2/json/cluster/k8s/' + name + '/events',
                            },
                            autoLoad: true,
                        }),
                        columns: [
                            { text: gettext('Time'), dataIndex: 'time', width: 170 },
                            { text: gettext('Type'), dataIndex: 'type', width: 80 },
                            { text: gettext('Reason'), dataIndex: 'reason', width: 130 },
                            { text: gettext('Object'), dataIndex: 'object', width: 160 },
                            { text: gettext('Message'), dataIndex: 'message', flex: 1 },
                        ],
                    }],
                }).show();
            },
        });

        let addonsBtn = Ext.create('Ext.button.Button', {
            text: gettext('Add-ons'),
            iconCls: 'fa fa-fw fa-puzzle-piece',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                let store = Ext.create('Ext.data.Store', {
                    fields: ['name', 'status', 'mustdeploy', 'summary'],
                    proxy: {
                        type: 'proxmox',
                        url: '/api2/json/cluster/k8s/' + name + '/addons',
                    },
                    autoLoad: true,
                });
                let enableBtn = Ext.create('Ext.button.Button', {
                    text: gettext('Configure / Enable'),
                    iconCls: 'fa fa-fw fa-cog',
                    disabled: true,
                    handler: function() {
                        let sel = grid.getSelection();
                        if (!sel || sel.length < 1) {
                            return;
                        }
                        let addon = sel[0].data.name;
                        let items = [];
                        if (addon === 'cert-manager') {
                            items = [
                                {
                                    xtype: 'combobox',
                                    name: 'issuer',
                                    fieldLabel: gettext('Issuer'),
                                    store: ['ca', 'acme'],
                                    value: 'ca',
                                    editable: false,
                                    allowBlank: false,
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'email',
                                    fieldLabel: gettext('ACME Email'),
                                    emptyText: gettext('only for the acme issuer'),
                                },
                            ];
                        } else if (addon === 'external-dns') {
                            items = [
                                {
                                    xtype: 'textfield',
                                    name: 'pdns-url',
                                    fieldLabel: gettext('PowerDNS API URL'),
                                    emptyText: 'http://dns.example.com:8081/api/v1/servers/localhost',
                                    allowBlank: false,
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'zone',
                                    fieldLabel: gettext('Zone'),
                                    emptyText: 'example.com',
                                    allowBlank: false,
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'pdns-api-key',
                                    fieldLabel: gettext('PowerDNS API Key'),
                                    inputType: 'password',
                                    allowBlank: false,
                                },
                            ];
                        } else {
                            return;
                        }
                        let formWin = Ext.create('Ext.window.Window', {
                            title: Ext.String.format(
                                gettext('Configure {0}'), addon),
                            modal: true,
                            width: 560,
                            layout: 'fit',
                            items: [{
                                xtype: 'form',
                                bodyPadding: 10,
                                border: false,
                                fieldDefaults: {
                                    labelWidth: 170,
                                    anchor: '100%',
                                },
                                items: items,
                                buttons: [{
                                    text: gettext('Enable'),
                                    handler: function() {
                                        let form = formWin.down('form').getForm();
                                        if (!form.isValid()) {
                                            return;
                                        }
                                        Proxmox.Utils.API2Request({
                                            url: '/cluster/k8s/' + name
                                                + '/addons/' + addon + '/enable',
                                            method: 'POST',
                                            params: form.getValues(),
                                            failure: function(response) {
                                                Ext.Msg.alert(gettext('Error'),
                                                    Proxmox.Utils.extractRequestError(response, true));
                                            },
                                            success: function(response) {
                                                formWin.close();
                                                store.load();
                                                let upid = response.result.data;
                                                if (upid) {
                                                    Ext.create('Proxmox.window.TaskViewer', {
                                                        upid: upid,
                                                    }).show();
                                                }
                                            },
                                        });
                                    },
                                }, {
                                    text: gettext('Cancel'),
                                    handler: function() {
                                        formWin.close();
                                    },
                                }],
                            }],
                        });
                        formWin.show();
                    },
                });
                let grid = Ext.create('Ext.grid.Panel', {
                    store: store,
                    tbar: [enableBtn],
                    columns: [
                        { text: gettext('Add-on'), dataIndex: 'name', width: 150 },
                        { text: gettext('Status'), dataIndex: 'status', width: 130 },
                        {
                            text: gettext('Recommended'),
                            dataIndex: 'mustdeploy',
                            width: 120,
                            renderer: function(v) {
                                return v ? gettext('Yes') : '';
                            },
                        },
                        { text: gettext('Description'), dataIndex: 'summary', flex: 1 },
                    ],
                    listeners: {
                        selectionchange: function(model, selected) {
                            let rec = selected && selected[0];
                            enableBtn.setDisabled(!rec
                                || (rec.data.name !== 'cert-manager'
                                    && rec.data.name !== 'external-dns'));
                        },
                    },
                });
                Ext.create('Ext.window.Window', {
                    title: Ext.String.format(gettext('Add-ons of {0}'), name),
                    width: 780,
                    height: 420,
                    layout: 'fit',
                    items: [grid],
                }).show();
            },
        });

        let backupBtn = Ext.create('Ext.button.Button', {
            text: gettext('Backup'),
            iconCls: 'fa fa-fw fa-save',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Proxmox.Utils.API2Request({
                    url: '/cluster/k8s/' + name + '/backup',
                    method: 'POST',
                    failure: function(response) {
                        Ext.Msg.alert(gettext('Error'),
                            Proxmox.Utils.extractRequestError(response, true));
                    },
                    success: function(response) {
                        let upid = response.result.data;
                        if (upid) {
                            Ext.create('Proxmox.window.TaskViewer', {
                                upid: upid,
                            }).show();
                        }
                    },
                });
            },
        });

        let restoreBtn = Ext.create('Ext.button.Button', {
            text: gettext('Restore'),
            iconCls: 'fa fa-fw fa-undo',
            disabled: true,
            handler: function() {
                let selection = me.getSelection();
                if (!selection || selection.length < 1) {
                    return;
                }
                let name = selection[0].data.name;
                Ext.Msg.prompt(
                    gettext('Restore etcd'),
                    gettext('Backup file name (rolls back ALL '
                        + 'cluster data to that point):'),
                    function(answer, value) {
                        if (answer !== 'ok' || !value) {
                            return;
                        }
                        Proxmox.Utils.API2Request({
                            url: '/cluster/k8s/' + name + '/restore',
                            method: 'POST',
                            params: { backup: value, force: 1 },
                            failure: function(response) {
                                Ext.Msg.alert(gettext('Error'),
                                    Proxmox.Utils.extractRequestError(response, true));
                            },
                            success: function(response) {
                                let upid = response.result.data;
                                if (upid) {
                                    Ext.create('Proxmox.window.TaskViewer', {
                                        upid: upid,
                                    }).show();
                                }
                            },
                        });
                    });
            },
        });

        Ext.apply(me, {
            store: store,
            columns: [
                {
                    text: gettext('Name'),
                    dataIndex: 'name',
                    flex: 2,
                },
                {
                    text: gettext('State'),
                    dataIndex: 'state',
                    flex: 1,
                    renderer: function(value) {
                        if (value === 'ready') {
                            return '<i class="fa fa-check good"></i> ' + value;
                        }
                        if (value === 'provisioning') {
                            return '<i class="fa fa-refresh"></i> ' + value;
                        }
                        return value || Proxmox.Utils.unknownText;
                    },
                },
                {
                    text: gettext('Version'),
                    dataIndex: 'k8s-version',
                    width: 90,
                },
                {
                    text: gettext('Image Rev'),
                    dataIndex: 'template-rev',
                    width: 90,
                },
                {
                    text: gettext('Control Plane'),
                    dataIndex: 'cp',
                    width: 110,
                },
                {
                    text: gettext('Workers'),
                    dataIndex: 'workers',
                    width: 90,
                },
                {
                    text: gettext('Node Subnet'),
                    dataIndex: 'node-subnet',
                    flex: 2,
                },
                {
                    text: gettext('Storage'),
                    dataIndex: 'storage',
                    flex: 1,
                },
            ],
            tbar: [
                {
                    text: gettext('Create'),
                    iconCls: 'fa fa-fw fa-plus-circle',
                    handler: function() {
                        Ext.create('PVE.dc.K8sCreateWindow', {
                            onDone: function() {
                                store.load();
                            },
                        }).show();
                    },
                },
                provisionBtn,
                rollBtn,
                scaleBtn,
                upgradeBtn,
                nodesBtn,
                kubeconfigBtn,
                eventsBtn,
                addonsBtn,
                backupBtn,
                restoreBtn,
                removeBtn,
                '-',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-fw fa-refresh',
                    handler: function() {
                        store.load();
                    },
                },
            ],
            listeners: {
                selectionchange: function(model, selected) {
                    let disabled = !selected || selected.length < 1;
                    provisionBtn.setDisabled(disabled);
                    rollBtn.setDisabled(disabled);
                    scaleBtn.setDisabled(disabled);
                    upgradeBtn.setDisabled(disabled);
                    nodesBtn.setDisabled(disabled);
                    kubeconfigBtn.setDisabled(disabled);
                    eventsBtn.setDisabled(disabled);
                    addonsBtn.setDisabled(disabled);
                    backupBtn.setDisabled(disabled);
                    restoreBtn.setDisabled(disabled);
                    removeBtn.setDisabled(disabled);
                },
                afterrender: function() {
                    me.pollTask = Ext.util.TaskManager.start({
                        run: function() {
                            store.load();
                        },
                        interval: 15000,
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
