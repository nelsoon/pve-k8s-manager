# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::API2::Cluster::K8s;

use strict;
use warnings;

use PVE::K8s::Config;
use PVE::K8s::Provision;
use PVE::RPCEnvironment;

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
                description => "Kubernetes version, e.g. '1.37'.",
            },
            cp => {
                type => 'integer',
                minimum => 1,
                maximum => 5,
                default => 3,
                optional => 1,
                description => "Control-plane node count (1, 3 or 5).",
            },
            workers => {
                type => 'integer',
                minimum => 0,
                maximum => 50,
                default => 2,
                optional => 1,
                description => "Worker node count (single default pool for now).",
            },
            pools => {
                type => 'string',
                optional => 1,
                description => "Worker pools as JSON: [{name, size, labels, "
                    . "taints, hosts, storage, device-profile}].",
            },
            'node-subnet' => {
                type => 'string',
                optional => 1,
                description => "SDN subnet for node VMs, e.g. '192.168.200.0/24'.",
            },
            gateway => {
                type => 'string',
                optional => 1,
                description => "Gateway for node VMs, e.g. '192.168.200.1'.",
            },
            'lb-range' => {
                type => 'string',
                optional => 1,
                description => "LoadBalancer address range, "
                    . "e.g. '192.168.200.100-192.168.200.120'.",
            },
            storage => {
                type => 'string',
                format => 'pve-storage-id',
                optional => 1,
                description => "PVE storage for node disks.",
            },
            'maintenance-window' => {
                type => 'string',
                pattern => '^\d{2}:\d{2}-\d{2}:\d{2}$',
                optional => 1,
                description => "Rolling window HH:MM-HH:MM (local time).",
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
        # new clusters only on upstream-supported minors
        PVE::K8s::Config::assert_supported_version($param->{'k8s-version'});
        # validate pools eagerly so a bad pool spec fails at
        # create time, not halfway through provisioning
        PVE::K8s::Config::parse_pools($param->{pools}, $param->{workers} // 2)
            if defined $param->{pools};

        PVE::K8s::Config::lock_config(sub {
            my $cfg = PVE::K8s::Config->config();

            die "cluster '$name' already exists\n" if $cfg->{ids}->{$name};

            $cfg->{ids}->{$name} = {
                type => 'cluster',
                'k8s-version' => $param->{'k8s-version'},
                cp => $cp,
                workers => $param->{workers} // 2,
                state => 'config-only',
                created => time(),
                (map { $param->{$_} ? ($_ => $param->{$_}) : () }
                    qw(node-subnet gateway lb-range pools storage
                        maintenance-window description)),
            };

            PVE::K8s::Config::store_config($cfg);
        });

        return undef;
    }});

__PACKAGE__->register_method({
    name => 'provision',
    path => '{name}/provision',
    method => 'POST',
    protected => 1,
    description => "Provision (or resume provisioning) the cluster's VMs and bootstrap Kubernetes.",
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
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $name = $param->{name};
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        # Provisioning takes minutes; run it as a PVE task so the
        # UI can show progress in the task log like other actions.
        return $rpcenv->fork_worker('k8sprovision', $name, $authuser, sub {
            PVE::K8s::Provision::provision_cluster($name);
        });
    }});

__PACKAGE__->register_method({
    name => 'roll',
    path => '{name}/roll',
    method => 'POST',
    protected => 1,
    description => "Roll nodes onto the latest template revision "
        . "(surge replacement, one at a time).",
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
            force => {
                type => 'boolean',
                optional => 1,
                description => "Roll even outside the maintenance window.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $name = $param->{name};
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8sroll', $name, $authuser, sub {
            PVE::K8s::Provision::roll_cluster(
                $name, force => $param->{force} // 0);
        });
    }});

__PACKAGE__->register_method({
    name => 'upgrade',
    path => '{name}/upgrade',
    method => 'POST',
    protected => 1,
    description => "Upgrade Kubernetes by one minor version "
        . "(kubeadm sequencing + rolling replacement).",
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
            to => {
                type => 'string',
                pattern => '^\d+\.\d+(\.\d+)?$',
                description => "Target Kubernetes minor, e.g. '1.37'.",
            },
            force => {
                type => 'boolean',
                optional => 1,
                description => "Upgrade even outside the maintenance window.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $name = $param->{name};
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8supgrade', $name, $authuser, sub {
            PVE::K8s::Provision::upgrade_cluster(
                $name, $param->{to}, force => $param->{force} // 0);
        });
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
    description => "Delete a managed Kubernetes cluster: destroys its VMs "
        . "and disks, removes its scoped PVE users, and only then drops "
        . "the config entry.",
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
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $name = $param->{name};
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8sdelete', $name, $authuser, sub {
            PVE::K8s::Provision::delete_cluster($name);
        });
    }});

1;
