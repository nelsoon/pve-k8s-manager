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
        my $past = $mode eq 'apply' ? 'applied' : 'removed';
        print "pve-k8s: $past integration in $file\n";
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

my $k8s_resources_code = "\n"
    . "\tif (!\$param->{type} || \$param->{type} eq 'k8s') {\n"
    . "\t    if (\$rpcenv->check(\$authuser, \"/cluster\", "
    . "['Sys.Audit'], 1)) {\n"
    . "\t\tmy \$k8s_cfg = eval { PVE::K8s::Config->config() } || {};\n"
    . "\t\tpush \@\$res, "
    . "PVE::K8s::Config::resource_entries(\$k8s_cfg)->\@*;\n"
    . "\t    }\n"
    . "\t}\n";
my $k8s_property = "\t\tk8s => {\n"
    . "\t\t    description => \"The Kubernetes cluster name "
    . "(for type 'k8s').\",\n"
    . "\t\t    type => 'string',\n"
    . "\t\t    optional => 1,\n"
    . "\t\t},\n";
run_patch({
    file => "$pm/PVE/API2/Cluster.pm",
    marker => 'PVE::K8s::Config::resource_entries',
    apply => sub {
        my ($src) = @_;
        my $start = index($src, "    name => 'resources',");
        return undef if $start < 0;
        my $code_start = index($src, "\n    code => sub {", $start);
        return undef if $code_start < 0;

        my $head = substr($src, $start, $code_start - $start);
        my $changed = $head;
        $changed =~ s/(enum => \[[^\]]*'sdn')(\])/$1, 'k8s'$2/g;
        return undef if $changed eq $head;
        $head = $changed;

        my $property = index($head, "\t\tplugintype => {");
        return undef if $property < 0;
        substr($head, $property, 0) = $k8s_property;
        $src = substr($src, 0, $start) . $head
            . substr($src, $code_start);

        $code_start = index($src, "\n    code => sub {", $start);
        my $return = index($src, "\n\treturn \$res;", $code_start);
        return undef if $return < 0;
        substr($src, $return, 0) = $k8s_resources_code;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$k8s_resources_code\E//;
        $src =~ s/\Q$k8s_property\E//;
        my $start = index($src, "    name => 'resources',");
        return $src if $start < 0;
        my $code_start = index($src, "\n    code => sub {", $start);
        return $src if $code_start < 0;
        my $head = substr($src, $start, $code_start - $start);
        $head =~ s/, 'k8s'(\])/$1/g;
        return substr($src, 0, $start) . $head
            . substr($src, $code_start);
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

my $resource_type = "\t    k8s: {\n"
    . "\t\ticonCls: 'fa fa-cubes',\n"
    . "\t\ttext: gettext('Kubernetes'),\n"
    . "\t    },\n";
run_patch({
    file => "$js/pvemanagerlib.js",
    marker => "\t    k8s: {\n\t\ticonCls: 'fa fa-cubes',",
    apply => sub {
        my ($src) = @_;
        my $anchor = "\t    sdn: {\n"
            . "\t\ticonCls: 'fa fa-th',\n"
            . "\t\ttext: gettext('SDN'),\n"
            . "\t    },\n";
        return undef if index($src, $anchor) < 0;
        $src =~ s/\Q$anchor\E/$anchor$resource_type/;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$resource_type\E//;
        return $src;
    },
});

my $resource_order = "\t    case 'k8s': return 5;\n";
run_patch({
    file => "$js/pvemanagerlib.js",
    marker => "case 'k8s': return 5;",
    apply => sub {
        my ($src) = @_;
        my $anchor = "\t    case 'sdn': return 3;\n";
        return undef if index($src, $anchor) < 0;
        $src =~ s/\Q$anchor\E/$anchor$resource_order/;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$resource_order\E//;
        return $src;
    },
});

my $resource_route = "\t\t\t    k8s: 'pveK8sConfig',\n";
run_patch({
    file => "$js/pvemanagerlib.js",
    marker => "k8s: 'pveK8sConfig'",
    apply => sub {
        my ($src) = @_;
        # An earlier build routed to the class name, which
        # Ext tries to load as /widget/PVE/k8s/Config.js.
        my $legacy = "\t\t\t    k8s: 'PVE.k8s.Config',\n";
        if (index($src, $legacy) >= 0) {
            $src =~ s/\Q$legacy\E/$resource_route/;
            return $src;
        }
        my $anchor = "\t\t\t    sdn: 'PVE.sdn.Browser',\n";
        return undef if index($src, $anchor) < 0;
        $src =~ s/\Q$anchor\E/$anchor$resource_route/;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$resource_route\E//;
        return $src;
    },
});

exit 0;
