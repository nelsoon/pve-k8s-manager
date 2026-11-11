# The image revision is derived from existing templates at build
# time (EKS-style release numbers), never pinned in the repo.
use strict;
use warnings;
use Test::More;

sub rev {
    my ($minor, $arch, @names) = @_;
    my $in = join("\n", @names) . "\n";
    open my $p, '-|', 'sh', '-c',
        ". images/revision.sh; printf '%s' \"\$1\" | next_revision $minor $arch",
        '--', $in or die $!;
    my $out = do { local $/; <$p> };
    close $p;
    chomp $out;
    return $out;
}

is(rev('1.36', 'amd64'), 1, 'first build of a minor is r1');
is(rev('1.36', 'amd64', 'k8s-node-1.36-r4', 'k8s-node-1.36-r2'), 5,
    'next is highest existing plus one');
is(rev('1.36', 'amd64', 'k8s-node-1.36-r9', 'k8s-node-1.36-r10'), 11,
    'revisions compare numerically, not as text');
is(rev('1.36', 'amd64', 'k8s-node-1.35-r7', 'local-w1'), 1,
    'other minors and ordinary VMs are ignored');
is(rev('1.36', 'amd64', 'k8s-node-1.36-r3-arm64'), 1,
    'arm64 templates do not advance amd64 revisions');
is(rev('1.36', 'arm64', 'k8s-node-1.36-r3-arm64', 'k8s-node-1.36-r8'), 4,
    'arm64 counts only arm64 templates');
is(rev('1.36', 'amd64', 'k8s-node-1x36-r8'), 1,
    'the dot in the minor is literal');

for my $f (glob 'images/versions/*.env') {
    open my $fh, '<', $f or die $!;
    my $t = do { local $/; <$fh> };
    unlike($t, qr/IMAGE_REVISION/, "$f pins no revision");
}
open my $bt, '<', 'images/build-template.sh' or die $!;
my $script = do { local $/; <$bt> };
like($script, qr/next_revision/, 'build script derives the revision');
done_testing;
