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
                    xtype: 'textfield',
                    name: 'k8s-version',
                    fieldLabel: gettext('Kubernetes Version'),
                    value: '1.31',
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
            fields: ['name', 'state', 'k8s-version', 'cp', 'workers',
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
