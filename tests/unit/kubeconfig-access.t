# Kubeconfigs per PVE user: own service account, role from the PVE
# privilege, validity capped per cluster, revocable; pve-k8s's own
# reads use a separate account. Pure parts only.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use MIME::Base64;
use PVE::K8s::Provision;

my $P = 'PVE::K8s::Provision';
my $sa = $P->can('user_sa_name');

like($sa->('root@pam'), qr/^pve-root-pam-[0-9a-f]{8}$/, 'readable name plus a hash');
is($sa->('root@pam'), $sa->('root@pam'), 'stable for the same user');
isnt($sa->('Alice@pve'), $sa->('alice@pve'), 'ids that sanitize alike stay apart');
isnt($sa->('ci@pve!deploy'), $sa->('ci@pve'), 'an API token is its own identity');
for my $id ('root@pam', 'ci@pve!deploy', 'Jöhn_Doe@ad.example.com', '@@@', ('x' x 120) . '@pve') {
    my $n = $sa->($id);
    ok($n =~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/ && length($n) <= 63,
        "valid service-account name for '$id' ($n)");
}

is($P->can('user_k8s_role')->(1), 'admin', 'Sys.Modify: cluster-admin');
is($P->can('user_k8s_role')->(0), 'view', 'Sys.Audit only: read-only');

my $hours = $P->can('kubeconfig_hours');
is($hours->({}, undef), 1, 'default validity is one hour');
is($hours->({}, 24), 24, 'up to 24 hours by default');
eval { $hours->({}, 25) };
like($@, qr/limited to 24 hour/, 'over the default cap is refused');
is($hours->({ 'kubeconfig-max-hours' => 168 }, 72), 72, 'the cluster can allow more');
eval { $hours->({ 'kubeconfig-max-hours' => 4 }, 8) };
like($@, qr/limited to 4 hour/, 'or less');
eval { $hours->({}, 0) };
like($@, qr/whole number/, 'zero is refused');

my $script = $P->can('token_script');
my $admin = $script->(namespace => 'pve-k8s-users', sa => 'pve-a-1', role => 'admin',
    seconds => 3600, userid => "o'brien\@pve");
like($admin, qr/create namespace pve-k8s-users/, 'user namespace is created');
like($admin, qr/clusterrolebinding pve-a-1-admin --clusterrole=cluster-admin/, 'admin binding');
like($admin, qr/delete clusterrolebinding pve-a-1-view --ignore-not-found/,
    'a user who lost Sys.Modify loses admin, and the reverse');
