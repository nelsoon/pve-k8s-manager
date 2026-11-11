# Copyright (C) 2026 pve-k8s contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::K8s::Templates;

use strict;
use warnings;

use JSON::PP ();

use PVE::K8s::Config;

# Template refresh policy (weekly rebuilds, severity stamps,
# remediation deadlines, pruning). Pure functions plus a small
# pmxcfs state file shared by every host; the build itself lives
# in PVE::K8s::Provision. Image revisions are never pinned: each
# build is a new revision (see images/revision.sh).
#
# There is deliberately no CVE feed polling: that would need
# internet access and break air-gapped sites. The operator stamps
# a rebuild with a severity, and the remediation deadline
# (critical 7 days, high 30 days) runs from that stamp.

our $STATE_FILE = '/etc/pve/k8s/template-state.json';
our $WEEK = 7 * 86400;
our %DEADLINE_DAYS = (critical => 7, high => 30);
our $STALE_CLAIM = 7200;

sub valid_severity {
    my ($sev) = @_;
    return defined $sev && $sev =~ /^(?:routine|high|critical)$/ ? 1 : 0;
}

sub empty_state {
    return { 'last-run' => 0, busy => 0, builds => {} };
}

sub read_state {
    my $json = eval {
        open my $fh, '<', $STATE_FILE or die $!;
        local $/;
        <$fh>;
    };
    return empty_state() if !$json;
    my $state = eval { JSON::PP->new->decode($json) };
    return ref $state eq 'HASH' ? $state : empty_state();
}

sub write_state {
    my ($state) = @_;

    open my $fh, '>', "$STATE_FILE.tmp"
        or die "cannot write template state: $!\n";
    print $fh JSON::PP->new->canonical->encode($state);
    close $fh or die "cannot write template state: $!\n";
    rename "$STATE_FILE.tmp", $STATE_FILE
        or die "cannot store template state: $!\n";
}

# Run $code with the state under the cluster config lock.
sub with_state {
    my ($code) = @_;

    my @ret;
    PVE::K8s::Config::lock_config(sub {
        my $state = read_state();
        @ret = $code->($state);
        write_state($state);
    });
    return @ret;
}

# One refresh at a time cluster-wide; a claim older than
# $STALE_CLAIM seconds is considered dead (host crashed).
sub claim {
    my ($host, $now) = @_;

    my ($ok) = with_state(sub {
        my ($state) = @_;
        return 0 if $state->{busy}
            && $now - ($state->{at} // 0) < $STALE_CLAIM;
        @$state{qw(busy leader at)} = (1, $host, $now);
        return 1;
    });
    return $ok;
}

sub release {
    my ($now, $ok, $error) = @_;

    with_state(sub {
        my ($state) = @_;
        $state->{busy} = 0;
        $state->{at} = $now;
        if ($ok) {
            delete $state->{'last-failure'};
        } else {
            $state->{'last-failure'} = { at => $now, error => $error };
        }
    });
}

# Pure: is the weekly rebuild due?
sub refresh_due {
    my ($state, $now, $interval) = @_;

    $interval //= $WEEK;
    return $now - (($state // {})->{'last-run'} // 0) >= $interval ? 1 : 0;
}

# Pure: (minor, arch) pairs some cluster uses, sorted, unique.
# Only these are rebuilt, so no builder VM is burned on versions
# nobody runs.
sub targets_in_use {
    my ($ids) = @_;

    my %seen;
    for my $name (keys %{$ids // {}}) {
        my $scfg = $ids->{$name};
        my $minor = $scfg->{'k8s-version'} or next;
        my @archs = ($scfg->{'cp-arch'} // 'amd64');
        my $pools = eval { PVE::K8s::Config::parse_pools(
            $scfg->{pools}, $scfg->{workers} // 2) } // [];
        push @archs, map { $_->{arch} // 'amd64' } $pools->@*;
        $seen{"$minor/$_"} = 1 for @archs;
    }
    return map { my ($m, $a) = split m{/}; { minor => $m, arch => $a } }
        sort keys %seen;
}

sub build_key {
    my ($minor, $arch, $rev) = @_;
    return "$minor/" . ($arch // 'amd64') . "/r$rev";
}

# Pure: remember when a revision was built and how urgent it was.
sub record_build {
    my ($state, $minor, $arch, $rev, $severity, $now) = @_;

    die "severity must be routine, high or critical\n"
        if !valid_severity($severity);
    $state->{builds}->{build_key($minor, $arch, $rev)}
        = { at => $now, severity => $severity };
    return $state;
}

# Pure: remediation status of a node running image revision
# $node_rev. A newer revision stamped high/critical sets a
# deadline (built-at + 7/30 days); the earliest applicable
# deadline wins. Routine rebuilds never create an overdue state.
# Returns { pending => bool, deadline => epoch|undef,
#           severity => str|undef, overdue => bool }.
sub remediation {
    my ($state, $minor, $arch, $node_rev, $now) = @_;

    my ($deadline, $severity, $pending);
    my $prefix = build_key($minor, $arch, '');
    for my $key (keys %{($state // {})->{builds} // {}}) {
        next if index($key, $prefix) != 0;
        my ($rev) = substr($key, length $prefix) =~ /^(\d+)$/ or next;
        next if $rev <= ($node_rev // 0);
        $pending = 1;
        my $b = $state->{builds}->{$key};
        my $days = $DEADLINE_DAYS{$b->{severity} // ''} or next;
        my $due = ($b->{at} // 0) + $days * 86400;
        if (!defined $deadline || $due < $deadline) {
            ($deadline, $severity) = ($due, $b->{severity});
        }
    }
    return {
        pending => $pending ? 1 : 0,
        deadline => $deadline,
        severity => $severity,
        overdue => defined $deadline && $now > $deadline ? 1 : 0,
    };
}

# Pure: which revisions of one minor+arch may be pruned. Keep
# every revision a node or cluster record still uses plus the
# newest $keep (rollback material); the rest are returned.
sub prune_plan {
    my ($present, $in_use, $keep) = @_;

    $keep //= 2;
    my @desc = sort { $b <=> $a } @{$present // []};
    my %keep = map { $_ => 1 } @desc[0 .. ($keep < @desc ? $keep : scalar @desc) - 1];
    $keep{$_} = 1 for grep { $in_use->{$_} } @desc;
    return sort { $a <=> $b } grep { !$keep{$_} } @desc;
}

1;
