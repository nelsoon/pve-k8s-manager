# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Config;

use strict;
use warnings;

use JSON::PP ();

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
use PVE::JSONSchema;
use PVE::SectionConfig;

use base qw(PVE::SectionConfig);

# Cluster-wide desired state for managed Kubernetes clusters.
# Lives in pmxcfs, replicated to all nodes like other PVE config.
my $FILENAME = 'k8s/clusters.cfg';

cfs_register_file(
    $FILENAME,
    sub { __PACKAGE__->parse_config(@_); },
    sub { __PACKAGE__->write_config(@_); });

# Section header is just the cluster name; the type is fixed.
sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+)\s*$/) {
        my $id = $1;
        my $errmsg = undef;
        eval { PVE::JSONSchema::pve_verify_configid($id) };
        $errmsg = $@ if $@;
        return ('cluster', $id, $errmsg, {});
    }
    return undef;
}

sub format_section_header {
    my ($class, $type, $sectionId, $scfg, $done_hash) = @_;

    return "$sectionId\n";
}

sub type {
    return 'cluster';
}

my $defaultData = {
    propertyList => {
        id => {
            type => 'string',
            description => "The name of the Kubernetes cluster.",
            format => 'pve-configid',
        },
        description => {
            type => 'string',
            description => "Description of the cluster.",
            optional => 1,
            maxLength => 4096,
        },
        'k8s-version' => {
            type => 'string',
            description => "Kubernetes version, e.g. '1.36'.",
            pattern => '^\d+\.\d+(\.\d+)?$',
        },
        cp => {
            type => 'integer',
            description => "Control-plane node count (1, 3 or 5).",
            minimum => 1,
            maximum => 5,
            default => 3,
            optional => 1,
        },
        workers => {
            type => 'integer',
            description => "Worker node count (legacy single default pool).",
            minimum => 0,
            maximum => 50,
            default => 2,
            optional => 1,
        },
        pools => {
            type => 'string',
            description => "Worker pools as JSON: [{name, size, labels, "
                . "taints, hosts, storage, device-profile}]. Overrides workers.",
            optional => 1,
        },
        'node-subnet' => {
            type => 'string',
            description => "SDN subnet for node VMs, e.g. '192.168.200.0/24'.",
            optional => 1,
        },
        gateway => {
            type => 'string',
            description => "Gateway for node VMs, e.g. '192.168.200.1'.",
            optional => 1,
        },
        'builder-ip' => {
            type => 'string',
            description => "Free static IP on the host network "
                . "for the throwaway template-builder VM. When "
                . "set and no node template exists, provision "
                . "builds one itself.",
            optional => 1,
        },
        'lb-range' => {
            type => 'string',
            description => "LoadBalancer address range, e.g. '192.168.200.100-192.168.200.120'.",
            optional => 1,
        },
        'file-backend' => {
            type => 'string',
            description => "Shared-file (RWX) tier backend "
                . "(T3.6a): nfs against an admin-registered "
                . "NFS server/share, or cephfs auto-managed "
                . "on a hyper-converged PVE Ceph cluster "
                . "(filesystem + scoped CephX user created "
                . "for the cluster; Ceph itself is never "
                . "deployed by the plugin).",
            optional => 1,
        },
        'file-state' => {
            type => 'string',
            description => "Shared-file tier probe result "
                . "recorded by the provisioner (JSON: "
                . "backend, ok, capacity/free bytes, time).",
            optional => 1,
        },
        'file-server' => {
            type => 'string',
            description => "NFS server (IP or host) for "
                . "file-backend nfs.",
            optional => 1,
        },
        'file-share' => {
            type => 'string',
            description => "NFS export path for file-backend "
                . "nfs, e.g. /srv/k8s.",
            optional => 1,
        },
        'storage-shared' => {
            type => 'integer',
            description => "Recorded by the provisioner: "
                . "whether the cluster storage is shared "
                . "across PVE hosts (drives pinning warnings).",
            optional => 1,
        },
        'sdn-zone' => {
            type => 'string',
            description => "Proxmox SDN EVPN zone for a dedicated "
                . "per-cluster VNet (T3.4 re-spec). With "
                . "public-subnet, provisioning creates the VNet "
                . "and its internal/public subnets and removes "
                . "them on delete. Without it, the template's "
                . "pre-made shared VNet is used (legacy mode).",
            optional => 1,
        },
        'public-subnet' => {
            type => 'string',
            description => "Public /24 of a dedicated VNet: "
                . "LoadBalancer IPs and the external apiserver "
                . "VIP live here; only this subnet is meant to "
                . "be advertised upstream (T3.4 re-spec).",
            optional => 1,
        },
        'sdn-vnet' => {
            type => 'string',
            description => "Dedicated SDN VNet recorded by the "
                . "provisioner (T3.4 re-spec).",
            optional => 1,
        },
        'sdn-vni' => {
            type => 'integer',
            description => "VXLAN VNI allocated for the dedicated "
                . "VNet, recorded by the provisioner.",
            optional => 1,
        },
        storage => {
            type => 'string',
            format => 'pve-storage-id',
            description => "PVE storage for node disks.",
            optional => 1,
        },
        nodes => {
            type => 'string',
            description => "Node inventory JSON recorded by the provisioner.",
            optional => 1,
        },
        'template-rev' => {
            type => 'integer',
            description => "Template image revision the nodes should run.",
            optional => 1,
        },
        'upgrade-applied' => {
            type => 'string',
            description => "kubeadm version whose upgrade apply already ran.",
            optional => 1,
        },
        'maintenance-window' => {
            type => 'string',
            description => "Rolling window HH:MM-HH:MM (local time).",
            optional => 1,
        },
        'storage-profile' => {
            type => 'string',
            enum => ['shared', 'local'],
            description => "Storage profile chosen at create: "
                . "shared (Ceph RBD disks + shared PVs) or "
                . "local (node-local disks and PVs). Presets "
                . "the storage choices; per-pool storage "
                . "overrides still apply.",
            optional => 1,
        },
        'cp-policy' => {
            type => 'string',
            enum => ['ha', 'replace'],
            description => "Control-plane failure policy: ha "
                . "(Proxmox HA reboots CP VMs on a peer; only "
                . "honoured on shared storage) or replace "
                . "(plugin rebuilds failed CP members).",
            optional => 1,
        },
        'scaler-state' => {
            type => 'string',
            description => "Scaler leader/action state JSON (T2.4).",
            optional => 1,
        },
        'action-state' => {
            type => 'string',
            description => "Live mutating action claim JSON "
                . "(key, task, UPID, node, started, heartbeat). "
                . "Serializes provisioning and day-2 actions "
                . "per cluster.",
            optional => 1,
        },
        'retired-nodes' => {
            type => 'string',
            description => "Force-retired node ghosts JSON (T2.6).",
            optional => 1,
        },
        addons => {
            type => 'string',
            description => "Enabled opt-in add-ons JSON (T3.3).",
            optional => 1,
        },
        'backup-dir' => {
            type => 'string',
            description => "Host directory for etcd backups "
                . "(shared/PBS-mounted path recommended).",
            optional => 1,
        },
        'backup-retention' => {
            type => 'integer',
            description => "Etcd backups to keep per cluster.",
            minimum => 1,
            maximum => 100,
            optional => 1,
        },
        'kubeconfig-max-hours' => {
            type => 'integer',
            description => "Longest kubeconfig validity users may ask "
                . "for, in hours (default 24).",
            minimum => 1,
            maximum => 720,
            optional => 1,
        },
        'scale-in-cooldown' => {
            type => 'integer',
            description => "Minutes after any scale action before the "
                . "scaler may remove a node (default 10).",
            minimum => 1,
            maximum => 1440,
            optional => 1,
        },
        state => {
            type => 'string',
            description => "Lifecycle state recorded by pve-k8sd.",
            optional => 1,
        },
        created => {
            type => 'integer',
            description => "Creation time (epoch seconds).",
            optional => 1,
        },
    },
};

