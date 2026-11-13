// Copyright (C) 2026 pve-k8s contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
// Datacenter -> Kubernetes (T1.6): cluster list/health, create
// wizard and provision-with-task-progress, in pve-manager style.
// The REST API stays the contract; this panel is a thin client.

// Create dialog: the stock Proxmox.window.Edit + InputPanel, so
// validation, API errors, the Advanced checkbox and the reset
// button behave like every other PVE create dialog. Only the name
// (and, where it matters, a public subnet) is asked by default;
// everything else is detected, shown in the summary line and
// editable under Advanced. Create then provisions, as one step.
Ext.define('PVE.dc.K8sCreateWindow', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveDcK8sCreateWindow',

    subject: gettext('Kubernetes Cluster'),
    isCreate: true,
    url: '/cluster/k8s',
    method: 'POST',
    submitText: gettext('Create'),
    width: 640,

    // Minors this release can create. Kept in step with
    // PVE::K8s::Config::supported_versions by tests/unit/ui-k8s.t.
    supportedVersions: ['1.35', '1.36', '1.37'],
    // Minors whose add-on stack is a pre-release (PVE::K8s::Config
    // %PREVIEW_VERSIONS): labelled, never the default.
    previewVersions: ['1.37'],
    // Upstream end of life per minor, kept in step with
    // PVE::K8s::Config %VERSION_DATES by tests/unit/supported-versions.t.
    versionEol: { '1.35': '2027-02-28', '1.36': '2027-06-28', '1.37': '2027-10-28' },
    // Backend defaults, only used for the summary line.
    defaultControlPlane: 3,
    defaultWorkers: 2,

    // callback fired after the provision task was started
    onDone: undefined,

    // Create only writes the config; provisioning is the second
    // call. The window closes at once, the task viewer follows.
    apiCallDone: function(success, response, options) {
        let me = this;
        if (!success) {
            return;
        }
        let name = options.params.name;
        Proxmox.Utils.API2Request({
            url: '/cluster/k8s/' + encodeURIComponent(name) + '/provision',
            method: 'POST',
            failure: function(resp) {
                Ext.Msg.alert(gettext('Error'),
                    Proxmox.Utils.extractRequestError(resp, true));
                if (me.onDone) {
                    me.onDone();
                }
            },
            success: function(resp) {
                let upid = resp.result.data;
                if (upid) {
                    Ext.create('Proxmox.window.TaskViewer', {
                        autoShow: true,
                        upid: upid,
                    });
                }
                if (me.onDone) {
                    me.onDone();
                }
            },
        });
    },

    initComponent: function() {
        let me = this;

        let versions = me.supportedVersions;
        let ga = versions.filter(v => me.previewVersions.indexOf(v) < 0);
        let latest = ga[ga.length - 1];
        let versionStore = versions.map(v => [v,
            me.previewVersions.indexOf(v) < 0 ? v : v + ' (' + gettext('preview') + ')']);
        let supportText = function(v) {
            let eol = me.versionEol[v];
            let txt = eol ? Ext.String.format(gettext('Upstream support until {0}'), eol) : '';
            if (me.previewVersions.indexOf(v) >= 0) {
                txt += (txt ? '. ' : '')
                    + gettext('Preview: its Cilium is a pre-release');
            }
            return txt;
        };

        let zoneStore = Ext.create('Ext.data.Store', {
            fields: ['zone'],
            proxy: { type: 'proxmox', url: '/api2/json/cluster/sdn/zones' },
            autoLoad: true,
        });

        let ipanel;
        let get = function(name) {
            return ipanel.down('[name=' + name + ']');
        };

        // Storage and availability agree by construction: shared
        // storage means HA, local storage means rebuild. The
        // mismatch state (HA on local storage) cannot be chosen;
        // the backend refuses it too, for API callers.
        let applyResilience = function(preset) {
            let shared = preset !== 'local-replace';
            get('storage-profile').setValue(shared ? 'shared' : 'local');
            get('cp-policy').setValue(shared ? 'ha' : 'replace');
            let sc = get('storage');
            let store = sc.getStore();
            store.removeFilter('k8s-shared', true);
            store.addFilter({
                id: 'k8s-shared',
                filterFn: function(r) {
                    return (r.get('shared') ? 1 : 0) === (shared ? 1 : 0);
                },
            });
            if (!store.findRecord('storage', sc.getValue(), 0, false, true, true)) {
                let first = store.getAt(0);
                sc.setValue(first ? first.get('storage') : '');
            }
        };

        // Explain a blocked choice only when it is blocked.
        let syncStorage = function() {
            let sc = get('storage');
            let combo = get('resilience');
            let store = sc.getStore();
            // wait for the list: deciding on an empty store would pick
            // "local" and hide the shared storages that load next
            if (!store.isLoaded()) {
                return;
            }
            // look at all storages, not just those our own filter shows
            let all = store.getData().getSource() || store.getData();
            let anyShared = false;
            all.each(function(r) {
                if (r.get('shared') && !r.get('disable')) {
                    anyShared = true;
                }
            });
            let note = ipanel.down('#haNote');
            note.setVisible(!anyShared);
            combo.setDisabled(!anyShared);
            let preset = anyShared ? 'shared-ha' : 'local-replace';
            if (combo.getValue() !== preset && !combo.userChose) {
                combo.setValue(preset);
            }
            applyResilience(combo.getValue());
            updateSummary();
        };

        // One place decides how the network fields relate.
        let syncNetwork = function() {
            let zone = get('sdn-zone');
            let subnet = get('public-subnet');
            let count = zoneStore.getCount();
            subnet.setVisible(count > 0);
            subnet.setDisabled(count === 0);
            zone.setVisible(count > 1);
            zone.setDisabled(count < 2);
            zone.allowBlank = !subnet.getValue();
            zone.validate();
            ipanel.down('#subnetHint').setVisible(count > 0);
            ipanel.down('#subnetHint').setValue(count === 1
                ? Ext.String.format(gettext('Optional. A free /24 that publishes '
                    + 'LoadBalancer IPs and the API address through SDN zone {0}. '
                    + 'Leave empty to stay on the shared cluster network.'),
                    Ext.String.htmlEncode(zoneStore.getAt(0).get('zone')))
                : gettext('Optional. A free /24 that publishes LoadBalancer IPs '
                    + 'and the API address through an SDN zone. Leave empty to '
                    + 'stay on the shared cluster network.'));
            updateSummary();
        };

        let updateSummary = function() {
            if (!ipanel || !ipanel.rendered) {
                return;
            }
            let cp = get('cp') ? get('cp').getValue() : me.defaultControlPlane;
            let ver = get('k8s-version') ? get('k8s-version').getValue() : latest;
            let stor = get('storage') ? get('storage').getValue() : '';
            let ha = get('cp-policy') && get('cp-policy').getValue() === 'ha';
            let sub = get('public-subnet');
            let net = sub && !sub.isDisabled() && sub.getValue()
                ? Ext.String.format(gettext('LoadBalancer IPs from {0}'),
                    Ext.String.htmlEncode(sub.getValue()))
                : gettext('shared cluster network');
            let line = Ext.String.format(
                gettext('{0} control-plane nodes and {1} workers, Kubernetes {2}'),
                cp, me.defaultWorkers, Ext.String.htmlEncode(ver || latest));
            if (stor) {
                line += ', ' + Ext.String.format(
                    ha ? gettext('storage {0} (HA)') : gettext('storage {0}'),
                    Ext.String.htmlEncode(stor));
            }
            line += ', ' + net;
            let sum = ipanel.down('#summary');
            if (sum) {
                sum.setValue(line);
            }
        };

        ipanel = Ext.create('Proxmox.panel.InputPanel', {
            column1: [
                {
                    xtype: 'textfield',
                    name: 'name',
                    fieldLabel: gettext('Name'),
                    emptyText: 'c1',
                    allowBlank: false,
                    regex: /^[A-Za-z][A-Za-z0-9_-]*$/,
                    regexText: gettext('Letters, digits, - and _; must start with a letter'),
                },
                {
                    xtype: 'textfield',
                    name: 'public-subnet',
                    fieldLabel: gettext('Public Subnet'),
                    emptyText: gettext('none (shared network)'),
                    hidden: true,
                    disabled: true,
                    listeners: { change: function() { syncNetwork(); } },
                },
                {
                    xtype: 'displayfield',
                    itemId: 'subnetHint',
                    userCls: 'pmx-hint',
                    hidden: true,
                    value: '',
                },
                {
                    xtype: 'combobox',
                    name: 'sdn-zone',
                    fieldLabel: gettext('SDN Zone'),
                    store: zoneStore,
                    displayField: 'zone',
                    valueField: 'zone',
                    queryMode: 'local',
                    editable: false,
                    allowBlank: true,
                    hidden: true,
                    disabled: true,
                    emptyText: gettext('select the zone'),
                    listeners: { change: function() { syncNetwork(); } },
                },
            ],
            columnB: [
                {
                    xtype: 'displayfield',
                    itemId: 'summary',
                    fieldLabel: gettext('This creates'),
                    labelWidth: 100,
                    value: '',
                },
            ],
            advancedColumn1: [
                {
                    xtype: 'combobox',
                    name: 'k8s-version',
                    fieldLabel: gettext('Kubernetes Version'),
                    store: versionStore,
                    value: latest,
                    editable: false,
                    allowBlank: false,
                    listeners: {
                        change: function(f, v) {
                            get('k8s-support').setValue(supportText(v));
                            updateSummary();
                        },
                    },
                },
                {
                    xtype: 'displayfield',
                    name: 'k8s-support',
                    submitValue: false,
                    fieldLabel: gettext('Support'),
                    value: supportText(latest),
                },
                {
                    xtype: 'combobox',
                    name: 'cp',
                    fieldLabel: gettext('Control Plane Nodes'),
                    store: [1, 3, 5],
                    value: me.defaultControlPlane,
                    editable: false,
                    listeners: { change: function() { updateSummary(); } },
                },
                {
                    xtype: 'combobox',
                    name: 'resilience',
                    fieldLabel: gettext('Availability'),
                    store: [
                        ['shared-ha', gettext('High availability (shared storage)')],
                        ['local-replace', gettext('Standard (local storage)')],
                    ],
                    value: 'shared-ha',
                    editable: false,
                    listeners: {
                        select: function(combo) {
                            combo.userChose = true;
                        },
                        change: function(combo, preset) {
                            applyResilience(preset);
                            updateSummary();
                        },
                    },
                },
                {
                    xtype: 'displayfield',
                    itemId: 'haNote',
                    userCls: 'pmx-hint',
                    hidden: true,
                    value: gettext('No shared storage is configured, so a failed node '
                        + 'is rebuilt instead of restarted by Proxmox HA.'),
                },
                {
                    xtype: 'pveStorageSelector',
                    name: 'storage',
                    fieldLabel: gettext('Storage'),
                    clusterView: true,
                    storageContent: 'images',
                    // not required: the backend picks a default, and a
                    // blank advanced field would make the stock window
                    // pop the Advanced section open on its own
                    allowBlank: true,
                    emptyText: gettext('Proxmox storage for node disks'),
                    listeners: { change: function() { updateSummary(); } },
                },
                { xtype: 'hiddenfield', name: 'storage-profile', value: 'shared' },
                { xtype: 'hiddenfield', name: 'cp-policy', value: 'ha' },
            ],
            advancedColumn2: [
                {
                    xtype: 'textfield',
                    name: 'node-subnet',
                    fieldLabel: gettext('Node Subnet'),
                    emptyText: gettext('auto: first free 10.10.x.0/24'),
                },
                {
                    xtype: 'textfield',
                    name: 'gateway',
                    fieldLabel: gettext('Gateway'),
                    emptyText: gettext('auto: .1 of the node subnet'),
                },
                {
                    xtype: 'textfield',
                    name: 'lb-range',
                    fieldLabel: gettext('LoadBalancer Range'),
                    emptyText: gettext('auto: .100-.120 of the public subnet'),
                },
                {
                    xtype: 'textfield',
                    name: 'builder-ip',
                    fieldLabel: gettext('Template Builder IP'),
                    emptyText: gettext('auto: DHCP on the host LAN'),
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

            onGetValues: function(values) {
                // resilience is a dialog-only bundle: the profile
                // and policy travel, it does not
                delete values.resilience;
                // one SDN zone needs no decision when a public
                // subnet is given: use it
                if (values['public-subnet'] && !values['sdn-zone']
                    && zoneStore.getCount() === 1) {
                    values['sdn-zone'] = zoneStore.getAt(0).get('zone');
                }
                // optional fields: omit blanks entirely
                Object.keys(values).forEach(function(key) {
                    if (values[key] === '' || values[key] === undefined) {
                        delete values[key];
                    }
                });
                return values;
            },
        });

        Ext.apply(me, { items: [ipanel] });
        me.callParent();

        // everything that depends on loaded stores waits for them
        let sc = get('storage');
        sc.getStore().on('load', syncStorage);
        zoneStore.on('load', syncNetwork);
        me.on('afterrender', function() {
            // follow the Advanced checkbox explicitly: with no stored
            // state the stock window passes undefined, which shows it
            let sp = Ext.state.Manager.getProvider();
            ipanel.setAdvancedVisible(!!(sp && sp.get('proxmox-advanced-cb')));
            syncStorage();
            syncNetwork();
        });
    },
});


// Node group editor: stock Edit window. A group is a name and a
// node count; autoscaling (Min/Max) is one checkbox away and
// everything about placement and sizing is under Advanced.
// Saving hands the entry to the caller, which writes all groups
// and converges the cluster; nothing is submitted from here.
Ext.define('PVE.dc.K8sGroupWindow', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveDcK8sGroupWindow',

    subject: gettext('Node Group'),
    url: '/cluster/k8s',
    width: 640,

    existing: undefined,   // the group being edited, undefined for a new one
    deviceStore: undefined,
    onSave: undefined,     // function(entry)

    submit: function() {
        let me = this;
        if (!me.isValid()) {
            return;
        }
        let v = me.getValues();
        let size = parseInt(v.size, 10);
        let autoscale = !!v.autoscale;
        let min = autoscale ? parseInt(v.min, 10) : size;
        let max = autoscale ? parseInt(v.max, 10) : size;
        if (!(min <= size && size <= max)) {
            Ext.Msg.alert(gettext('Error'),
                gettext('Min <= Nodes <= Max required'));
            return;
        }
        let entry = { name: v.name, size: size, min: min, max: max };
        let hosts = Ext.isArray(v.hosts) ? v.hosts.join(',') : v.hosts;
        v.hosts = hosts;
        ['labels', 'taints', 'hosts', 'storage', 'arch', 'policy',
            'device-profile'].forEach(function(k) {
                if (v[k]) { entry[k] = v[k]; }
            });
        ['cpu', 'memory', 'disk'].forEach(function(k) {
            if (v[k] !== '' && v[k] !== null && v[k] !== undefined) {
                entry[k] = parseInt(v[k], 10);
            }
        });
        me.close();
        me.onSave(entry);
    },

    initComponent: function() {
        let me = this;
        let ex = me.existing;
        me.isCreate = !ex;
        let autoscale = ex ? !(ex.min === ex.size && ex.max === ex.size) : false;

        let sync = function(cb) {
            let on = !!cb.getValue();
            ['min', 'max'].forEach(function(n) {
                let f = me.down('[name=' + n + ']');
                f.setVisible(on);
                f.setDisabled(!on);
            });
            me.down('#scaleHint').setVisible(on);
        };

        let ipanel = Ext.create('Proxmox.panel.InputPanel', {
            column1: [
                {
                    xtype: 'textfield', name: 'name',
                    fieldLabel: gettext('Name'),
                    value: ex ? ex.name : '',
                    readOnly: !!ex, allowBlank: false,
                    regex: /^[a-z][a-z0-9-]*$/,
                    regexText: gettext('Lowercase letters, digits and -'),
                },
                {
                    xtype: 'numberfield', name: 'size',
                    fieldLabel: gettext('Nodes'),
                    value: ex ? ex.size : 2,
                    minValue: 0, maxValue: 50, allowBlank: false,
                },
            ],
            column2: [
                {
                    xtype: 'proxmoxcheckbox', name: 'autoscale',
                    fieldLabel: gettext('Autoscale'),
                    checked: autoscale, uncheckedValue: 0,
                    listeners: {
                        change: sync,
                        afterrender: sync,
                    },
                },
                {
                    xtype: 'numberfield', name: 'min',
                    fieldLabel: gettext('Min'),
                    value: ex ? ex.min : 1,
                    minValue: 0, maxValue: 50, allowBlank: false,
                    hidden: !autoscale, disabled: !autoscale,
                },
                {
                    xtype: 'numberfield', name: 'max',
                    fieldLabel: gettext('Max'),
                    value: ex ? ex.max : 3,
                    minValue: 0, maxValue: 50, allowBlank: false,
                    hidden: !autoscale, disabled: !autoscale,
                },
            ],
            columnB: [
                {
                    xtype: 'displayfield', itemId: 'scaleHint',
                    userCls: 'pmx-hint', hidden: !autoscale,
                    value: gettext('The scaler adds nodes for pending pods up '
                        + 'to Max and removes idle ones down to Min; Nodes is '
                        + 'the size enforced when you save.'),
                },
            ],
            advancedColumn1: [
                {
                    xtype: 'numberfield', name: 'cpu',
                    fieldLabel: gettext('CPU Cores'),
                    value: ex ? (ex.cpu || '') : '',
                    minValue: 1, maxValue: 64, allowBlank: true,
                    emptyText: gettext('default 2'),
                },
                {
                    xtype: 'numberfield', name: 'memory',
                    fieldLabel: gettext('Memory (MiB)'),
                    value: ex ? (ex.memory || '') : '',
                    minValue: 512, maxValue: 1048576, allowBlank: true,
                    emptyText: gettext('default 4096'),
                },
                {
                    xtype: 'numberfield', name: 'disk',
                    fieldLabel: gettext('Disk (GiB)'),
                    value: ex ? (ex.disk || '') : '',
                    minValue: 8, maxValue: 4096, allowBlank: true,
                    emptyText: gettext('template size'),
                },
                {
                    xtype: 'combobox', name: 'arch',
                    fieldLabel: gettext('Architecture'),
                    store: [['', gettext('default')], 'amd64', 'arm64'],
                    value: ex ? (ex.arch || '') : '',
                    editable: false,
                },
                {
                    // HA is refused by the backend unless this
                    // group's storage (and the pod storage) is shared
                    xtype: 'combobox', name: 'policy',
                    fieldLabel: gettext('Failure Policy'),
                    store: [
                        ['replace', gettext('Replace')],
                        ['ha', gettext('HA (shared storage only)')],
                    ],
                    value: ex ? (ex.policy || 'replace') : 'replace',
                    editable: false,
                },
            ],
            advancedColumn2: [
                {
                    // autoSelect off: the stock selectors pick the first
                    // entry on load, which would silently pin the group
                    xtype: 'pveNodeSelector', name: 'hosts',
                    fieldLabel: gettext('PVE Hosts'),
                    multiSelect: true, allowBlank: true, autoSelect: false,
                    value: ex && ex.hosts ? ex.hosts.split(',') : [],
                    emptyText: gettext('any host'),
                },
                {
                    xtype: 'pveStorageSelector', name: 'storage',
                    fieldLabel: gettext('Storage'),
                    clusterView: true, storageContent: 'images',
                    allowBlank: true, autoSelect: false,
                    value: ex ? (ex.storage || '') : '',
                    emptyText: gettext('cluster default'),
                },
                {
                    xtype: 'combobox', name: 'device-profile',
                    fieldLabel: gettext('Device Profile (GPU)'),
                    store: me.deviceStore,
                    displayField: 'id', valueField: 'id',
                    editable: true, allowBlank: true,
                    value: ex ? (ex['device-profile'] || '') : '',
                    emptyText: gettext('PVE PCI resource mapping'),
                },
                {
                    xtype: 'textfield', name: 'labels',
                    fieldLabel: gettext('Labels'),
                    value: ex ? (ex.labels || '') : '',
                    emptyText: 'key=value,...',
                },
                {
                    xtype: 'textfield', name: 'taints',
                    fieldLabel: gettext('Taints'),
                    value: ex ? (ex.taints || '') : '',
                    emptyText: 'key=value:NoSchedule,...',
                },
            ],
        });
        Ext.apply(me, { items: [ipanel] });
        me.callParent();
    },
});


