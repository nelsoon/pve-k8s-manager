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
        'lb-range' => {
            type => 'string',
            description => "LoadBalancer address range, e.g. '192.168.200.100-192.168.200.120'.",
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
        'maintenance-window' => {
            type => 'string',
            description => "Rolling window HH:MM-HH:MM (local time).",
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
        gateway => {
            type => 'string',
            description => "Gateway for node VMs, e.g. '192.168.200.1'.",
            optional => 1,
        },
        'lb-range' => { optional => 1 },
        nodes => { optional => 1 },
        'template-rev' => { optional => 1 },
        'maintenance-window' => { optional => 1 },
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

__PACKAGE__->register();
__PACKAGE__->init();

# Worker pools (T2.1). Stored as one JSON property so pmxcfs
# stays a flat section file; an absent property means the
# legacy single default pool sized by 'workers'. Labels and
# taints are comma lists of key=value (taints key=value:Effect
# or bare key). 'hosts' is a comma list of PVE node names the
# pool may be placed on; 'device-profile' is reserved for
# future GPU support and only carried, never acted on in v1.
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
        for my $key (qw(labels taints hosts)) {
            next if !defined $pool->{$key};
            die "pool '$name' $key must be a string\n"
                if ref $pool->{$key};
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

1;
