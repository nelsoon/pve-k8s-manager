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
like($js, qr/params: auto \? \{ url: window\.location\.origin \} : \{ hours: current \}/,
    'validity is chosen in the window, or auto-refresh');

# --- the vsock path: identity setup as API requests ---------------
my $ir = $P->can('identity_requests');
my @adm = $ir->(namespace => 'pve-k8s-users', sa => 'pve-a-1', role => 'admin',
    seconds => 3600, userid => 'a@pve');
is($adm[0]{path}, '/api/v1/namespaces/pve-k8s-users?fieldManager=pve-k8s&force=true',
    'the namespace first');
ok(!(grep { $_->{method} ne 'PATCH' || $_->{type} ne 'application/apply-patch+yaml' }
    grep { $_->{method} eq 'PATCH' } @adm), 'creates are server-side apply (safe to repeat)');
is($adm[1]{body}{metadata}{annotations}{'pve-k8s.proxmox.com/user'}, 'a@pve',
    'the account names its PVE user');
my ($ab) = grep { $_->{path} =~ m|clusterrolebindings/pve-a-1-admin\?| } @adm;
is($ab->{body}{roleRef}{name}, 'cluster-admin', 'admin binding');
is($ab->{body}{metadata}{labels}{'pve-k8s.proxmox.com/user-sa'}, 'pve-a-1',
    'bindings are labelled for the Access list and revoke');
is_deeply([map { $_->{path} =~ m|/([^/]+)$|; $1 } grep { $_->{method} eq 'DELETE' } @adm],
    ['pve-a-1-view', 'pve-a-1-view-cluster'], 'a promotion drops the read-only bindings');
ok((grep { $_ == 404 } $adm[-2]{ok}->@*), 'a binding already gone is fine');
is($adm[-1]{path}, '/api/v1/namespaces/pve-k8s-users/serviceaccounts/pve-a-1/token',
    'the TokenRequest comes last');
is($adm[-1]{body}{spec}{expirationSeconds}, 3600, 'with the asked validity');
my @view = $ir->(namespace => 'pve-k8s-users', sa => 'pve-b-1', role => 'view', seconds => 600);
my ($cr) = grep { $_->{path} =~ m|clusterroles/pve-k8s-cluster-view\?| } @view;
ok($cr, 'read-only: the cluster-scope read role');
is_deeply([sort map { @{ $_->{resources} } } $cr->{body}{rules}->@*],
    [qw(namespaces nodes persistentvolumes storageclasses)], 'nodes, namespaces, storage');