// Upgrade: runs the read-only pre-flight first and shows it, like an
// upgrade-insights page. The Upgrade button stays disabled while a
// check blocks; warnings need an explicit acknowledgement. The target
// is always the next minor (kubeadm cannot skip one), so there is
// nothing to type.
Ext.define('PVE.dc.K8sUpgradeWindow', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveDcK8sUpgradeWindow',

    subject: gettext('Upgrade Kubernetes'),
    title: gettext('Upgrade Kubernetes'),
    isCreate: true,
    method: 'POST',
    showTaskViewer: true,
    submitText: gettext('Upgrade'),
    width: 640,
    // a click on Upgrade is explicit: do not wait for the window
    extraRequestParams: { force: 1 },

    clusterName: undefined,
    currentVersion: undefined,

    initComponent: function() {
        let me = this;
        let name = me.clusterName;
        me.url = '/cluster/k8s/' + encodeURIComponent(name) + '/upgrade';
        let parts = String(me.currentVersion || '').split('.');
        let target = parts[0] + '.' + (parseInt(parts[1], 10) + 1);
        let icons = {
            ok: 'fa fa-check good',
            warn: 'fa fa-exclamation-triangle warning',
            block: 'fa fa-times-circle critical',
        };
        let state = { loaded: false, blockers: 0, warnings: 0 };

        let gate = function() {
            if (!state.loaded) {
                return gettext('Checking the cluster...');
            }
            if (state.blockers) {
                return gettext('Resolve the blocking checks first.');
            }
            let ack = me.down('[name=ack]');
            if (state.warnings && !ack.getValue()) {
                return gettext('Confirm the warnings to continue.');
            }
            return true;
        };
        let revalidate = function() {
            me.down('[name=gate]').validate();
        };

        let ipanel = Ext.create('Proxmox.panel.InputPanel', {
            items: [
                {
                    xtype: 'displayfield',
                    fieldLabel: gettext('Version'),
                    value: Ext.String.format('{0} → {1}',
                        Ext.String.htmlEncode(me.currentVersion),
                        Ext.String.htmlEncode(target)),
                },
                { xtype: 'hiddenfield', name: 'to', value: target },
                {
                    xtype: 'component',
                    itemId: 'checks',
                    padding: '4 0 8 0',
                    html: '<i class="fa fa-spinner fa-pulse"></i> '
                        + gettext('Checking the cluster...'),
                },
                {
                    xtype: 'proxmoxcheckbox',
                    name: 'ack',
                    boxLabel: gettext('I have read the warnings and want to continue'),
                    submitValue: false,
                    hidden: true,
                    uncheckedValue: 0,
                    listeners: { change: revalidate },
                },
                {
                    // keeps the Upgrade button disabled while a check
                    // blocks; never submitted
                    xtype: 'textfield',
                    name: 'gate',
                    hidden: true,
                    submitValue: false,
                    validator: gate,
                },
            ],
        });
        Ext.apply(me, { items: [ipanel] });
        me.callParent();

        me.on('afterrender', function() {
            Proxmox.Utils.API2Request({
                url: '/cluster/k8s/' + encodeURIComponent(name) + '/upgrade-check',
                method: 'GET',
                params: { to: target },
                success: function(resp) {
                    let res = resp.result.data || {};
                    state.loaded = true;
                    state.blockers = res.blockers || 0;
                    state.warnings = res.warnings || 0;
                    let rows = (res.checks || []).map(function(c) {
                        return '<div style="padding:2px 0"><i class="' + (icons[c.level] || icons.ok)
                            + '"></i> ' + Ext.String.htmlEncode(c.message) + '</div>';
                    });
                    me.down('#checks').update(rows.join(''));
                    me.down('[name=ack]').setVisible(!!state.warnings && !state.blockers);
                    revalidate();
                },
                failure: function(resp) {
                    state.loaded = false;
                    me.down('#checks').update(Ext.String.htmlEncode(
                        Proxmox.Utils.extractRequestError(resp, true)));
                },
            });
            revalidate();
        });
    },
});