like($admin, qr/'pve-k8s\.proxmox\.com\/user=o'\\''brien\@pve'/, 'userid is shell-quoted');
like($admin, qr/create token pve-a-1 --duration=3600s\necho\necho ---PVE-K8S-CA---\nbase64/,
    'token, a line end (kubectl prints none), then CA: one exec');
my $view = $script->(namespace => 'pve-k8s-users', sa => 'pve-b-2', role => 'view',
    seconds => 28800);
like($view, qr/--clusterrole=view /, 'view binding');
like($view, qr/clusterrole pve-k8s-cluster-view --verb=get,list,watch --resource=nodes/,
    'read-only users can see nodes too');
like($view, qr/delete clusterrolebinding pve-b-2-admin/, 'and never keep admin');
unlike($view, qr/cluster-admin/, 'no cluster-admin in a read-only issue');
my $mgr = $script->(namespace => 'kube-system', sa => 'pve-k8s-manager', role => 'admin',
    seconds => 3600);
unlike($mgr, qr/create namespace/, 'kube-system is never created');

my ($tok, $ca) = $P->can('parse_token_output')->("noise\neyJ.a.b\n---PVE-K8S-CA---\nQ0E=\n");
is($tok, 'eyJ.a.b', 'token is the last word before the marker');
is($ca, 'Q0E=', 'CA after the marker');
($tok, $ca) = $P->can('parse_token_output')->("eyJ.c.d---PVE-K8S-CA---\nQ0E=");
is($tok, 'eyJ.c.d', 'a marker glued to the token (no newline from kubectl) still parses');
eval { $P->can('parse_token_output')->("error: forbidden\n") };
like($@, qr/could not issue/, 'no marker: failure');

my $payload = encode_base64(encode_json({ exp => 1800000000 }), '');
$payload =~ tr{+/}{-_}; $payload =~ s/=+$//;
is($P->can('token_expiry')->("h.$payload.s"), 1800000000, 'expiry read from the JWT');
is($P->can('token_expiry')->('garbage'), undef, 'no JWT: unknown');

my $rows = $P->can('access_rows')->(
    { items => [
        { metadata => { name => 'pve-b', annotations => { 'pve-k8s.proxmox.com/user' => 'bob@pve' },
            creationTimestamp => '2026-11-13T10:00:00Z' } },
        { metadata => { name => 'pve-a', annotations => { 'pve-k8s.proxmox.com/user' => 'alice@pve' } } },
        { metadata => { name => 'default' } },
    ] },
    { items => [
        { metadata => { labels => { 'pve-k8s.proxmox.com/user-sa' => 'pve-a' } }, roleRef => { name => 'cluster-admin' } },
        { metadata => { labels => { 'pve-k8s.proxmox.com/user-sa' => 'pve-b' } }, roleRef => { name => 'view' } },
        { metadata => { labels => { 'pve-k8s.proxmox.com/user-sa' => 'pve-b' } }, roleRef => { name => 'pve-k8s-cluster-view' } },
    ] });
is_deeply([map { "$_->{user}=$_->{role}" } @$rows], ['alice@pve=admin', 'bob@pve=view'],
    'access rows: one per user, sorted, role from the bindings; unrelated accounts skipped');
is_deeply($P->can('access_rows')->({}, {}), [], 'nothing issued yet');

my $c = {};
PVE::K8s::Provision::apply_cluster_options($c, { 'kubeconfig-max-hours' => 168 });
is($c->{'kubeconfig-max-hours'}, 168, 'max validity is a cluster setting');
eval { PVE::K8s::Provision::apply_cluster_options($c, { 'kubeconfig-max-hours' => 721 }) };
like($@, qr/1\.\.720/, 'capped at 30 days');
PVE::K8s::Provision::apply_cluster_options($c, { delete => ['kubeconfig-max-hours'] });
ok(!exists $c->{'kubeconfig-max-hours'}, 'and clearable');

# Wiring.
my $src = do { local $/; open my $f, '<', 'PVE/K8s/Provision.pm' or die; <$f> };
like($src, qr/sa => \$MANAGER_SA,/, 'pve-k8s reads with its own account');
like($src, qr/delete serviceaccount pve-k8s-admin/, 'the shared old account is retired');
my $api = do { local $/; open my $f, '<', 'PVE/API2/Cluster/K8s.pm' or die; <$f> };
like($api, qr/path => '\{name\}\/kubeconfig',[\s\S]*?\['Sys\.Audit'\]/,
    'read-only users may get a (read-only) kubeconfig');
like($api, qr/check\(\$user, '\/cluster', \['Sys\.Modify'\], 1\)/, 'role follows Sys.Modify');
like($api, qr/path => '\{name\}\/access\/\{userid\}',\s+method => 'DELETE',[\s\S]*?\['Sys\.Modify'\]/,
    'revoking needs Sys.Modify');
my $js = do { local $/; open my $f, '<', 'www/manager6/PVEK8sWorkspace.js' or die; <$f> };
like($js, qr/\['access', gettext\('Access'\)/, 'Access page in the cluster menu');
like($js, qr/params: \{ hours: me\.down\('#hours'\)\.getValue\(\) \}/, 'validity is chosen in the window');

done_testing;
