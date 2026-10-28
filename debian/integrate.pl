#!/usr/bin/perl
# Integration patcher for stock pve-manager files.
#
# Until the Kubernetes feature is part of pve-manager itself,
# installing this package needs the four small integration
# points listed in INTEGRATION.md inside files owned by
# pve-manager. This script applies them (mode "apply", run
# from postinst) or removes exactly what it added (mode
# "remove", run from postrm). The Makefile embeds this file
# verbatim into both maintainer scripts; it is kept separate
# so the unit tests can run it against fixture trees.
#
# Rules: a patch is skipped when its marker is already
# present (idempotent) or when its anchor text is not found
# (stock file changed upstream; warn, never corrupt, never
# fail the install). Every modified file is first copied to
# <file>.pve-k8s.bak if no such backup exists yet. Writes go
# through a temp file + rename so a crash cannot leave a
# half-written stock file behind.
use strict;
use warnings;

my ($mode, $prefix) = @ARGV;
$prefix //= '';
if (!defined $mode || ($mode ne 'apply' && $mode ne 'remove')) {
    print STDERR "usage: integrate.pl apply|remove [prefix]\n";
    exit 0;
}

my sub slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

my sub write_atomic {
    my ($file, $data) = @_;
    my $tmp = "$file.pve-k8s.tmp";
    open(my $fh, '>', $tmp) or return 0;
    print {$fh} $data;
    close($fh) or return 0;
    return rename($tmp, $file);
}

my sub backup_once {
    my ($file) = @_;
    my $bak = "$file.pve-k8s.bak";
    return if -e $bak;
    my $data = slurp($file);
    write_atomic($bak, $data) if defined $data;
}

# $patch: { file, marker, apply => sub($src)->$new|undef,
#           remove => sub($src)->$new }
my sub run_patch {
    my ($patch) = @_;
    my $file = $patch->{file};
    if (!-f $file) {
        print STDERR "pve-k8s: $file not found, skipping\n";
        return;
    }
    my $src = slurp($file);
    if (!defined $src) {
        print STDERR "pve-k8s: cannot read $file, skipping\n";
        return;
    }
    my $has = index($src, $patch->{marker}) >= 0;
    return if $mode eq 'apply' && $has;
    return if $mode eq 'remove' && !$has;
    my $new = $patch->{$mode}->($src);
    if (!defined $new || $new eq $src) {
        print STDERR "pve-k8s: anchor not found in $file, "
            . "integration step skipped (see INTEGRATION.md)\n";
        return;
    }
    backup_once($file) if $mode eq 'apply';
    if (write_atomic($file, $new)) {
        print "pve-k8s: ${mode}ed integration in $file\n";
    } else {
        print STDERR "pve-k8s: cannot write $file, skipping\n";
    }
}

my $pm = "$prefix/usr/share/perl5";
my $js = "$prefix/usr/share/pve-manager/js";
my $tpl = "$prefix/usr/share/pve-manager/index.html.tpl";

my $api_use = "use PVE::API2::Cluster::K8s;\n";
my $api_block = "\n__PACKAGE__->register_method ({\n"
    . "    subclass => \"PVE::API2::Cluster::K8s\",\n"
    . "    path => 'k8s',\n});\n";
run_patch({
    file => "$pm/PVE/API2/Cluster.pm",
    marker => 'PVE::API2::Cluster::K8s',
    apply => sub {
        my ($src) = @_;
        my $use_anchor = "use PVE::API2::Cluster::Ceph;\n";
        my $reg_anchor = "    path => 'ceph',\n});\n";
        return undef if index($src, $use_anchor) < 0
            || index($src, $reg_anchor) < 0;
        $src =~ s/\Q$use_anchor\E/$use_anchor$api_use/;
        $src =~ s/\Q$reg_anchor\E/$reg_anchor$api_block/;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$api_use\E//;
        $src =~ s/\Q$api_block\E//;
        return $src;
    },
});

my $cfs_line = "    'k8s/clusters.cfg' => 1,\n";
run_patch({
    file => "$pm/PVE/Cluster.pm",
    marker => "'k8s/clusters.cfg'",
    apply => sub {
        my ($src) = @_;
        my $start = index($src, 'my $observed = {');
        return undef if $start < 0;
        my $close = index($src, "\n};", $start);
        return undef if $close < 0;
        # insert as the last entry, just before the closing
        substr($src, $close + 1, 0) = $cfs_line;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$cfs_line\E//;
        return $src;
    },
});

my $script_tag = '    <script type="text/javascript" '
    . 'src="/pve2/js/PVEK8sWorkspace.js?ver=[% version %]">'
    . "</script>\n";
run_patch({
    file => $tpl,
    marker => 'PVEK8sWorkspace.js',
    apply => sub {
        my ($src) = @_;
        my $anchor = '/pve2/js/pvemanagerlib.js';
        my $pos = index($src, $anchor);
        return undef if $pos < 0;
        my $eol = index($src, "\n", $pos);
        return undef if $eol < 0;
        substr($src, $eol + 1, 0) = $script_tag;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$script_tag\E//;
        return $src;
    },
});

my $dc_block = "\t    {\n"
    . "\t\txtype: 'pveDcK8sView',\n"
    . "\t\ttitle: gettext('Kubernetes'),\n"
    . "\t\ticonCls: 'fa fa-cubes',\n"
    . "\t\titemId: 'k8s',\n"
    . "\t    },\n";
run_patch({
    file => "$js/pvemanagerlib.js",
    marker => 'pveDcK8sView',
    apply => sub {
        my ($src) = @_;
        # insert after the Ceph entry of the Datacenter
        # view list: its itemId line, then the closing brace
        my $id = index($src, "\t\titemId: 'ceph',");
        return undef if $id < 0;
        my $close = index($src, "\t    },\n", $id);
        return undef if $close < 0;
        substr($src, $close + length("\t    },\n"), 0) = $dc_block;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$dc_block\E//;
        return $src;
    },
});

exit 0;
