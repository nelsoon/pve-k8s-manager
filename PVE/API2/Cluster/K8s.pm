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
                description => "Kubernetes version, e.g. '1.36'.",
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
            'lb-mode' => {
                type => 'string',
                pattern => '^(l2|bgp)$',
                optional => 1,
                description => "LoadBalancer announcement: l2 "
                    . "(default, ARP on the node subnet) or bgp "
                    . "(Cilium BGP to an external router).",
            },
            'bgp-peer-address' => {
                type => 'string',
                optional => 1,
                description => "BGP router address (lb-mode bgp).",
            },
            'bgp-peer-asn' => {
                type => 'integer',
                optional => 1,
                description => "BGP router ASN (lb-mode bgp).",
            },
            'bgp-local-asn' => {
                type => 'integer',
                optional => 1,
                description => "ASN for the cluster's Cilium "
                    . "BGP speakers (lb-mode bgp).",
            },
            'backup-dir' => {
                type => 'string',
                optional => 1,
                description => "Host directory for etcd backups "
                    . "(shared/PBS-mounted path recommended).",
            },
            'backup-retention' => {
                type => 'integer',
                minimum => 1,
                maximum => 100,
                optional => 1,
                description => "Etcd backups to keep.",
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
        PVE::K8s::Config::assert_bgp_config($param);
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
                        maintenance-window backup-dir lb-mode
                        bgp-peer-address bgp-peer-asn bgp-local-asn
                        backup-retention description)),
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
                description => "Target Kubernetes minor, e.g. '1.36'.",
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
    name => 'scale',
    path => '{name}/scale',
    method => 'POST',
    protected => 1,
    description => "Run one autoscaler reconcile pass (repair, "
        . "scale out/in by pool min/max).",
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

        return $rpcenv->fork_worker('k8sscale', $name, $authuser, sub {
            PVE::K8s::Provision::scale_cluster($name);
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
    name => 'kubeconfig',
    path => '{name}/kubeconfig',
    method => 'GET',
    protected => 1,
    description => "Issue a short-lived (1h) admin kubeconfig "
        . "for the cluster (TokenRequest token; the call is "
        . "the audit record).",
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
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        return PVE::K8s::Provision::kubeconfig_cluster($param->{name});
    }});

__PACKAGE__->register_method({
    name => 'events',
    path => '{name}/events',
    method => 'GET',
    description => "Recent Kubernetes events for the cluster.",
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
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        return PVE::K8s::Provision::cluster_events($param->{name});
    }});

__PACKAGE__->register_method({
    name => 'node-drain',
    path => '{name}/nodes/{node}/drain',
    method => 'POST',
    protected => 1,
    description => "Cordon and drain one node (PDB-safe, "
        . "time-boxed).",
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
            node => {
                type => 'string',
                description => "The Kubernetes node name.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8snodedrain',
            $param->{name}, $authuser, sub {
                PVE::K8s::Provision::drain_node(
                    $param->{name}, $param->{node});
            });
    }});

__PACKAGE__->register_method({
    name => 'node-replace',
    path => '{name}/nodes/{node}/replace',
    method => 'POST',
    protected => 1,
    description => "Replace one worker node: drain, destroy, "
        . "recreate from the template (same name/IP).",
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
            node => {
                type => 'string',
                description => "The Kubernetes node name.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8snodereplace',
            $param->{name}, $authuser, sub {
                PVE::K8s::Provision::replace_node(
                    $param->{name}, $param->{node});
            });
    }});

__PACKAGE__->register_method({
    name => 'node-force-retire',
    path => '{name}/nodes/{node}/force-retire',
    method => 'POST',
    protected => 1,
    description => "Force-retire a dead worker node (the VM "
        . "must be powered off or lost; requires force=1). "
        . "Optionally provisions its replacement.",
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
            node => {
                type => 'string',
                description => "The Kubernetes node name.",
            },
            force => {
                type => 'boolean',
                optional => 1,
                description => "Confirm the VM is powered off "
                    . "or permanently lost.",
            },
            replace => {
                type => 'boolean',
                optional => 1,
                description => "Provision a replacement node "
                    . "after retiring the dead one.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8snodeforceretire',
            $param->{name}, $authuser, sub {
                PVE::K8s::Provision::force_retire_node(
                    $param->{name}, $param->{node},
                    force => $param->{force} // 0,
                    replace => $param->{replace} // 0);
            });
    }});