// Rebuild the node image now. The severity is the operator's call (no
// CVE feed): it only sets how long nodes may stay on the old image.
Ext.define('PVE.dc.K8sRebuildWindow', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveDcK8sRebuildWindow',

    subject: gettext('Node Image'),
    title: gettext('Rebuild Node Image'),
    isCreate: true,
    method: 'POST',
    showTaskViewer: true,
    submitText: gettext('Rebuild'),
    width: 560,
    clusterName: undefined,

    initComponent: function() {
        let me = this;
        me.url = '/cluster/k8s/' + encodeURIComponent(me.clusterName) + '/rebuild-template';
        Ext.apply(me, {
            items: [{
                xtype: 'inputpanel',
                items: [
                    {
                        xtype: 'displayfield',
                        userCls: 'pmx-hint',
                        value: gettext('Builds a fresh node image (current OS and '
                            + 'security updates). Nodes move to it in the next '
                            + 'maintenance window, or when you run Roll.'),
                    },
                    {
                        xtype: 'combobox',
                        name: 'severity',
                        fieldLabel: gettext('Reason'),
                        store: [
                            ['routine', gettext('Routine refresh')],
                            ['high', gettext('Security fix: nodes updated within 30 days')],
                            ['critical', gettext('Critical security fix: within 7 days')],
                        ],
                        value: 'routine',
                        editable: false,
                        allowBlank: false,
                    },
                ],
            }],
        });
        me.callParent();
    },
});


// Add-ons that need answers before they are enabled: a stock Edit
// window, run as a task. Only the fields that apply are shown (the
// ACME email only for the ACME issuer).
Ext.define('PVE.dc.K8sAddonWindow', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveDcK8sAddonWindow',

    isCreate: true,
    method: 'POST',
    showTaskViewer: true,
    submitText: gettext('Enable'),
    width: 560,
    clusterName: undefined,
    addon: undefined,

    initComponent: function() {
        let me = this;
        me.url = '/cluster/k8s/' + encodeURIComponent(me.clusterName)
            + '/addons/' + me.addon + '/enable';
        me.title = Ext.String.format(gettext('Enable {0}'), me.addon);
        let hint = function(text) {
            return { xtype: 'displayfield', userCls: 'pmx-hint', value: text };
        };
        let items;
        if (me.addon === 'cert-manager') {
            items = [
                {
                    xtype: 'proxmoxKVComboBox',
                    name: 'issuer',
                    fieldLabel: gettext('Issuer'),
                    comboItems: [
                        ['ca', gettext('Cluster CA (internal names)')],
                        ['acme', gettext("ACME (Let's Encrypt)")],
                    ],
                    value: 'ca',
                    allowBlank: false,
                    listeners: {
                        change: function(field, value) {
                            let email = me.down('field[name=email]');
                            let acme = value === 'acme';
                            email.setHidden(!acme);
                            email.setDisabled(!acme);
                        },
                    },
                },
                {
                    xtype: 'textfield',
                    name: 'email',
                    vtype: 'proxmoxMail',
                    fieldLabel: gettext('ACME Email'),
                    allowBlank: false,
                    hidden: true,
                    disabled: true,
                },
            ];
        } else {
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
                    fieldLabel: gettext('API Key'),
                    inputType: 'password',
                    allowBlank: false,
                },
                hint(gettext('Publishes DNS records for LoadBalancer services '
                    + 'and ingresses into this PowerDNS zone.')),
            ];
        }
        Ext.apply(me, {
            items: [{
                xtype: 'inputpanel',
                fieldDefaults: { labelWidth: 150 },
                items: items,
            }],
        });
        me.callParent();
    },
});


