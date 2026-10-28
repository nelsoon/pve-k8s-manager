# Unit tests: the maintainer-script integration patcher
# (debian/integrate.pl) against fixture copies of the stock
# pve-manager anchors it patches. Applying twice must be a
# no-op; removing must restore the stock bytes exactly; a
# missing anchor must leave the file untouched.
# Run via `make test`.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/usr/share/perl5/PVE/API2",
    "$dir/usr/share/perl5/PVE",
    "$dir/usr/share/pve-manager/js");

sub put {
    my ($path, $data) = @_;
    open(my $fh, '>', "$dir/$path") or die $!;
    print {$fh} $data;
    close($fh);
}
sub get {
    my ($path) = @_;
    open(my $fh, '<', "$dir/$path") or die $!;
    local $/;
    return <$fh>;
}
sub integrate {
    my ($mode) = @_;
    my $rc = system($^X, 'debian/integrate.pl', $mode, $dir);
    is($rc, 0, "integrate.pl $mode exits clean");
}

my %stock = (
    'usr/share/perl5/PVE/API2/Cluster.pm' =>
        "use PVE::API2::Cluster::Ceph;\n\n"
        . "__PACKAGE__->register_method ({\n"
        . "    subclass => \"PVE::API2::Cluster::Ceph\",\n"
        . "    path => 'ceph',\n});\n\n1;\n",
    'usr/share/perl5/PVE/Cluster.pm' =>
        "my \$observed = {\n    'vzdump.cron' => 1,\n"
        . "    'mapping/usb.cfg' => 1,\n};\n\n1;\n",
    'usr/share/pve-manager/index.html.tpl' =>
        "    <script type=\"text/javascript\" "
        . "src=\"/pve2/js/pvemanagerlib.js?ver=[% version %]\">"
        . "</script>\n",
    'usr/share/pve-manager/js/pvemanagerlib.js' =>
        "\t    {\n\t\ttitle: 'Ceph',\n\t\titemId: 'ceph',\n"
        . "\t\ticonCls: 'fa fa-ceph',\n"
        . "\t\txtype: 'pveNodeCephStatus',\n\t    },\n",
);
put($_, $stock{$_}) for keys %stock;

integrate('apply');
like(get('usr/share/perl5/PVE/API2/Cluster.pm'),
    qr/use PVE::API2::Cluster::Ceph;\nuse PVE::API2::Cluster::K8s;/,
    'API module loaded after the Ceph module');
like(get('usr/share/perl5/PVE/API2/Cluster.pm'),
    qr/path => 'k8s',/, 'API path k8s registered');
like(get('usr/share/perl5/PVE/Cluster.pm'),
    qr/'mapping\/usb\.cfg' => 1,\n    'k8s\/clusters\.cfg' => 1,\n\};/,
    'clusters.cfg observed as the last cfs entry');
like(get('usr/share/pve-manager/index.html.tpl'),
    qr/pvemanagerlib\.js.*\n.*PVEK8sWorkspace\.js/s,
    'UI script loads after the manager library');
like(get('usr/share/pve-manager/js/pvemanagerlib.js'),
    qr/itemId: 'ceph',\n\t\ticonCls: 'fa fa-ceph',\n\t\txtype: 'pveNodeCephStatus',\n\t    \},\n\t    \{\n\t\txtype: 'pveDcK8sView',/,
    'Kubernetes view listed after the Ceph view');
ok(-e "$dir/usr/share/perl5/PVE/Cluster.pm.pve-k8s.bak",
    'stock file backed up before patching');

my %applied = map { $_ => get($_) } keys %stock;
integrate('apply');
is(get($_), $applied{$_}, "second apply is a no-op: $_")
    for keys %stock;

integrate('remove');
is(get($_), $stock{$_}, "remove restores stock bytes: $_")
    for keys %stock;
integrate('remove');
is(get($_), $stock{$_}, "second remove is a no-op: $_")
    for keys %stock;

# Anchor drift upstream: warn and leave the file alone.
put('usr/share/perl5/PVE/Cluster.pm', "package PVE::Cluster;\n1;\n");
integrate('apply');
is(get('usr/share/perl5/PVE/Cluster.pm'),
    "package PVE::Cluster;\n1;\n",
    'missing anchor leaves the stock file untouched');

my $mk = do { open my $fh, '<', 'Makefile' or die $!; local $/; <$fh> };
like($mk, qr/debian\/postinst/, 'Makefile ships a real postinst');
like($mk, qr/debian\/postrm/, 'Makefile ships a real postrm');
like($mk, qr/integrate\.pl/, 'Makefile embeds the integration patcher');

done_testing();
