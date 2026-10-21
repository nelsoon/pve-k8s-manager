# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Provision;

use strict;
use warnings;

use JSON::PP ();
use MIME::Base64 ();
use Time::Local ();

use PVE::Tools qw(run_command);

use PVE::K8s::Addons;
use PVE::K8s::Config;
use PVE::K8s::Scaler;

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

# --- multi-host placement (T2.1): VMs may live on any PVE
# host in the cluster. Cluster members trust each other's
# root SSH keys (pmxcfs-distributed), so remote qm/guest
# operations go over ssh with shell-quoted arguments.
my %VM_HOST;
my $LOCAL_NODE;

my sub shq {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub local_node_name {
    if (!$LOCAL_NODE) {
        $LOCAL_NODE = run(['hostname'], timeout => 30);
        $LOCAL_NODE =~ s/\s+//g;
    }
    return $LOCAL_NODE;
}

my sub qm_on {
    my ($host, @args) = @_;

    return qm(@args) if !$host || $host eq local_node_name();
    my $cmd = join ' ', 'qm', map { shq($_) } @args;
    return run(['ssh', '-o', 'BatchMode=yes', $host, $cmd], timeout => 600);
}

# Run an arbitrary command on a PVE host (local or via ssh).
my sub host_run_on {
    my ($host, @args) = @_;

    return run([@args], timeout => 120) if !$host || $host eq local_node_name();
    my $cmd = join ' ', map { shq($_) } @args;
    return run(['ssh', '-o', 'BatchMode=yes', $host, $cmd], timeout => 120);
}

# MTU of a bridge on a host; VXLAN SDN bridges are typically
# 1450, and guests left at 1500 blackhole larger packets.
my sub bridge_mtu_on {
    my ($host, $bridge) = @_;

    my $out = host_run_on($host, 'ip', '-o', 'link', 'show', $bridge);
    return $out =~ /mtu (\d+)/ ? int $1 : 1500;
}

# Like qm_on but never dies on non-zero exit (guest exec
# returns a pid with a non-zero status while still running).
my sub qm_raw_on {
    my ($host, @args) = @_;

    if (!$host || $host eq local_node_name()) {
        return run(['qm', @args], noerr => 1, timeout => 600);
    }
    my $cmd = join ' ', 'qm', map { shq($_) } @args;
    return run(['ssh', '-o', 'BatchMode=yes', $host, $cmd],
        noerr => 1, timeout => 600);
}

my sub host_of {
    my ($vmid) = @_;
    return $VM_HOST{$vmid} // local_node_name();
}

# pvesh can prefix human notices (e.g. "user config -
# ignore ...") ahead of the JSON payload on stdout; strip
# everything before the first JSON opener, like guest_exec
# already does for qm output.
sub decode_pvesh_json {
    my ($out) = @_;

    my @starts = grep { $_ >= 0 }
        map { index($out // '', $_) } ('[', '{');
    my $start = @starts ? (sort { $a <=> $b } @starts)[0] : undef;
    $out = substr($out, $start) if defined $start;
    return JSON::PP->new->decode($out);
}

# Online PVE node names from cluster status.
my sub pve_online_nodes {
    my $out = run(['pvesh', 'get', '/cluster/status',
        '--output-format', 'json'], timeout => 60);
    my $status = decode_pvesh_json($out);
    return [grep { defined }
        map { ($_->{type} // '') eq 'node' && ($_->{online} // 0) ? $_->{name} : undef }
        $status->@*];
}

# HA group per host (first group containing it), or undef.
# HA groups are Proxmox's fault-domain unit (there are no
# host labels), so placement spreads across them when set.
my sub ha_group_by_host {
    my $out = eval {
        run(['pvesh', 'get', '/cluster/ha/groups',
            '--output-format', 'json'], timeout => 60, noerr => 1);
    } // '[]';
    my $groups = eval { JSON::PP->new->decode($out) } // [];
    my %by_host;
    for my $group ($groups->@*) {
        for my $entry (split /,/, $group->{nodes} // '') {
            my ($host) = split /:/, $entry;
            $by_host{$host} //= $group->{group};
        }
    }
    return \%by_host;
}

# Cluster-wide VM inventory: name -> { vmid, node }.
my sub cluster_vms {
    my $out = run(['pvesh', 'get', '/cluster/resources',
        '--type', 'vm', '--output-format', 'json'], timeout => 60);
    my $res = decode_pvesh_json($out);
    my %vms;
    for my $vm ($res->@*) {
        next if !defined $vm->{name};
        # Validate through regex captures: values decoded from
        # JSON are tainted under the daemon's -T, and passing
        # them to exec (ssh/qm) dies with "Insecure dependency".
        next if ($vm->{vmid} // '') !~ /^(\d+)$/;
        my $vmid = $1;
        next if ($vm->{node} // '') !~ /^([a-zA-Z0-9._-]+)$/;
        my $node = $1;
        next if $vm->{name} !~ /^([a-zA-Z0-9._-]+)$/;
        $vms{$1} = { vmid => $vmid, node => $node };
        $VM_HOST{$vmid} = $node;
    }
    return \%vms;
}

# Placement scorer: control plane spreads first across HA
# groups, then across hosts; workers spread their own pool
# first, then overall load. Pure and unit-tested.
sub choose_host {
    my ($candidates, $group_of, $counts, $mode) = @_;

    my ($best, $best_key);
    for my $host ($candidates->@*) {
        my $group = $group_of->{$host} // $host;
        my $key = $mode eq 'cp'
            ? [ $counts->{"cp-group:$group"} // 0,
                $counts->{"cp:$host"} // 0,
                $counts->{"total:$host"} // 0 ]
            : [ $counts->{"pool:$host"} // 0,
                $counts->{"total:$host"} // 0 ];
        my $better = !$best;
        if ($best) {
            for my $i (0 .. $key->$#*) {
                next if $key->[$i] == $best_key->[$i];
                $better = $key->[$i] < $best_key->[$i];
                last;
            }
        }
        ($best, $best_key) = ($host, $key) if $better;
    }
    return $best;
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

# In-cluster add-ons (CCM/CSI) call back into the PVE API.
# They must use a real host address: the node gateway is a
# host interface in the L2/VXLAN design but only an anycast
# SVI inside a VRF in the EVPN design, where no pveproxy
# listens. Resolve this host's own name (its management IP)
# and fall back to the gateway for exotic setups.
sub pve_api_url {
    my ($gateway) = @_;

    require Sys::Hostname;
    my $name = Sys::Hostname::hostname();
    my @addr = gethostbyname($name);
    if (@addr > 4) {
        for my $packed (@addr[4 .. $#addr]) {
            my $ip = join('.', unpack('C4', $packed));
            return "https://$ip:8006/api2/json"
                if $ip !~ /^127\./;
        }
    }
    return "https://$gateway:8006/api2/json";
}

my sub guest_exec {
    my ($vmid, $shell_cmd) = @_;

    # noerr: qm exits non-zero when it hands back a pid for a
    # still-running command; the JSON payload is what matters.
    my $json = qm_raw_on(host_of($vmid), 'guest', 'exec', $vmid,
        '--timeout', 540, '--', '/bin/sh', '-c', $shell_cmd) // '';
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
        my $status = qm_raw_on(host_of($vmid), 'guest', 'exec-status',
            $vmid, $pid);
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
        return 1 if eval { qm_on(host_of($vmid), 'agent', $vmid, 'ping'); 1 };
        sleep 15;
    }
    die "guest agent on $vmid never came up\n";
}

# Templates are named k8s-node-<minor>-r<rev>; pick highest rev.
sub find_template_in_list {
    my ($list, $k8s_version) = @_;

    my ($best_id, $best_rev) = (undef, -1);
    for my $line (split /\n/, $list // '') {
        next if $line !~ /^\s*(\d+)\s+k8s-node-\Q$k8s_version\E-r(\d+)\s/;
        my ($id, $rev) = ($1, $2);
        ($best_id, $best_rev) = ($id, $rev) if $rev > $best_rev;
    }
    return ($best_id, $best_rev);
}

my sub find_template {
    my ($k8s_version) = @_;

    my ($best_id) = find_template_in_list(qm('list'), $k8s_version);
    die "no template k8s-node-$k8s_version-r* found; build one first (images/)\n"
        if !defined $best_id;
    return $best_id;
}

# Template distribution (T2.1): on nothing-shared storage a
# copy is made lazily, once per revision, only on hosts where
# a node is placed (clone locally, migrate the copy, mark it
# template there); shared storage needs no copies at all.
my sub ensure_template_on {
    my ($host, $k8s_version, $canon_id) = @_;

    return $canon_id if $host eq local_node_name();
    my ($canon_rev) = (find_template_in_list(qm('list'), $k8s_version))[1];
    my ($existing, $existing_rev) = find_template_in_list(
        qm_on($host, 'list'), $k8s_version);
    return $existing if defined $existing && $existing_rev >= $canon_rev;
    my $tpl_name = "k8s-node-$k8s_version-r$canon_rev";
    # a previous distribution that died mid-migrate leaves a
    # local copy behind; remove it before making a fresh one
    for my $line (split /\n/, qm('list')) {
        if ($line =~ /^\s*(\d+)\s+\Q$tpl_name\E\s/ && $1 != $canon_id) {
            # never destroy a VM that is itself marked template
            my $other = qm('config', $1);
            next if $other =~ /^template:/m;
            print "removing stale template copy $1\n";
            qm('destroy', $1, '--purge');
        }
    }
    my $copy_id = run(['pvesh', 'get', '/cluster/nextid'], timeout => 60);
    $copy_id =~ s/\D//g;
    print "distributing template copy to $host (vmid $copy_id)\n";
    # full clone: a linked clone cannot migrate to another host
    qm('clone', $canon_id, $copy_id, '--full', 1, '--name', $tpl_name);
    run(['qm', 'migrate', $copy_id, $host, '--with-local-disks', 1],
        timeout => 3600);
    qm_on($host, 'template', $copy_id);
    # prune the superseded revision copy on this host
    if (defined $existing && $existing != $copy_id) {
        eval { qm_on($host, 'destroy', $existing, '--purge') };
        print "pruned stale template r$existing_rev on $host\n";
    }
    return $copy_id;
}

my sub find_vmid_by_name {
    my ($name) = @_;

    my $vms = cluster_vms();
    my $vm = $vms->{$name} or return undef;
    return $vm->{vmid};
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

# Snippets live on the target host's local storage.
my sub write_snippet_on {
    my ($host, $file, $content) = @_;

    return write_snippet($file, $content) if $host eq local_node_name();
    my $b64 = MIME::Base64::encode_base64($content, '');
    run(['ssh', '-o', 'BatchMode=yes', $host,
        "mkdir -p /var/lib/vz/snippets && echo $b64 | base64 -d "
        . "> /var/lib/vz/snippets/$file"], timeout => 120);
    return "local:snippets/$file";
}

my sub remove_snippet_on {
    my ($host, $file) = @_;

    if ($host eq local_node_name()) {
        unlink "/var/lib/vz/snippets/$file";
    } else {
        run(['ssh', '-o', 'BatchMode=yes', $host,
            "rm -f /var/lib/vz/snippets/$file"],
            timeout => 60, noerr => 1);
    }
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

    my $enc_file = '';
    if ($a{role} =~ /^cp/ && $a{enc_key}) {
        my $yaml = encryption_config_yaml($a{enc_key});
        $enc_file = "  - path: /etc/kubernetes/enc/enc.yaml\n"
            . "    permissions: '0600'\n    content: |\n"
            . join('', map { "      $_\n" } split(/\n/, $yaml));
    }

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
$vip_manifest$enc_file
runcmd:
  # write_files runs before cloud-init regenerates /etc/hosts
  # (manage_etc_hosts), so assert the kubernetes name again in
  # the final stage, in the hosts file and in the template
  # cloud-init regenerates it from.
  - grep -q ' kubernetes\$' /etc/hosts || echo '127.0.0.1 kubernetes' >> /etc/hosts
  - |
    T=/etc/cloud/templates/hosts.debian.tmpl
    grep -q ' kubernetes\$' \$T || echo '127.0.0.1 kubernetes' >> \$T
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
# Etcd encryption at rest (T3.2): one plugin-managed key
# per cluster, kept as a 0600 file in pmxcfs (replicated to
# every PVE host, never exposed through the API). Written
# into each control-plane node's EncryptionConfiguration
# at creation; the kubeadm ClusterConfiguration points the
# apiserver at it. Clusters created before this existed
# simply never get the apiserver argument (their init is
# long done) - encryption is a create-time property in v1.
sub cluster_encryption_key {
    my ($name) = @_;

    my $key;
    PVE::K8s::Config::lock_config(sub {
        my $dir = '/etc/pve/k8s/keys';
        mkdir $dir if !-d $dir;
        my $file = "$dir/$name.key";
        if (open my $fh, '<', $file) {
            $key = <$fh>;
            close $fh;
            $key =~ s/\s+//g if $key;
        }
        if (!$key) {
            open my $rnd, '<', '/dev/urandom'
                or die "open /dev/urandom: $!\n";
            binmode $rnd;
            my $raw = '';
            read($rnd, $raw, 32) == 32
                or die "could not read 32 random bytes\n";
            close $rnd;
            $key = MIME::Base64::encode_base64($raw, '');
            open my $fh, '>', $file or die "$file: $!\n";
            chmod 0600, $file;
            print $fh "$key\n";
            close $fh or die "$file: $!\n";
        }
    });
    return $key;
}

sub encryption_config_yaml {
    my ($key) = @_;

    return <<EOF;
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - aescbc:
          keys:
            - name: pve-k8s-1
              secret: $key
      - identity: {}
EOF
}

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
    apiServer:
      extraArgs:
      - {name: encryption-provider-config, value: /etc/kubernetes/enc/enc.yaml}
      extraVolumes:
      - name: enc
        hostPath: /etc/kubernetes/enc
        mountPath: /etc/kubernetes/enc
        readOnly: true
        pathType: DirectoryOrCreate
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
        # if cloud-init's kubeadm init died before its own
        # mark step (slow lab image pulls did exactly this),
        # the node has no control-plane label/taint and the
        # CCM (which selects CP nodes) can never schedule
        . '&& kubectl --kubeconfig /root/local-super-admin.conf '
        . 'label node $(hostname) '
        . 'node-role.kubernetes.io/control-plane= --overwrite '
        . '&& kubectl --kubeconfig /root/local-super-admin.conf '
        . 'taint node $(hostname) '
        . 'node-role.kubernetes.io/control-plane:NoSchedule '
        . '--overwrite '
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

# Every VM that belongs to the cluster, cluster-wide by name
# pattern (<cluster>-<node>). This also catches VMs from an
# earlier, larger layout and from any pool naming.
my sub find_cluster_vmids {
    my ($name) = @_;

    my $vms = cluster_vms();
    my %found;
    for my $vmname (keys $vms->%*) {
        next if $vmname !~ /^\Q$name\E-/;
        $found{$vmname} = $vms->{$vmname};
    }
    return \%found;
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
# --- T3.4 re-spec: dedicated per-cluster SDN VNet -------
# With sdn-zone + public-subnet set, a cluster gets its own
# VNet inside the tenant's EVPN zone: the node subnet is
# internal (never meant to be advertised), the public
# subnet carries LB IPs and the apiserver VIP and is the
# only range that leaves the VRF (whole-subnet via exit
# nodes, or per-address in an EVPN fabric). The zone is
# the tenant boundary and is created by the SDN admin,
# once; the plugin owns the per-cluster VNet lifecycle.
# EXPERIMENTAL until the delayed nested-lab SDN proof
# runs (pvesh SDN shapes are written against the PVE API
# but not yet exercised end to end).

my sub sdn_get {
    my ($path) = @_;

    return decode_pvesh_json(run(
        ['pvesh', 'get', $path, '--output-format', 'json'],
        timeout => 60));
}

my sub record_sdn_identity {
    my ($name, $vnet, $vni) = @_;

    PVE::K8s::Config::lock_config(sub {
        my $cfg = PVE::K8s::Config->config();
        $cfg->{ids}->{$name}->{'sdn-vnet'} = $vnet;
        $cfg->{ids}->{$name}->{'sdn-vni'} = $vni;
        PVE::K8s::Config::store_config($cfg);
    });
}

my sub ensure_cluster_vnet {
    my ($name, $scfg) = @_;

    my $zone = $scfg->{'sdn-zone'} or return undef;
    my $vnet = PVE::K8s::Config::cluster_vnet_name($name);

    my $zones = sdn_get('/cluster/sdn/zones');
    my ($z) = grep { ($_->{zone} // '') eq $zone } $zones->@*;
    die "SDN zone '$zone' does not exist; create the tenant "
        . "EVPN zone once (SDN admin task) before provisioning\n"
        if !$z;
    die "SDN zone '$zone' is type '$z->{type}', not evpn: "
        . "dedicated cluster VNets need an EVPN zone "
        . "(T3.4 re-spec)\n"
        if ($z->{type} // '') ne 'evpn';

    my $vnets = sdn_get('/cluster/sdn/vnets');
    my ($existing) = grep { ($_->{vnet} // '') eq $vnet }
        $vnets->@*;
    my $vni = $scfg->{'sdn-vni'};
    if (!$existing) {
        if (!$vni) {
            my %used = map { ($_->{tag} // 0) => 1 } $vnets->@*;
            $vni = 10000;
            $vni++ while $used{$vni};
        }
        run(['pvesh', 'create', '/cluster/sdn/vnets',
            '--vnet', $vnet, '--zone', $zone,
            '--tag', $vni, '--alias', $name], timeout => 60);
        print "created SDN VNet $vnet (zone $zone, VNI $vni) "
            . "for cluster '$name'\n";
    }
    $vni //= $existing->{tag};
    record_sdn_identity($name, $vnet, $vni)
        if ($scfg->{'sdn-vnet'} // '') ne $vnet
            || ($scfg->{'sdn-vni'} // 0) != ($vni // 0);

    my $subnets = sdn_get("/cluster/sdn/vnets/$vnet/subnets");
    my %have = map { ($_->{subnet} // '') => 1 } $subnets->@*;
    for my $cidr ($scfg->{'node-subnet'},
                  $scfg->{'public-subnet'}) {
        next if $have{$cidr};
        my ($gw) = $cidr =~ m|^(\d+\.\d+\.\d+\.)0/24$|;
        run(['pvesh', 'create', "/cluster/sdn/vnets/$vnet/subnets",
            '--type', 'subnet', '--subnet', $cidr,
            '--gateway', "${gw}1", '--snat', 0], timeout => 60);
        print "created subnet $cidr in VNet $vnet\n";
    }
    run(['pvesh', 'set', '/cluster/sdn'], timeout => 120);
    return $vnet;
}

my sub remove_cluster_vnet {
    my ($name, $scfg) = @_;

    my $vnet = $scfg->{'sdn-vnet'} or return;
    my $ok = eval {
        my $subnets = sdn_get("/cluster/sdn/vnets/$vnet/subnets");
        for my $sn ($subnets->@*) {
            run(['pvesh', 'delete',
                "/cluster/sdn/vnets/$vnet/subnets/$sn->{id}"],
                timeout => 60);
        }
        run(['pvesh', 'delete', "/cluster/sdn/vnets/$vnet"],
            timeout => 60);
        run(['pvesh', 'set', '/cluster/sdn'], timeout => 120);
        1;
    };
    print $ok
        ? "removed SDN VNet $vnet of cluster '$name'\n"
        : "WARNING: SDN VNet $vnet of cluster '$name' could "
            . "not be removed; delete it by hand in SDN\n";
}

# Bridge node VMs attach to: the dedicated VNet when the
# cluster has one recorded, else undef (template default).
my sub cluster_bridge {
    my ($scfg) = @_;

    return $scfg->{'sdn-vnet'};
}

sub delete_cluster {
    my ($name) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";

    set_state($name, 'deleting');

    my $vmids = find_cluster_vmids($name);
    for my $vmname (sort keys $vmids->%*) {
        my ($vmid, $host) = $vmids->{$vmname}->@{qw(vmid node)};
        eval { qm_on($host, 'stop', $vmid) };
        qm_on($host, 'destroy', $vmid, '--purge',
            '--destroy-unreferenced-disks', 1);
        remove_snippet_on($host, "k8s-$vmname.yaml");
        print "destroyed $vmname (vmid $vmid on $host) and its disks\n";
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

    remove_cluster_vnet($name, $scfg);

    PVE::K8s::Config::lock_config(sub {
        my $locked = PVE::K8s::Config->config();
        delete $locked->{ids}->{$name};
        delete $locked->{order}->{$name};
        PVE::K8s::Config::store_config($locked);
        # the etcd encryption key is the cluster master key:
        # it must not outlive the cluster it protects
        my $key_file = "/etc/pve/k8s/keys/$name.key";
        unlink $key_file if -e $key_file;
    });
    print "cluster '$name' deleted: no orphan VMs, disks or users\n";
}

sub pve_cluster_region {
    my $out = run(['pvesh', 'get', '/cluster/status', '--output-format', 'json']);
    my $status = decode_pvesh_json($out);
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

# Node list for a cluster from its config: control plane
# first, then workers pool by pool. Shared by provisioning,
# rolling and upgrades.
sub cluster_nodes {
    my ($name, $scfg, $prefix) = @_;

    my $pools = PVE::K8s::Config::parse_pools(
        $scfg->{pools}, $scfg->{workers} // 2);
    my @nodes;
    for my $i (1 .. ($scfg->{cp} // 3)) {
        push @nodes, {
            host => "$name-cp$i", role => 'cp', pool => 'control-plane',
            ip => "$prefix." . (59 + $i), idx => $i
        };
    }
    my $worker_ip = 69;
    for my $pool ($pools->@*) {
        for my $i (1 .. $pool->{size}) {
            my $vmname = $pool->{name} eq 'default'
                ? "$name-w" . ($worker_ip - 68)
                : "$name-$pool->{name}$i";
            push @nodes, {
                host => $vmname, role => 'worker', pool => $pool->{name},
                pool_hosts => $pool->{hosts},
                labels => $pool->{labels}, taints => $pool->{taints},
                pool_storage => $pool->{storage},
                ip => "$prefix." . (++$worker_ip), idx => $i,
            };
        }
    }
    return \@nodes;
}

# Record the node inventory in the cluster config so rolls,
# upgrades and the UI know what is running where.
my sub store_inventory {
    my ($name, $nodes, $rev) = @_;

    my @inventory = map {
        { name => $_->{host}, vmid => $_->{vmid}, pvehost => $_->{pvehost},
          pool => $_->{pool}, ip => $_->{ip}, rev => $_->{rev} // $rev }
    } $nodes->@*;
    PVE::K8s::Config::lock_config(sub {
        my $cfg = PVE::K8s::Config->config();
        $cfg->{ids}->{$name}->{nodes} =
            JSON::PP->new->canonical->encode(\@inventory);
        $cfg->{ids}->{$name}->{'template-rev'} = $rev;
        PVE::K8s::Config::store_config($cfg);
    });
}

# Clone (or reuse) one node VM on its placed host and wait
# for its guest agent. $ctx: { version, template, gateway }.
sub create_node_vm {
    my ($ctx, $node, $userdata) = @_;

    my ($version, $template, $gateway) =
        $ctx->@{qw(version template gateway)};
    my $vmname = $node->{host};
    my $target = $node->{pvehost};
    # Reuse is decided by where the VM actually is, never
    # by the placement guess: the aggregated cluster view
    # can lag a loaded host, and cloning then would create
    # a duplicate name/IP (seen in the lab, 2026-10-19).
    # If the aggregate misses it, ask every online host
    # directly before believing the VM does not exist.
    my $vm = cluster_vms()->{$vmname};
    if (!$vm) {
        for my $host (pve_online_nodes()->@*) {
            my $list = eval { qm_on($host, 'list') } // '';
            if ($list =~ /^\s*(\d+)\s+\Q$vmname\E\s/m) {
                $vm = { vmid => $1, node => $host };
                last;
            }
        }
    }
    my $vmid = $vm ? $vm->{vmid} : undef;
    if ($vm) {
        $target = $vm->{node};
        $node->{pvehost} = $target;
    }
    if (!$vmid) {
        my $tpl = ensure_template_on($target, $version, $template);
        $vmid = run(['pvesh', 'get', '/cluster/nextid'], timeout => 60);
        $vmid =~ s/\D//g;
        $VM_HOST{$vmid} = $target;
        # Full clone, always: a linked clone's disk stays
        # chained to the template base on that host's local
        # storage, and PVE then refuses to migrate the VM
        # anywhere (found by T3.5 host evacuation).
        my @clone = ('clone', $tpl, $vmid, '--name', $vmname,
            '--full', 1);
        push @clone, '--storage', $node->{pool_storage}
            if $node->{pool_storage};
        qm_on($target, @clone);
        # Dedicated-VNet clusters (T3.4 re-spec) attach to
        # their own VNet, not the template's shared bridge.
        if (my $bridge = $ctx->{bridge}) {
            my $pre = qm_on($target, 'config', $vmid);
            my ($mac) = $pre =~ /net0: virtio=([0-9A-Fa-f:]+)/;
            qm_on($target, 'set', $vmid, '--net0',
                "virtio=$mac,bridge=$bridge") if $mac;
        }
        # match the guest MTU to the bridge (VXLAN SDN
        # bridges run below 1500; larger packets blackhole)
        my $vmcfg = qm_on($target, 'config', $vmid);
        if ($vmcfg =~ /net0: virtio=([0-9A-Fa-f:]+),bridge=([^\s,]+)/) {
            my ($mac, $bridge) = ($1, $2);
            my $mtu = bridge_mtu_on($target, $bridge);
            qm_on($target, 'set', $vmid, '--net0',
                "virtio=$mac,bridge=$bridge,mtu=$mtu") if $mtu < 1500;
        }
        # A migrated template copy can lose or mangle its
        # cloud-init drive; without it the guest finds no
        # datasource and never configures network or userdata.
        my $storage = $node->{pool_storage} // $ctx->{storage}
            // 'local-zfs';
        if ($vmcfg !~ /^ide2: .*cloudinit/m) {
            qm_on($target, 'set', $vmid, '--ide2', "$storage:cloudinit");
        }
        my $snippet = write_snippet_on($target,
            "k8s-$vmname.yaml", $userdata);
        qm_on($target, 'set', $vmid,
            '--cicustom', "user=$snippet",
            '--ipconfig0', "ip=$node->{ip}/24,gw=$gateway",
            '--nameserver', '1.1.1.1',
            '--memory', $node->{role} eq 'cp' ? 3072 : 4096,
            '--cores', $node->{role} eq 'cp' ? 4 : 2,
        );
        qm_on($target, 'start', $vmid);
        print "created $vmname (vmid $vmid on $target, $node->{ip})\n";
    } else {
        $VM_HOST{$vmid} = $target;
        eval { qm_on($target, 'start', $vmid) };
        print "reusing $vmname (vmid $vmid on $target)\n";
    }
    $node->{vmid} = $vmid;
    wait_agent($vmid);
    return $vmid;
}

# Provisioning (and anything built on it, like the scaler)
# must never run while a host carrying THIS cluster's nodes
# is offline: that host's VMs vanish from the cluster-wide
# inventory, and the provisioner would recreate live nodes
# on other hosts - duplicate names and IPs (seen in the
# lab, 2026-10-18). Offline hosts with no nodes of this
# cluster are fine; placement only picks online hosts, so
# a 19-of-20-hosts cluster still provisions normally and
# the down host simply receives nothing.
my sub assert_cluster_hosts_online {
    my ($name, $scfg) = @_;

    my $out = run(['pvesh', 'get', '/cluster/status',
        '--output-format', 'json'], timeout => 60);
    my $status = decode_pvesh_json($out);
    my %offline = map { $_->{name} => 1 }
        grep { ($_->{type} // '') eq 'node' && !($_->{online} // 0) }
        $status->@*;
    return if !%offline;

    # Hosts already carrying this cluster's nodes are the
    # only hard stop; other offline hosts are simply skipped
    # by placement (it already chooses among online hosts).
    my %cluster_hosts;
    if ($scfg->{nodes}) {
        my $inventory = eval {
            JSON::PP->new->decode($scfg->{nodes}) } // [];
        $cluster_hosts{$_->{pvehost}} = 1 for $inventory->@*;
    } else {
        my $vms = cluster_vms();
        for my $vmname (keys $vms->%*) {
            $cluster_hosts{$vms->{$vmname}{node}} = 1
                if $vmname =~ /^\Q$name\E-/;
        }
    }
    my @blocking = grep { $cluster_hosts{$_} } sort keys %offline;
    die "Proxmox host(s) offline: " . join(', ', @blocking)
        . "; they host nodes of cluster '$name', whose VMs "
        . "would look missing and be recreated elsewhere. "
        . "Refusing to provision until they are back\n"
        if @blocking;
    my @skipped = sort keys %offline;
    print "note: Proxmox host(s) offline: "
        . join(', ', @skipped)
        . "; placement will skip them\n";
}

sub check_retired_ghosts;

sub provision_cluster {
    my ($name) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";

    assert_cluster_hosts_online($name, $scfg);
    check_retired_ghosts($name, $scfg);

    my $version = $scfg->{'k8s-version'};
    my $cp_count = $scfg->{cp} // 3;
    my $workers = $scfg->{workers} // 2;
    my $subnet = $scfg->{'node-subnet'}
        or die "cluster '$name' has no node-subnet configured\n";
    my $storage = $scfg->{storage} // 'local-zfs';

    $subnet =~ m|^(\d+\.\d+\.\d+)\.0/24$|
        or die "node-subnet must be a /24, got '$subnet'\n";
    my $prefix = $1;

    # Addressing inside the /24: node IPs from .60 (CP) and
    # .70 (workers); the apiserver VIP at .59 of the public
    # subnet in dedicated-VNet mode, else of the node subnet.
    my $vip = PVE::K8s::Config::vip_for($scfg);
    my $gateway = $scfg->{gateway} // "$prefix.1";

    set_state($name, 'provisioning');

    # Dedicated per-cluster VNet first (T3.4 re-spec), so
    # node VMs can attach to it. No-op in shared-VNet mode.
    my $bridge = ensure_cluster_vnet($name, $scfg);

    my $template = find_template($version);
    print "using template vmid $template for Kubernetes $version\n";
    my $ctx = { version => $version, template => $template,
        gateway => $gateway, storage => $storage,
        bridge => $bridge };

    my @nodes = cluster_nodes($name, $scfg, $prefix)->@*;
    my $total = scalar @nodes;

    # --- placement (T2.1): spread CP across HA groups, then
    # hosts (strictly distinct when enough hosts exist); spread
    # each worker pool softly. Existing VMs keep their host.
    my $hosts = pve_online_nodes();
    $hosts = [local_node_name()] if !$hosts->@*;
    my $group_of = ha_group_by_host();
    if ($cp_count > 1 && $cp_count > scalar $hosts->@*) {
        print "WARNING: $cp_count control-plane nodes but only "
            . scalar($hosts->@*) . " PVE hosts online; CP anti-affinity "
            . "cannot be strict for cluster '$name'\n";
    }
    my $existing = cluster_vms();
    my %counts;
    for my $node (@nodes) {
        my $host;
        if (my $vm = $existing->{$node->{host}}) {
            $host = $vm->{node};
        } else {
            my $candidates = $hosts;
            if ($node->{pool_hosts}) {
                my %allowed = map { $_ => 1 }
                    grep { length } split /\s*,\s*/, $node->{pool_hosts};
                $candidates = [grep { $allowed{$_} } $hosts->@*];
                die "pool '$node->{pool}' placement hosts match no online "
                    . "PVE node\n" if !$candidates->@*;
            }
            my %pool_counts = map { ("pool:$_" => $counts{"pool:$node->{pool}:$_"} // 0) }
                $candidates->@*;
            $host = choose_host($candidates, $group_of,
                { %counts, %pool_counts },
                $node->{role} eq 'cp' ? 'cp' : 'worker');
        }
        $node->{pvehost} = $host;
        $node->{site} = $group_of->{$host} // $host;
        my $group = $group_of->{$host} // $host;
        $counts{"total:$host"}++;
        $counts{"cp:$host"}++ if $node->{role} eq 'cp';
        $counts{"cp-group:$group"}++ if $node->{role} eq 'cp';
        $counts{"pool:$node->{pool}:$host"}++;
        print "placement: $node->{host} -> $host (site $node->{site})\n";
    }

    # --- first control-plane node: kubeadm init
    my $cp1 = $nodes[0];
    my $enc_key = cluster_encryption_key($name);
    create_node_vm($ctx, $cp1, node_userdata(
        hostname => $cp1->{host}, role => 'cp', vip => $vip,
        enc_key => $enc_key,
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
    # The VIP answers now, so point join discovery at it before
    # any node joins: kubeadm writes the discovery endpoint
    # into each node's kubelet.conf, and a node address there
    # would strand every kubelet when that node is replaced.
    guest_exec($cp1->{vmid},
        'kubeadm init phase bootstrap-token '
        . '--kubeconfig /etc/kubernetes/admin.conf');
    guest_exec($cp1->{vmid},
        PVE::K8s::Addons::cilium_install_cmd(
            '/root/local-super-admin.conf', $vip));
    set_external_cloud_provider($cp1);
    print "control plane initialised on $cp1->{host}\n";

    # --- join material from cp1 (discovery via the VIP, so
    # kubelet.conf on joined nodes names the VIP, not cp1)
    my $join_cmd = guest_exec($cp1->{vmid}, 'kubeadm token create --print-join-command');
    chomp $join_cmd;
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
        create_node_vm($ctx, $node, node_userdata(
            hostname => $node->{host}, role => $node->{role}, vip => $vip,
            enc_key => $is_cp ? $enc_key : undef,
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

    # Point join discovery at the VIP from the start:
    # cluster-info was created from the local endpoint during
    # bootstrap and would otherwise name cp1's address forever.
    eval {
        guest_exec($cp1->{vmid},
            'kubeadm init phase bootstrap-token '
            . '--kubeconfig /etc/kubernetes/admin.conf');
    };

    # --- pool labels/taints and site topology (T2.1)
    for my $node (@nodes) {
        my @label = ("pve-k8s.proxmox.com/pool=$node->{pool}",
            "topology.pve-k8s.proxmox.com/site=$node->{site}");
        push @label, grep { /^[a-zA-Z0-9.\/-]+=[^,]+$/ }
            split /\s*,\s*/, $node->{labels} // '';
        guest_exec($cp1->{vmid},
            'kubectl --kubeconfig /root/local-super-admin.conf label nodes '
            . "$node->{host} " . join(' ', @label) . ' --overwrite');
        if ($node->{taints}) {
            my $effect = '(NoSchedule|NoExecute|PreferNoSchedule)';
            my @taint = grep { /^[a-zA-Z0-9.\/-]+(=[^:,]*)?:$effect$/
                || /^[a-zA-Z0-9.\/-]+:$effect$/ }
                split /\s*,\s*/, $node->{taints};
            guest_exec($cp1->{vmid},
                'kubectl --kubeconfig /root/local-super-admin.conf taint nodes '
                . "$node->{host} " . join(' ', @taint) . ' --overwrite')
                if @taint;
        }
        print "labelled $node->{host} pool=$node->{pool} site=$node->{site}\n";
    }

    # --- Proxmox CCM: scoped token in, providerIDs out
    my ($token_id, $token_secret) = ensure_ccm_credentials($name);
    my $ccm_config = PVE::K8s::Addons::ccm_config_yaml(
        pve_api_url($gateway),
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
        pve_api_url($gateway),
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

    # --- LoadBalancer pool: explicit lb-range, else the
    # public subnet's .100-.120 in dedicated-VNet mode.
    my $range = $scfg->{'lb-range'};
    if (!$range && $scfg->{'public-subnet'}) {
        my ($pp) = $scfg->{'public-subnet'}
            =~ m|^(\d+\.\d+\.\d+)\.0/24$|;
        $range = "$pp.100-$pp.120" if $pp;
    }
    if ($range) {
        guest_exec($cp1->{vmid}, PVE::K8s::Addons::lb_apply_cmd(
            '/root/local-super-admin.conf',
            PVE::K8s::Addons::lb_pool_yaml($range)));
        print "LoadBalancer pool $range applied "
            . "(Cilium LB IPAM, L2 announcement)\n";
    }

    my (undef, $template_rev) = find_template_in_list(qm('list'), $version);
    store_inventory($name, \@nodes, $template_rev);
    set_state($name, 'ready');
    print "cluster '$name' ready: $ready/$total nodes\n";
    return $total;
}

# --- Rolling engine (T2.2) and minor upgrades (T2.3) --------
# Nodes are immutable: a roll replaces each node whose template
# revision (or Kubernetes version) is behind, one at a time,
# surging a replacement in before draining the old node out.
# Control plane goes first, at most one at a time (maxSurge=1),
# and only after an etcd snapshot exists.

sub in_maintenance_window {
    my ($window, $now) = @_;

    return 1 if !$window;
    my ($sh, $sm, $eh, $em) = $window =~ /^(\d\d):(\d\d)-(\d\d):(\d\d)$/
        or die "maintenance-window must be HH:MM-HH:MM\n";
    my @lt = localtime($now // time());
    my $cur = $lt[2] * 60 + $lt[1];
    my ($start, $end) = ($sh * 60 + $sm, $eh * 60 + $em);
    return $start <= $end
        ? ($cur >= $start && $cur < $end)
        : ($cur >= $start || $cur < $end);
}

# One-minor-at-a-time gate for Kubernetes upgrades (T2.3).
sub assert_minor_upgrade {
    my ($current, $target) = @_;

    my ($cmaj, $cmin) = $current =~ /^(\d+)\.(\d+)/
        or die "cannot parse current Kubernetes version '$current'\n";
    my ($tmaj, $tmin) = ($target // '') =~ /^(\d+)\.(\d+)/
        or die "cannot parse target Kubernetes version '$target'\n";
    die "Kubernetes upgrade must go one minor at a time: "
        . "$current -> $target is not allowed (next is $cmaj."
        . ($cmin + 1) . ")\n"
        if $tmaj != $cmaj || $tmin != $cmin + 1;
    return "$tmaj.$tmin";
}

my sub node_rev_on {
    my ($node) = @_;

    return $node->{rev} if defined $node->{rev};
    my $cfg = eval {
        qm_on($node->{pvehost}, 'config', $node->{vmid}) } // '';
    return $cfg =~ /image-revision(?::|%3A)\s*(\d+)/ ? int $1 : undef;
}

# etcdctl runs as a one-off ctr container with the node's
# own etcd image: newer Kubernetes images no longer ship
# crictl, and ctr is part of containerd, which is always
# there. The PKI and data dir are bind-mounted in.
my sub etcdctl_cmd {
    my ($args) = @_;

    return 'IMG=$(ctr -n k8s.io containers list '
        . "| awk '\$2 ~ /etcd/ {print \$2; exit}'); "
        . '[ -z "$IMG" ] && IMG=$(ctr -n k8s.io images list '
        . "| awk '\$1 ~ /etcd/ {print \$1; exit}'); "
        . 'ctr -n k8s.io run --rm --net-host '
        . '--mount type=bind,src=/etc/kubernetes/pki/etcd,'
        . 'dst=/pki,options=rbind:ro '
        . '--mount type=bind,src=/var/lib/etcd,'
        . 'dst=/var/lib/etcd,options=rbind '
        . '"$IMG" etcdctl-$$ etcdctl '
        . '--endpoints=https://127.0.0.1:2379 '
        . '--cacert=/pki/ca.crt --cert=/pki/server.crt '
        . "--key=/pki/server.key $args";
}

my sub etcd_snapshot {
    my ($cp) = @_;

    my $file = "/var/lib/etcd/pre-roll-" . time() . ".db";
    guest_exec($cp->{vmid},
        etcdctl_cmd("snapshot save $file >/dev/null")
        . " && test -s $file && echo $file");
    print "etcd snapshot saved on $cp->{host}: $file\n";
    return $file;
}

my sub etcd_member_remove {
    my ($survivor, $old_host) = @_;

    my $list = guest_exec($survivor->{vmid},
        etcdctl_cmd('member list'));
    my ($id) = $list =~ /^([0-9a-f]+),[^,]+,\s*\Q$old_host\E,/m;
    return if !$id;
    guest_exec($survivor->{vmid},
        etcdctl_cmd("member remove $id >/dev/null"));
    print "etcd member $old_host ($id) removed\n";
}

my sub kubectl_on {
    my ($cp, $args) = @_;
    # admin.conf exists on every control-plane node;
    # local-super-admin.conf only ever existed on the init node
    return guest_exec($cp->{vmid},
        "kubectl --kubeconfig /etc/kubernetes/admin.conf $args");
}

my sub wait_node_ready {
    my ($cp, $host) = @_;

    for (1 .. 80) {
        my $out = eval { kubectl_on($cp, 'get nodes --no-headers') } // '';
        return 1 if $out =~ /^\Q$host\E\s+Ready/m;
        sleep 15;
    }
    die "node $host never became Ready\n";
}

my sub label_node {
    my ($cp, $node) = @_;

    my @label = ("pve-k8s.proxmox.com/pool=$node->{pool}",
        "topology.pve-k8s.proxmox.com/site=$node->{site}");
    push @label, grep { /^[a-zA-Z0-9.\/-]+=[^,]+$/ }
        split /\s*,\s*/, $node->{labels} // '';
    kubectl_on($cp, "label nodes $node->{host} "
        . join(' ', @label) . ' --overwrite');
    if ($node->{taints}) {
        my $effect = '(NoSchedule|NoExecute|PreferNoSchedule)';
        my @taint = grep { /^[a-zA-Z0-9.\/-]+(=[^:,]*)?:$effect$/
            || /^[a-zA-Z0-9.\/-]+:$effect$/ }
            split /\s*,\s*/, $node->{taints};
        kubectl_on($cp, "taint nodes $node->{host} "
            . join(' ', @taint) . ' --overwrite') if @taint;
    }
}

my sub remove_node {
    my ($cp, $old, $all) = @_;

    eval { kubectl_on($cp, "cordon $old->{host}") };
    eval { kubectl_on($cp, "drain $old->{host} --ignore-daemonsets "
        . '--delete-emptydir-data --force --timeout=240s') };
    if ($old->{role} eq 'cp') {
        my ($survivor) = grep {
            $_->{role} eq 'cp' && $_->{host} ne $old->{host} } $all->@*;
        etcd_member_remove($survivor, $old->{host}) if $survivor;
    }
    eval { guest_exec($old->{vmid}, 'kubeadm reset -f') };
    eval { kubectl_on($cp, "delete node $old->{host}") };
    eval { qm_on($old->{pvehost}, 'stop', $old->{vmid}) };
    qm_on($old->{pvehost}, 'destroy', $old->{vmid}, '--purge',
        '--destroy-unreferenced-disks', 1);
    remove_snippet_on($old->{pvehost}, "k8s-$old->{host}.yaml");
    print "removed $old->{host} (vmid $old->{vmid} on $old->{pvehost})\n";
}

# --- autoscaler (T2.4) -------------------------------------
# One reconcile pass per call, driven by the API task or the
# systemd timer on every PVE host. Leadership is a stamp in
# the cluster config (host + time, pmxcfs-replicated): only
# the host holding a fresh stamp acts, another takes over
# when the stamp goes stale (pve-ha-manager pattern, at
# config-file scale). Decisions come from PVE::K8s::Scaler
# simulation; at most one action per pass.

my sub iso_epoch {
    my ($iso) = @_;

    return 0 if ($iso // '') !~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)Z$/;
    return Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1);
}

my sub kubectl_json {
    my ($cp, $args) = @_;

    my $out = kubectl_on($cp, "$args -o json");
    my $start = index($out, '{');
    $out = substr($out, $start) if $start > 0;
    return JSON::PP->new->decode($out);
}

my sub claim_scaler_leadership {
    my ($name) = @_;

    my $me = local_node_name();
    my $now = time();
    my $claimed = 0;
    PVE::K8s::Config::lock_config(sub {
        my $cfg = PVE::K8s::Config->config();
        my $scfg = $cfg->{ids}->{$name} or die "no cluster '$name'\n";
        my $state = eval {
            JSON::PP->new->decode($scfg->{'scaler-state'} // '{}') } // {};
        if (($state->{busy} // 0) && ($now - ($state->{at} // 0)) < 1800) {
            print "scaler pass already running on "
                . "$state->{leader}, standing down\n";
            return;
        }
        $state->{leader} = $me;
        $state->{at} = $now;
        $state->{busy} = 1;
        $scfg->{'scaler-state'} =
            JSON::PP->new->canonical->encode($state);
        PVE::K8s::Config::store_config($cfg);
        $claimed = 1;
    });
    return $claimed;
}

my sub set_pool_size {
    my ($name, $pool_name, $size) = @_;

    PVE::K8s::Config::lock_config(sub {
        my $cfg = PVE::K8s::Config->config();
        my $scfg = $cfg->{ids}->{$name} or die "no cluster '$name'\n";
        my $pools = PVE::K8s::Config::parse_pools(
            $scfg->{pools}, $scfg->{workers} // 2);
        for my $pool ($pools->@*) {
            $pool->{size} = $size if $pool->{name} eq $pool_name;
        }
        $scfg->{pools} = JSON::PP->new->canonical->encode($pools);
        PVE::K8s::Config::store_config($cfg);
    });
}

my sub release_scaler_leadership {
    my ($name, $acted) = @_;

    PVE::K8s::Config::lock_config(sub {
        my $cfg = PVE::K8s::Config->config();
        my $scfg = $cfg->{ids}->{$name} or return;
        my $state = eval {
            JSON::PP->new->decode($scfg->{'scaler-state'} // '{}') } // {};
        $state->{busy} = 0;
        $state->{at} = time();
        $state->{'last-action'} = time() if $acted;
        $scfg->{'scaler-state'} =
            JSON::PP->new->canonical->encode($state);
        PVE::K8s::Config::store_config($cfg);
    });
}

sub scale_cluster {
    my ($name) = @_;

    return 0 if !claim_scaler_leadership($name);
    my $acted = eval { scale_reconcile($name) };
    my $err = $@;
    release_scaler_leadership($name, $acted // 0);
    die $err if $err;
    return $acted;
}

sub scale_reconcile {
    my ($name) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    die "cluster '$name' is not provisioned yet\n"
        if !$scfg->{nodes};
    my $subnet = $scfg->{'node-subnet'} or die "no node-subnet\n";
    $subnet =~ m|^(\d+\.\d+\.\d+)\.0/24$| or die "bad node-subnet\n";
    my $prefix = $1;

    my $pools = PVE::K8s::Config::parse_pools(
        $scfg->{pools}, $scfg->{workers} // 2);
    my %pool_by_name = map { $_->{name} => $_ } $pools->@*;

    my $inventory = JSON::PP->new->decode($scfg->{nodes});
    my @nodes;
    for my $item ($inventory->@*) {
        my ($idx) = $item->{name} =~ /(\d+)$/;
        my $pool = $item->{pool} // 'default';
        push @nodes, {
            host => $item->{name},
            role => $pool eq 'control-plane' ? 'cp' : 'worker',
            pool => $pool, idx => $idx // 1, ip => $item->{ip},
            vmid => $item->{vmid}, pvehost => $item->{pvehost},
            labels => ($pool_by_name{$pool} // {})->{labels},
            taints => ($pool_by_name{$pool} // {})->{taints},
        };
        $VM_HOST{$item->{vmid}} = $item->{pvehost};
    }

    my ($cp) = grep { $_->{role} eq 'cp' } @nodes;
    for my $candidate (grep { $_->{role} eq 'cp' } @nodes) {
        my $ok = eval { guest_exec($candidate->{vmid}, 'true'); 1 } // 0;
        if ($ok) { $cp = $candidate; last }
    }
    die "no control-plane node answers for '$name'\n" if !$cp;

    my $knodes = kubectl_json($cp, 'get nodes')->{items} // [];
    my $kpods = kubectl_json($cp, 'get pods -A')->{items} // [];
    my %k8s_node = map { $_->{metadata}{name} => $_ } $knodes->@*;

    # Repair first: a worker whose kubelet is gone AND whose
    # VM does not answer is replaced; a merely unhappy
    # kubelet on a live VM is reported, never destroyed.
    for my $node (grep { $_->{role} eq 'worker' } @nodes) {
        my $kn = $k8s_node{$node->{host}} or next;
        my ($ready) = grep { ($_->{type} // '') eq 'Ready' }
            ($kn->{status}{conditions} // [])->@*;
        next if !$ready || ($ready->{status} // '') eq 'True';
        my $since = time() - iso_epoch($ready->{lastTransitionTime});
        next if $since < 300;
        my $vm_alive = eval {
            qm_on($node->{pvehost}, 'agent', $node->{vmid}, 'ping'); 1
        } // 0;
        if ($vm_alive) {
            print "repair: $node->{host} NotReady for ${since}s but "
                . "its VM answers; leaving it alone\n";
            next;
        }
        print "repair: replacing dead node $node->{host} "
            . "(NotReady ${since}s, VM silent)\n";
        remove_node($cp, $node, \@nodes);
        provision_cluster($name);
        print "repair: $node->{host} replaced\n";
        return 1;
    }

    # Build simulator state from the live cluster.
    my %pods_by_node;
    push $pods_by_node{$_->{spec}{nodeName}}->@*, $_
        for grep { $_->{spec}{nodeName} } $kpods->@*;
    my @sim_nodes;
    for my $kn ($knodes->@*) {
        my $alloc = $kn->{status}{allocatable} // {};
        my $sim = PVE::K8s::Scaler::make_node(
            $kn->{metadata}{name}, $kn->{metadata}{labels} // {},
            $kn->{spec}{taints} // [],
            PVE::K8s::Scaler::parse_cpu($alloc->{cpu}),
            PVE::K8s::Scaler::parse_mem($alloc->{memory}));
        for my $pod (($pods_by_node{$kn->{metadata}{name}} // [])->@*) {
            next if ($pod->{status}{phase} // '') eq 'Succeeded'
                || ($pod->{status}{phase} // '') eq 'Failed';
            my $r = PVE::K8s::Scaler::pod_requests($pod);
            $sim->{used_cpu} += $r->{cpu};
            $sim->{used_mem} += $r->{mem};
            push $sim->{pods}->@*, $pod;
        }
        push @sim_nodes, $sim;
    }
    my ($worker_sim) = grep {
        ($_->{labels}{'pve-k8s.proxmox.com/pool'} // '') ne 'control-plane'
    } @sim_nodes;
    my $tmpl = $worker_sim
        ? { cpu => $worker_sim->{cpu}, mem => $worker_sim->{mem} }
        : { cpu => 2000, mem => 4 * 1024**3 };

    my $now = time();
    my @pending = grep {
        $now - iso_epoch($_->{metadata}{creationTimestamp}) > 120
    } PVE::K8s::Scaler::schedulable_pending($kpods)->@*;

    # Scale out, one pool per pass.
    if (@pending) {
        for my $pool ($pools->@*) {
            my $room = $pool->{max} - $pool->{size};
            next if $room <= 0;
            my $needed = PVE::K8s::Scaler::nodes_needed(
                \@sim_nodes, \@pending, $pool, $room, $tmpl);
            next if !$needed;
            my $res = eval {
                run(['pvesh', 'get', '/cluster/resources',
                    '--type', 'node', '--output-format', 'json'],
                    timeout => 60);
            } // '';
            my $hosts = eval { JSON::PP->new->decode($res) } // [];
            my $free = grep {
                ($_->{maxmem} // 0) - ($_->{mem} // 0) > 4 * 1024**3
            } $hosts->@*;
            if (!$free) {
                print "scale: $name pool $pool->{name} needs "
                    . "$needed node(s) but all Proxmox hosts are "
                    . "saturated (no host with 4GiB free); not "
                    . "scaling\n";
                next;
            }
            print "scale: pool $pool->{name} $pool->{size} -> "
                . ($pool->{size} + $needed)
                . " for " . scalar(@pending) . " pending pod(s)\n";
            set_pool_size($name, $pool->{name},
                $pool->{size} + $needed);
            provision_cluster($name);
            return 1;
        }
        print "scale: pending pods exist but no pool can host "
            . "them (labels/taints/size/max); not scaling\n";
    }

    # Scale in: only the highest-index node of a pool is a
    # candidate, so canonical node naming stays consistent.
    my $candidates = PVE::K8s::Scaler::scale_in_candidates(
        \@sim_nodes, 0.3);
    for my $host ($candidates->@*) {
        my ($node) = grep { $_->{host} eq $host } @nodes;
        next if !$node || $node->{role} ne 'worker';
        my $pool = $pool_by_name{$node->{pool}} or next;
        next if $pool->{size} <= $pool->{min};
        my @pool_nodes = grep { $_->{pool} eq $node->{pool} } @nodes;
        my $last = (sort { $b->{idx} <=> $a->{idx} } @pool_nodes)[0];
        next if $last->{host} ne $host;
        my $kn = $k8s_node{$host};
        next if $now - iso_epoch($kn->{metadata}{creationTimestamp})
            < 1800;
        print "scale: removing idle node $host "
            . "(pool $pool->{name} $pool->{size} -> "
            . ($pool->{size} - 1) . ")\n";
        # Drain via eviction (PDB-safe). kubectl drain
        # retries PDB-refused evictions forever, so the
        # drain is time-boxed in the guest; a blocked drain
        # uncordons the node and ends the pass - the VM is
        # never force-drained past a PDB.
        kubectl_on($cp, "cordon $host");
        my $drained = eval {
            guest_exec($cp->{vmid},
                'timeout 240 kubectl '
                . '--kubeconfig /etc/kubernetes/admin.conf '
                . "drain $host --ignore-daemonsets "
                . '--delete-emptydir-data --timeout=200s');
            1;
        } // 0;
        if (!$drained) {
            eval { kubectl_on($cp, "uncordon $host") };
            print "scale: drain of $host blocked (likely a "
                . "PodDisruptionBudget); node uncordoned and "
                . "left in place\n";
            return 0;
        }
        eval { guest_exec($node->{vmid}, 'kubeadm reset -f') };
        kubectl_on($cp, "delete node $host");
        eval { qm_on($node->{pvehost}, 'stop', $node->{vmid}) };
        qm_on($node->{pvehost}, 'destroy', $node->{vmid},
            '--purge', '--destroy-unreferenced-disks', 1);
        remove_snippet_on($node->{pvehost}, "k8s-$host.yaml");
        set_pool_size($name, $pool->{name}, $pool->{size} - 1);
        provision_cluster($name);
        return 1;
    }

    print "scale: $name steady (no repair, no scaling)\n";
    return 0;
}

sub roll_cluster {
    my ($name, %opts) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    if (!$opts{force} && $scfg->{'maintenance-window'}
        && !in_maintenance_window($scfg->{'maintenance-window'})) {
        die "outside maintenance window "
            . "$scfg->{'maintenance-window'} for cluster '$name' "
            . "(retry with force to roll anyway)\n";
    }

    my $subnet = $scfg->{'node-subnet'}
        or die "cluster '$name' has no node-subnet configured\n";
    $subnet =~ m|^(\d+\.\d+\.\d+)\.0/24$| or die "bad node-subnet\n";
    my $prefix = $1;
    my $vip = PVE::K8s::Config::vip_for($scfg);
    my $gateway = $scfg->{gateway} // "$prefix.1";
    my $version = $opts{target_version} // $scfg->{'k8s-version'};

    my $template = find_template($version);
    my (undef, $want_rev) = find_template_in_list(qm('list'), $version);
    print "rolling '$name' to Kubernetes $version template r$want_rev\n";

    # After a roll, node names no longer match the canonical
    # provision layout, so the stored inventory is authoritative
    # when present.
    my @nodes;
    if ($scfg->{nodes}) {
        my $pools = PVE::K8s::Config::parse_pools(
            $scfg->{pools}, $scfg->{workers} // 2);
        my %pool_by_name = map { $_->{name} => $_ } $pools->@*;
        my $inventory = JSON::PP->new->decode($scfg->{nodes});
        for my $item ($inventory->@*) {
            my ($idx) = $item->{name} =~ /(\d+)$/;
            my $pool = $item->{pool} // 'default';
            my $pdef = $pool_by_name{$pool} // {};
            push @nodes, {
                host => $item->{name},
                role => $pool eq 'control-plane' ? 'cp' : 'worker',
                pool => $pool, idx => $idx // 1, ip => $item->{ip},
                vmid => $item->{vmid}, pvehost => $item->{pvehost},
                rev => $item->{rev},
                labels => $pdef->{labels}, taints => $pdef->{taints},
                pool_hosts => $pdef->{hosts},
                pool_storage => $pdef->{storage},
            };
        }
        @nodes = sort { $a->{role} cmp $b->{role} } @nodes;
    } else {
        @nodes = cluster_nodes($name, $scfg, $prefix)->@*;
        my $existing = cluster_vms();
        for my $node (@nodes) {
            my $vm = $existing->{$node->{host}}
                or die "node VM $node->{host} not found; "
                . "run provision first\n";
            $node->{vmid} = $vm->{vmid};
            $node->{pvehost} = $vm->{node};
        }
    }
    for my $node (@nodes) {
        $node->{site} = $node->{pvehost};
        $VM_HOST{$node->{vmid}} = $node->{pvehost} if $node->{vmid};
        $node->{rev} = node_rev_on($node);
    }
    my $group_of = ha_group_by_host();
    $_->{site} = $group_of->{$_->{pvehost}} // $_->{pvehost} for @nodes;

    my @behind = grep {
        !defined $_->{rev} || $_->{rev} != $want_rev
        || ($opts{target_version}
            && $version ne $scfg->{'k8s-version'})
    } @nodes;
    if (!@behind) {
        print "all nodes already on Kubernetes $version r$want_rev\n";
        return 0;
    }

    set_state($name, 'rolling');
    my $ctx = { version => $version, template => $template,
        gateway => $gateway, storage => $scfg->{storage} // 'local-zfs',
        bridge => cluster_bridge($scfg) };
    my $hosts = pve_online_nodes();
    # Operations (snapshot, join material, upgrade apply,
    # kubectl) run from the first control-plane node whose
    # guest agent actually answers; any CP can serve, and the
    # first by name may be the least healthy one.
    my ($cp1) = grep { $_->{role} eq 'cp' } @nodes;
    for my $candidate (grep { $_->{role} eq 'cp' } @nodes) {
        my $ok = eval { guest_exec($candidate->{vmid}, 'true'); 1 } // 0;
        if ($ok) {
            $cp1 = $candidate;
            last;
        }
        print "roll operations: $candidate->{host} not answering, "
            . "trying next control-plane node\n";
    }
    print "roll operations via $cp1->{host}\n";

    # etcd snapshot gate before any control-plane replacement
    etcd_snapshot($cp1) if grep { $_->{role} eq 'cp' } @behind;

    # cluster-info may still point at the first CP's address
    # (it is created during provisioning from the local
    # endpoint); point discovery at the VIP so joins survive
    # that node being rolled away.
    eval {
        guest_exec($cp1->{vmid},
            'kubeadm init phase bootstrap-token '
            . '--kubeconfig /etc/kubernetes/admin.conf');
    };

    my ($join_cmd, $cert_key);
    my $upgraded = 0;
    for my $old (@behind) {
        # surge: build the replacement first, with a fresh
        # name/IP (next free index in its role/pool)
        my $new = { $old->%* };
        if ($old->{role} eq 'cp') {
            my $next = 1 + (sort { $b <=> $a }
                map { $_->{idx} } grep { $_->{role} eq 'cp' } @nodes)[0];
            $new->{host} = "$name-cp$next";
            $new->{idx} = $next;
            $new->{ip} = "$prefix." . (59 + $next);
        } else {
            my @pool = grep { $_->{pool} eq $old->{pool} } @nodes;
            my $next = 1 + (sort { $b <=> $a } map { $_->{idx} } @pool)[0];
            $new->{host} = $old->{pool} eq 'default'
                ? "$name-w$next" : "$name-$old->{pool}$next";
            $new->{idx} = $next;
            my $max_ip = (sort { $b <=> $a }
                map { /(\d+)$/ ? int $1 : 69 }
                map { $_->{ip} } @nodes)[0];
            $new->{ip} = "$prefix." . ($max_ip + 1);
        }
        delete $new->{vmid};
        delete $new->{rev};

        # placement: prefer a different host than the old node
        my %counts;
        for my $n (@nodes) {
            $counts{"total:$n->{pvehost}"}++;
            $counts{"cp:$n->{pvehost}"}++ if $n->{role} eq 'cp';
            my $g = $group_of->{$n->{pvehost}} // $n->{pvehost};
            $counts{"cp-group:$g"}++ if $n->{role} eq 'cp';
            $counts{"pool:$n->{pool}:$n->{pvehost}"}++;
        }
        my @candidates = grep { $_ ne $old->{pvehost} } $hosts->@*;
        @candidates = $hosts->@* if !@candidates;
        if ($new->{pool_hosts}) {
            my %allowed = map { $_ => 1 }
                split /\s*,\s*/, $new->{pool_hosts};
            @candidates = grep { $allowed{$_} } @candidates;
        }
        my %pool_counts = map {
            ("pool:$_" => $counts{"pool:$new->{pool}:$_"} // 0) } @candidates;
        $new->{pvehost} = choose_host(\@candidates, $group_of,
            { %counts, %pool_counts },
            $new->{role} eq 'cp' ? 'cp' : 'worker');
        $new->{site} = $group_of->{$new->{pvehost}} // $new->{pvehost};
        print "surge: replacing $old->{host} with $new->{host} "
            . "on $new->{pvehost}\n";

        # A resumed roll may find its replacement already
        # created and joined (the previous run died waiting for
        # it); adopt it instead of surging yet another node.
        my $adopted = 0;
        if ((cluster_vms()->{$new->{host}} // {})->{vmid}) {
            my $out = eval {
                kubectl_on($cp1, 'get nodes --no-headers') } // '';
            $adopted = $out =~ /^\Q$new->{host}\E\s/m ? 1 : 0;
        }
        if ($adopted) {
            $new->{vmid} = cluster_vms()->{$new->{host}}->{vmid};
            $VM_HOST{$new->{vmid}} = $new->{pvehost};
            print "adopting already-joined replacement $new->{host}\n";
            goto ADOPTED;
        }

        create_node_vm($ctx, $new, node_userdata(
            hostname => $new->{host}, role => $new->{role}, vip => $vip,
            enc_key => $new->{role} eq 'cp'
                ? cluster_encryption_key($name) : undef,
            extra_runcmd => ''));
        # the external flag must be set before kubeadm join so
        # the kubelet registers with the uninitialized taint
        # the CCM needs to initialise the node
        set_external_cloud_provider($new);

        # Kubernetes minor upgrade (T2.3): before the first
        # new-version CP joins, run kubeadm upgrade apply on an
        # existing CP with the target kubeadm binary fetched to
        # /tmp (the node itself stays immutable and is replaced
        # later in this same roll).
        if ($opts{target_version} && !$upgraded
            && $new->{role} eq 'cp') {
            my $kver = guest_exec($new->{vmid},
                'kubeadm version -o short');
            chomp $kver;
            guest_exec($cp1->{vmid},
                "curl -sL https://dl.k8s.io/release/$kver/bin/linux/"
                . 'amd64/kubeadm -o /tmp/kubeadm && chmod +x /tmp/kubeadm');
            # upgrade apply pulls all control-plane images and
            # can outrun any exec transport timeout on slow
            # hosts, so it runs detached in the guest and is
            # polled to completion
            guest_exec($cp1->{vmid},
                'rm -f /root/upgrade.rc; nohup sh -c '
                . "'/tmp/kubeadm upgrade apply $kver --yes "
                . '> /root/upgrade.log 2>&1; echo $? > /root/upgrade.rc'
                . "' >/dev/null 2>&1 &");
            my $rc;
            for (1 .. 80) {
                $rc = eval {
                    guest_exec($cp1->{vmid}, 'cat /root/upgrade.rc')
                } // '';
                chomp $rc;
                last if $rc =~ /^\d+$/;
                sleep 30;
            }
            die "kubeadm upgrade apply did not finish on $cp1->{host}\n"
                if $rc !~ /^\d+$/;
            if ($rc != 0) {
                my $log = eval {
                    guest_exec($cp1->{vmid}, 'tail -5 /root/upgrade.log')
                } // '';
                die "kubeadm upgrade apply failed on $cp1->{host}: $log\n";
            }
            $upgraded = 1;
            print "control plane upgraded to $kver via $cp1->{host}\n";
        }

        # Join material is refreshed for every replacement, and
        # discovery uses the VIP (cluster-info was refreshed to
        # it above): the node material came from may itself
        # have been rolled away, so a node address is not stable
        # enough here, unlike during initial provisioning.
        $join_cmd = guest_exec($cp1->{vmid},
            'kubeadm token create --print-join-command');
        chomp $join_cmd;
        $cert_key = guest_exec($cp1->{vmid},
            'kubeadm init phase upload-certs --upload-certs '
            . '2>/dev/null | tail -1');
        chomp $cert_key;
        my $join = join_command($join_cmd, $cert_key,
            $new->{role} eq 'cp' ? 1 : 0);
        my $joined = 0;
        for my $attempt (1 .. 3) {
            $joined = eval { guest_exec($new->{vmid}, $join); 1 } // 0;
            last if $joined;
            eval { guest_exec($new->{vmid}, 'kubeadm reset -f') };
            sleep 20;
        }
        die "replacement $new->{host} failed to join\n" if !$joined;
      ADOPTED:
        set_external_cloud_provider($new);
        wait_node_ready($cp1, $new->{host});
        label_node($cp1, $new);

        $new->{rev} = $want_rev;
        @nodes = map { $_->{host} eq $old->{host} ? $new : $_ } @nodes;
        remove_node($cp1, $old, \@nodes);
        $cp1 = (grep { $_->{role} eq 'cp' } @nodes)[0]
            if $cp1->{host} eq $old->{host};
        store_inventory($name, \@nodes, $want_rev);
        print "rolled $old->{host} -> $new->{host}\n";
    }

    if ($opts{target_version}) {
        PVE::K8s::Config::lock_config(sub {
            my $locked = PVE::K8s::Config->config();
            $locked->{ids}->{$name}->{'k8s-version'} = $version;
            PVE::K8s::Config::store_config($locked);
        });
    }
    store_inventory($name, \@nodes, $want_rev);
    set_state($name, 'ready');
    print "cluster '$name' rolled: all nodes on $version r$want_rev\n";
    return 1;
}

# --- day-2 operations (T2.5) -------------------------------
# Shared helpers: inventory-shaped node list and the first
# answering control-plane node for kubectl operations.

my sub load_nodes {
    my ($name, $scfg) = @_;

    die "cluster '$name' is not provisioned yet\n"
        if !$scfg->{nodes};
    my $pools = PVE::K8s::Config::parse_pools(
        $scfg->{pools}, $scfg->{workers} // 2);
    my %pool_by_name = map { $_->{name} => $_ } $pools->@*;
    my $inventory = JSON::PP->new->decode($scfg->{nodes});
    my @nodes;
    for my $item ($inventory->@*) {
        my ($idx) = $item->{name} =~ /(\d+)$/;
        my $pool = $item->{pool} // 'default';
        push @nodes, {
            host => $item->{name},
            role => $pool eq 'control-plane' ? 'cp' : 'worker',
            pool => $pool, idx => $idx // 1, ip => $item->{ip},
            vmid => $item->{vmid}, pvehost => $item->{pvehost},
            labels => ($pool_by_name{$pool} // {})->{labels},
            taints => ($pool_by_name{$pool} // {})->{taints},
        };
        $VM_HOST{$item->{vmid}} = $item->{pvehost};
    }
    return \@nodes;
}

my sub ops_cp {
    my ($nodes) = @_;

    for my $candidate (grep { $_->{role} eq 'cp' } $nodes->@*) {
        my $ok = eval { guest_exec($candidate->{vmid}, 'true'); 1 } // 0;
        return $candidate if $ok;
    }
    die "no control-plane node answers\n";
}

my sub find_node {
    my ($nodes, $host) = @_;

    my ($node) = grep { $_->{host} eq $host } $nodes->@*;
    die "node '$host' is not part of this cluster\n" if !$node;
    return $node;
}

# Short-lived (1h) admin kubeconfig: a TokenRequest token
# for a dedicated service account, never a static credential.
# The PVE API call itself is the audit record (authenticated
# user, Sys.Modify required).
sub kubeconfig_cluster {
    my ($name) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    my $subnet = $scfg->{'node-subnet'} or die "no node-subnet\n";
    $subnet =~ m|^(\d+\.\d+\.\d+)\.0/24$| or die "bad node-subnet\n";
    my $vip = PVE::K8s::Config::vip_for($scfg);

    my $nodes = load_nodes($name, $scfg);
    my $cp = ops_cp($nodes);
    guest_exec($cp->{vmid},
        'kubectl --kubeconfig /etc/kubernetes/admin.conf '
        . 'create serviceaccount pve-k8s-admin -n kube-system '
        . '--dry-run=client -o yaml | '
        . 'kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -; '
        . 'kubectl --kubeconfig /etc/kubernetes/admin.conf '
        . 'create clusterrolebinding pve-k8s-admin '
        . '--clusterrole=cluster-admin '
        . '--serviceaccount=kube-system:pve-k8s-admin '
        . '--dry-run=client -o yaml | '
        . 'kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -');
    my $token = guest_exec($cp->{vmid},
        'kubectl --kubeconfig /etc/kubernetes/admin.conf '
        . 'create token pve-k8s-admin -n kube-system '
        . '--duration=3600s');
    $token =~ s/\s+//g;
    my $ca = guest_exec($cp->{vmid},
        'base64 -w0 /etc/kubernetes/pki/ca.crt');
    $ca =~ s/\s+//g;
    die "could not issue a token for cluster '$name'\n"
        if !$token || !$ca;

    return {
        kubeconfig => <<EOF,
apiVersion: v1
kind: Config
clusters:
- name: $name
  cluster:
    server: https://$vip:6443
    certificate-authority-data: $ca
contexts:
- name: $name
  context:
    cluster: $name
    user: pve-k8s-admin
current-context: $name
users:
- name: pve-k8s-admin
  user:
    token: $token
EOF
        expires => '1h (TokenRequest, service account '
            . 'kube-system/pve-k8s-admin, cluster-admin)',
        server => "https://$vip:6443",
    };
}

sub drain_node {
    my ($name, $host) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    my $nodes = load_nodes($name, $scfg);
    my $node = find_node($nodes, $host);
    my $cp = ops_cp($nodes);
    kubectl_on($cp, "cordon $host");
    # time-boxed like scale-in: PDB refusals must not hang
    guest_exec($cp->{vmid},
        'timeout 600 kubectl '
        . '--kubeconfig /etc/kubernetes/admin.conf '
        . "drain $host --ignore-daemonsets "
        . '--delete-emptydir-data --timeout=540s');
    print "node $host drained (pods evicted, node cordoned)\n";
    return 1;
}

sub replace_node {
    my ($name, $host) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    my $nodes = load_nodes($name, $scfg);
    my $node = find_node($nodes, $host);
    die "control-plane replacement goes through roll/upgrade, "
        . "not the node replace action\n" if $node->{role} eq 'cp';
    my $cp = ops_cp($nodes);
    print "replacing node $host (drain, destroy, recreate)\n";
    remove_node($cp, $node, $nodes);
    provision_cluster($name);
    print "node $host replaced\n";
    return 1;
}

# Force-retire a dead worker (T2.6): for a node whose VM or
# host is gone, drain is impossible. The administrator
# confirms the VM is powered off/lost (the API requires
# force=1); we delete the stale Node object, retire the
# inventory entry, and record a ghost marker so a later
# reappearing VM (same name+VMID) blocks provisioning
# instead of silently rejoining. Optionally provisions the
# replacement (fresh identity comes from the scaler or the
# provisioner's canonical naming once the ghost is gone).
sub force_retire_node {
    my ($name, $host, %opts) = @_;

    die "force-retire requires explicit confirmation "
        . "(force=1): the VM must be powered off or lost\n"
        if !$opts{force};
    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    my $nodes = load_nodes($name, $scfg);
    my $node = find_node($nodes, $host);
    die "force-retire is for worker nodes; control-plane "
        . "membership goes through roll/upgrade\n"
        if $node->{role} eq 'cp';
    my $cp = ops_cp($nodes);

    my $knodes = kubectl_json($cp, 'get nodes')->{items} // [];
    my ($kn) = grep { $_->{metadata}{name} eq $host } $knodes->@*;
    if ($kn) {
        my ($ready) = grep { ($_->{type} // '') eq 'Ready' }
            ($kn->{status}{conditions} // [])->@*;
        die "node $host is Ready; use drain/replace instead\n"
            if $ready && ($ready->{status} // '') eq 'True';
    }

    # If the VM is still reachable, destroying it here is
    # the fencing act; if its host is gone this fails and
    # the ghost marker below covers its return. No marker
    # when the destroy succeeded: VMIDs get recycled, and a
    # marker would match the legitimate replacement.
    eval { qm_on($node->{pvehost}, 'stop', $node->{vmid}) };
    my $destroyed = eval {
        qm_on($node->{pvehost}, 'destroy', $node->{vmid},
            '--purge', '--destroy-unreferenced-disks', 1);
        1;
    } // 0;
    eval { kubectl_on($cp, "delete node $host") };

    PVE::K8s::Config::lock_config(sub {
        my $cfg2 = PVE::K8s::Config->config();
        my $s2 = $cfg2->{ids}->{$name};
        my $inv = JSON::PP->new->decode($s2->{nodes});
        $s2->{nodes} = JSON::PP->new->canonical->encode(
            [grep { $_->{name} ne $host } $inv->@*]);
        if (!$destroyed) {
            my $retired = eval {
                JSON::PP->new->decode($s2->{'retired-nodes'} // '[]')
            } // [];
            push $retired->@*, { name => $host,
                vmid => $node->{vmid},
                pvehost => $node->{pvehost}, at => time() };
            $s2->{'retired-nodes'} =
                JSON::PP->new->canonical->encode($retired);
        }
        PVE::K8s::Config::store_config($cfg2);
    });
    print "force-retired dead node $host (ghost marker kept "
        . "for vmid $node->{vmid} on $node->{pvehost})\n";

    if ($opts{replace}) {
        provision_cluster($name);
        print "replacement for $host provisioned\n";
    }
    return 1;
}

# A force-retired VM that reappears (its host came back)
# must never silently rejoin: stop provisioning until an
# operator wipes it.
sub check_retired_ghosts {
    my ($name, $scfg) = @_;

    my $retired = eval {
        JSON::PP->new->decode($scfg->{'retired-nodes'} // '[]')
    } // [];
    return if !$retired->@*;
    my $out = run(['pvesh', 'get', '/cluster/resources',
        '--type', 'vm', '--output-format', 'json'], timeout => 60);
    my $vms = decode_pvesh_json($out);
    for my $ghost ($retired->@*) {
        my ($vm) = grep {
            ($_->{name} // '') eq $ghost->{name}
            && int($_->{vmid} // 0) == int($ghost->{vmid})
        } $vms->@*;
        die "force-retired node $ghost->{name} (vmid "
            . "$ghost->{vmid} on $ghost->{pvehost}) has "
            . "reappeared; wipe that VM before provisioning "
            . "(it still holds the old node identity)\n" if $vm;
    }
}

# Chunked file transfer through the guest agent (no SSH in
# the node images). Base64 chunks keep each exec bounded.
my sub guest_fetch_file {
    my ($vmid, $guest_path, $host_path) = @_;

    my $size = guest_exec($vmid, "stat -c%s $guest_path");
    $size =~ s/\D//g;
    die "cannot stat $guest_path in guest\n" if !$size;
    my $chunk = 512 * 1024;
    my $parts = int(($size + $chunk - 1) / $chunk);
    open my $fh, '>', $host_path or die "open $host_path: $!\n";
    binmode $fh;
    for my $i (0 .. $parts - 1) {
        my $b64 = guest_exec($vmid,
            "dd if=$guest_path bs=$chunk skip=$i count=1 "
            . 'status=none | base64 -w0');
        $b64 =~ s/\s+//g;
        print $fh MIME::Base64::decode_base64($b64);
    }
    close $fh or die "close $host_path: $!\n";
    return $size;
}

my sub guest_push_file {
    my ($vmid, $host_path, $guest_path) = @_;

    open my $fh, '<', $host_path or die "open $host_path: $!\n";
    binmode $fh;
    local $/;
    my $data = <$fh>;
    close $fh;
    my $b64 = MIME::Base64::encode_base64($data, '');
    guest_exec($vmid, "rm -f $guest_path.b64 $guest_path");
    # 48k chunks: a single argv string is capped near
    # 128 KiB by the kernel, and the guest agent adds its
    # own overhead on top.
    for (my $off = 0; $off < length $b64; $off += 48_000) {
        my $part = substr($b64, $off, 48_000);
        guest_exec($vmid, "printf %s '$part' >> $guest_path.b64");
    }
    guest_exec($vmid, "base64 -d $guest_path.b64 > $guest_path "
        . "&& rm -f $guest_path.b64");
    return length $data;
}

my sub backup_dir_for {
    my ($scfg, $name) = @_;

    my $dir = $scfg->{'backup-dir'}
        or die "cluster '$name' has no backup-dir configured "
        . "(set one at create time, e.g. a PBS-mounted or "
        . "shared directory)\n";
    die "backup-dir '$dir' does not exist on this host\n"
        if !-d $dir;
    return $dir;
}

# Etcd backup (T3.1): snapshot on a control-plane node,
# fetched off-cluster to backup-dir with a manifest sidecar,
# retention-pruned. Leader-stamped like the scaler so the
# timer on every host produces one backup, not N.
sub backup_cluster {
    my ($name) = @_;

    return 0 if !claim_scaler_leadership($name);
    my $done = eval {
        my $cfg = PVE::K8s::Config->config();
        my $scfg = $cfg->{ids}->{$name}
            or die "cluster '$name' does not exist\n";
        my $dir = backup_dir_for($scfg, $name);
        my $nodes = load_nodes($name, $scfg);
        my $cp = ops_cp($nodes);
        my $guest_file = etcd_snapshot($cp);
        my $stamp = time();
        my $file = "$dir/$name-etcd-$stamp.db";
        my $size = guest_fetch_file($cp->{vmid}, $guest_file, $file);
        my $sha = do {
            require Digest::SHA;
            my $d = Digest::SHA->new(256);
            $d->addfile($file);
            $d->hexdigest;
        };
        # The PKI (CA, etcd CA, SA keys) travels with the
        # snapshot: without it a fresh control-plane set
        # would mint a new CA and every worker certificate
        # would become invalid (T3.1b). It contains the
        # cluster CA private key - files are 0600 and the
        # backup-dir must be protected accordingly.
        guest_exec($cp->{vmid},
            'tar czf /tmp/pve-k8s-pki.tgz -C /etc/kubernetes pki');
        my $pki_size = guest_fetch_file($cp->{vmid},
            '/tmp/pve-k8s-pki.tgz', "$file.pki.tgz");
        my $pki_sha = do {
            require Digest::SHA;
            my $d = Digest::SHA->new(256);
            $d->addfile("$file.pki.tgz");
            $d->hexdigest;
        };
        chmod 0600, $file, "$file.pki.tgz";
        my $manifest = JSON::PP->new->canonical->encode({
            cluster => $name, file => "$name-etcd-$stamp.db",
            size => $size + 0, sha256 => $sha, at => $stamp,
            'k8s-version' => $scfg->{'k8s-version'},
            from => $cp->{host},
            pki => { file => "$name-etcd-$stamp.db.pki.tgz",
                size => $pki_size + 0, sha256 => $pki_sha },
        });
        open my $mf, '>', "$file.json" or die "$file.json: $!\n";
        print $mf "$manifest\n";
        close $mf;
        print "etcd backup for '$name': $file "
            . "($size bytes, sha256 $sha)\n";

        my $keep = $scfg->{'backup-retention'} // 7;
        my @backups = sort grep { -f }
            glob("$dir/$name-etcd-*.db");
        while (@backups > $keep) {
            my $old = shift @backups;
            unlink $old, "$old.json", "$old.pki.tgz";
            print "pruned old backup $old\n";
        }
        1;
    };
    my $err = $@;
    release_scaler_leadership($name, $done // 0);
    die $err if $err;
    return $done;
}

# --- T3.5 hypervisor maintenance: evacuate every managed
# cluster VM off a PVE host by live migration (local disks
# included), so the host can be serviced with the clusters
# staying up. Workers move first; control-plane members
# move one at a time with an API health gate between them.

sub evacuation_plan {
    my ($nodes, $source, $hosts, $group_of) = @_;

    my @targets = grep { $_->{pvehost} eq $source } $nodes->@*;
    return [] if !@targets;

    my @candidates = grep { $_ ne $source } $hosts->@*;
    die "no other online PVE host can take VMs from '$source'\n"
        if !@candidates;

    my (%total, %cps, %pool);
    for my $node ($nodes->@*) {
        $total{$node->{pvehost}}++;
        $cps{"$node->{cluster}:$node->{pvehost}"}++
            if $node->{role} eq 'cp';
        $pool{"$node->{cluster}:$node->{pool}:$node->{pvehost}"}++;
    }

    my @plan;
    my @ordered = (
        (grep { $_->{role} ne 'cp' } @targets),
        (grep { $_->{role} eq 'cp' } @targets),
    );
    for my $node (@ordered) {
        my ($best, $best_key);
        for my $host (@candidates) {
            my $group = $group_of->{$host} // $host;
            my $key = $node->{role} eq 'cp'
                ? [ $cps{"$node->{cluster}:$host"} // 0,
                    $total{$host} // 0 ]
                : [ $pool{"$node->{cluster}:$node->{pool}:$host"} // 0,
                    $total{$host} // 0 ];
            my $better = !$best;
            if ($best) {
                for my $i (0 .. $key->$#*) {
                    next if $key->[$i] == $best_key->[$i];
                    $better = $key->[$i] < $best_key->[$i];
                    last;
                }
            }
            ($best, $best_key) = ($host, $key) if $better;
        }
        push @plan, {
            cluster => $node->{cluster}, host => $node->{host},
            vmid => $node->{vmid}, role => $node->{role},
            pool => $node->{pool},
            from => $source, to => $best,
        };
        $total{$best}++;
        $cps{"$node->{cluster}:$best"}++ if $node->{role} eq 'cp';
        $pool{"$node->{cluster}:$node->{pool}:$best"}++;
        $total{$source}--;
    }
    return \@plan;
}

my sub update_node_pvehost {
    my ($name, $nodename, $newhost) = @_;

    PVE::K8s::Config::lock_config(sub {
        my $cfg = PVE::K8s::Config->config();
        my $inventory = JSON::PP->new->decode(
            $cfg->{ids}->{$name}->{nodes});
        for my $item ($inventory->@*) {
            $item->{pvehost} = $newhost
                if $item->{name} eq $nodename;
        }
        $cfg->{ids}->{$name}->{nodes} =
            JSON::PP->new->canonical->encode($inventory);
        PVE::K8s::Config::store_config($cfg);
    });
}

my sub vm_has_local_disks {
    my ($vmid, $host) = @_;

    my $cfg = qm_on($host, 'config', $vmid);
    my %storage;
    while ($cfg =~ /^(?:scsi|virtio|ide|sata)\d+:\s+([^:,]+):/mg) {
        $storage{$1} = 1;
    }
    return 0 if !%storage;
    my $out = run(['pvesh', 'get', "/nodes/$host/storage",
        '--output-format', 'json'], timeout => 60);
    my $entries = decode_pvesh_json($out);
    my %shared = map {
        (($_->{storage} // '') =~ /^([a-zA-Z0-9_.-]+)$/)
            ? ($1 => ($_->{shared} // 0)) : ()
    } $entries->@*;
    for my $id (keys %storage) {
        return 1 if !($shared{$id} // 0);
    }
    return 0;
}

my sub migrate_vm_live {
    my ($step) = @_;

    my ($vmid, $from, $to) = $step->@{qw(vmid from to)};
    # Trust live placement, not the plan's snapshot: the
    # VM may already sit on the target (a previous partial
    # evacuation, a manual migration) or on a third host
    # (stale resource view). Migrating from where the VM
    # is not fails in qm before anything moves.
    my $live = cluster_vms();
    my $current = $live->{$step->{host}}->{node} // $from;
    if ($current eq $to) {
        print "$step->{host} (vmid $vmid) already on $to\n";
        return 1;
    }
    $from = $current;
    my $with_local = vm_has_local_disks($vmid, $from);
    print "migrating $step->{host} (vmid $vmid) $from -> $to"
        . ($with_local ? ' with local disks' : '') . "\n";
    my $started = time();
    # Detached on the source host: pvesh create stays
    # attached to the migration task, so a client-side
    # timeout aborts the migration with a broken pipe.
    my $migrate_cmd = "setsid qm migrate $vmid $to --online"
        . ($with_local ? ' --with-local-disks' : '')
        . " >/root/k8s-migrate-$vmid.log 2>&1 </dev/null &"
        . ' echo launched';
    host_run_on($from, '/bin/sh', '-c', $migrate_cmd);
    # Local-disk migrations of large VMs legitimately run
    # for hours; poll until the VM lands on the target.
    # Fail fast on a dead migration task (below) or when
    # the migration log stops advancing for 30 minutes
    # (a genuinely stuck migration), with a 12-hour hard
    # cap so a maintenance window can never hang forever.
    my $deadline = $started + 12 * 3600;
    my ($last_progress, $last_mtime) = (time(), -1);
    while (time() < $deadline) {
        my $vms = cluster_vms();
        my $vm = $vms->{$step->{host}};
        if ($vm && $vm->{node} eq $to) {
            my $status = qm_on($to, 'status', $vmid);
            return 1 if $status =~ /status:\s*running/;
        }
        my $mtime = eval {
            my $out = host_run_on($from, 'stat', '-c', '%Y',
                "/root/k8s-migrate-$vmid.log");
            $out =~ /(\d+)/ ? int $1 : undef;
        };
        if (defined $mtime) {
            if ($mtime != $last_mtime) {
                ($last_mtime, $last_progress) = ($mtime, time());
            } elsif (time() - $last_progress > 1800) {
                die "migration of $step->{host} (vmid $vmid) "
                    . "stalled: no progress in the migration "
                    . "log for 30 minutes (see "
                    . "/root/k8s-migrate-$vmid.log on $from)\n";
            }
        }
        # Fail fast when the migration task itself dies
        # (e.g. linked-clone disks PVE refuses to move)
        # instead of polling the full timeout.
        my $tasks = eval {
            decode_pvesh_json(run(['pvesh', 'get',
                "/nodes/$from/tasks", '--vmid', $vmid,
                '--type', 'qmigrate', '--limit', 1,
                '--output-format', 'json'], timeout => 60));
        } // [];
        if (my ($task) = grep {
                ($_->{endtime} // 0) >= $started - 120
            } $tasks->@*) {
            die "migration of $step->{host} (vmid $vmid) "
                . "failed: " . ($task->{status} // 'unknown')
                . " (see qmigrate task on $from)\n";
        }
        sleep 15;
    }
    die "migration of $step->{host} (vmid $vmid) to $to "
        . "did not complete\n";
}

my sub wait_cluster_ready {
    my ($name, $nodes) = @_;

    my $total = scalar $nodes->@*;
    for (1 .. 24) {
        my $ok = eval {
            my $cp = ops_cp($nodes);
            my $out = guest_exec($cp->{vmid},
                'kubectl --kubeconfig /etc/kubernetes/admin.conf '
                . 'get nodes --no-headers');
            my @ready = grep { /\sReady\s/ } split /\n/, $out;
            scalar @ready == $total;
        } // 0;
        return 1 if $ok;
        sleep 15;
    }
    die "cluster '$name' did not return to $total Ready "
        . "nodes after a control-plane migration\n";
}

sub evacuate_host {
    my ($host) = @_;

    ($host) = $host =~ /^([a-zA-Z0-9._-]+)$/
        or die "invalid PVE host name '$host'\n";

    my $hosts = pve_online_nodes();
    die "PVE host '$host' is not online\n"
        if !grep { $_ eq $host } $hosts->@*;
    my $group_of = ha_group_by_host();

    my $cfg = PVE::K8s::Config->config();
    my $live = cluster_vms();
    my (@all_nodes, %nodes_by_cluster);
    for my $name (sort keys $cfg->{ids}->%*) {
        my $scfg = $cfg->{ids}->{$name};
        next if !$scfg->{nodes};
        my $nodes = load_nodes($name, $scfg);
        $nodes_by_cluster{$name} = $nodes;
        push @all_nodes, map {
            { cluster => $name, host => $_->{host},
              vmid => $_->{vmid},
              # Live placement wins over the stored
              # inventory: a previous evacuation (or a
              # manual migration) may have moved the VM
              # after the inventory was written.
              pvehost => ($live->{$_->{host}}->{node}
                  // $_->{pvehost}),
              stored_pvehost => $_->{pvehost},
              pool => $_->{pool}, role => $_->{role} }
        } $nodes->@*;
    }
    # Converge the stored inventory onto live placement
    # before planning, so re-running an evacuation after
    # a partial (or manual) move finishes the job instead
    # of migrating VMs that already left the host.
    for my $node (@all_nodes) {
        next if $node->{pvehost} eq $node->{stored_pvehost};
        update_node_pvehost($node->{cluster}, $node->{host},
            $node->{pvehost});
        print "$node->{host} inventory reconciled: "
            . "$node->{stored_pvehost} -> $node->{pvehost}\n";
    }

    my $plan = evacuation_plan(\@all_nodes, $host, $hosts,
        $group_of);
    if (!$plan->@*) {
        print "no managed cluster VMs on PVE host '$host'\n";
        return 0;
    }

    for my $step ($plan->@*) {
        migrate_vm_live($step);
        update_node_pvehost($step->{cluster}, $step->{host},
            $step->{to});
        print "$step->{host} now on $step->{to}\n";
        if ($step->{role} eq 'cp') {
            wait_cluster_ready($step->{cluster},
                $nodes_by_cluster{$step->{cluster}});
            print "cluster '$step->{cluster}' healthy after "
                . "control-plane move\n";
        }
    }
    print "PVE host '$host' evacuated: " . scalar($plan->@*)
        . " cluster VM(s) live-migrated\n";
    return scalar $plan->@*;
}

# --- T3.3 add-ons: Cilium ingress/Gateway ship with every
# cluster; cert-manager and external-dns are must-deploy but
# stay "unconfigured" until enabled here; the rest are
# catalog entries for a later add/remove UI.

sub addons_state {
    my ($scfg) = @_;

    return {} if !$scfg->{addons};
    my $state = eval {
        JSON::PP->new->decode($scfg->{addons}) };
    return $state // {};
}

sub list_addons {
    my ($name) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    my $state = addons_state($scfg);

    my @addons = ({
        name => 'cilium-ingress',
        status => ($scfg->{state} // '') eq 'ready'
            ? 'installed' : 'pending',
        mustdeploy => 0,
        summary => 'Cilium ingress controller + Gateway API '
            . '(part of the Cilium install)',
    });
    for my $addon (
        ['cert-manager', 'TLS certificates (internal CA by '
            . 'default, ACME optional)'],
        ['external-dns', 'Publishes Ingress/Gateway hostnames '
            . 'to a DNS provider (PowerDNS)'],
    ) {
        my ($addon_name, $summary) = @$addon;
        my $conf = $state->{$addon_name};
        push @addons, {
            name => $addon_name,
            status => $conf ? 'configured' : 'unconfigured',
            mustdeploy => 1,
            summary => $summary,
            ($conf ? (config => $conf) : ()),
        };
    }
    for my $addon (
        ['cilium-mesh', 'Cilium service mesh features (mTLS, '
            . 'L7 policy, Hubble)'],
        ['prometheus', 'Prometheus/Grafana monitoring stack'],
        ['velero', 'Application-level backup to object '
            . 'storage'],
    ) {
        my ($addon_name, $summary) = @$addon;
        push @addons, {
            name => $addon_name,
            status => 'available',
            mustdeploy => 0,
            summary => $summary,
        };
    }
    return \@addons;
}

sub enable_addon {
    my ($name, $addon, $opts) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    die "cluster '$name' is not ready\n"
        if ($scfg->{state} // '') ne 'ready';

    my $nodes = load_nodes($name, $scfg);
    my $cp = ops_cp($nodes);
    my $kubeconfig = '/etc/kubernetes/admin.conf';
    my %record;

    if ($addon eq 'cert-manager') {
        my $issuer_yaml =
            PVE::K8s::Addons::certmanager_issuer_yaml($opts);
        guest_exec($cp->{vmid},
            PVE::K8s::Addons::certmanager_install_cmd(
                $kubeconfig, $issuer_yaml));
        %record = (
            issuer => $opts->{issuer} // 'ca',
            ($opts->{email} ? (email => $opts->{email}) : ()),
        );
        print "cert-manager enabled on cluster '$name' "
            . "with issuer '$record{issuer}'\n";
    } elsif ($addon eq 'external-dns') {
        my $values =
            PVE::K8s::Addons::external_dns_values_yaml(
                $name, $opts);
        my $api_key = $opts->{'pdns-api-key'}
            or die "external-dns needs a pdns-api-key\n";
        guest_exec($cp->{vmid},
            PVE::K8s::Addons::external_dns_install_cmd(
                $kubeconfig, $values, $api_key));
        # the API key lives only in the in-cluster Secret,
        # never in the cluster config on pmxcfs
        %record = (
            provider => $opts->{provider} // 'pdns',
            'pdns-url' => $opts->{'pdns-url'},
            zone => $opts->{zone},
        );
        print "external-dns enabled on cluster '$name' "
            . "for zone '$record{zone}'\n";
    } else {
        die "add-on '$addon' cannot be enabled "
            . "(want cert-manager or external-dns)\n";
    }

    PVE::K8s::Config::lock_config(sub {
        my $locked = PVE::K8s::Config->config();
        my $state = addons_state($locked->{ids}->{$name});
        $state->{$addon} = \%record;
        $locked->{ids}->{$name}->{addons} =
            JSON::PP->new->canonical->encode($state);
        PVE::K8s::Config::store_config($locked);
    });
    return 1;
}

sub list_backups {
    my ($name) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    return [] if !$scfg->{'backup-dir'} || !-d $scfg->{'backup-dir'};
    my $dir = $scfg->{'backup-dir'};
    my @out;
    for my $file (sort glob("$dir/$name-etcd-*.db")) {
        my @st = stat $file;
        next if !@st;
        my ($base) = $file =~ m{/([^/]+)$};
        push @out, { file => $base, size => $st[7],
            mtime => $st[9] };
    }
    return \@out;
}

# Etcd restore (T3.1): roll every control-plane member back
# to one snapshot. Certificates are untouched; only the
# etcd data directories are replaced (old ones kept as
# /var/lib/etcd.pre-restore-<ts>). Requires force=1 and a
# healthy VM set - this is a data rollback, not a repair.
sub restore_cluster {
    my ($name, $file, %opts) = @_;

    die "restore requires explicit confirmation (force=1)\n"
        if !$opts{force};
    die "invalid backup file name '$file'\n"
        if ($file // '') !~ /^[\w.-]+$/;
    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    my $dir = backup_dir_for($scfg, $name);
    my $path = "$dir/$file";
    die "backup '$file' not found in $dir\n" if !-f $path;
    my $subnet = $scfg->{'node-subnet'} or die "no node-subnet\n";
    $subnet =~ m|^(\d+\.\d+\.\d+)\.0/24$|
        or die "bad node-subnet\n";
    my $vip = PVE::K8s::Config::vip_for($scfg);

    my $nodes = load_nodes($name, $scfg);
    my @cps = grep { $_->{role} eq 'cp' } $nodes->@*;
    my $initial = join ',', map {
        "$_->{host}=https://$_->{ip}:2380" } @cps;
    my $token = 'pve-k8s-restore-' . time();

    # Fresh-set restore (T3.1b): control-plane VMs that no
    # longer exist are recreated blank and rebuilt from the
    # backup's PKI + etcd data, keeping the cluster's
    # original identity. Only when NO control-plane node
    # answers - with quorum alive the right move is member
    # replacement, not a snapshot rollback.
    my $vms = cluster_vms();
    my (@fresh, @answering);
    for my $cp (@cps) {
        if (!$vms->{$cp->{host}}) {
            push @fresh, $cp;
            next;
        }
        my $ok = eval {
            qm_on($cp->{pvehost}, 'agent', $cp->{vmid}, 'ping');
            1;
        } // 0;
        if ($ok) {
            # A VM recreated by an earlier, interrupted
            # fresh restore answers the agent but has no
            # control plane yet: it is fresh, not answering.
            my $has_cp = eval {
                guest_exec($cp->{vmid},
                    'test -f /etc/kubernetes/admin.conf');
                1;
            } // 0;
            if ($has_cp) {
                push @answering, $cp;
            } else {
                push @fresh, $cp;
            }
        }
    }
    if (@fresh && @answering) {
        die "control-plane VM(s) missing ("
            . join(', ', map { $_->{host} } @fresh)
            . ") but quorum survives on "
            . join(', ', map { $_->{host} } @answering)
            . "; replace the missing member(s) via "
            . "provision/roll instead of restoring a backup\n";
    }
    if (@fresh) {
        die "backup '$file' has no PKI archive; fresh-set "
            . "restore is impossible (workers could not "
            . "trust a new CA)\n" if !-f "$path.pki.tgz";
        my $ctx = { version => $scfg->{'k8s-version'},
            template => find_template($scfg->{'k8s-version'}),
            # node gateway always derives from the NODE
            # subnet (the VIP may live on the public one)
            gateway => $scfg->{gateway}
                // do { my $g = $subnet; $g =~ s|\.0/24$|.1|; $g },
            storage => $scfg->{storage} // 'local-zfs',
            bridge => cluster_bridge($scfg) };
        my $hosts = pve_online_nodes();
        my $group_of = ha_group_by_host();
        for my $cp (@fresh) {
            my %online = map { $_ => 1 } $hosts->@*;
            $cp->{pvehost} = ($cp->{pvehost}
                && $online{$cp->{pvehost}})
                ? $cp->{pvehost}
                : choose_host($hosts, $group_of, {}, 'cp');
            $cp->{site} = $group_of->{$cp->{pvehost}}
                // $cp->{pvehost};
            if (!$vms->{$cp->{host}}) {
                create_node_vm($ctx, $cp, node_userdata(
                    hostname => $cp->{host}, role => 'cp',
                    enc_key => (-s "/etc/pve/k8s/keys/$name.key")
                        ? cluster_encryption_key($name) : undef,
                    vip => $vip));
                print "recreated fresh control-plane VM "
                    . "$cp->{host} (vmid $cp->{vmid} on "
                    . "$cp->{pvehost})\n";
            }
        }
    }
    my %fresh_vm = map { $_->{vmid} => 1 } @fresh;

    # Fast path: when this host owns the cluster gateway
    # address, serve the backup over HTTP and let the
    # guests curl it; otherwise fall back to chunked push.
    my $gateway = $scfg->{gateway} // '';
    my $serve_pid;
    if ($gateway && host_run_on(undef, 'ip', '-o', 'addr', 'show')
        =~ /inet \Q$gateway\E\//) {
        $serve_pid = fork();
        if (!defined $serve_pid) {
            $serve_pid = undef;
        } elsif ($serve_pid == 0) {
            exec('python3', '-m', 'http.server', '18099',
                '--bind', $gateway, '--directory', $dir);
            exit 1;
        } else {
            sleep 2;
        }
    }
    for my $cp (@cps) {
        if ($serve_pid) {
            my ($base) = $path =~ m{/([^/]+)$};
            guest_exec($cp->{vmid},
                "curl -fsS http://$gateway:18099/$base "
                . '-o /var/lib/restore.db');
        } else {
            guest_push_file($cp->{vmid}, $path,
                '/var/lib/restore.db');
        }
    }
    for my $cp (@fresh) {
        if ($serve_pid) {
            guest_exec($cp->{vmid},
                "curl -fsS http://$gateway:18099/$file.pki.tgz "
                . '-o /tmp/pki.tgz');
        } else {
            guest_push_file($cp->{vmid}, "$path.pki.tgz",
                '/tmp/pki.tgz');
        }
        guest_exec($cp->{vmid},
            'mkdir -p /etc/kubernetes && '
            . 'tar xzf /tmp/pki.tgz -C /etc/kubernetes && '
            . 'test -f /etc/kubernetes/pki/ca.key');
        print "installed backed-up PKI on fresh "
            . "$cp->{host}\n";
    }
    if ($serve_pid) {
        kill 'TERM', $serve_pid;
        waitpid $serve_pid, 0;
    }
    for my $cp (@cps) {
        # Stopping kubelet does NOT stop static pods, so:
        # manifests away first (running kubelet kills the
        # control plane), wait for etcd to actually close,
        # only then stop kubelet and swap the data dir.
        guest_exec($cp->{vmid},
            'mkdir -p /root/manifests-restore; '
            . 'mv /etc/kubernetes/manifests/*.yaml '
            . '/root/manifests-restore/; '
            . 'for i in $(seq 1 40); do '
            . 'ss -tln | grep -q :2379 || break; sleep 3; done; '
            . 'systemctl stop kubelet; '
            . 'mv /var/lib/etcd /var/lib/etcd.pre-restore-'
            . time() . ' 2>/dev/null || true; '
            . 'mkdir -p /var/lib/etcd');
    }
    for my $cp (@cps) {
        my $cmd = 'IMG=$(ctr -n k8s.io containers list '
            . "| awk '\$2 ~ /etcd/ {print \$2; exit}'); "
            . '[ -z "$IMG" ] && IMG=$(ctr -n k8s.io images '
            . "list | awk '\$1 ~ /etcd/ {print \$1; exit}'); "
            . 'ctr -n k8s.io run --rm '
            . '--mount type=bind,src=/var/lib,'
            . 'dst=/varlib,options=rbind '
            . '"$IMG" etcdutl-restore etcdutl snapshot restore '
            . '/varlib/restore.db '
            . "--name $cp->{host} "
            . "--initial-cluster $initial "
            . "--initial-cluster-token $token "
            . "--initial-advertise-peer-urls "
            . "https://$cp->{ip}:2380 "
            . '--data-dir /varlib/etcd';
        guest_exec($cp->{vmid}, $cmd);
    }
    # Fresh members need their kubeadm phases (certs and
    # kubeconfigs are skipped where the backed-up PKI
    # already provides them) before kubelet starts.
    for my $cp (@fresh) {
        my $full = guest_exec($cp->{vmid},
            'kubeadm version -o short');
        $full =~ s/\s+//g;
        $full =~ s/^v//;
        guest_exec($cp->{vmid},
            "cat > /root/kubeadm-restore.yaml <<'CFG'
"
            . "apiVersion: kubeadm.k8s.io/v1beta4
"
            . "kind: ClusterConfiguration
"
            . "kubernetesVersion: v$full
"
            . "controlPlaneEndpoint: \"$vip:6443\"
"
            . "networking:
"
            . "  podSubnet: 10.244.0.0/16
"
            . "  serviceSubnet: 10.96.0.0/12
"
            . "etcd:
  local:
    extraArgs:
"
            . "      - {name: heartbeat-interval, value: \"500\"}
"
            . "      - {name: election-timeout, value: \"5000\"}
"
            . "apiServer:
  certSANs:
"
            . "    - \"$vip\"
    - \"$cp->{ip}\"
"
            . ((-s "/etc/pve/k8s/keys/$name.key")
                ? "  extraArgs:
"
                . "    - {name: encryption-provider-config, value: /etc/kubernetes/enc/enc.yaml}
"
                . "  extraVolumes:
"
                . "    - name: enc
"
                . "      hostPath: /etc/kubernetes/enc
"
                . "      mountPath: /etc/kubernetes/enc
"
                . "      readOnly: true
"
                . "      pathType: DirectoryOrCreate
"
                : '')
            . "CFG
"
            . 'kubeadm init phase certs all '
            . '--config /root/kubeadm-restore.yaml; '
            . 'kubeadm init phase kubeconfig all '
            . '--config /root/kubeadm-restore.yaml; '
            . 'kubeadm init phase kubelet-start '
            . '--config /root/kubeadm-restore.yaml; '
            . 'kubeadm init phase etcd local '
            . '--config /root/kubeadm-restore.yaml; '
            . 'kubeadm init phase control-plane all '
            . '--config /root/kubeadm-restore.yaml');
        print "kubeadm phases complete on fresh $cp->{host}\n";
    }
    for my $cp (@cps) {
        guest_exec($cp->{vmid},
            'mv /root/manifests-restore/*.yaml '
            . '/etc/kubernetes/manifests/ 2>/dev/null || true; '
            . 'systemctl start kubelet');
    }
    my $cp1 = $cps[0];
    my $api_back = 0;
    for (1 .. 40) {
        my $ok = eval {
            my $out = kubectl_on($cp1, 'get nodes --no-headers');
            ($out =~ tr/\n/\n/) >= 1;
        } // 0;
        if ($ok) { $api_back = 1; last }
        sleep 15;
    }
    die "control plane did not come back after restore\n"
        if !$api_back;
    # Kubelets that lived through the rollback wedge in
    # two ways: CP kubelets started while their local
    # apiserver was down never retry CSINode
    # initialization, and worker kubelets loop on status
    # for pods the rollback deleted. Restart every kubelet
    # once the API is healthy, then wait for Ready.
    for my $node ($nodes->@*) {
        eval { guest_exec($node->{vmid},
            'systemctl restart kubelet') };
    }
    for (1 .. 40) {
        my $out = eval {
            kubectl_on($cp1, 'get nodes --no-headers') } // '';
        my $ready = () = $out =~ /^\S+\s+Ready\b/gm;
        if ($ready >= scalar @cps) {
            for my $cp (@fresh) {
                eval { kubectl_on($cp1,
                    "label node $cp->{host} "
                    . 'node-role.kubernetes.io/control-plane= '
                    . '--overwrite') };
                eval { kubectl_on($cp1,
                    "taint node $cp->{host} "
                    . 'node-role.kubernetes.io/control-plane:'
                    . 'NoSchedule --overwrite') };
            }
            print "etcd restored from $file on "
                . scalar(@cps) . " control-plane node(s), "
                . "all Ready\n";
            return 1;
        }
        sleep 15;
    }
    die "control-plane nodes did not become Ready "
        . "after restore\n";
}

# Recent Kubernetes events, newest last, as flat rows for
# the UI events view (PVE-side actions are the task log).
sub cluster_events {
    my ($name, $limit) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    my $nodes = load_nodes($name, $scfg);
    my $cp = ops_cp($nodes);
    my $data = kubectl_json($cp,
        'get events -A --sort-by=.lastTimestamp');
    my @events;
    for my $e (($data->{items} // [])->@*) {
        # core v1 Event and events.k8s.io/v1 Event shapes
        my $obj = $e->{involvedObject} // $e->{regarding} // {};
        push @events, {
            time => $e->{lastTimestamp} // $e->{eventTime}
                // $e->{metadata}{creationTimestamp} // '',
            type => $e->{type} // '',
            reason => $e->{reason} // '',
            object => ($obj->{kind} // '') . '/'
                . ($obj->{name} // ''),
            message => $e->{message} // $e->{note} // '',
        };
    }
    $limit //= 100;
    @events = @events[-$limit .. -1] if @events > $limit;
    return \@events;
}

sub upgrade_cluster {
    my ($name, $target, %opts) = @_;

    my $cfg = PVE::K8s::Config->config();
    my $scfg = $cfg->{ids}->{$name}
        or die "cluster '$name' does not exist\n";
    my $to = assert_minor_upgrade($scfg->{'k8s-version'}, $target);
    # template must exist before anything is touched
    find_template($to);
    return roll_cluster($name, target_version => $to, force => $opts{force});
}

1;