// Kubeconfig: shaped like the stock Cluster Join Information window
// (modal, one line of explanation, read-only fields, Copy in a bottom
// toolbar). Each opening issues a fresh 1-hour token: that GET is the
// audit record.
Ext.define('PVE.dc.K8sKubeconfigWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcK8sKubeconfigWindow',

    width: 760,
    modal: true,
    resizable: false,
    clusterName: undefined,
    maxHours: undefined,

    initComponent: function() {
        let me = this;
        let text;
        let max = parseInt(me.maxHours, 10) || 24;
        let choices = [1, 8, 24].filter(function(h) { return h <= max; });
        if (choices.indexOf(max) < 0) { choices.push(max); }
        me.title = Ext.String.format(gettext('Kubeconfig: {0}'), me.clusterName);
        let save = function() {
            if (!text) { return; }
            let blob = new Blob([text], { type: 'text/yaml' });
            let a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = me.clusterName + '.kubeconfig';
            a.click();
            URL.revokeObjectURL(a.href);
        };
        let saveHelper = function() {
            Proxmox.Utils.API2Request({
                url: '/cluster/k8s/' + encodeURIComponent(me.clusterName) + '/auth-helper',
                method: 'GET',
                success: function(r) {
                    let data = r.result.data || {};
                    let blob = new Blob([data.content || ''], { type: 'text/x-python' });
                    let a = document.createElement('a');
                    a.href = URL.createObjectURL(blob);
                    a.download = data.filename || 'pve-k8s-auth';
                    a.click();
                    URL.revokeObjectURL(a.href);
                },
                failure: function(r) { Ext.Msg.alert(gettext('Error'), r.htmlStatus); },
            });
        };
        let tokenId = 'k8s-' + me.clusterName;
        let hints = {
            fixed: gettext('A kubeconfig of your own: the role follows '
                + 'your Proxmox VE privileges. Save it as ~/.kube/config '
                + 'or pass it to kubectl with --kubeconfig.'),
            auto: Ext.String.format(gettext('Auto-refresh: kubectl runs '
                + 'pve-k8s-auth (Python 3, download it below and put it on '
                + 'your PATH), which uses your API token {0} to get a 1 hour '
                + 'Kubernetes token whenever needed. Delete the token, or '
                + 'revoke your access, to stop it.'), tokenId),
        };
        let copy = function() {
            if (!text) { return; }
            let area = me.down('textarea');
            area.inputEl.dom.select();
            if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(text);
            } else {
                document.execCommand('copy');
            }
        };
        Ext.apply(me, {
            items: [
                {
                    xtype: 'component',
                    itemId: 'hint',
                    padding: 10,
                    html: hints.fixed,
                },
                {
                    xtype: 'container',
                    // anchor, not form: a form row will not give the
                    // textarea its height
                    layout: 'anchor',
                    padding: '0 10 10 10',
                    defaults: { anchor: '100%', labelWidth: 100 },
                    items: [
                        {
                            xtype: 'proxmoxKVComboBox',
                            itemId: 'hours',
                            fieldLabel: gettext('Validity'),
                            comboItems: choices.map(function(h) {
                                return [h, h === 1 ? gettext('1 hour')
                                    : Ext.String.format(gettext('{0} hours'), h)];
                            }).concat([['auto', gettext('Auto-refresh (1 hour tokens)')]]),
                            value: 1,
                            listeners: {
                                // another validity: issue a new one
                                select: function(combo) {
                                    if (combo.getValue() !== 'auto') {
                                        current = combo.getValue();
                                        load();
                                        return;
                                    }
                                    // it creates (or replaces) an API token: ask
                                    Ext.Msg.show({
                                        title: gettext('Auto-refresh'),
                                        icon: Ext.Msg.WARNING,
                                        buttons: Ext.Msg.YESNO,
                                        defaultFocus: 'no',
                                        message: Ext.String.format(gettext(
                                            'This creates the API token {0} under your '
                                            + 'user, or gives it a new secret: a previous '
                                            + 'auto-refresh kubeconfig for this cluster '
                                            + 'stops working. Continue?'), tokenId),
                                        fn: function(btn) {
                                            if (btn === 'yes') {
                                                current = 'auto';
                                                load();
                                            } else {
                                                combo.setValue(current);
                                            }
                                        },
                                    });
                                },
                            },
                        },
                        {
                            xtype: 'displayfield',
                            itemId: 'info',
                            fieldLabel: gettext('Role'),
                        },
                        {
                            xtype: 'textfield',
                            itemId: 'server',
                            fieldLabel: gettext('API Server'),
                            editable: false,
                        },
                        {
                            xtype: 'textarea',
                            fieldLabel: 'Kubeconfig',
                            height: 280,
                            editable: false,
                            fieldStyle: 'font-family: monospace; white-space: pre;',
                        },
                    ],
                },
            ],
            dockedItems: [{
                dock: 'bottom',
                xtype: 'toolbar',
                items: [
                    {
                        text: gettext('Copy'),
                        iconCls: 'fa fa-clipboard',
                        itemId: 'copy',
                        disabled: true,
                        handler: copy,
                    },
                    {
                        text: gettext('Download'),
                        iconCls: 'fa fa-download',
                        itemId: 'download',
                        disabled: true,
                        handler: save,
                    },
                    '->',
                    {
                        text: gettext('Download pve-k8s-auth'),
                        iconCls: 'fa fa-download',
                        itemId: 'helper',
                        hidden: true,
                        handler: saveHelper,
                    },
                ],
            }],
        });
        me.callParent();
        let current = 1;
        let load = function() {
            let auto = current === 'auto';
            text = undefined;
            me.down('#copy').disable();
            me.down('#download').disable();
            me.down('#helper').setHidden(!auto);
            me.down('#hint').setHtml(auto ? hints.auto : hints.fixed);
            me.down('textarea').setValue('');
            me.setLoading(true);
            Proxmox.Utils.API2Request({
                url: '/cluster/k8s/' + encodeURIComponent(me.clusterName) + '/kubeconfig',
                method: auto ? 'POST' : 'GET',
                params: auto ? { url: window.location.origin } : { hours: current },
                success: function(r) {
                    me.setLoading(false);
                    let data = r.result.data || {};
                    text = data.kubeconfig || '';
                    me.down('#server').setValue(data.server || '');
                    let role = data.role === 'admin'
                        ? gettext('Administrator (cluster-admin)')
                        : gettext('Read-only (view)');
                    me.down('#info').setValue(Ext.htmlEncode(role + ', ' + (auto
                        ? Ext.String.format(gettext('renewed hourly with API token {0}'),
                            data['api-token'])
                        : Ext.String.format(gettext('expires {0}'),
                            Ext.Date.format(new Date(data['expires-at'] * 1000),
                                'Y-m-d H:i')))));
                    me.down('textarea').setValue(text);
                    me.down('#copy').enable();
                    me.down('#download').enable();
                },
                failure: function(r) {
                    me.close();
                    Ext.Msg.alert(gettext('Error'), r.htmlStatus);
                },
            });
        };
        me.on('show', function() {
            load();        }, me, { single: true });
    },
});


// Evacuate a PVE host: pick it (stock node selector) instead of
// typing its name; the API runs it as a task.
Ext.define('PVE.dc.K8sEvacuateWindow', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveDcK8sEvacuateWindow',

    subject: gettext('PVE Host'),
    title: gettext('Evacuate PVE Host'),
    isCreate: true,
    method: 'POST',
    showTaskViewer: true,
    submitText: gettext('Evacuate'),
    width: 480,
    clusterName: undefined,

    initComponent: function() {
        let me = this;
        let base = '/cluster/k8s/' + encodeURIComponent(me.clusterName) + '/hosts/';
        me.url = base;
        // the host is part of the URL, not a request parameter
        me.submitUrl = function(url, values) {
            let host = values.host;
            delete values.host;
            return base + encodeURIComponent(host) + '/evacuate';
        };
        Ext.apply(me, {
            items: [{
                xtype: 'inputpanel',
                items: [
                    {
                        xtype: 'pveNodeSelector',
                        name: 'host',
                        fieldLabel: gettext('Host'),
                        allowBlank: false,
                        autoSelect: false,
                        onlineValidator: true,
                    },
                    {
                        xtype: 'displayfield',
                        userCls: 'pmx-hint',
                        value: gettext('Live-migrates every VM of this cluster '
                            + 'off the host, e.g. before host maintenance.'),
                    },
                ],
            }],
        });
        me.callParent();
    },
});


