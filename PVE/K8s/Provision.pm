# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Provision;

use strict;
use warnings;

use JSON::PP ();

use PVE::Tools qw(run_command);

use PVE::K8s::Addons;
use PVE::K8s::Config;

# Provisioning FSM (T1.4). Runs in a protected API task worker on
# one PVE node. All node VMs for a cluster are created on the
# local node for now; multi-host placement arrives with node
# pools (T2.1). Steps are ordered so a re-run after failure is
# safe: existing VMs are detected by name and reused.

my sub run {
    my ($cmd, %opts) = @_;

    my $out = '';
    run_command($cmd,
        outfunc => sub { $out .= "$_[0]\n" },
        errfunc => sub { $out .= "$_[0]\n" },
        timeout => $opts{timeout} // 300,
        noerr => $opts{noerr} // 0,
    );
    return $out;
}

my sub qm {
    my (@args) = @_;
    return run(['qm', @args], timeout => 600);
}

# qm guest exec returns only a pid once its timeout passes;
# the command keeps running in the guest and must be polled
# via exec-status instead of being treated as failed (a
# kubeadm join reset mid-flight is the failure this avoids).
sub exec_pending {
    my ($res) = @_;

    return 0 if !$res || ($res->{exited} // 0);
    return defined $res->{pid} || exists $res->{exited};
}

my sub guest_exec {
    my ($vmid, $shell_cmd) = @_;

    # noerr: qm exits non-zero when it hands back a pid for a
    # still-running command; the JSON payload is what matters.
    my $json = run(['qm', 'guest', 'exec', $vmid, '--timeout', 540,
        '--', '/bin/sh', '-c', $shell_cmd], noerr => 1, timeout => 600);
    # qm may prefix human notices ("timeout reached, returning
    # pid") ahead of the JSON payload.
    my $json_start = index($json, '{');
    $json = substr($json, $json_start) if $json_start > 0;
    my $res = eval { JSON::PP->new->decode($json) };
    die "guest exec on $vmid failed: $json\n" if !$res;
    my $pid = $res->{pid};
    for (1 .. 90) {
        last if !exec_pending($res);
        sleep 10;
        my $status = run(['qm', 'guest', 'exec-status', $vmid, $pid],
            noerr => 1, timeout => 600);
        my $next = eval { JSON::PP->new->decode($status) };
        die "guest exec-status on $vmid failed: $status\n" if !$next;
        $res = $next;
    }
    die "guest exec on $vmid did not finish: $json\n" if exec_pending($res);
    if (($res->{exitcode} // 1) != 0) {
        my $detail = ($res->{'err-data'} // '') . ($res->{'out-data'} // '');
        $detail =~ s/\s+$//;
        die "guest exec on $vmid failed (exit "
            . ($res->{exitcode} // '?') . "): $detail\n";
    }
    return $res->{'out-data'} // '';
}

my sub wait_agent {
    my ($vmid, $tries) = @_;

    for (1 .. ($tries // 80)) {
        return 1 if eval { qm('agent', $vmid, 'ping'); 1 };
        sleep 15;
    }
    die "guest agent on $vmid never came up\n";
}

my sub find_template {
    my ($k8s_version) = @_;

    # Templates are named k8s-node-<minor>-r<rev>; pick highest rev.
    my $list = qm('list');
    my ($best_id, $best_rev) = (undef, -1);
    for my $line (split /\n/, $list) {
        next if $line !~ /^\s*(\d+)\s+k8s-node-\Q$k8s_version\E-r(\d+)\s/;
        my ($id, $rev) = ($1, $2);
        ($best_id, $best_rev) = ($id, $rev) if $rev > $best_rev;
    }
    die "no template k8s-node-$k8s_version-r* found; build one first (images/)\n"
        if !defined $best_id;
    return $best_id;
}

my sub find_vmid_by_name {
    my ($name) = @_;

    for my $line (split /\n/, qm('list')) {
        return $1 if $line =~ /^\s*(\d+)\s+\Q$name\E\s/;
    }
    return undef;
}

my sub set_state {
    my ($name, $state) = @_;

    PVE::K8s::Config::lock_config(sub {
        my $cfg = PVE::K8s::Config->config();
        $cfg->{ids}->{$name}->{state} = $state;
        PVE::K8s::Config::store_config($cfg);
    });
}

my sub write_snippet {
    my ($file, $content) = @_;

    my $path = "/var/lib/vz/snippets/$file";
    open(my $fh, '>', $path) or die "open $path: $!\n";
    print {$fh} $content;
    close($fh) or die "write $path: $!\n";
    return "local:snippets/$file";
}

sub kube_vip_manifest {
    my ($vip, $iface) = @_;

    return <<EOF;
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  containers:
  - name: kube-vip
    image: ghcr.io/kube-vip/kube-vip:v0.8.4
    args: [manager]
    env:
    - {name: vip_arp, value: "true"}
    - {name: port, value: "6443"}
    - {name: vip_interface, value: "$iface"}
    - {name: vip_cidr, value: "32"}
    - {name: address, value: "$vip"}
    - {name: cp_enable, value: "true"}
    - {name: cp_namespace, value: "kube-system"}
    securityContext:
      capabilities: {add: [NET_ADMIN, NET_RAW]}
    volumeMounts:
    - {name: apiserver-certs, mountPath: /etc/kubernetes/pki}
    - {name: kubeconfig, mountPath: /etc/kubernetes/admin.conf}
  hostAliases:
  - {hostnames: [kubernetes], ip: 127.0.0.1}
  hostNetwork: true
  volumes:
  - {name: apiserver-certs, hostPath: {path: /etc/kubernetes/pki}}
  # type: File is essential: without it kubelet creates a
  # directory at the hostPath before kubeadm writes the file,
  # which then blocks kubeadm and kube-vip alike. admin.conf is
  # written by kubeadm init/join on every control-plane node; its
  # cluster-admin binding is created by the provisioner's init
  # completion step, after which kube-vip leader election works.
  - {name: kubeconfig, hostPath: {path: /etc/kubernetes/admin.conf, type: File}}
EOF
}

sub node_userdata {
    my (%a) = @_; # hostname, role, extra_runcmd, vip

    my $vip_manifest = $a{role} =~ /^cp/
        ? "  - path: /etc/kubernetes/manifests/kube-vip.yaml\n    content: |\n"
            . join('', map { "      $_\n" } split(/\n/, kube_vip_manifest($a{vip}, 'eth0')))
        : '';

    return <<EOF;
#cloud-config
hostname: $a{hostname}
manage_etc_hosts: true
users:
  - name: kube
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
write_files:
  # kube-vip talks to the local API server as "kubernetes" via
  # loopback; that name must resolve from the node's own hosts
  # file (pod hostAliases proved unreliable across restarts).
  - path: /etc/hosts
    append: true
    content: "127.0.0.1 kubernetes\n"
$vip_manifest
runcmd:
  # write_files runs before cloud-init regenerates /etc/hosts
  # (manage_etc_hosts), so assert the kubernetes name again in
  # the final stage, in the hosts file and in the template
  # cloud-init regenerates it from.
  - grep -q ' kubernetes$' /etc/hosts || echo '127.0.0.1 kubernetes' >> /etc/hosts
  - |
    T=/etc/cloud/templates/hosts.debian.tmpl
    grep -q ' kubernetes$' \$T || echo '127.0.0.1 kubernetes' >> \$T
  - systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true
  - systemctl mask apt-daily.service apt-daily-upgrade.service || true
  - systemctl enable --now containerd qemu-guest-agent kubelet
$a{extra_runcmd}
EOF
}

# cloud-init runcmd fragment for the first control-plane node.
# The cluster config stores only the Kubernetes minor (e.g. 1.31),
# but kubeadm rejects a bare minor as kubernetesVersion, so the
# full version is read from the kubeadm binary baked into the
# immutable template at boot time.
sub kubeadm_init_runcmd {
    my ($vip) = @_;

    return sprintf(<<'EOF', $vip);
  - |
    KVER=$(kubeadm version -o short)
    cat > /root/kubeadm-config.yaml <<YAML
    apiVersion: kubeadm.k8s.io/v1beta4
    kind: ClusterConfiguration
    kubernetesVersion: $KVER
    controlPlaneEndpoint: "%s:6443"
    networking: {podSubnet: "10.244.0.0/16"}
    etcd:
      local:
        extraArgs:
        - {name: heartbeat-interval, value: "500"}
        - {name: election-timeout, value: "5000"}
    YAML
    [ -f /etc/kubernetes/admin.conf ] || kubeadm init --config /root/kubeadm-config.yaml \
        --upload-certs
EOF
}

# kubeadm init can exit at the wait-control-plane phase on slow
# hosts before its late phases run (upload-config, bootstrap-token
# RBAC, kubelet-finalize, CoreDNS/kube-proxy addons). Those phases
# are idempotent, so the provisioner always runs them once the API
# answers; super-admin.conf works before the cluster-admins binding
# exists. CNI is applied here too, not from cloud-init, because at
# cloud-init time the VIP may not be up yet.
my sub local_kubeconfig_cmd {
    return <<'EOF';
IP=$(ip -o -4 route get 1.1.1.1 | sed -n 's/.*src \([0-9.]*\).*/\1/p') \
&& sed -E "s|server: https://[^ ]+:6443|server: https://$IP:6443|" \
    /etc/kubernetes/super-admin.conf > /root/local-super-admin.conf \
&& chmod 600 /root/local-super-admin.conf
EOF
}

# First completion step, via the local API endpoint: store the
# kubeadm config and create the admin user's ClusterRoleBinding.
# The VIP only comes up after this, because kube-vip leader
# election needs that binding, and cp1's kubelet needs the VIP to
# register its node object - which later phases require.
sub init_upload_config_cmd {
    my $kc = local_kubeconfig_cmd();
    chomp $kc;
    # A full kubeadm init creates the kubeadm:cluster-admins
    # ClusterRoleBinding as a side effect; run standalone, the
    # upload-config phase does not, so create it explicitly.
    # kube-vip leader election (admin.conf) and every later phase
    # depend on it.
    my $binding = <<'YAML';
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:cluster-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: kubeadm:cluster-admins
YAML
    chomp $binding;
    return "cd /root && $kc"
        . '&& kubeadm init phase upload-config kubeadm --config kubeadm-config.yaml'
        . ' --kubeconfig /root/local-super-admin.conf'
        . " && kubectl --kubeconfig /root/local-super-admin.conf apply -f - <<'BINDING'\n"
        . "$binding\nBINDING";
}

sub init_completion_cmd {
    my $kc = local_kubeconfig_cmd();
    chomp $kc;
    return "cd /root && $kc"
        . '&& kubeadm init phase upload-config kubelet --config kubeadm-config.yaml '
        . '--kubeconfig /root/local-super-admin.conf '
        . '&& kubeadm init phase bootstrap-token --config kubeadm-config.yaml '
        . '--kubeconfig /root/local-super-admin.conf '
        . '&& kubeadm init phase kubelet-finalize all --config kubeadm-config.yaml '
        . '&& kubeadm init phase addon all --config kubeadm-config.yaml '
        . '--kubeconfig /root/local-super-admin.conf';
}

# Full kubeadm join command for one node, run by the provisioner
# via the guest agent (not from cloud-init): control-plane joins
# in particular must be serialised and verified one at a time so
# stacked etcd never has two unsettled learners at once.
# Point kubeadm join discovery at a specific control-plane
# node's address instead of the VIP: discovery is a single
# cluster-info fetch with tight internal retries, and the VIP
# can flap while etcd membership is changing. The fetched
# cluster-info still carries the VIP endpoint for kubelet and
# all later phases.
sub join_endpoint_cmd {
    my ($join_cmd, $endpoint) = @_;

    $join_cmd =~ s/^kubeadm join \S+/kubeadm join $endpoint/;
    return $join_cmd;
}

sub join_command {
    my ($join_cmd, $cert_key, $is_cp) = @_;

    return $is_cp
        ? "$join_cmd --control-plane --certificate-key $cert_key"
        : $join_cmd;
}

# Scoped PVE API credentials for the in-cluster CCM (privileges
# per the upstream CCM install doc). The token is (re)created on
# every provision run and only ever stored in the in-cluster
# Secret, never in pmxcfs or on disk.
sub ensure_pve_token {
    my ($user, $token_name, $role, $privs, $privsep) = @_;

    # Role IDs starting with "PVE" are reserved for built-ins.
    run(['pveum', 'role', 'add', $role, '-privs', $privs], noerr => 1);
    run(['pveum', 'user', 'add', $user], noerr => 1);
    run(['pveum', 'aclmod', '/', '-user', $user, '-role', $role],
        noerr => 1);
    run(['pvesh', 'delete', "/access/users/$user/token/$token_name"],
        noerr => 1);
    my $out = run(['pvesh', 'create', "/access/users/$user/token/$token_name",
        '-privsep', $privsep, '--output-format', 'json']);
    # pvesh may print human notices ahead of the JSON payload.
    my $json_start = index($out, '{');
    die "PVE token creation returned no JSON: $out\n" if $json_start < 0;
    my $res = JSON::PP->new->decode(substr($out, $json_start));
    my $secret = $res->{value} or die "PVE token creation returned no value\n";
    if ($privsep) {
        run(['pveum', 'aclmod', '/', '-tokens', "$user!$token_name",
            '-role', $role], noerr => 1);
    }
    my $acl = JSON::PP->new->decode(
        run(['pvesh', 'get', '/access/acl', '--output-format', 'json']));
    my $want_ugid = $privsep ? "$user!$token_name" : $user;
    my ($granted) = grep {
        ($_->{ugid} // '') eq $want_ugid && ($_->{roleid} // '') eq $role
    } @$acl;
    die "$role role/ACL for $user did not land on this Proxmox host\n"
        if !$granted;
    return ("$user!$token_name", $secret);
}

sub ensure_ccm_credentials {
    my ($name) = @_;

    # VM.GuestAgent.Audit only exists on PVE 9; VM.Audit and
    # Sys.Audit are what the CCM needs on PVE 8 and 9 alike.
    return ensure_pve_token("k8s-$name\@pve", 'ccm', 'K8sCCM',
        'VM.Audit Sys.Audit', 0);
}

sub ensure_csi_credentials {
    my ($name) = @_;

    return ensure_pve_token("k8s-$name-csi\@pve", 'csi', 'K8sCSI',
        'VM.Audit VM.Config.Disk Datastore.Allocate '
        . 'Datastore.AllocateSpace Datastore.Audit', 1);
}

sub cluster_vm_names {
    my ($name, $cp_count, $workers) = @_;

    return (
        (map { "$name-cp$_" } 1 .. $cp_count),
        (map { "$name-w$_" } 1 .. $workers),
    );
}

# Every VM that belongs to the cluster, by name pattern. This
# also catches VMs from an earlier, larger layout.
my sub find_cluster_vmids {
    my ($name) = @_;

    my %vmids;
    for my $line (split /\n/, qm('list')) {
        if ($line =~ /^\s*(\d+)\s+(\Q$name\E-(?:cp|w)\d+)\s/) {
            $vmids{$2} = $1;
        }
    }
    return \%vmids;
}

my sub pve_user_exists {
    my ($user) = @_;

    my $out = run(['pveum', 'user', 'list'], noerr => 1);
    return $out =~ /\Q$user\E/;
}

# T1.7: destroy everything the cluster owns, then verify
# nothing is left before dropping the config entry. Order
# matters: VMs and their owned disks first (CSI volumes live
# and die with the node VMs), scoped CCM/CSI users next, the
# pmxcfs entry last, so a failed delete can simply be retried.
sub delete_cluster {
    my ($name) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";

    set_state($name, 'deleting');

    my $vmids = find_cluster_vmids($name);
    for my $vmname (sort keys $vmids->%*) {
        my $vmid = $vmids->{$vmname};
        eval { qm('stop', $vmid) };
        qm('destroy', $vmid, '--purge', '--destroy-unreferenced-disks', 1);
        unlink "/var/lib/vz/snippets/k8s-$vmname.yaml";
        print "destroyed $vmname (vmid $vmid) and its disks\n";
    }

    my $left = find_cluster_vmids($name);
    die "orphan VMs remain for cluster '$name': "
        . join(', ', sort keys $left->%*) . "\n"
        if $left->%*;

    for my $user ("k8s-$name\@pve", "k8s-$name-csi\@pve") {
        # the user config update can lag a moment behind the
        # delete, so poll instead of checking exactly once
        for (1 .. 6) {
            run(['pveum', 'user', 'delete', $user], noerr => 1);
            last if !pve_user_exists($user);
            sleep 5;
        }
        die "orphan PVE user '$user' remains for cluster '$name'\n"
            if pve_user_exists($user);
        print "removed scoped PVE user $user (tokens included)\n";
    }

    PVE::K8s::Config::lock_config(sub {
        my $locked = PVE::K8s::Config->config();
        delete $locked->{ids}->{$name};
        delete $locked->{order}->{$name};
        PVE::K8s::Config::store_config($locked);
    });
    print "cluster '$name' deleted: no orphan VMs, disks or users\n";
}

sub pve_cluster_region {
    my $out = run(['pvesh', 'get', '/cluster/status', '--output-format', 'json']);
    my $status = JSON::PP->new->decode($out);
    for my $entry (@$status) {
        return $entry->{name} if ($entry->{type} // '') eq 'cluster';
    }
    die "could not determine Proxmox cluster name\n";
}

# External cloud provider on the kubelet, as the CCM requires;
# idempotent and followed by a kubelet restart.
sub set_external_cloud_provider {
    my ($node) = @_;

    guest_exec($node->{vmid},
        'grep -q cloud-provider=external /var/lib/kubelet/kubeadm-flags.env '
        . '|| sed -i \'s/"$/ --cloud-provider=external"/\' '
        . '/var/lib/kubelet/kubeadm-flags.env; systemctl restart kubelet');
}

sub provision_cluster {
    my ($name) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";

    my $version = $scfg->{'k8s-version'};
    my $cp_count = $scfg->{cp} // 3;
    my $workers = $scfg->{workers} // 2;
    my $subnet = $scfg->{'node-subnet'}
        or die "cluster '$name' has no node-subnet configured\n";
    my $storage = $scfg->{storage} // 'local-zfs';

    $subnet =~ m|^(\d+\.\d+\.\d+)\.0/24$|
        or die "node-subnet must be a /24, got '$subnet'\n";
    my $prefix = $1;

    # Lab/lab-like addressing inside the /24: VIP at .59, control
    # plane from .60, workers from .70. (Real IPAM arrives with
    # the SDN integration in T1.5/T2.)
    my $vip = "$prefix.59";
    my $gateway = $scfg->{gateway} // "$prefix.1";

    set_state($name, 'provisioning');

    my $template = find_template($version);
    print "using template vmid $template for Kubernetes $version\n";

    my $total = $cp_count + $workers;
    my @nodes;
    for my $i (1 .. $cp_count) {
        push @nodes, {
            host => "$name-cp$i", role => 'cp', ip => "$prefix." . (59 + $i), idx => $i
        };
    }
    for my $i (1 .. $workers) {
        push @nodes, {
            host => "$name-w$i", role => 'worker', ip => "$prefix." . (69 + $i), idx => $i
        };
    }

    my $create_node = sub {
        my ($node, $userdata) = @_;

        my $vmname = $node->{host};
        my $vmid = find_vmid_by_name($vmname);
        if (!$vmid) {
            $vmid = run(['pvesh', 'get', '/cluster/nextid'], timeout => 60);
            $vmid =~ s/\D//g;
            qm('clone', $template, $vmid, '--name', $vmname);
            my $snippet = write_snippet("k8s-$vmname.yaml", $userdata);
            qm('set', $vmid,
                '--cicustom', "user=$snippet",
                '--ipconfig0', "ip=$node->{ip}/24,gw=$gateway",
                '--nameserver', '1.1.1.1',
                '--memory', $node->{role} eq 'cp' ? 3072 : 4096,
                '--cores', $node->{role} eq 'cp' ? 4 : 2,
            );
            qm('start', $vmid);
            print "created $vmname (vmid $vmid, $node->{ip})\n";
        } else {
            eval { qm('start', $vmid) };
            print "reusing $vmname (vmid $vmid)\n";
        }
        $node->{vmid} = $vmid;
        wait_agent($vmid);
        return $vmid;
    };

    # --- first control-plane node: kubeadm init
    my $cp1 = $nodes[0];
    $create_node->($cp1, node_userdata(
        hostname => $cp1->{host}, role => 'cp', vip => $vip,
        extra_runcmd => kubeadm_init_runcmd($vip),
    ));
    # kubeadm init runs inside cloud-init, which may still be
    # running (or retrying) when the guest agent first answers:
    # poll instead of failing on the first attempt.
    my $cp_ready = 0;
    for (1 .. 40) {
        $cp_ready = eval {
            guest_exec($cp1->{vmid},
                'test -f /etc/kubernetes/super-admin.conf && kubectl '
                . '--kubeconfig /etc/kubernetes/super-admin.conf '
                . "--server https://$cp1->{ip}:6443 get nodes >/dev/null");
            1;
        } // 0;
        last if $cp_ready;
        sleep 15;
    }
    die "control plane on $cp1->{host} did not initialise\n" if !$cp_ready;
    guest_exec($cp1->{vmid}, init_upload_config_cmd());
    # With the admin binding in place kube-vip can elect a leader
    # and bring up the VIP, which cp1's kubelet needs to register
    # its node object; later kubeadm phases require that object.
    my $node_seen = 0;
    for (1 .. 40) {
        my $out = eval {
            guest_exec($cp1->{vmid},
                'kubectl --kubeconfig /etc/kubernetes/super-admin.conf '
                . "--server https://$cp1->{ip}:6443 get nodes --no-headers");
        } // '';
        $node_seen = 1 if $out =~ /^\Q$cp1->{host}\E\s/m;
        last if $node_seen;
        sleep 15;
    }
    die "node $cp1->{host} never registered via the VIP\n" if !$node_seen;
    guest_exec($cp1->{vmid}, init_completion_cmd());
    guest_exec($cp1->{vmid},
        PVE::K8s::Addons::cilium_install_cmd('/root/local-super-admin.conf', $vip));
    set_external_cloud_provider($cp1);
    print "control plane initialised on $cp1->{host}\n";

    # --- join material from cp1
    my $join_cmd = guest_exec($cp1->{vmid}, 'kubeadm token create --print-join-command');
    chomp $join_cmd;
    $join_cmd = join_endpoint_cmd($join_cmd, "$cp1->{ip}:6443");
    my $cert_key = guest_exec($cp1->{vmid},
        'kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1');
    chomp $cert_key;

    # --- remaining control-plane nodes one at a time (stacked
    # etcd: never two joining members at once), then workers.
    # The join itself is run by the provisioner via the guest
    # agent and verified before the next node is touched.
    for my $node (@nodes[1 .. $#nodes]) {
        my $is_cp = $node->{role} eq 'cp';
        my $join = join_command($join_cmd, $cert_key, $is_cp);
        $create_node->($node, node_userdata(
            hostname => $node->{host}, role => $node->{role}, vip => $vip,
            extra_runcmd => '',
        ));
        my $joined = eval {
            guest_exec($node->{vmid}, 'test -f /etc/kubernetes/kubelet.conf');
            1;
        } // 0;
        if (!$joined) {
            my $last_error = '';
            for my $attempt (1 .. 3) {
                $joined = eval { guest_exec($node->{vmid}, $join); 1 } // 0;
                $last_error = $@ if !$joined;
                last if $joined;
                eval { guest_exec($node->{vmid}, 'kubeadm reset -f'); };
                sleep 20;
            }
            die "kubeadm join failed on $node->{host} after retries: $last_error\n"
                if !$joined;
        }
        # verify the node registered before joining the next one
        my $seen = 0;
        for (1 .. 40) {
            my $out = eval {
                guest_exec($cp1->{vmid},
                    'kubectl --kubeconfig /etc/kubernetes/super-admin.conf '
                    . "--server https://$cp1->{ip}:6443 get nodes --no-headers");
            } // '';
            $seen = 1 if $out =~ /^\Q$node->{host}\E\s/m;
            last if $seen;
            sleep 15;
        }
        die "$node->{host} joined but never registered with the API\n" if !$seen;
        set_external_cloud_provider($node);
        print "$node->{host} joined\n";
    }

    # --- Ready gate: all nodes Ready according to kubectl
    my $ready = 0;
    for (1 .. 40) {
        my $out = eval {
            guest_exec($cp1->{vmid},
                'kubectl --kubeconfig /root/local-super-admin.conf get nodes --no-headers');
        } // '';
        my @ready_nodes = grep { /\sReady\s/ } split /\n/, $out;
        $ready = scalar @ready_nodes;
        last if $ready >= $total;
        sleep 15;
    }
    die "only $ready/$total nodes Ready after waiting\n" if $ready < $total;

    # --- Proxmox CCM: scoped token in, providerIDs out
    my ($token_id, $token_secret) = ensure_ccm_credentials($name);
    my $ccm_config = PVE::K8s::Addons::ccm_config_yaml(
        "https://$gateway:8006/api2/json",
        $token_id, $token_secret, pve_cluster_region());
    # Nodes that predate the external kubelet flag never got the
    # uninitialized taint that makes the CCM initialise them
    # (providerID, addresses, taint removal); add it explicitly.
    for my $node (@nodes) {
        eval {
            guest_exec($cp1->{vmid},
                'kubectl --kubeconfig /root/local-super-admin.conf taint nodes '
                . "$node->{host} node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule "
                . '--overwrite');
        };
    }
    guest_exec($cp1->{vmid}, PVE::K8s::Addons::ccm_apply_cmd(
        '/root/local-super-admin.conf', $ccm_config));
    my $identified = 0;
    for (1 .. 40) {
        my $out = eval {
            guest_exec($cp1->{vmid},
                'kubectl --kubeconfig /root/local-super-admin.conf '
                . 'get nodes -o jsonpath=\'{range .items[*]}{.spec.providerID}{"\n"}{end}\'');
        } // '';
        my @ids = grep { /^proxmox:\/\// } split /\n/, $out;
        $identified = scalar @ids;
        last if $identified >= $total;
        sleep 15;
    }
    die "CCM set providerID on only $identified/$total nodes\n"
        if $identified < $total;
    print "CCM initialised $identified/$total nodes\n";

    # --- Proxmox CSI: shared-block (default) + local-block classes
    my ($csi_token_id, $csi_secret) = ensure_csi_credentials($name);
    my $csi_values = PVE::K8s::Addons::csi_values_yaml(
        "https://$gateway:8006/api2/json",
        $csi_token_id, $csi_secret, pve_cluster_region(), $storage);
    guest_exec($cp1->{vmid}, PVE::K8s::Addons::csi_install_cmd(
        '/root/local-super-admin.conf', $csi_values));
    my $csi_ok = 0;
    for (1 .. 20) {
        $csi_ok = eval {
            my $out = guest_exec($cp1->{vmid},
                'kubectl --kubeconfig /root/local-super-admin.conf get csidriver '
                . 'csi.proxmox.sinextra.dev -o name; '
                . 'kubectl --kubeconfig /root/local-super-admin.conf get sc '
                . '-o name');
            $out =~ /csidriver/ && $out =~ /shared-block/ && $out =~ /local-block/;
        } // 0;
        last if $csi_ok;
        sleep 15;
    }
    die "Proxmox CSI did not come up (driver or storage classes missing)\n"
        if !$csi_ok;
    print "Proxmox CSI installed (shared-block default, local-block)\n";

    # --- LoadBalancer pool from the cluster config, if configured
    if (my $range = $scfg->{'lb-range'}) {
        guest_exec($cp1->{vmid}, PVE::K8s::Addons::lb_apply_cmd(
            '/root/local-super-admin.conf',
            PVE::K8s::Addons::lb_pool_yaml($range)));
        print "LoadBalancer pool $range applied (Cilium LB IPAM, L2)\n";
    }

    set_state($name, 'ready');
    print "cluster '$name' ready: $ready/$total nodes\n";
    return $total;
}

1;