__PACKAGE__->register_method({
    name => 'backup',
    path => '{name}/backup',
    method => 'POST',
    protected => 1,
    description => "Take an etcd backup to the cluster's "
        . "backup-dir (snapshot + off-cluster copy + manifest).",
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

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8sbackup',
            $param->{name}, $authuser, sub {
                PVE::K8s::Provision::backup_cluster($param->{name});
            });
    }});

__PACKAGE__->register_method({
    name => 'backups',
    path => '{name}/backups',
    method => 'GET',
    description => "List etcd backups in the cluster's backup-dir.",
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
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        return PVE::K8s::Provision::list_backups($param->{name});
    }});

__PACKAGE__->register_method({
    name => 'restore',
    path => '{name}/restore',
    method => 'POST',
    protected => 1,
    description => "Restore etcd from a backup file on every "
        . "control-plane node (data rollback; requires force=1).",
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
            backup => {
                type => 'string',
                description => "Backup file name (see backups list).",
            },
            force => {
                type => 'boolean',
                optional => 1,
                description => "Confirm the etcd data rollback.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8srestore',
            $param->{name}, $authuser, sub {
                PVE::K8s::Provision::restore_cluster(
                    $param->{name}, $param->{backup},
                    force => $param->{force} // 0);
            });
    }});

__PACKAGE__->register_method({
    name => 'evacuate',
    path => '{name}/hosts/{host}/evacuate',
    method => 'POST',
    protected => 1,
    description => "Evacuate a PVE host for maintenance: "
        . "live-migrate every managed cluster VM off it "
        . "(local disks included), workers first, "
        . "control-plane members one at a time with a "
        . "cluster health gate between moves. The cluster "
        . "in the path is the API context; evacuation "
        . "covers all managed clusters.",
    permissions => {
        check => ['perm', '/cluster', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            name => {
                type => 'string',
                format => 'pve-configid',
                description => "Context cluster (evacuation "
                    . "itself covers all managed clusters).",
            },
            host => {
                type => 'string',
                description => "The PVE host to empty.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return $rpcenv->fork_worker('k8sevacuate',
            $param->{host}, $authuser, sub {
                PVE::K8s::Provision::evacuate_host(
                    $param->{host});
            });
    }});

__PACKAGE__->register_method({
    name => 'addons',
    path => '{name}/addons',
    method => 'GET',
    description => "List add-ons for a cluster: Cilium "
        . "ingress/Gateway (installed), cert-manager and "
        . "external-dns (unconfigured until enabled), and "
        . "catalog entries available for later.",
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
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        return PVE::K8s::Provision::list_addons($param->{name});
    }});

__PACKAGE__->register_method({
    name => 'addon_enable',
    path => '{name}/addons/{addon}/enable',
    method => 'POST',
    protected => 1,
    description => "Enable an opt-in add-on (cert-manager or "
        . "external-dns) on a ready cluster.",
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
            addon => {
                type => 'string',
                pattern => '^(cert-manager|external-dns)$',
                description => "The add-on to enable.",
            },
            issuer => {
                type => 'string',
                pattern => '^(ca|acme)$',
                optional => 1,
                description => "cert-manager issuer (default ca).",
            },
            email => {
                type => 'string',
                optional => 1,
                description => "ACME account email.",
            },
            'acme-server' => {
                type => 'string',
                optional => 1,
                description => "ACME directory URL (default "
                    . "Let's Encrypt production).",
            },
            provider => {
                type => 'string',
                pattern => '^pdns$',
                optional => 1,
                description => "external-dns provider (pdns).",
            },
            'pdns-url' => {
                type => 'string',
                optional => 1,
                description => "PowerDNS API URL, e.g. "
                    . "http://dns.example.com:8081/api/v1/servers/localhost.",
            },
            'pdns-api-key' => {
                type => 'string',
                optional => 1,
                description => "PowerDNS API key (stored only "
                    . "in the in-cluster Secret).",
            },
            zone => {
                type => 'string',
                optional => 1,
                description => "DNS zone (domain filter).",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $addon = $param->{addon};
        my %opts = map { $_ => $param->{$_} }
            grep { defined $param->{$_} }
            qw(issuer email acme-server provider
                pdns-url pdns-api-key zone);

        return $rpcenv->fork_worker('k8saddon',
            $param->{name}, $authuser, sub {
                PVE::K8s::Provision::enable_addon(
                    $param->{name}, $addon, \%opts);
            });
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