sub private {
    return $defaultData;
}

sub options {
    return {
        description => { optional => 1 },
        'k8s-version' => {},
        cp => { optional => 1 },
        workers => { optional => 1 },
        pools => { optional => 1 },
        'node-subnet' => { optional => 1 },
        gateway => { optional => 1 },
        'builder-ip' => { optional => 1 },
        gateway => {
            type => 'string',
            description => "Gateway for node VMs, e.g. '192.168.200.1'.",
            optional => 1,
        },
        'lb-range' => { optional => 1 },
        nodes => { optional => 1 },
        'template-rev' => { optional => 1 },
        'upgrade-applied' => { optional => 1 },
        'maintenance-window' => { optional => 1 },
        'storage-profile' => { optional => 1 },
        'cp-policy' => { optional => 1 },
        'scaler-state' => { optional => 1 },
        'action-state' => { optional => 1 },
        'retired-nodes' => { optional => 1 },
        addons => { optional => 1 },
        'file-backend' => { optional => 1 },
        'file-state' => { optional => 1 },
        'file-server' => { optional => 1 },
        'file-share' => { optional => 1 },
        'storage-shared' => { optional => 1 },
        'sdn-zone' => { optional => 1 },
        'public-subnet' => { optional => 1 },
        'sdn-vnet' => { optional => 1 },
        'sdn-vni' => { optional => 1 },
        'backup-dir' => { optional => 1 },
        'backup-retention' => { optional => 1 },
        'scale-in-cooldown' => { optional => 1 },
        'kubeconfig-max-hours' => { optional => 1 },
        storage => { optional => 1 },
        state => { optional => 1 },
        created => { optional => 1 },
    };
}

