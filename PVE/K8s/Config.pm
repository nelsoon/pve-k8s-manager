# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Config;

use strict;
use warnings;

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
            description => "Kubernetes version, e.g. '1.31'.",
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

sub assert_valid_cp_count {
    my ($cp) = @_;

    die "cp must be 1, 3 or 5\n" if !grep { $_ == $cp } (1, 3, 5);
    return $cp;
}

1;
