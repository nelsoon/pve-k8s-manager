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

# Every mutating task goes through here so one cluster can
# never run two actions at once (a slow provision started
# twice forked racing workers). The claim is taken in pmxcfs
# before the task forks: an identical repeat returns the live
# task's UPID (the UI then just shows that task), any other
# action is refused with a busy error. Nothing is queued -
# queued parameters could be stale by the time they ran.
my sub fork_cluster_worker {
    my ($type, $name, $key, $code) = @_;

    my $rpcenv = PVE::RPCEnvironment::get();
    my $authuser = $rpcenv->get_user();

    my $claim = PVE::K8s::Provision::claim_cluster_action(
        $name, $key, $type, $authuser);
    if ($claim->{status} eq 'coalesce') {
        # The first request may still be attaching its UPID;
        # wait briefly for it rather than forking a duplicate.
        for (1 .. 10) {
            my $record = PVE::K8s::Provision::cluster_action_record($name);
            return $record->{upid}
                if $record && ($record->{token} // '')
                    eq ($claim->{record}->{token} // '')
                    && $record->{upid};
            sleep 1;
        }
        die "cluster '$name' already running: "
            . PVE::K8s::Provision::cluster_action_describe(
                $name, $claim->{record})
            . "; open its task from the task log instead\n";
    }
    die "cluster '$name' already running: "
        . PVE::K8s::Provision::cluster_action_describe(
            $name, $claim->{record})
        . "; wait for it to finish before starting another "
        . "action on this cluster\n"
        if $claim->{status} ne 'claimed';

    my $token = $claim->{token};
    my $upid = eval {
        $rpcenv->fork_worker($type, $name, $authuser, sub {
            PVE::K8s::Provision::run_cluster_action(
                $name, $token, $code);
        });
    };
    if (my $err = $@) {
        eval { PVE::K8s::Provision::release_cluster_action(
            $name, $token) };
        die $err;
    }
    # Attaching can collide with the worker's first config
    # writes; retry briefly - without the UPID a duplicate
    # request cannot be coalesced onto this task.
    for (1 .. 5) {
        eval { PVE::K8s::Provision::attach_cluster_action_upid(
            $name, $token, $upid) };
        my $record = eval {
            PVE::K8s::Provision::cluster_action_record($name) };
        last if $record && ($record->{upid} // '') eq $upid;
        sleep 1;
    }
    return $upid;
}

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
                optional => 1,
                description => "Kubernetes version, e.g. '1.36'. "
                    . "Default: the newest supported minor.",
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
                    . "taints, hosts, storage, device-profile, arch}].",
            },
            'cp-arch' => {
                type => 'string',
                pattern => '^(amd64|arm64)$',
                optional => 1,
                description => "Control-plane architecture; only "
                    . "meaningful on mixed-arch PVE clusters "
                    . "(default: amd64 templates).",
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
            'builder-ip' => {
                type => 'string',
                optional => 1,
                description => "Free static IP for the throwaway "
                    . "template-builder VM; provision builds a "
                    . "node template itself when none exists.",
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
            'storage-profile' => {
                type => 'string',
                enum => ['shared', 'local'],
                optional => 1,
                description => "Storage profile: shared (Ceph "
                    . "RBD disks + shared PVs) or local "
                    . "(node-local disks and PVs).",
            },
            'cp-policy' => {
                type => 'string',
                enum => ['ha', 'replace'],
                optional => 1,
                description => "Control-plane failure policy.",
            },
            'maintenance-window' => {
                type => 'string',
                pattern => '^\d{2}:\d{2}-\d{2}:\d{2}$',
                optional => 1,
                description => "Rolling window HH:MM-HH:MM (local time).",
            },
            'sdn-zone' => {
                type => 'string',
                optional => 1,
                description => "SDN EVPN zone for a dedicated "
                    . "per-cluster VNet (T3.4 re-spec). Set "
                    . "with public-subnet; without them the "
                    . "template's shared VNet is used.",
            },
            'public-subnet' => {
                type => 'string',
                optional => 1,
                description => "Public /24 for LoadBalancer "
                    . "IPs and the apiserver VIP, e.g. "
                    . "'192.168.212.0/24' (dedicated mode).",
            },
            'file-backend' => {
                type => 'string',
                pattern => '^(nfs|cephfs)$',
                optional => 1,
                description => "Shared-file (RWX) tier "
                    . "backend (T3.6a): nfs or cephfs.",
            },
            'file-server' => {
                type => 'string',
                optional => 1,
                description => "NFS server IPv4 (file-backend nfs).",
            },
            'file-share' => {
                type => 'string',
                optional => 1,
                description => "NFS export path, e.g. /srv/k8s.",
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
        $param->{'k8s-version'} //=
            PVE::K8s::Config::latest_supported_version();
        PVE::K8s::Config::assert_supported_version($param->{'k8s-version'});
        # Node networking needs no decision: first free
        # /24 in 10.10.0.0/16 unless the caller pins one.
        # (The dialog shows the same suggestion, computed
        # the same way, so API and UI agree.)
        if (!$param->{'node-subnet'}) {
            my $cfg = PVE::K8s::Config->config();
            my @used = map { $cfg->{ids}->{$_}->{'node-subnet'} }
                keys $cfg->{ids}->%*;
            $param->{'node-subnet'} =
                PVE::K8s::Config::allocate_node_subnet(\@used);
        }
        # Fail fast on the classic mismatch: HA policy on
        # non-shared storage silently degraded to replace
        # at provision time. Refuse here instead.
        if (($param->{'cp-policy'} // '') eq 'ha' && $param->{storage}) {
            my $shared = eval {
                require PVE::Storage;
                PVE::Storage::config()->{ids}
                    ->{$param->{storage}}->{shared};
            } // 0;
            die "cp-policy 'ha' needs a shared storage; "
                . "'$param->{storage}' is not shared\n"
                if !$shared;
        }
        PVE::K8s::Config::assert_network_config($param);
        PVE::K8s::Config::assert_file_config($param);
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
                        maintenance-window backup-dir sdn-zone
                        public-subnet file-backend file-server
                        file-share cp-arch storage-profile
                        cp-policy builder-ip
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

        # Provisioning takes minutes; run it as a PVE task so the
        # UI can show progress in the task log like other actions.
        return fork_cluster_worker('k8sprovision', $name,
            'provision', sub {
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

        return fork_cluster_worker('k8sroll', $name, 'roll', sub {
            PVE::K8s::Provision::roll_cluster(
                $name, force => $param->{force} // 0);
        });
    }});

__PACKAGE__->register_method({
    name => 'rebuild_template',
    path => '{name}/rebuild-template',
    method => 'POST',
    protected => 1,
    description => "Build a new node image revision now (for example "
        . "after a critical security fix) instead of waiting for the "
        . "weekly refresh. Nodes keep running their current revision "
        . "until a roll replaces them; the severity stamp starts the "
        . "remediation deadline (critical 7 days, high 30 days).",
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
            severity => {
                type => 'string',
                enum => ['routine', 'high', 'critical'],
                default => 'routine',
                optional => 1,
                description => "How urgent this image update is.",
            },
            arch => {
                type => 'string',
                enum => ['amd64', 'arm64'],
                optional => 1,
                description => "Only rebuild this architecture.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $name = $param->{name};
        my $cfg = PVE::K8s::Config->config();
        my $scfg = $cfg->{ids}->{$name}
            or die "cluster '$name' does not exist\n";
        my $severity = $param->{severity} // 'routine';
        my $minor = $scfg->{'k8s-version'}
            or die "cluster '$name' has no Kubernetes version\n";
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        # Not a cluster action: rebuilding an image touches no node,
        # so the scaler and rolls keep running; one refresh at a
        # time cluster-wide is enforced by the template claim.
        return $rpcenv->fork_worker('k8srebuild', $name, $authuser, sub {
            my $ids = PVE::K8s::Config->config()->{ids};
            my @targets = PVE::K8s::Provision::rebuild_targets(
                { $name => $ids->{$name} },
                { minor => $minor, arch => $param->{arch} });
            die "nothing to rebuild for cluster '$name'\n" if !@targets;
            PVE::K8s::Provision::rebuild_templates(\@targets, $severity);
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

        return fork_cluster_worker('k8supgrade', $name,
            "upgrade:$param->{to}", sub {
                PVE::K8s::Provision::upgrade_cluster(
                    $name, $param->{to},
                    force => $param->{force} // 0);
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

        return fork_cluster_worker('k8sscale', $name, 'scale', sub {
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
    name => 'update',
    path => '{name}',
    method => 'PUT',
    protected => 1, # writes the cluster config (pmxcfs lock needs root)
    description => "Update mutable rollout options of a managed "
        . "Kubernetes cluster (used by the S3 scenario to narrow "
        . "and open the maintenance window around a roll).",
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
            'maintenance-window' => {
                type => 'string',
                pattern => '^\d{2}:\d{2}-\d{2}:\d{2}$',
                optional => 1,
                description => "Rolling window HH:MM-HH:MM (local time).",
            },
            pools => {
                type => 'string',
                optional => 1,
                description => "Worker node groups as JSON: "
                    . "[{name, size, min, max, labels, taints, "
                    . "hosts, storage, arch}]. The next scale "
                    . "pass converges membership; removing a "
                    . "group retires its nodes.",
            },
            'backup-retention' => {
                type => 'integer',
                minimum => 1,
                maximum => 100,
                optional => 1,
                description => "Etcd backups to keep.",
            },
            'cp-policy' => {
                type => 'string',
                enum => ['ha', 'replace'],
                optional => 1,
                description => "Control-plane failure policy.",
            },
            'storage-profile' => {
                type => 'string',
                enum => ['shared', 'local'],
                optional => 1,
                description => "Storage profile (shared/local).",
            },
            description => {
                type => 'string',
                maxLength => 4096,
                optional => 1,
                description => "Description of the cluster.",
            },
            delete => {
                type => 'string',
                optional => 1,
                description => "Comma-separated settings to clear: "
                    . "maintenance-window, backup-retention, description.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        die "nothing to update: pass maintenance-window, pools, "
            . "backup-retention, description or delete\n"
            if !defined $param->{delete}
            && !defined $param->{'maintenance-window'}
            && !defined $param->{pools}
            && !defined $param->{'backup-retention'}
            && !defined $param->{description}
            && !defined $param->{'cp-policy'}
            && !defined $param->{'storage-profile'};

        PVE::K8s::Provision::set_cluster_options($param->{name}, {
            'maintenance-window' => $param->{'maintenance-window'},
            pools => $param->{pools},
            'backup-retention' => $param->{'backup-retention'},
            description => $param->{description},
            'cp-policy' => $param->{'cp-policy'},
            'storage-profile' => $param->{'storage-profile'},
            delete => [ grep { length } split /\s*,\s*/,
                $param->{delete} // '' ],
        });

        return undef;
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
    protected => 1, # kubectl via qm guest exec needs root
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
    name => 'certificates',
    path => '{name}/certificates',
    method => 'GET',
    protected => 1, # kubectl via qm guest exec needs root
    description => "kubeadm certificate expiry for the cluster "
        . "(control-plane PKI expires after one year).",
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

        return PVE::K8s::Provision::cert_expiry($param->{name});
    }});

__PACKAGE__->register_method({
    name => 'upgrade_check',
    path => '{name}/upgrade-check',
    method => 'GET',
    protected => 1, # kubectl via qm guest exec needs root
    description => "Read-only checks before a Kubernetes minor upgrade: "
        . "version skew, template, host headroom for the surge node, "
        . "etcd backup, certificates, PodDisruptionBudgets and "
        . "deprecated APIs still in use. Changes nothing.",
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
            to => {
                type => 'string',
                pattern => '^\\d+\\.\\d+(\\.\\d+)?$',
                description => "Target Kubernetes minor version.",
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        return PVE::K8s::Provision::upgrade_check(
            $param->{name}, $param->{to});
    }});

__PACKAGE__->register_method({
    name => 'power',
    path => '{name}/power',
    method => 'POST',
    protected => 1,
    description => "Start or stop every node VM of the cluster "
        . "(start: control plane first; stop: workers first).",
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
            action => {
                type => 'string',
                enum => ['start', 'stop'],
                description => "Power action.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        # task type carries the action so the task log
        # reads "Start VMs"/"Stop VMs", not "k8spower"
        my $type = ($param->{action} // '') eq 'stop'
            ? 'k8spowerstop' : 'k8spowerstart';
        return fork_cluster_worker($type, $param->{name},
            "power:$param->{action}", sub {
                PVE::K8s::Provision::set_cluster_power(
                    $param->{name}, $param->{action});
            });
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

        return fork_cluster_worker('k8snodedrain',
            $param->{name}, "node-drain:$param->{node}", sub {
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

        return fork_cluster_worker('k8snodereplace',
            $param->{name}, "node-replace:$param->{node}", sub {
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

        return fork_cluster_worker('k8snodeforceretire',
            $param->{name},
            "node-force-retire:$param->{node}", sub {
                PVE::K8s::Provision::force_retire_node(
                    $param->{name}, $param->{node},
                    force => $param->{force} // 0,
                    replace => $param->{replace} // 0);
            });
    }});

__PACKAGE__->register_method({
    name => 'volume-move',
    path => '{name}/volumes/move',
    method => 'POST',
    protected => 1,
    description => "Move a local-block PVC's disk to another "
        . "Proxmox host (T3.6b): the image is copied, the "
        . "PV/PVC pair is recreated with the same names and "
        . "disk identity, and the source image is deleted "
        . "once the claim rebinds. The PVC must not be in "
        . "use by a running pod.",
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
            namespace => {
                type => 'string',
                description => "Namespace of the PVC.",
            },
            pvc => {
                type => 'string',
                description => "Name of the PVC to move.",
            },
            'target-host' => {
                type => 'string',
                description => "Destination Proxmox host name.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        return fork_cluster_worker('k8svolumemove',
            $param->{name},
            "volume-move:$param->{namespace}/$param->{pvc}", sub {
                PVE::K8s::Provision::move_local_pvc(
                    $param->{name}, $param->{namespace},
                    $param->{pvc}, $param->{'target-host'});
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

        return fork_cluster_worker('k8sbackup',
            $param->{name}, 'backup', sub {
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

        return fork_cluster_worker('k8srestore',
            $param->{name}, "restore:$param->{backup}", sub {
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

        return fork_cluster_worker('k8sevacuate',
            $param->{name}, "evacuate:$param->{host}", sub {
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
                pattern => '^(cert-manager|external-dns|metrics-server)$',
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

        my $addon = $param->{addon};
        my %opts = map { $_ => $param->{$_} }
            grep { defined $param->{$_} }
            qw(issuer email acme-server provider
                pdns-url pdns-api-key zone);

        return fork_cluster_worker('k8saddonenable',
            $param->{name}, "addon-enable:$addon", sub {
                PVE::K8s::Provision::enable_addon(
                    $param->{name}, $addon, \%opts);
            });
    }});

__PACKAGE__->register_method({
    name => 'addon_disable',
    path => '{name}/addons/{addon}/disable',
    method => 'POST',
    protected => 1,
    description => "Disable an add-on (metrics-server).",
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
                pattern => '^metrics-server$',
                description => "The add-on to disable.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        return fork_cluster_worker('k8saddondisable',
            $param->{name}, "addon-disable:$param->{addon}", sub {
                PVE::K8s::Provision::disable_addon(
                    $param->{name}, $param->{addon});
            });
    }});

__PACKAGE__->register_method({
    name => 'workloads',
    path => '{name}/workloads',
    method => 'GET',
    protected => 1, # kubectl via qm guest exec needs root
    description => "Read-only workload listing (deployments, "
        . "pods, services) for the cluster.",
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

        return PVE::K8s::Provision::workloads_cluster(
            $param->{name});
    }});

__PACKAGE__->register_method({
    name => 'metrics',
    path => '{name}/metrics',
    method => 'GET',
    protected => 1, # kubectl via qm guest exec needs root
    description => "Node VM metrics (PVE RRD) and, when the "
        . "metrics-server add-on is enabled, pod CPU/memory.",
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

        return PVE::K8s::Provision::metrics_cluster(
            $param->{name});
    }});

__PACKAGE__->register_method({
    name => 'summary',
    path => '{name}/summary',
    method => 'GET',
    protected => 1, # aggregates kubectl via qm guest exec
    description => "Visual Summary data for one cluster: "
        . "health verdict, node readiness, node VM capacity, "
        . "LoadBalancer usage, last backup, worst "
        . "certificate expiry. Live pieces degrade to "
        . "absent fields instead of failing.",
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

        return PVE::K8s::Provision::summary_cluster(
            $param->{name});
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

        return fork_cluster_worker('k8sdelete', $name,
            'delete', sub {
                PVE::K8s::Provision::delete_cluster($name);
            });
    }});

1;
