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
            push $trial->@*, make_node("sim-$_",
                pool_node_labels($pool), parse_taints($pool),
                $tmpl->{cpu}, $tmpl->{mem});
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

1;