ok(!(grep { ($_->{verbs} // [])->@* != 3 } $cr->{body}{rules}->@*), 'get/list/watch only');
is_deeply([map { $_->{body}{roleRef}{name} } grep { $_->{path} =~ /clusterrolebindings\/.*\?/ } @view],
    ['view', 'pve-k8s-cluster-view'], 'read-only bindings');
ok((grep { $_->{method} eq 'DELETE' && $_->{path} =~ /pve-b-1-admin$/ } @view),
    'a demotion drops the admin binding');
ok(!exists $view[1]{body}{metadata}{annotations}, 'no user annotation without a userid');
my @mgr = $ir->(namespace => 'kube-system', sa => 'pve-k8s-manager', role => 'admin', seconds => 3600);
ok(!(grep { $_->{path} =~ m|^/api/v1/namespaces/kube-system\?| } @mgr), 'kube-system is never applied');

my @rv = $P->can('revoke_requests')->('pve-a-1');
is($rv[0]{path}, '/api/v1/namespaces/pve-k8s-users/serviceaccounts/pve-a-1',
    'revoke deletes the account');
like($rv[1]{path}, qr/clusterrolebindings\?labelSelector=pve-k8s\.proxmox\.com\/user-sa%3Dpve-a-1$/,
    'and its labelled bindings');

my $fail = $P->can('api_failure');
my @r2 = ({ method => 'PATCH', path => '/a', ok => [200, 201] }, { method => 'POST', path => '/b', ok => [201] });
is($fail->(\@r2, [{ code => 201 }, { code => 201 }]), undef, 'accepted codes pass');
like($fail->(\@r2, [{ code => 200 }, { code => 403, body => { message => 'forbidden' } }]),
    qr|^POST /b returned 403: forbidden|, 'the first refusal is the error');
like($fail->([{ method => 'GET', path => '/c' }], [{ code => 404, body => 'x' }]),
    qr|GET /c returned 404: x|, 'plain 200 expected by default');

# --- auto-refresh -------------------------------------------------
is($P->can('refresh_token_id')->('local'), 'k8s-local', 'one API token per cluster');
my $url = $P->can('pve_url');
is($url->('https://pve.example.com:8006/'), 'https://pve.example.com:8006', 'trailing slash dropped');
is($url->('https://[fd00::1]:8006'), 'https://[fd00::1]:8006', 'IPv6 literal');
for my $bad ('http://pve:8006', 'https://pve:8006/x', 'https://a b', "https://pve\n") {
    eval { $url->($bad) };
    like($@, qr/must look like/, "refused: '$bad'");
}
is($P->can('yq')->('a"b\\c'), '"a\\"b\\\\c"', 'YAML quoting');
my $kc = $P->can('kubeconfig_exec_text')->(name => 'local', server => 'https://10.0.0.5:6443',
    ca => 'Q0E=', user => 'root@pam', url => 'https://pve:8006', pveca => 'UEVWRQ==',
    secret => 'root@pam!k8s-local=0000-1111');
like($kc, qr/^      command: pve-k8s-auth$/m, 'kubectl runs pve-k8s-auth');
like($kc, qr/^      apiVersion: client\.authentication\.k8s\.io\/v1$/m, 'exec credential v1');
like($kc, qr/- --url\n      - "https:\/\/pve:8006"\n      - --cluster\n      - local\n      - --ca-data\n      - UEVWRQ==/,
    'where to ask, which cluster, which CA');
like($kc, qr/name: PVE_K8S_API_TOKEN\n        value: "root\@pam!k8s-local=0000-1111"/,
    'the API token travels in the environment');
unlike($kc, qr/^\s+token:/m, 'no Kubernetes token in the file');
like($kc, qr/interactiveMode: Never/, 'never prompts');

like($src, qr/role => 'admin', seconds => 3600, exec_only => 1,/,
    'pve-k8s\'s own account bootstraps over guest exec');
like($src, qr/my \@reqs = \$o\{exec_only\} \? \(\) : identity_requests\(%o\);/,
    'user identities go over vsock first');
like($src, qr/privsep => 1,/, 'the API token is privilege separated (no PVE rights of its own)');
like($src, qr/eval \{ narrow_refresh_tokens\(\$name\) \};/, 'older wide tokens are narrowed by the timer');
like($api, qr/my \$who = PVE::K8s::Provision::credential_principal\(\$user,\s+\$param->\{name\}\);\s+\$rpcenv->check\(\$who, '\/cluster', \['Sys\.Audit'\]\);/,
    'credential: Sys.Audit checked on the principal');
like($src, qr/PVE::API2::User->update_token_info\(\{ %p, regenerate => 1 \}\)/,
    'a new kubeconfig replaces the secret');
like($src, qr/# a fresh identity[^\n]*\n\s+remove_identities\(\$name, \$nodes, user_sa_name\(\$full\)\);/,
    'and the identity, so the old one stops at once');
like($src, qr/push \@sas, user_sa_name\("\$userid!\$tokenid"\);\n\s+\$pve_token = \$userid;/,
    'revoking a user also revokes its auto-refresh token');
like($src, qr/if \$userid =~ \/!\/;/, 'auto-refresh is for user logins');
like($src, qr/renew_manager_token\(\$name, \$cp, \$tf, \$cf\)/, 'the manager token renews over vsock');
like($api, qr/path => '\{name\}\/kubeconfig',\s+method => 'POST',[\s\S]*?\['Sys\.Audit'\]/,
    'auto-refresh kubeconfig: POST, Sys.Audit');
like($api, qr/path => '\{name\}\/credential',\s+method => 'GET',[\s\S]*?user => 'all',/,
    'credential call for pve-k8s-auth: checked in code');

my $who = $P->can('credential_principal');
is($who->('alice@pve!k8s-local', 'local'), 'alice@pve', 'own refresh token: judged by its user');
is($who->('alice@pve', 'local'), 'alice@pve', 'a login is itself');
is($who->('alice@pve!k8s-other', 'local'), 'alice@pve!k8s-other', 'another cluster\'s token is itself');
is($who->('alice@pve!ci', 'local'), 'alice@pve!ci', 'any other token is itself');
is($who->('alice@pve!k8s-local2', 'local'), 'alice@pve!k8s-local2', 'name must match exactly');
is($who->('a!k8s-local@pve!k8s-local', 'local'), 'a!k8s-local@pve', 'only the last token part');
my $wide = $P->can('wide_refresh_tokens');
is_deeply([$wide->({ users => {
    'a@pve' => { tokens => { 'k8s-local' => { privsep => 0 } } },
    'b@pve' => { tokens => { 'k8s-local' => { privsep => 1 } } },
    'c@pve' => { tokens => { 'k8s-other' => { privsep => 0 } } },
    'd@pve' => { tokens => { 'k8s-local' => {} } },
    'e@pve' => {},
} }, 'local')], [['a@pve', 'k8s-local']], 'only this cluster\'s wide tokens');
is_deeply([$wide->(undef, 'local')], [], 'no user.cfg, nothing');
like($js, qr/defaultFocus: 'no',/, 'replacing the token is confirmed');
like($js, qr/itemId: 'helper',/, 'pve-k8s-auth can be downloaded');

# --- the helpers ------------------------------------------------------
my $vg = do { local $/; open my $f, '<', 'tools/pve-k8s-vsock-get' or die; <$f> };
like($vg, qr/elsif \(\$arg eq '--requests'\)/, 'vsock helper takes requests');
like($vg, qr/\(GET\|POST\|PUT\|PATCH\|DELETE\)/, 'only known methods');
like($vg, qr/Content-Length: " \. length\(\$body\)/, 'bodies are sent with their length');
my $auth = do { local $/; open my $f, '<', 'tools/pve-k8s-auth' or die; <$f> };
like($auth, qr/"Authorization": "PVEAPIToken=" \+ token/, 'pve-k8s-auth uses the API token');
like($auth, qr/cached\.get\("parent"\) != parent/, 'a repeated call from one kubectl refetches');
like($auth, qr/os\.chmod\(tmp, 0o600\)/, 'the cache is private');
my $mk = do { local $/; open my $f, '<', 'Makefile' or die; <$f> };
like($mk, qr|install -m 0755 tools/pve-k8s-auth \$\(STAGE\)/usr/sbin/pve-k8s-auth|, 'packaged');

done_testing;