// Settings: the stock ObjectGrid, one property per row with its own
// small Edit window (like the VM Options tab). An emptied value is
// cleared through the API's `delete` parameter, so every setting that
// can be set can also be unset. Read-only rows show what was decided
// at creation.
Ext.define('PVE.dc.K8sSettings', {
    extend: 'Proxmox.grid.ObjectGrid',
    alias: 'widget.pveDcK8sSettings',

    clusterName: undefined,
    onChanged: undefined,
    // true for a user without Sys.Modify: no Edit button, no editors
    viewOnly: false,
    cwidth1: 260,

    initComponent: function() {
        let me = this;
        let name = encodeURIComponent(me.clusterName);
        me.url = '/api2/json/cluster/k8s/' + name;
        me.interval = 10000;
        me.editorConfig = {
            url: '/cluster/k8s/' + name,
            method: 'PUT',
            apiCallDone: function(ok) {
                if (ok && me.onChanged) {
                    me.onChanged();
                }
            },
        };

        let hint = function(text) {
            return { xtype: 'displayfield', userCls: 'pmx-hint', value: text };
        };
        let edit = function(subject, items) {
            return {
                xtype: 'proxmoxWindowEdit',
                subject: subject,
                fieldDefaults: { labelWidth: 150 },
                width: 520,
                items: items,
            };
        };
        let readonly = function(header, renderer) {
            return { header: header, required: false, renderer: renderer };
        };
        let policy = function(v) {
            return v === 'ha' ? gettext('HA (Proxmox restarts the VM)')
                : gettext('Replace (a failed node is rebuilt)');
        };

        me.rows = {
            description: {
                header: gettext('Description'),
                required: true,
                defaultValue: '',
                editor: edit(gettext('Description'), [{
                    xtype: 'proxmoxtextfield', name: 'description',
                    fieldLabel: gettext('Description'), deleteEmpty: true,
                }]),
            },
            'maintenance-window': {
                header: gettext('Maintenance Window'),
                required: true,
                defaultValue: '',
                renderer: function(v) {
                    return v ? Ext.htmlEncode(v) : gettext('none (updates only when you run Roll)');
                },
                editor: edit(gettext('Maintenance Window'), [
                    {
                        xtype: 'proxmoxtextfield', name: 'maintenance-window',
                        fieldLabel: gettext('Window'), deleteEmpty: true,
                        emptyText: 'HH:MM-HH:MM',
                        regex: /^\d{2}:\d{2}-\d{2}:\d{2}$/,
                        regexText: gettext('Use HH:MM-HH:MM, local time of the host'),
                    },
                    hint(gettext('Nodes move to a new image on their own only '
                        + 'inside this window. Leave empty to update nodes only '
                        + 'when you run Roll.')),
                ]),
            },
            'backup-retention': {
                header: gettext('etcd Backups Kept'),
                required: true,
                defaultValue: '',
                renderer: function(v) {
                    return v ? Ext.htmlEncode(String(v)) : gettext('default');
                },
                editor: edit(gettext('etcd Backups Kept'), [{
                    xtype: 'proxmoxintegerfield', name: 'backup-retention',
                    fieldLabel: gettext('Backups'), minValue: 1, maxValue: 100,
                    deleteEmpty: true, emptyText: gettext('default'),
                }]),
            },
            'scale-in-cooldown': {
                header: gettext('Scale-in Cooldown'),
                required: true,
                defaultValue: '',
                renderer: function(v) {
                    return v ? Ext.String.format(gettext('{0} min'), v)
                        : gettext('default') + ' (10 min)';
                },
                editor: edit(gettext('Scale-in Cooldown'), [{
                    xtype: 'proxmoxintegerfield', name: 'scale-in-cooldown',
                    fieldLabel: gettext('Minutes'), minValue: 1, maxValue: 1440,
                    deleteEmpty: true, emptyText: '10',
                }, hint(gettext('After any scale action, the scaler waits '
                    + 'this long before it removes a node.'))]),
            },
            'kubeconfig-max-hours': {
                header: gettext('Kubeconfig Max Validity'),
                required: true,
                defaultValue: '',
                renderer: function(v) {
                    return v ? Ext.String.format(gettext('{0} h'), v)
                        : gettext('default') + ' (24 h)';
                },
                editor: edit(gettext('Kubeconfig Max Validity'), [{
                    xtype: 'proxmoxintegerfield', name: 'kubeconfig-max-hours',
                    fieldLabel: gettext('Hours'), minValue: 1, maxValue: 720,
                    deleteEmpty: true, emptyText: '24',
                }, hint(gettext('The longest validity users can pick when '
                    + 'they get a kubeconfig.'))]),
            },
            'cp-policy': {
                header: gettext('Control Plane Failure Policy'),
                required: false,
                renderer: policy,
                editor: edit(gettext('Control Plane Failure Policy'), [
                    {
                        xtype: 'proxmoxKVComboBox', name: 'cp-policy',
                        fieldLabel: gettext('Policy'),
                        comboItems: [
                            ['replace', gettext('Replace (a failed node is rebuilt)')],
                            ['ha', gettext('HA (Proxmox restarts the VM)')],
                        ],
                        value: 'replace', allowBlank: false,
                    },
                    hint(gettext('HA needs shared storage; the API refuses it otherwise.')),
                ]),
            },
            'storage-profile': {
                header: gettext('Storage Profile'),
                required: false,
                renderer: function(v) {
                    return v === 'local' ? gettext('Local disks') : gettext('Shared (Ceph)');
                },
                editor: edit(gettext('Storage Profile'), [{
                    xtype: 'proxmoxKVComboBox', name: 'storage-profile',
                    fieldLabel: gettext('Profile'),
                    comboItems: [
                        ['shared', gettext('Shared (Ceph)')],
                        ['local', gettext('Local disks')],
                    ],
                    value: 'shared', allowBlank: false,
                }]),
            },
            'k8s-version': readonly(gettext('Kubernetes Version')),
            state: readonly(gettext('State')),
            cp: readonly(gettext('Control Plane Nodes')),
            storage: readonly(gettext('Storage')),
            'node-subnet': readonly(gettext('Node Subnet')),
            'public-subnet': readonly(gettext('Public Subnet')),
            'sdn-zone': readonly(gettext('SDN Zone')),
            'template-rev': readonly(gettext('Image Revision')),
            'cp-arch': readonly(gettext('Control Plane Architecture')),
        };
        let order = ['description', 'maintenance-window', 'backup-retention',
            'scale-in-cooldown', 'kubeconfig-max-hours', 'cp-policy',
            'storage-profile',
            'k8s-version', 'state', 'cp',
            'storage', 'node-subnet', 'public-subnet', 'sdn-zone',
            'template-rev', 'cp-arch'];
        me.sorterFn = function(a, b) {
            return order.indexOf(a.data.key) - order.indexOf(b.data.key);
        };

        let editBtn = Ext.create('Ext.button.Button', {
            text: gettext('Edit'),
            disabled: true,
            handler: function() { me.run_editor(); },
        });
        if (me.viewOnly) {
            // no Sys.Modify: the same values, nothing to edit
            Ext.Object.each(me.rows, function(key, row) { delete row.editor; });
        } else {
            me.tbar = [editBtn];
        }
        me.callParent();

        me.on('selectionchange', function(sm, sel) {
            let key = sel && sel.length ? sel[0].data.key : null;
            editBtn.setDisabled(!key || !me.rows[key] || !me.rows[key].editor);
        });
        me.on('itemdblclick', function() { me.run_editor(); });
        me.on('activate', function() { me.rstore.startUpdate(); });
        me.on('deactivate', function() { me.rstore.stopUpdate(); });
        me.on('destroy', function() { me.rstore.stopUpdate(); });
        me.rstore.startUpdate();
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

        // Every write call needs Sys.Modify (the API checks it on
        // /cluster). A user with only Sys.Audit gets the same pages
        // without the buttons that could only fail; GuiCap is what
        // PVE's own panels read.
        let caps = Ext.state.Manager.get('GuiCap') || {};
        let canModify = !!(caps.dc && caps.dc['Sys.Modify']);
        me.canModify = canModify;
        // Hide every button except those marked k8sReadOnly, and any
        // toolbar left with nothing to show. Applied to each panel as
        // it is built and to the page's own top bar.
        let readOnlyView = function(comp) {
            if (canModify || !comp || !comp.query) { return comp; }
            comp.query('button').forEach(function(b) {
                // tab headers are buttons too: they only switch views
                if (!b.k8sReadOnly && !(b instanceof Ext.tab.Tab)) { b.hide(); }
            });
            comp.query('toolbar').forEach(function(tb) {
                let shown = tb.items.findBy(function(it) {
                    return !it.hidden && !(it instanceof Ext.toolbar.Fill)
                        && !(it instanceof Ext.toolbar.Separator)
                        && !(it instanceof Ext.toolbar.Spacer);
                });
                if (!shown) { tb.hide(); }
            });
            return comp;
        };

        let api = function(opts) {
            Proxmox.Utils.API2Request(Ext.apply({
                failure: function(response) {
                    Ext.Msg.alert(gettext('Error'),
                        Proxmox.Utils.extractRequestError(response, true));
                },
            }, opts));
        };
        // One summary request per cluster at a time, shared by whoever
        // asks within a few seconds. Opening a cluster page starts it at
        // once, so the Overview does not wait for the cluster list first.
        let summaryReq = {};
        let fetchSummary = function(name, onOk, onFail) {
            let r = summaryReq[name];
            if (!r || (r.done && Date.now() - r.done > 5000)) {
                r = summaryReq[name] = { waiters: [] };
                Proxmox.Utils.API2Request({
                    url: '/cluster/k8s/' + encodeURIComponent(name) + '/summary',
                    method: 'GET',
                    timeout: 120000,
                    success: function(resp) {
                        r.done = Date.now(); r.ok = true; r.resp = resp;
                        r.waiters.forEach(function(w) { w[0](resp); });
                        r.waiters = [];
                    },
                    failure: function(resp) {
                        r.done = Date.now(); r.ok = false; r.resp = resp;
                        r.waiters.forEach(function(w) { w[1](resp); });
                        r.waiters = [];
                    },
                });
            }
            if (r.done) {
                // always asynchronous, like a network reply: the caller
                // may still be building (and not rendering) its panel
                let cb = r.ok ? onOk : onFail;
                Ext.defer(function() { cb(r.resp); }, 1);
            } else {
                r.waiters.push([onOk, onFail]);
            }
        };
        if (fixedClusterName) {
            fetchSummary(fixedClusterName, Ext.emptyFn, Ext.emptyFn);
        }

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

        // Destroying a cluster deletes every node VM and disk: the stock
        // type-the-name dialog, like removing a VM, not a yes/no box.
        let destroyCluster = function(name, done) {
            Ext.create('Proxmox.window.SafeDestroy', {
                autoShow: true,
                url: '/cluster/k8s/' + encodeURIComponent(name),
                item: { id: name },
                taskName: 'k8sdelete',
                showProgress: true,
                note: gettext('All node VMs of this cluster and their disks '
                    + 'are deleted.'),
                taskDone: done,
                apiCallDone: function(success) {
                    if (success) {
                        done();
                    }
                },
            });
        };

        let clusterStore = Ext.create('Ext.data.Store', {
            fields: ['name', 'state', 'k8s-version', 'template-rev',
                'cp', 'workers', 'node-subnet', 'gateway', 'lb-range',
                'storage', 'sdn-zone', 'public-subnet',
                'maintenance-window', 'pools', 'action-state',
                'storage-profile', 'cp-policy', 'scaler-state',
                'kubeconfig-max-hours'],
            proxy: { type: 'proxmox', url: '/api2/json/cluster/k8s' },
        });

        let panels = {};   // clusterName:panelKey -> component

        let grid = function(fields, url, columns, tbar, selModel) {
            return Ext.create('Ext.grid.Panel', {
                header: false,
                border: false,
                selModel: selModel || 'rowmodel',
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
            if (!poolsText) {
                // a new cluster has no explicit groups yet: the backend
                // default is one group sized by 'workers' (as on Nodes)
                poolsText = 'default: ' + (parseInt(rec.workers, 10) || 2)
                    + gettext(' nodes');
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
            let groupsInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Node Groups'),
                // one group per line - a '; '-joined
                // sentence wraps into mush past 2 groups
                value: Ext.htmlEncode(poolsText)
                    .replace(/; /g, '<br>'),
                labelWidth: 160,
            });
            let actionInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Running Action'),
                value: Ext.htmlEncode(actionText
                    || gettext('none')),
                labelWidth: 160,
            });
            let parkedInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Parked (awaiting placement)'),
                value: Ext.htmlEncode(parkedText
                    || gettext('none')),
                labelWidth: 160,
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
                    certInfo.setValue((worst === 'ok'
                        ? '<i class="fa fa-check good"></i> '
                        : '<i class="fa fa-exclamation-triangle warning"></i> ')
                        + (worst === 'ok'
                            ? gettext('ok')
                            : Ext.String.format(gettext('{0}: next {1}'),
                                worst, soon)));
                },
                failure: function() {
                    certInfo.setValue(gettext('unknown'));
                },
            });
            // Visual Summary (Increment 7): verdict banner,
            // readiness counts and node capacity bars fed by
            // the /summary aggregate; each piece degrades to
            // 'unknown' instead of breaking the panel.
            let healthInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Status'),
                value: gettext('loading...'),
                labelWidth: 160,
            });
            let versionInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Kubernetes'),
                value: Ext.htmlEncode(String(
                    rec['k8s-version'] || '')),
                labelWidth: 160,
            });
            let nodesInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Nodes'),
                value: gettext('loading...'),
                labelWidth: 160,
            });
            let podsInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Pods'),
                value: gettext('loading...'),
                labelWidth: 160,
            });
            let storageInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Storage Profile'),
                value: Ext.htmlEncode(String(
                    rec['storage-profile'] || '')),
                labelWidth: 160,
            });
            let lbInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('LoadBalancer IPs'),
                value: gettext('loading...'),
                labelWidth: 160,
            });
            let backupInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Last Backup'),
                value: gettext('loading...'),
                labelWidth: 160,
            });
            let imageInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Node Image'),
                value: gettext('loading...'),
                labelWidth: 160,
            });
            let repairInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('Auto-repair'),
                value: gettext('none'),
                labelWidth: 160,
            });
            let haInfo = Ext.create('Ext.form.field.Display', {
                fieldLabel: gettext('HA Errors'),
                value: gettext('none'),
                labelWidth: 160,
            });
            // Increment 9: stock Summary idiom - the
            // toolkit RRD chart widget, same as node
            // Summary history panels.
            let summaryChart = function(title) {
                return Ext.create('Proxmox.widget.RRDChart', {
                    height: 250,
                    title: title,
                    fields: ['pct'],
                    fieldTitles: [title],
                    unit: 'percent',
                    store: Ext.create('Ext.data.Store', {
                        fields: [
                            { name: 'time', type: 'date' },
                            { name: 'pct', type: 'int' },
                        ],
                    }),
                });
            };
            let cpuGauge = Ext.create('Proxmox.panel.GaugeWidget', {
                title: gettext('CPU'),
                flex: 1,
            });
            let memGauge = Ext.create('Proxmox.panel.GaugeWidget', {
                title: gettext('Memory'),
                flex: 1,
                warningThreshold: 0.9,
                criticalThreshold: 0.975,
            });
            let summaryChartMem = summaryChart(
                gettext('Node VMs memory (cluster average %)'));
            let summaryChartCpu = summaryChart(
                gettext('Node VMs CPU (cluster average %)'));
            fetchSummary(name, function(r) {
                    let s = r.result.data || {};
                    let icons = {
                        ok: 'fa fa-check good',
                        degraded: 'fa fa-exclamation-triangle warning',
                        down: 'fa fa-times critical',
                    };
                    let icon = icons[s.health]
                        || 'fa fa-question-circle warning';
                    healthInfo.setValue('<i class="' + icon
                        + '"></i> ' + Ext.htmlEncode(
                            String(s.health || 'unknown')));
                    // upstream support window of the running minor
                    let vs = s['version-support'] || {};
                    let ver = Ext.htmlEncode(String(s['k8s-version']
                        || rec['k8s-version'] || ''));
                    if (vs.status === 'eol') {
                        versionInfo.setValue('<i class="fa fa-times critical"></i> '
                            + ver + ' - ' + Ext.String.format(gettext(
                                'end of life since {0}, no security patches: upgrade'),
                                Ext.htmlEncode(vs.eol)));
                    } else if (vs.status === 'maintenance') {
                        versionInfo.setValue('<i class="fa fa-exclamation-triangle warning"></i> '
                            + ver + ' - ' + Ext.String.format(gettext(
                                'critical fixes only, end of life {0} ({1} days): plan the upgrade'),
                                Ext.htmlEncode(vs.eol), vs.days));
                    } else if (vs.status === 'supported') {
                        versionInfo.setValue(ver + ' - ' + Ext.String.format(
                            gettext('upstream support until {0}'),
                            Ext.htmlEncode(vs.eol))
                            + (vs.preview ? ' (' + gettext('preview') + ': '
                                + Ext.htmlEncode(vs.preview) + ')' : ''));
                    }
                    // Datacenter-Health idiom: every
                    // check carries its own status icon
                    let checkIcon = function(ok, warn) {
                        return ok
                            ? '<i class="fa fa-check good"></i> '
                            : warn
                                ? '<i class="fa fa-exclamation-triangle warning"></i> '
                                : '<i class="fa fa-times critical"></i> ';
                    };
                    let cpQuorum = Math.floor((s.cp || 0) / 2) + 1;
                    nodesInfo.setValue(s.nodes_ready !== undefined
                        && s.nodes_ready !== null
                        ? checkIcon(s.cp_ready >= s.cp
                                && s.nodes_ready >= s.nodes_total,
                            s.cp_ready >= cpQuorum)
                            + Ext.String.format(gettext(
                                '{0}/{1} Ready (control plane {2}/{3})'),
                                s.nodes_ready, s.nodes_total,
                                s.cp_ready, s.cp)
                        : gettext('unknown'));
                    podsInfo.setValue(s.pods
                        ? checkIcon(s.pods.pending === 0,
                            s.pods.running > 0)
                            + Ext.String.format(gettext(
                                '{0} running, {1} pending, {2} total'),
                                s.pods.running, s.pods.pending,
                                s.pods.total)
                        : gettext('unknown'));
                    lbInfo.setValue(s.lb
                        ? checkIcon(true, false)
                            + Ext.String.format(gettext('{0} of {1} used'),
                                s.lb.used, s.lb.total)
                        : gettext('unknown'));
                    backupInfo.setValue(s.backup
                        ? checkIcon(true, false) + Ext.Date.format(
                            new Date(s.backup.last * 1000),
                            'Y-m-d H:i')
                        : checkIcon(false, true) + gettext('none'));
                    // Node image: overdue = error, pending = warning
                    let im = s.image;
                    if (!im) {
                        imageInfo.setValue(gettext('unknown'));
                    } else if (!im.pending) {
                        imageInfo.setValue(checkIcon(true, false)
                            + gettext('up to date'));
                    } else {
                        // image replacements and resizes (an edited
                        // node group) are rolled the same way
                        let parts = [];
                        let byImage = im.pending - (im.resize || 0);
                        if (byImage > 0) {
                            parts.push(Ext.String.format(gettext(
                                '{0} node(s) pending replacement by the '
                                + 'newest image'), byImage));
                        }
                        if (im.resize) {
                            parts.push(Ext.String.format(gettext(
                                '{0} node(s) pending resize to their '
                                + 'node group'), im.resize));
                        }
                        let msg = parts.join(', ');
                        if (im.deadline) {
                            msg += ', ' + Ext.String.format(gettext(
                                '{0} deadline {1}'), im.severity,
                                Ext.Date.format(
                                    new Date(im.deadline * 1000),
                                    'Y-m-d H:i'));
                        }
                        msg += im.auto
                            ? ' (' + Ext.String.format(gettext(
                                'rolls automatically in window {0}'),
                                im.window) + ')'
                            : ' (' + gettext('no maintenance window: '
                                + 'roll manually') + ')';
                        imageInfo.setValue(checkIcon(false, !im.overdue)
                            + Ext.htmlEncode(msg));
                    }
                    // Replacements made automatically: never invisible
                    let reps = s.repairs || [];
                    repairInfo.setValue(reps.length
                        ? '<i class="fa fa-exclamation-triangle warning"></i> '
                            + reps.slice(-3).reverse().map(function(x) {
                                return Ext.htmlEncode(x.node) + ' ('
                                    + Ext.Date.format(
                                        new Date(x.at * 1000), 'Y-m-d H:i')
                                    + ': ' + x.reason + ')';
                            }).join('<br>')
                        : '<i class="fa fa-check good"></i> '
                            + gettext('none'));
                    haInfo.setValue(s.ha_errors
                        && s.ha_errors.length
                        ? '<i class="fa fa-times critical"></i> '
                            + Ext.htmlEncode(
                                s.ha_errors.join(', '))
                        : '<i class="fa fa-check good"></i> '
                            + gettext('none'));
                    if (s.capacity) {
                        cpuGauge.updateValue(
                            (s.capacity.cpu_pct || 0) / 100,
                            gettext('node VMs (average)'));
                        memGauge.updateValue(
                            (s.capacity.mem_pct || 0) / 100,
                            Ext.String.format('{0} of {1} GiB',
                                ((s.capacity.mem_used || 0)
                                    / 1073741824).toFixed(1),
                                ((s.capacity.mem_total || 0)
                                    / 1073741824).toFixed(1)));
                    }
                    if (s.series) {
                        let toRows = function(pts) {
                            return (pts || []).map(function(p) {
                                return {
                                    time: new Date(p[0] * 1000),
                                    pct: p[1],
                                };
                            });
                        };
                        summaryChartMem.getStore().loadData(
                            toRows(s.series.mem));
                        summaryChartCpu.getStore().loadData(
                            toRows(s.series.cpu));
                    }
            }, function() {
                    healthInfo.setValue(gettext('unknown'));
                    nodesInfo.setValue(gettext('unknown'));
                    podsInfo.setValue(gettext('unknown'));
                    lbInfo.setValue(gettext('unknown'));
                    backupInfo.setValue(gettext('unknown'));
                    imageInfo.setValue(gettext('unknown'));
            });
            let act = function(label, icon, fn, extra) {
                return Ext.apply({
                    text: label, iconCls: icon,
                    handler: function() { fn(name); },
                }, extra);
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
                    act(gettext('Rebuild Image'), 'fa fa-fw fa-wrench', function(n) {
                        Ext.create('PVE.dc.K8sRebuildWindow', {
                            autoShow: true,
                            clusterName: n,
                            apiCallDone: function(ok) {
                                if (ok) { me.reloadClusters(); }
                            },
                        });
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
                        Ext.create('PVE.dc.K8sUpgradeWindow', {
                            autoShow: true,
                            clusterName: n,
                            currentVersion: (me.clusterIndex[n] || {})['k8s-version'],
                            apiCallDone: function(ok) {
                                if (ok) { me.reloadClusters(); }
                            },
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
                        Ext.create('PVE.dc.K8sKubeconfigWindow', {
                            autoShow: true,
                            clusterName: n,
                            maxHours: (me.clusterIndex[n] || {})['kubeconfig-max-hours'],
                        });
                    }, {
                        // Sys.Audit users get a read-only kubeconfig
                        k8sReadOnly: true,
                    }),
                ],
                items: [{
                    // Increment 9: Datacenter-Summary
                    // skeleton - column layout of titled
                    // cards (Health / Resources / history /
                    // Details), stock widgets only.
                    xtype: 'panel',
                    border: false,
                    layout: 'column',
                    defaults: { padding: 5, columnWidth: 1 },
                    listeners: {
                        resize: function(panel) {
                            Proxmox.Utils.updateColumns(panel);
                        },
                    },
                    items: [
                        {
                            title: gettext('Overview'),
                            xtype: 'panel',
                            bodyPadding: 10,
                            minHeight: 250,
                            layout: 'column',
                            defaults: { columnWidth: 0.5 },
                            items: [
                                // two balanced columns: the cluster's
                                // health on the left, operations on
                                // the right (7 rows each)
                                {
                                    xtype: 'container',
                                    itemId: 'healthCol',
                                    items: [healthInfo, versionInfo,
                                        nodesInfo, podsInfo, lbInfo,
                                        certInfo, backupInfo],
                                },
                                {
                                    xtype: 'container',
                                    itemId: 'opsCol',
                                    items: [groupsInfo, storageInfo,
                                        imageInfo, actionInfo, parkedInfo,
                                        repairInfo, haInfo],
                                },
                            ],
                        },
                        {
                            title: gettext('Resources'),
                            xtype: 'panel',
                            bodyPadding: 5,
                            minHeight: 250,
                            layout: 'hbox',
                            items: [cpuGauge, memGauge],
                        },
                        // the RRD chart widget carries
                        // its own header/legend - no
                        // wrapping card (that nested it)
                        summaryChartCpu,
                        summaryChartMem,
                    ],
                }],
            });
        };

        let nodesPanel = function(name) {
            let store = Ext.create('Ext.data.Store', {
                fields: ['name', 'pool', 'pvehost', 'vmid', 'ip', 'rev'],
            });
            let g;
            // Stock selection buttons: disabled without a selection,
            // the stock confirm box (No focused for dangerous ones).
            let sm = Ext.create('Ext.selection.RowModel', {});
            let nodeAct = function(action, label, extra, confirmText, dangerous) {
                return {
                    xtype: 'proxmoxButton',
                    text: label,
                    disabled: true,
                    selModel: sm,
                    dangerous: !!dangerous,
                    confirmMsg: function(rec) {
                        return Ext.String.format(confirmText
                            || gettext('{0} node {1}?'), label,
                            Ext.htmlEncode(rec.data.name));
                    },
                    handler: function(btn, event, rec) {
                        api({
                            url: '/cluster/k8s/' + name + '/nodes/'
                                + encodeURIComponent(rec.data.name) + action,
                            method: 'POST',
                            params: extra || {},
                            success: function(r) {
                                task(r.result.data);
                            },
                        });
                    },
                };
            };
            g = Ext.create('Ext.grid.Panel', {
                border: false,
                store: store,
                selModel: sm,
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
                            + 'be provisioned.'), true),
                    {
                        text: gettext('Reload'),
                        k8sReadOnly: true,
                        handler: function() { loadNodes(); },
                    },
                    {
                        text: gettext('Evacuate Host'),
                        iconCls: 'fa fa-fw fa-sign-out',
                        handler: function() {
                            Ext.create('PVE.dc.K8sEvacuateWindow', {
                                autoShow: true,
                                clusterName: name,
                            });
                        },
                    },
                ],
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
            // Resource fields are selectors, not free
            // text: hosts, storages and PCI mappings all
            // come from the PVE API (typed values that do
            // not exist fail much later otherwise).
            let pickStore = function(field, url, key) {
                let store = Ext.create('Ext.data.Store', {
                    fields: [field],
                });
                api({
                    url: url,
                    method: 'GET',
                    success: function(r) {
                        store.loadData((r.result.data || [])
                            .map(function(row) {
                                let rec = {};
                                rec[field] = row[key || field];
                                return rec;
                            }));
                    },
                    failure: function() { /* type-ahead stays empty */ },
                });
                return store;
            };
            let groupWindow = function(existing) {
                Ext.create('PVE.dc.K8sGroupWindow', {
                    autoShow: true,
                    existing: existing || undefined,
                    deviceStore: pickStore('id', '/cluster/mapping/pci'),
                    onSave: function(entry) {
                        let groups = currentGroups().filter(function(gr) {
                            return gr.name !== entry.name;
                        });
                        groups.push(entry);
                        saveGroups(groups);
                    },
                });
            };
            let gsm = Ext.create('Ext.selection.RowModel', {});
            groupsGrid = Ext.create('Ext.grid.Panel', {
                selModel: gsm,
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
                    {
                        text: gettext('Create'),
                        handler: function() { groupWindow(null); },
                    },
                    {
                        xtype: 'proxmoxButton',
                        text: gettext('Edit'),
                        disabled: true,
                        selModel: gsm,
                        handler: function(btn, event, rec) {
                            groupWindow(rec.data);
                        },
                    },
                    {
                        xtype: 'proxmoxButton',
                        text: gettext('Delete'),
                        disabled: true,
                        selModel: gsm,
                        dangerous: true,
                        confirmMsg: function(rec) {
                            return Ext.String.format(gettext(
                                'Delete node group {0}? Its nodes are '
                                + 'drained and retired on save.'),
                                Ext.htmlEncode(rec.data.name));
                        },
                        handler: function(btn, event, rec) {
                            saveGroups(currentGroups().filter(function(gr) {
                                return gr.name !== rec.data.name;
                            }));
                        },
                    },
                ],
                listeners: {
                    // like every stock grid: double-click edits
                    itemdblclick: function(view, rec) {
                        if (canModify) { groupWindow(rec.data); }
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
            // add-ons that need answers first get a stock Edit window;
            // the others are enabled directly
            let configurable = { 'cert-manager': 1, 'external-dns': 1 };
            let enableable = Ext.apply({ 'metrics-server': 1 }, configurable);
            let asm = Ext.create('Ext.selection.RowModel', {});
            let enableBtn = {
                xtype: 'proxmoxButton',
                text: gettext('Enable'),
                iconCls: 'fa fa-fw fa-play',
                disabled: true,
                selModel: asm,
                enableFn: function(rec) { return !!enableable[rec.data.name]; },
                handler: function(btn, event, rec) {
                    let addon = rec.data.name;
                    if (configurable[addon]) {
                        Ext.create('PVE.dc.K8sAddonWindow', {
                            autoShow: true,
                            clusterName: name,
                            addon: addon,
                            apiCallDone: function(ok) {
                                if (ok) { store.load(); }
                            },
                        });
                        return;
                    }
                    api({
                        url: '/cluster/k8s/' + name + '/addons/' + addon + '/enable',
                        method: 'POST',
                        success: function(r) {
                            task(r.result.data); store.load();
                        },
                    });
                },
            };
            let disableBtn = {
                xtype: 'proxmoxButton',
                text: gettext('Disable'),
                iconCls: 'fa fa-fw fa-ban',
                disabled: true,
                selModel: asm,
                enableFn: function(rec) {
                    return rec.data.name === 'metrics-server'
                        && rec.data.status === 'configured';
                },
                confirmMsg: function(rec) {
                    return Ext.String.format(gettext('Disable {0}?'),
                        Ext.htmlEncode(rec.data.name));
                },
                handler: function(btn, event, rec) {
                    api({
                        url: '/cluster/k8s/' + name + '/addons/'
                            + rec.data.name + '/disable',
                        method: 'POST',
                        success: function(r) {
                            task(r.result.data); store.load();
                        },
                    });
                },
            };
            let g = Ext.create('Ext.grid.Panel', {
                header: false,
                border: false,
                store: store,
                selModel: asm,
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
            let bsm = Ext.create('Ext.selection.RowModel', {});
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
                        // stock selection button: no "select a file
                        // first" box, and the restore warning has No
                        // focused
                        xtype: 'proxmoxButton',
                        text: gettext('Restore'),
                        iconCls: 'fa fa-fw fa-undo',
                        disabled: true,
                        selModel: bsm,
                        dangerous: true,
                        confirmMsg: function(rec) {
                            return Ext.String.format(gettext(
                                'Roll back ALL cluster data to {0}? Everything '
                                + 'changed in the cluster since then is lost.'),
                                Ext.htmlEncode(rec.data.file));
                        },
                        handler: function(btn, event, rec) {
                            api({
                                url: '/cluster/k8s/' + name + '/restore',
                                method: 'POST',
                                params: { backup: rec.data.file, force: 1 },
                                success: function(r) {
                                    task(r.result.data);
                                },
                            });
                        },
                    },
                ], bsm);
            return g;
        };

        // Who holds kubeconfigs (EKS "access entries"): one service
        // account per PVE user or API token. Revoke deletes it, which
        // invalidates every token issued to it at once.
        let accessPanel = function(name) {
            let xsm = Ext.create('Ext.selection.RowModel', {});
            let roleText = function(v) {
                return v === 'admin' ? gettext('Administrator (cluster-admin)')
                    : v === 'view' ? gettext('Read-only (view)')
                    : Ext.htmlEncode(v || '');
            };
            let g = grid(
                ['user', 'role', 'service-account', 'created'],
                '/api2/json/cluster/k8s/' + name + '/access',
                [
                    { text: gettext('User'), dataIndex: 'user', flex: 1,
                        renderer: function(v) {
                            // the user's own auto-refresh token
                            let auto = '!k8s-' + name;
                            v = v || '';
                            if (v.endsWith(auto)) {
                                return Ext.htmlEncode(v.slice(0, -auto.length))
                                    + ' (' + gettext('auto-refresh') + ')';
                            }
                            return Ext.htmlEncode(v);
                        } },
                    { text: gettext('Role'), dataIndex: 'role', width: 220,
                        renderer: roleText },
                    { text: gettext('Service Account'), dataIndex: 'service-account',
                        flex: 1, renderer: Ext.htmlEncode },
                    { text: gettext('First Issued'), dataIndex: 'created', width: 170,
                        renderer: function(v) {
                            let d = v ? new Date(v) : null;
                            return d && !isNaN(d) ? Ext.Date.format(d, 'Y-m-d H:i') : '';
                        } },
                ], [
                    {
                        xtype: 'proxmoxButton',
                        text: gettext('Revoke'),
                        disabled: true,
                        selModel: xsm,
                        dangerous: true,
                        confirmMsg: function(rec) {
                            return Ext.String.format(gettext(
                                'Revoke every kubeconfig of {0}? They stop working '
                                + 'at once; a new one can be issued later.'),
                                Ext.htmlEncode(rec.data.user));
                        },
                        handler: function(btn, event, rec) {
                            api({
                                url: '/cluster/k8s/' + name + '/access/'
                                    + encodeURIComponent(rec.data.user),
                                method: 'DELETE',
                                waitMsgTarget: g,
                                success: function() { g.getStore().load(); },
                            });
                        },
                    },
                    {
                        text: gettext('Reload'),
                        iconCls: 'fa fa-fw fa-refresh',
                        k8sReadOnly: true,
                        handler: function() { g.getStore().load(); },
                    },
                ], xsm);
            return g;
        };

        let settingsPanel = function(rec) {
            return Ext.create('PVE.dc.K8sSettings', {
                clusterName: rec.name,
                viewOnly: !canModify,
                border: false,
                onChanged: function() { me.reloadClusters(); },
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
        let buildPanel = function(clusterName, key, rec) {
            if (key === 'overview') { return overviewPanel(rec); }
            if (key === 'nodes') { return nodesPanel(clusterName); }
            if (key === 'workloads') { return workloadsPanel(clusterName); }
            if (key === 'metrics') { return metricsPanel(clusterName); }
            if (key === 'addons') { return addonsPanel(clusterName); }
            if (key === 'events') { return eventsPanel(clusterName); }
            if (key === 'backups') { return backupsPanel(clusterName); }
            if (key === 'access') { return accessPanel(clusterName); }
            return settingsPanel(rec);
        };
        // Each menu entry is a light placeholder; its panel (and its
        // API reads) is built the first time it is shown. Building all
        // eight at once queued the Overview's summary behind workloads,
        // metrics and events in pvedaemon's few workers.
        let panelFor = function(clusterName, key, rec) {
            let id = clusterName + ':' + key;
            if (panels[id]) { return panels[id]; }
            let p = Ext.create('Ext.container.Container', {
                layout: 'fit',
                itemId: id,
                lazyBuild: function() {
                    return readOnlyView(buildPanel(clusterName, key, rec));
                },
            });
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
                if (target.lazyBuild) {
                    let build = target.lazyBuild;
                    target.lazyBuild = null;
                    target.add(build());
                }
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
                ['access', gettext('Access'), 'fa fa-key'],
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
                destroyCluster(name, function() {
                    me.currentCluster = null;
                    if (fixedClusterName && me.workspace) {
                        me.workspace.selectById('root');
                    } else {
                        me.reloadClusters();
                    }
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
                    destroyCluster(name, function() {
                        clusterStore.load();
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
                            k8sReadOnly: true,
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
                            fireOnStart: false,
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
            readOnlyView(me);
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
                        // the load above already ran: no second one
                        fireOnStart: false,
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
        readOnlyView(me);
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
