# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::API2::Cluster::K8s;

use strict;
use warnings;

use PVE::K8s::Config;

use base qw(PVE::RESTHandler);

# T1.2 scope: config CRUD only. Provisioning lands in T1.4;
# creating a cluster here records desired state, nothing is
# built yet (state stays 'config-only' until the FSM exists).

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "List managed Kubernetes clusters.",
    permissions => {
        check => ['perm', '/cluster', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
        links => [{ rel => 'child', href => "{name}" }],
    },
    code => sub {
        my ($param) = @_;

        my $cfg = PVE::K8s::Config->config();
        my $res = [];
        for my $name (sort keys $cfg->{ids}->%*) {
            push $res->@*, { name => $name, $cfg->{ids}->{$name}->%* };
        }
        return $res;
    }});

__PACKAGE__->register_method({
    name => 'create',
    path => '',
    method => 'POST',
    protected => 1,
    description => "Create a managed Kubernetes cluster (config only for now).",
    permissions => {
        check => ['perm', '/cluster', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            name => {
                type => 'string',
                format => 'pve-configid',
                description => "The name of the Kubernetes cluster.",
            },
            'k8s-version' => {
                type => 'string',
                pattern => '^\d+\.\d+(\.\d+)?$',
                description => "Kubernetes version, e.g. '1.31'.",
            },
            cp => {
                type => 'integer',
                minimum => 1,
                maximum => 5,
                default => 3,
                optional => 1,
                description => "Control-plane node count (1, 3 or 5).",
            },
            description => {
                type => 'string',
                maxLength => 4096,
                optional => 1,
                description => "Description of the cluster.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $name = $param->{name};
        my $cp = PVE::K8s::Config::assert_valid_cp_count($param->{cp} // 3);

        PVE::K8s::Config::lock_config(sub {
            my $cfg = PVE::K8s::Config->config();

            die "cluster '$name' already exists\n" if $cfg->{ids}->{$name};

            $cfg->{ids}->{$name} = {
                type => 'cluster',
                'k8s-version' => $param->{'k8s-version'},
                cp => $cp,
                state => 'config-only',
                created => time(),
                ($param->{description}
                    ? (description => $param->{description})
                    : ()),
            };

            PVE::K8s::Config::store_config($cfg);
        });

        return undef;
    }});

__PACKAGE__->register_method({
    name => 'get',
    path => '{name}',
    method => 'GET',
    description => "Get a managed Kubernetes cluster.",
    permissions => {
        check => ['perm', '/cluster', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            name => {
                type => 'string',
                format => 'pve-configid',
                description => "The name of the Kubernetes cluster.",
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $cfg = PVE::K8s::Config->config();
        my $scfg = $cfg->{ids}->{$param->{name}}
            or die "cluster '$param->{name}' does not exist\n";

        return { name => $param->{name}, $scfg->%* };
    }});

__PACKAGE__->register_method({
    name => 'delete',
    path => '{name}',
    method => 'DELETE',
    protected => 1,
    description => "Delete a managed Kubernetes cluster (config only for now).",
    permissions => {
        check => ['perm', '/cluster', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            name => {
                type => 'string',
                format => 'pve-configid',
                description => "The name of the Kubernetes cluster.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $name = $param->{name};

        PVE::K8s::Config::lock_config(sub {
            my $cfg = PVE::K8s::Config->config();

            die "cluster '$name' does not exist\n" if !$cfg->{ids}->{$name};

            delete $cfg->{ids}->{$name};
            delete $cfg->{order}->{$name};

            PVE::K8s::Config::store_config($cfg);
        });

        return undef;
    }});

1;