sub config {
    return cfs_read_file($FILENAME);
}

sub lock_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file($FILENAME, undef, $code);
    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub store_config {
    my ($cfg) = @_;

    cfs_write_file($FILENAME, $cfg);
}

# Logical datacenter-wide resources for the Proxmox resource
# tree. A Kubernetes cluster is not owned by one PVE node, so
# entries deliberately have no node or VMID.
sub resource_entries {
    my ($cfg) = @_;

    my $ids = ($cfg // {})->{ids} // {};
    return [map {
        my $cluster = $ids->{$_} // {};
        +{
            id => "k8s/$_",
            type => 'k8s',
            name => $_,
            k8s => $_,
            status => $cluster->{state} // 'unknown',
        }
    } sort keys $ids->%*];
}

__PACKAGE__->register();
__PACKAGE__->init();

# Worker pools (T2.1). Stored as one JSON property so pmxcfs
# stays a flat section file; an absent property means the
# legacy single default pool sized by 'workers'. Labels and
# taints are comma lists of key=value (taints key=value:Effect
# or bare key). 'hosts' is a comma list of PVE node names the
# pool may be placed on; 'device-profile' names a Proxmox
# PCI resource mapping attached to the pool's VMs as
# hostpci (GPU passthrough). Optional cpu/memory/disk
# size the pool's VMs (defaults: 2 cores, 4096 MiB,
# template disk).
sub parse_pools {
    my ($json, $workers) = @_;

    if (!defined $json || $json eq '') {
        return [{ name => 'default', size => $workers // 2 }];
    }

    my $pools = eval { JSON::PP->new->decode($json) };
    die "pools is not valid JSON: $@\n" if $@;
    die "pools must be a JSON array\n" if ref $pools ne 'ARRAY';

    my %seen;
    for my $pool ($pools->@*) {
        die "each pool must be a JSON object\n" if ref $pool ne 'HASH';
        my $name = $pool->{name} // die "each pool needs a name\n";
        die "pool name '$name' is not a valid config id\n"
            if $name !~ /^[a-z][a-z0-9-]*$/;
        die "duplicate pool name '$name'\n" if $seen{$name}++;
        my $size = $pool->{size} // die "pool '$name' needs a size\n";
        die "pool '$name' size must be 0..50\n"
            if $size !~ /^\d+$/ || $size > 50;
        $pool->{size} = int $size;
        # Autoscaling bounds (T2.4): absent min/max pins the
        # pool at its size (no scaling). When given, the
        # scaler keeps min <= size <= max.
        my $min = $pool->{min} // $pool->{size};
        my $max = $pool->{max} // $pool->{size};
        die "pool '$name' min/max must be 0..50\n"
            if "$min" !~ /^\d+$/ || "$max" !~ /^\d+$/ || $max > 50;
        die "pool '$name' needs min <= size <= max\n"
            if $min > $pool->{size} || $pool->{size} > $max;
        $pool->{min} = int $min;
        $pool->{max} = int $max;
        for my $key (qw(labels taints hosts)) {
            next if !defined $pool->{$key};
            die "pool '$name' $key must be a string\n"
                if ref $pool->{$key};
        }
        # A node group's architecture: its VMs only ever
        # run on PVE hosts of this arch (PVE clusters may
        # mix amd64 and arm64 hosts; a VM never moves
        # between them). Unset = unconstrained (single-arch
        # PVE clusters, the common case).
        if (defined $pool->{arch}) {
            die "pool '$name' arch must be amd64 or arm64\n"
                if $pool->{arch} !~ /^(amd64|arm64)$/;
        }
        # Failure policy (Increment 6): ha lets Proxmox HA
        # reboot the pool's VMs on a peer (shared storage
        # only, enforced at provision); replace lets the
        # plugin rebuild them. Absent = replace.
        if (defined $pool->{policy}) {
            die "pool '$name' policy must be ha or replace\n"
                if $pool->{policy} !~ /^(ha|replace)$/;
        }
        # Per-group VM sizing (absent = plugin defaults:
        # 2 cores / 4096 MiB / template disk). Disk is
        # grow-only at clone time.
        if (defined $pool->{cpu}) {
            die "pool '$name' cpu must be 1..64\n"
                if $pool->{cpu} !~ /^\d+$/
                    || $pool->{cpu} < 1 || $pool->{cpu} > 64;
            $pool->{cpu} = int $pool->{cpu};
        }
        if (defined $pool->{memory}) {
            die "pool '$name' memory must be 512..1048576 MiB\n"
                if $pool->{memory} !~ /^\d+$/
                    || $pool->{memory} < 512
                    || $pool->{memory} > 1048576;
            $pool->{memory} = int $pool->{memory};
        }
        if (defined $pool->{disk}) {
            die "pool '$name' disk must be 8..4096 GiB\n"
                if $pool->{disk} !~ /^\d+$/
                    || $pool->{disk} < 8 || $pool->{disk} > 4096;
            $pool->{disk} = int $pool->{disk};
        }
        # GPU/device passthrough: the value is a Proxmox
        # PCI resource mapping name (Datacenter ->
        # Resource Mappings); provision attaches it as
        # hostpci to this group's VMs.
        if (defined $pool->{'device-profile'}) {
            die "pool '$name' device-profile must be a string\n"
                if ref $pool->{'device-profile'};
            die "pool '$name' device-profile is not a valid "
                . "resource mapping name\n"
                if $pool->{'device-profile'}
                    !~ /^[A-Za-z0-9._-]+$/;
        }
    }
    return $pools;
}

# Supported Kubernetes minors for NEW clusters: upstream-
# maintained lines whose add-on stack (Cilium/CCM/CSI) is
# tested end to end. This deliberately lags the newest
# upstream minor: 1.37 is held back until Cilium officially
# tests it (a lab cluster ran fine on Cilium 1.20.3, but
# bleeding edge waits for the add-ons). Older clusters
# upgrade one minor at a time until they are back inside
# the window, so the upgrade path is not gated on this
# list. Templates in the lab: v1.35.9 and v1.36.5.
our @SUPPORTED_VERSIONS = ('1.35', '1.36');

sub supported_versions {
    return [@SUPPORTED_VERSIONS];
}

sub latest_supported_version {
    return $SUPPORTED_VERSIONS[-1];
}

sub assert_supported_version {
    my ($version) = @_;

    my ($minor) = ($version // '') =~ /^(\d+\.\d+)(?:\.\d+)?$/;
    die "invalid Kubernetes version '$version'\n" if !defined $minor;
    return $minor if grep { $_ eq $minor } @SUPPORTED_VERSIONS;
    die "Kubernetes $minor is not supported for new clusters "
        . "(end of life, or add-on testing still pending); "
        . "supported versions: " . join(', ', @SUPPORTED_VERSIONS) . "\n";
}

sub assert_valid_cp_count {
    my ($cp) = @_;

    die "cp must be 1, 3 or 5\n" if !grep { $_ == $cp } (1, 3, 5);
    return $cp;
}

# T3.4 re-spec (2026-10-20): LoadBalancer reachability is a
# Proxmox SDN concern, never Cilium BGP. Two topologies are
# supported: (1) the EVPN fabric itself carries per-address
# routes, (2) a BGP controller + exit nodes advertise the
# cluster's public subnet in plain unicast. In both, Cilium
# only announces LB IPs by L2 inside the cluster VNet.
# A cluster either stays on the template's pre-made shared
# VNet (legacy: lb-range inside the node subnet) or, with
# sdn-zone + public-subnet, gets a dedicated VNet in that
# EVPN zone holding an internal subnet (node-subnet, never
# advertised) and the public subnet (LB IPs + apiserver
# VIP, the only range meant to leave the VRF).
# First free /24 in 10.10.0.0/16 for a cluster's
# node subnet (pure: takes used subnet strings, so
# create and the UI suggest the same value). N=0 is
# skipped (network address reads oddly in labels).
sub allocate_node_subnet {
    my ($used) = @_;

    my %taken;
    for my $s (($used // [])->@*) {
        my ($n) = ($s // '') =~ /^10\.10\.(\d+)\.0\/24$/;
        $taken{$n} = 1 if defined $n;
    }
    for my $n (1 .. 254) {
        return "10.10.$n.0/24" if !$taken{$n};
    }
    die "no free /24 left in 10.10.0.0/16\n";
}

sub assert_network_config {
    my ($param) = @_;

    die "lb-mode bgp was removed by the T3.4 re-spec: "
        . "LoadBalancer routes come from Proxmox SDN (EVPN "
        . "fabric or BGP controller + exit nodes), not Cilium\n"
        if ($param->{'lb-mode'} // 'l2') eq 'bgp';
    die "lb-mode must be l2\n"
        if ($param->{'lb-mode'} // 'l2') ne 'l2';

    my ($zone, $public) = $param->@{qw(sdn-zone public-subnet)};
    die "sdn-zone and public-subnet must be set together "
        . "(dedicated per-cluster VNet, T3.4 re-spec)\n"
        if defined $zone xor defined $public;
    return 'shared' if !defined $zone;

    die "sdn-zone '$zone' is not a valid SDN zone name\n"
        if $zone !~ /^[a-zA-Z0-9]+[a-zA-Z0-9_-]*$/;
    my $node_subnet = $param->{'node-subnet'}
        or die "dedicated-VNet mode needs a node-subnet "
            . "(internal /24)\n";
    for my $pair (['node-subnet', $node_subnet],
                  ['public-subnet', $public]) {
        my ($key, $cidr) = @$pair;
        die "$key must be a /24 (e.g. 192.168.202.0/24), "
            . "got '$cidr'\n"
            if $cidr !~ m|^\d+\.\d+\.\d+\.0/24$|;
    }
    die "public-subnet must differ from node-subnet\n"
        if $public eq $node_subnet;
    return 'dedicated';
}

# T3.6a: the shared-file (RWX) tier. NFS: any admin NFS
# server/share, validated for reachability at provision
# time; per-PVC subdirectories are created by the CSI
# driver, nobody creates directories by hand. CephFS:
# auto-managed when a hyper-converged PVE Ceph cluster
# exists (the provisioner creates the filesystem and a
# scoped CephX CSI user through the PVE/Ceph APIs); the
# plugin never deploys Ceph itself, and provisioning a
# cephfs cluster without a Ceph cluster fails cleanly.
sub assert_file_config {
    my ($param) = @_;

    my $backend = $param->{'file-backend'} or return undef;
    die "file-backend must be nfs or cephfs\n"
        if $backend ne 'nfs' && $backend ne 'cephfs';
    return $backend if $backend eq 'cephfs';
    my ($server, $share) = $param->@{qw(file-server file-share)};
    die "file-backend nfs needs file-server and file-share\n"
        if !$server || !$share;
    die "file-server '$server' is not an IPv4 address\n"
        if $server !~ /^\d+\.\d+\.\d+\.\d+$/;
    die "file-share '$share' is not an absolute export path\n"
        if $share !~ m|^/[A-Za-z0-9._/-]*$|;
    return $backend;
}

# CephFS filesystem name owned by one cluster; recorded
# back into file-share so delete knows what it may remove.
sub cephfs_name {
    my ($name) = @_;

    my $clean = lc $name;
    $clean =~ s/[^a-z0-9]/-/g;
    return "k8s-$clean";
}

# Deterministic short VNet id for a dedicated cluster VNet
# (bridge-name length limits apply on the hosts).
sub cluster_vnet_name {
    my ($name) = @_;

    # PVE VNet ids are at most 8 characters: 'k8s' + 5.
    # (Was 7: 'k8suitest' died with a raw pvesh 400 halfway
    # into provision, lab 2026-11-02.)
    my $clean = lc $name;
    $clean =~ s/[^a-z0-9]//g;
    return 'k8s' . substr($clean, 0, 5);
}

# The apiserver VIP: on the public subnet in dedicated
# mode (reachable from outside through the advertised
# route), on the node subnet in legacy shared mode. The
# .59 convention matches node addressing (CPs from .60).
sub vip_for {
    my ($scfg) = @_;

    my $subnet = $scfg->{'public-subnet'}
        // $scfg->{'node-subnet'} // '';
    return $subnet =~ m|^(\d+\.\d+\.\d+)\.| ? "$1.59" : undef;
}

1;
