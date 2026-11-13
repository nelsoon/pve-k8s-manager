# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Scaler;

use strict;
use warnings;

# Scheduling simulation for the autoscaler (T2.4). Pure
# functions over decoded Kubernetes API objects: the scaler
# never acts on a count, it test-schedules pods against real
# and simulated nodes first (the Cluster Autoscaler model),
# so label/taint/affinity/resource rules are honoured before
# any VM is cloned or drained.

sub parse_cpu {
    my ($q) = @_;
    return 0 if !defined $q;
    return int($1 * 1000) if $q =~ /^(\d+(?:\.\d+)?)$/;
    return int $1 if $q =~ /^(\d+)m$/;
    die "unparsable cpu quantity '$q'\n";
}

my %MEM_MULT = (
    Ki => 1024, Mi => 1024**2, Gi => 1024**3, Ti => 1024**4,
    K => 1000, M => 1000**2, G => 1000**3, T => 1000**4,
);

sub parse_mem {
    my ($q) = @_;
    return 0 if !defined $q;
    return int $1 if $q =~ /^(\d+)$/;
    return int($1 * $MEM_MULT{$2}) if $q =~ /^(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|K|M|G|T)$/;
    die "unparsable memory quantity '$q'\n";
}

# Effective pod requests: app containers summed, init
# containers take the max single one (Kubernetes rules).
sub pod_requests {
    my ($pod) = @_;

    my $spec = $pod->{spec} // {};
    my ($cpu, $mem) = (0, 0);
    for my $c (($spec->{containers} // [])->@*) {
        my $r = $c->{resources}{requests} // {};
        $cpu += parse_cpu($r->{cpu});
        $mem += parse_mem($r->{memory});
    }
    for my $c (($spec->{initContainers} // [])->@*) {
        my $r = $c->{resources}{requests} // {};
        $cpu = parse_cpu($r->{cpu}) if parse_cpu($r->{cpu}) > $cpu;
        $mem = parse_mem($r->{memory}) if parse_mem($r->{memory}) > $mem;
    }
    return { cpu => $cpu, mem => $mem };
}

# Labels a node of this pool carries (mirrors label_node).
sub pool_node_labels {
    my ($pool) = @_;

    my %labels = ('pve-k8s.proxmox.com/pool' => $pool->{name});
    # kubelet sets this on real nodes; simulated nodes of
    # an arch-pinned group must carry it too, or a pending
    # arm64-only pod would trigger amd64 scale-out (or the
    # reverse) in simulation.
    $labels{'kubernetes.io/arch'} = $pool->{arch} if $pool->{arch};
    for my $kv (split /\s*,\s*/, $pool->{labels} // '') {
        $labels{$1} = $2 if $kv =~ /^([^=]+)=(.*)$/;
    }
    return \%labels;
}

sub parse_taints {
    my ($pool) = @_;

    my @taints;
    for my $t (split /\s*,\s*/, $pool->{taints} // '') {
        next if $t eq '';
        if ($t =~ /^([^=:]+)(?:=([^:]*))?:(\w+)$/) {
            push @taints, { key => $1, value => $2, effect => $3 };
        }
    }
    return \@taints;
}

my sub tolerates {
    my ($pod, $taints) = @_;

    my @tol = ($pod->{spec}{tolerations} // [])->@*;
    for my $taint ($taints->@*) {
        next if $taint->{effect} ne 'NoSchedule'
            && $taint->{effect} ne 'NoExecute';
        my $ok = grep {
            ($_->{effect} // $taint->{effect}) eq $taint->{effect}
            && ($_->{key} // '') eq $taint->{key}
            && (($_->{operator} // 'Equal') eq 'Exists'
                || (($_->{value} // '') eq ($taint->{value} // '')))
        } @tol;
        return 0 if !$ok;
    }
    return 1;
}

my sub match_expressions {
    my ($labels, $exprs) = @_;

    for my $e ($exprs->@*) {
        my ($key, $op) = $e->@{qw(key operator)};
        my @vals = ($e->{values} // [])->@*;
        if ($op eq 'In') {
            return 0 if !defined $labels->{$key}
                || !grep { $_ eq $labels->{$key} } @vals;
        } elsif ($op eq 'NotIn') {
            return 0 if defined $labels->{$key}
                && grep { $_ eq $labels->{$key} } @vals;
        } elsif ($op eq 'Exists') {
            return 0 if !defined $labels->{$key};
        } elsif ($op eq 'DoesNotExist') {
            return 0 if defined $labels->{$key};
        } else {
            return 0;
        }
    }
    return 1;
}

my sub affinity_ok {
    my ($pod, $labels) = @_;

    my $sel = $pod->{spec}{nodeSelector} // {};
    for my $k (keys $sel->%*) {
        return 0 if ($labels->{$k} // '') ne $sel->{$k};
    }
    my $req = $pod->{spec}{affinity}{nodeAffinity}
        {requiredDuringSchedulingIgnoredDuringExecution};
    return 1 if !$req;
    # terms are OR-ed, expressions within a term are AND-ed
    for my $term (($req->{nodeSelectorTerms} // [])->@*) {
        return 1 if match_expressions($labels,
            $term->{matchExpressions} // []);
    }
    return 0;
}

# Required pod anti-affinity on hostname: a pod may not join
# a node already running a pod matching its selector.
my sub anti_affinity_ok {
    my ($pod, $node) = @_;

    my $req = $pod->{spec}{affinity}{podAntiAffinity}
        {requiredDuringSchedulingIgnoredDuringExecution} // [];
    for my $term ($req->@*) {
        next if ($term->{topologyKey} // '') ne 'kubernetes.io/hostname';
        my $want = $term->{labelSelector}{matchLabels} // {};
        for my $other ($node->{pods}->@*) {
            my $ol = $other->{metadata}{labels} // {};
            my $same = !grep { ($ol->{$_} // '') ne $want->{$_} }
                keys $want->%*;
            return 0 if $same && keys $want->%*;
        }
    }
    return 1;
}

# One simulated node: { name, labels, taints, cpu, mem,
# used_cpu, used_mem, pods }.
sub make_node {
    my ($name, $labels, $taints, $cpu, $mem) = @_;

    return { name => $name, labels => $labels, taints => $taints,
        cpu => $cpu, mem => $mem, used_cpu => 0, used_mem => 0,
        pods => [] };
}

sub pod_fits_node {
    my ($pod, $node) = @_;

    return 0 if !affinity_ok($pod, $node->{labels});
    return 0 if !tolerates($pod, $node->{taints});
    return 0 if !anti_affinity_ok($pod, $node);
    my $r = pod_requests($pod);
    return 0 if $node->{used_cpu} + $r->{cpu} > $node->{cpu};
    return 0 if $node->{used_mem} + $r->{mem} > $node->{mem};
    return 1;
}

# Greedy placement: mutates node used/pods, returns
# (placed, unplaced) pod lists.
sub place_pods {
    my ($nodes, $pods) = @_;

    my (@placed, @unplaced);
    for my $pod ($pods->@*) {
        my ($node) = grep { pod_fits_node($pod, $_) } $nodes->@*;
        if ($node) {
            my $r = pod_requests($pod);
            $node->{used_cpu} += $r->{cpu};
            $node->{used_mem} += $r->{mem};
            push $node->{pods}->@*, $pod;
            push @placed, $pod;
        } else {
            push @unplaced, $pod;
        }
    }
    return (\@placed, \@unplaced);
}

my sub clone_nodes {
    my ($nodes) = @_;
    return [map {
        my $n = { $_->%* };
        $n->{pods} = [$n->{pods}->@*];
        $n;
    } $nodes->@*];
}

# --- Increment 10: decisions that keep the scaler from acting
# on guesses. All pure and unit-tested.

# S10.1: what DaemonSets already consume on a node, so a simulated
# new node is not treated as empty. Taken from the first worker node
# that runs DaemonSet pods; zero when none does.
sub daemonset_overhead {
    my ($nodes) = @_;

    for my $n ($nodes->@*) {
        next if ($n->{labels}{'pve-k8s.proxmox.com/pool'} // '')
            eq 'control-plane';
        my ($cpu, $mem, $seen) = (0, 0, 0);
        for my $pod ($n->{pods}->@*) {
            next if (($pod->{metadata}{ownerReferences}[0]{kind})
                // '') ne 'DaemonSet';
            my $r = pod_requests($pod);
            $cpu += $r->{cpu};
            $mem += $r->{mem};
            $seen = 1;
        }
        return { cpu => $cpu, mem => $mem } if $seen;
    }
    return { cpu => 0, mem => 0 };
}

# S10.5: the size of a NEW node of $pool, so a pool at size 0 can
# still be considered. A live node of the same pool is the best
# evidence; otherwise the pool definition (allocatable is about 90%
# of the VM's memory); otherwise a conservative default. The
# DaemonSet overhead is subtracted from the usable capacity.
sub pool_template {
    my ($pool, $nodes, $overhead) = @_;

    $overhead //= { cpu => 0, mem => 0 };
    my ($live) = grep {
        ($_->{labels}{'pve-k8s.proxmox.com/pool'} // '')
            eq ($pool->{name} // '')
    } $nodes->@*;
    my ($cpu, $mem, $source);
    if ($live && $live->{cpu} && $live->{mem}) {
        ($cpu, $mem, $source) = ($live->{cpu}, $live->{mem}, 'live node');
    } elsif ($pool->{cpu} && $pool->{memory}) {
        ($cpu, $mem, $source) = ($pool->{cpu} * 1000,
            int($pool->{memory} * 1048576 * 0.9), 'pool definition');
    } else {
        ($cpu, $mem, $source) = (2000, int(4 * 1024**3 * 0.9),
            'default size');
    }
    return { cpu => $cpu, mem => $mem, source => $source,
        overhead_cpu => $overhead->{cpu}, overhead_mem => $overhead->{mem} };
}

# S10.5: among pools that can host the pending pods pick the one that
# adds the least capacity (least waste); ties keep config order.
# Candidates: { pool, needed, cpu, mem }.
sub choose_pool {
    my ($cands) = @_;

    my ($best, $best_cost);
    for my $c ($cands->@*) {
        my $cost = $c->{needed} * $c->{mem};
        if (!defined $best_cost || $cost < $best_cost) {
            ($best, $best_cost) = ($c, $cost);
        }
    }
    return $best;
}

# S10.6: how many nodes of $pool the Proxmox hosts can really take:
# memory left after a 1 GiB host reserve, limited to the pool's
# `hosts` list when set. Host objects are /cluster/resources rows.
sub host_capacity {
    my ($hosts, $pool, $reserve) = @_;

    $reserve //= 1024**3;
    my $need = ($pool->{memory} // 4096) * 1048576;
    my %allowed = map { $_ => 1 }
        grep { length } split /\s*,\s*/, ($pool->{hosts} // '');
    my $count = 0;
    for my $h ($hosts->@*) {
        next if ($h->{status} // 'online') ne 'online';
        next if %allowed && !$allowed{$h->{node} // ''};
        my $free = ($h->{maxmem} // 0) - ($h->{mem} // 0) - $reserve;
        $count += int($free / $need) if $free >= $need;
    }
    return $count;
}

# S10.4: no scale-in during the cooldown after any scale action.
sub scale_in_allowed {
    my ($state, $now, $cooldown) = @_;

    $cooldown //= 600;
    return $now - (($state // {})->{'last-action'} // 0) >= $cooldown
        ? 1 : 0;
}

# S10.4: a scale-in candidate must be one on consecutive passes.
# Returns (confirmed, new_candidate_record). A record older than
# $stale seconds, or for another node, starts over.
sub confirm_scale_in {
    my ($state, $host, $now, $need, $stale) = @_;

    $need //= 2;
    $stale //= 900;
    my $c = ($state // {})->{'scale-in-candidate'} // {};
    my $count = (($c->{host} // '') eq $host
        && $now - ($c->{at} // 0) <= $stale) ? ($c->{count} // 0) + 1 : 1;
    return ($count >= $need ? 1 : 0,
        { host => $host, count => $count, at => $now });
}

# S10.3: would draining a node be refused by a PodDisruptionBudget?
# Kubernetes already computes status.disruptionsAllowed; a PDB with
# none left that selects any evictable pod on the node blocks the
# drain. Returns the blocking "namespace/name" list. DaemonSet pods
# are ignored (drain skips them).
sub selector_matches {
    my ($sel, $labels) = @_;

    $labels //= {};
    return 0 if !ref $sel || !%$sel;    # an empty selector selects nothing here
    for my $k (keys %{$sel->{matchLabels} // {}}) {
        return 0 if ($labels->{$k} // "\0") ne $sel->{matchLabels}{$k};
    }
    for my $e (($sel->{matchExpressions} // [])->@*) {
        my ($k, $op, $vals) = ($e->{key}, $e->{operator} // '', $e->{values} // []);
        my $has = exists $labels->{$k};
        my $in = $has && grep { $_ eq $labels->{$k} } $vals->@*;
        return 0 if $op eq 'In' && !$in;
        return 0 if $op eq 'NotIn' && $in;
        return 0 if $op eq 'Exists' && !$has;
        return 0 if $op eq 'DoesNotExist' && $has;
    }
    return 1;
}

sub pdb_blockers {
    my ($pods, $pdbs) = @_;

    my %out;
    for my $pod ($pods->@*) {
        next if (($pod->{metadata}{ownerReferences}[0]{kind}) // '')
            eq 'DaemonSet';
        for my $pdb ($pdbs->@*) {
            next if ($pdb->{metadata}{namespace} // '')
                ne ($pod->{metadata}{namespace} // '');
            next if ($pdb->{status}{disruptionsAllowed} // 1) > 0;
            next if !selector_matches($pdb->{spec}{selector},
                $pod->{metadata}{labels});
            $out{"$pdb->{metadata}{namespace}/$pdb->{metadata}{name}"} = 1;
        }
    }
    return [sort keys %out];
}

# S10.12: the scheduler's own reason a pod is unschedulable
# (context for the log line, never a trigger).
sub scheduling_reason {
    my ($pod) = @_;

    for my $c (($pod->{status}{conditions} // [])->@*) {
        next if ($c->{type} // '') ne 'PodScheduled'
            || ($c->{status} // '') ne 'False';
        my $m = $c->{message} // '';
        $m =~ s/\s+/ /g;
        return length $m > 200 ? substr($m, 0, 197) . '...' : $m;
    }
    return '';
}

# S10.11: did a scale-out help? $rec = { pool, at, uids } recorded
# when nodes were added. After $timeout seconds: 'ok' when none of
# those pods is still pending, 'failed' when any is (the simulation
# promised a placement the scheduler did not deliver).
sub verify_outcome {
    my ($rec, $pending_uids, $now, $timeout) = @_;

    return 'none' if !$rec || !($rec->{uids} // [])->@*;
    $timeout //= 900;
    return 'waiting' if $now - ($rec->{at} // 0) < $timeout;
    my %pending = map { $_ => 1 } $pending_uids->@*;
    return (grep { $pending{$_} } $rec->{uids}->@*) ? 'failed' : 'ok';
}

# S10.11: exponential backoff for a pool whose scale-out did not
# help: 1h, 2h, 4h, capped at 8h.
sub backoff_seconds {
    my ($level) = @_;

    my $s = 3600 * (2 ** ($level // 0));
    return $s > 8 * 3600 ? 8 * 3600 : $s;
}

sub pool_backed_off {
    my ($state, $pool, $now) = @_;

    my $b = ($state // {})->{'pool-backoff'}{$pool} or return 0;
    return ($b->{until} // 0) > $now ? 1 : 0;
}

# Would pending pods benefit from more nodes of this pool?
# Adds simulated nodes one at a time (up to $room) and
# returns how many nodes would raise the placed count.
sub nodes_needed {
    my ($nodes, $pending, $pool, $room, $tmpl) = @_;

    return 0 if !$room || !$pending->@*;
    my ($base) = place_pods(clone_nodes($nodes), $pending);
    my $best = scalar $base->@*;
    my $added = 0;
    while ($added < $room) {
        my $trial = clone_nodes($nodes);
        for (1 .. $added + 1) {
            my $sim = make_node("sim-$_",
                pool_node_labels($pool), parse_taints($pool),
                $tmpl->{cpu}, $tmpl->{mem});
            $sim->{used_cpu} = $tmpl->{overhead_cpu} // 0;
            $sim->{used_mem} = $tmpl->{overhead_mem} // 0;
            push $trial->@*, $sim;
        }
        my ($placed) = place_pods($trial, $pending);
        last if scalar $placed->@* <= $best;
        $best = scalar $placed->@*;
        $added++;
        last if $best == scalar $pending->@*;
    }
    return $added;
}

# Scale-in: nodes below $threshold utilisation whose pods
# all fit on the remaining nodes (simulation includes
# affinity, taints, anti-affinity and requests).
sub scale_in_candidates {
    my ($nodes, $threshold) = @_;

    my @out;
    for my $i (0 .. $#$nodes) {
        my $node = $nodes->[$i];
        next if !$node->{cpu} || !$node->{mem};
        my $util = $node->{used_cpu} / $node->{cpu};
        my $mutil = $node->{used_mem} / $node->{mem};
        $util = $mutil if $mutil > $util;
        next if $util >= $threshold;
        my @rest = map { $nodes->[$_] }
            grep { $_ != $i } 0 .. $#$nodes;
        my $trial = clone_nodes(\@rest);
        # existing pods on the survivors stay where they are
        my @moving = grep {
            my $kind = $_->{metadata}{ownerReferences}[0]{kind} // '';
            $kind ne 'DaemonSet';
        } $node->{pods}->@*;
        my (undef, $unplaced) = place_pods($trial, \@moving);
        push @out, $node->{name} if !$unplaced->@*;
    }
    return \@out;
}

# --- T3.6b: local-volume mobility -----------------------
# A Proxmox CSI volume handle is region/zone/storage/disk;
# zone is the Proxmox host holding the disk. Shared volumes
# carry an empty zone (region//storage/disk) and never need
# a move. Local volumes pin their pods to nodes on that one
# host: when every node there is gone or unschedulable, a
# recreated pod waits Pending forever unless the disk moves.
sub csi_volume_handle {
    my ($handle) = @_;

    my @parts = split m{/}, ($handle // ''), -1;
    return undef if @parts != 4 || !$parts[0] || !$parts[2]
        || !$parts[3];
    return { region => $parts[0], zone => $parts[1],
        storage => $parts[2], disk => $parts[3] };
}

# Pure decision for the reconcile loop: which Pending pods
# are stuck solely because their local PV's host has no
# schedulable node left. Inputs: pending pods, PVs by name
# ({zone, claim => "ns/pvc"}), and worker nodes as
# {name, pvehost, ready, schedulable}. Returns one record
# per stuck volume with the Ready nodes elsewhere that
# could receive the disk.
sub stuck_local_volumes {
    my ($pods, $pv_by_name, $nodes) = @_;

    my %schedulable_on;
    my @targets;
    for my $node ($nodes->@*) {
        next if !$node->{ready} || !$node->{schedulable};
        $schedulable_on{$node->{pvehost}} = 1;
        push @targets, $node;
    }
    my @out;
    for my $pod ($pods->@*) {
        next if ($pod->{status}{phase} // '') ne 'Pending';
        next if $pod->{spec}{nodeName};
        my $ns = $pod->{metadata}{namespace} // 'default';
        for my $vol (($pod->{spec}{volumes} // [])->@*) {
            my $claim = $vol->{persistentVolumeClaim}{claimName}
                or next;
            my ($pvname, $pv) = map { $_ => $pv_by_name->{$_} }
                grep { ($pv_by_name->{$_}{claim} // '')
                    eq "$ns/$claim" } keys $pv_by_name->%*;
            next if !$pv || !$pv->{zone};
            next if $schedulable_on{$pv->{zone}};
            push @out, {
                pod => "$ns/$pod->{metadata}{name}",
                pvc => "$ns/$claim", pv => $pvname,
                zone => $pv->{zone},
                targets => [grep {
                    $_->{pvehost} ne $pv->{zone} } @targets],
            };
        }
    }
    return \@out;
}

# Pending and unschedulable for a scheduling reason (not
# image pull / quota / admission, which nodes cannot fix).
sub schedulable_pending {
    my ($pods) = @_;

    my @out;
    for my $pod ($pods->@*) {
        next if ($pod->{status}{phase} // '') ne 'Pending';
        next if $pod->{spec}{nodeName};
        next if grep { ($_->{kind} // '') eq 'DaemonSet' }
            ($pod->{metadata}{ownerReferences} // [])->@*;
        my ($cond) = grep {
            ($_->{type} // '') eq 'PodScheduled'
            && ($_->{status} // '') eq 'False'
        } ($pod->{status}{conditions} // [])->@*;
        next if $cond && ($cond->{reason} // '') ne 'Unschedulable';
        push @out, $pod;
    }
    return \@out;
}

# node-problem-detector conditions that make a node unfit to keep:
# the kernel deadlocked or a file system went read-only. Both are
# set True by node-problem-detector and do not clear by themselves.
our @PROBLEM_CONDITIONS = qw(KernelDeadlock ReadonlyFilesystem);

# Pure: the first problem condition that is True on a node, as
# {type, since => lastTransitionTime, message}, or undef.
sub node_problem {
    my ($conditions) = @_;

    my %want = map { $_ => 1 } @PROBLEM_CONDITIONS;
    for my $c (($conditions // [])->@*) {
        next if !$want{$c->{type} // ''} || ($c->{status} // '') ne 'True';
        return { type => $c->{type}, since => $c->{lastTransitionTime},
            message => $c->{message} // '' };
    }
    return undef;
}

1;
