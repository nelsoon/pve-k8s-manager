#!/bin/sh
# T4.1 acceptance suite (spec.md Acceptance Scenarios), run
# as root on a PVE node with the package installed, from a
# clean plugin state (no clusters; templates 1.35+1.36 and,
# for the roll stage, a locally rev-bumped 1.35-r2 template
# built from the same recipe - see tasks.md):
#   sh tests/lab-acceptance.sh <name> <stage>
# Stages, in run order: create pvc roll scale upgrade delete
# Each stage prints "S<n> PASS" or dies with the evidence.
# Long operations run detached; the script polls state.
set -eu

NAME=${1:?cluster name}
STAGE=${2:?stage: create|pvc|roll|scale|upgrade|delete}
STATE=/tmp/$NAME-acc.env
K="kubectl --kubeconfig /etc/kubernetes/admin.conf"

say() { echo "== $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

cluster_json() { pvesh get "/cluster/k8s/$NAME" --output-format json; }

cp_target() { # "vmid host" of the first control-plane node
    cluster_json | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
nodes = json.loads(cfg["nodes"])
cp = [n for n in nodes if n["pool"] == "control-plane"][0]
print(cp["vmid"], cp["pvehost"])'
}

node_field() { # k8s-name field
    cluster_json | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
nodes = json.loads(cfg['nodes'])
n = [x for x in nodes if x['name'] == '$1'][0]
print(n['$2'])"
}

# `qm guest exec` answers with a JSON envelope; unwrap it
# so callers see the guest command's plain stdout.
unwrap_exec() {
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sys.stdout.write(d.get("out-data", ""))
sys.stderr.write(d.get("err-data", ""))'
}

# Guest-exec on the first CP, wherever it is placed: the
# command travels base64-encoded so quoting survives ssh.
CP() {
    _cmd=$1
    set -- $(cp_target); _vmid=$1; _host=$2
    if [ "$_host" = "$(hostname)" ]; then
        qm guest exec "$_vmid" --timeout 600 -- /bin/sh -c "$_cmd"
    else
        _enc=$(printf %s "$_cmd" | base64 -w0)
        # ConnectTimeout so a wedged host fails fast with a
        # clear error instead of hanging a stage for 10 min
        # (seen 2026-11-02: pve3 wedged, preflight stalled).
        timeout 660 ssh -o BatchMode=yes -o ConnectTimeout=20 \
            "root@$_host" \
            "qm guest exec $_vmid --timeout 600 -- /bin/sh -c \"\$(echo $_enc | base64 -d)\""
    fi | unwrap_exec
}

# Apply a manifest held in $1: heredocs do not survive the
# ssh hop to the CP's host, so the manifest travels inside
# the guest command, base64-encoded twice.
KAPPLY() {
    _menc=$(printf %s "$1" | base64 -w0)
    CP "echo $_menc | base64 -d | $K apply -f -"
}
KCP() { CP "$K $1"; }

wait_state() { # wanted-state timeout-sec
    i=0
    while [ $i -lt "$2" ]; do
        s=$(cluster_json | python3 -c \
            'import json,sys; print(json.load(sys.stdin)["state"])')
        [ "$s" = "$1" ] && return 0
        i=$((i + 30)); sleep 30
    done
    die "cluster state never became $1 (last: $s)"
}

# Wait until a detached operation actually starts (the state
# leaves $1) before waiting for its completion; without this
# the caller can observe the pre-operation state and pass or
# fail before anything happened.
wait_state_leave() { # old-state timeout-sec
    i=0
    while [ $i -lt "$2" ]; do
        s=$(cluster_json | python3 -c \
            'import json,sys; print(json.load(sys.stdin)["state"])')
        [ "$s" != "$1" ] && return 0
        i=$((i + 15)); sleep 15
    done
    die "cluster state never left $1 (still: $s)"
}

provision_bg() { # logfile
    setsid sh -c "pvesh create /cluster/k8s/$NAME/provision \
        > $1 2>&1" < /dev/null > /dev/null 2>&1 &
}

nodes_ready() { # expected-count
    KCP "get nodes --no-headers" | grep -c ' Ready '
}

stage_create() {
    say "S1 create 3CP/2W 1.35 on dedicated SDN VNet"
    pvesh create /cluster/k8s --name "$NAME" \
        --k8s-version 1.35 --cp 3 --workers 2 \
        --node-subnet 192.168.206.0/24 \
        --sdn-zone evpnzone --public-subnet 192.168.205.0/24 \
        --pools '[{"name":"default","size":2,"min":1,"max":3}]'
    provision_bg /tmp/$NAME-prov.log
    wait_state ready 3600
    tail -5 /tmp/$NAME-prov.log
    [ "$(nodes_ready)" = 5 ] || die "not 5 Ready nodes"
    KCP "get nodes -o wide"
    # VMs sit on the cluster VNet
    vnet=$(cluster_json | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
print(cfg.get("sdn-vnet") or "k8s" + cfg["name"])')
    [ -n "$vnet" ] || die "no dedicated vnet recorded"
    for vm in $(cluster_json | python3 -c '
import json, sys
print(" ".join(n["vmid"] for n in
    json.loads(json.load(sys.stdin)["nodes"])))'); do
        host=$(node_field_by_vmid "$vm")
        timeout 60 ssh -o BatchMode=yes "root@$host" \
            "qm config $vm" 2>/dev/null | grep -q "bridge=$vnet" \
            || die "VM $vm not on vnet $vnet"
    done
    # API answers on the VIP from inside a node
    vip=$(CP "grep -o 'server: https://[0-9.]*' \
        /etc/kubernetes/admin.conf | cut -d/ -f3")
    [ -n "$vip" ] || die "no API server in admin.conf"
    CP "curl -sk https://$vip:6443/readyz" | grep -q '^ok' \
        || die "API not answering on VIP $vip"
    echo "S1 PASS (VIP $vip, vnet $vnet)"
}

node_field_by_vmid() {
    cluster_json | python3 -c "
import json, sys
nodes = json.loads(json.load(sys.stdin)['nodes'])
n = [x for x in nodes if str(x['vmid']) == '$1'][0]
print(n['pvehost'])"
}

worker_vm() { # worker-index -> "vmid host k8sname"
    cluster_json | python3 -c "
import json, sys
nodes = json.loads(json.load(sys.stdin)['nodes'])
w = [n for n in nodes if n['pool'] != 'control-plane'][$1]
print(w['vmid'], w['pvehost'], w['name'])"
}

stage_pvc() {
    say "S2 PVC reattach after worker VM reboot"
    set -- $(worker_vm 0); WVMID=$1; WHOST=$2; WK8S=$3
    KAPPLY "apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: acc-data}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: shared-block
  resources: {requests: {storage: 2Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: acc-writer}
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - {key: kubernetes.io/hostname, operator: In, values: [$WK8S]}
  containers:
  - name: w
    image: busybox:1.36
    command: ['sleep', '3600']
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - name: d
    persistentVolumeClaim: {claimName: acc-data}"
    i=0; while [ $i -lt 40 ]; do
        p=$(KCP "get pod acc-writer --no-headers" 2>/dev/null \
            | awk '{print $3}')
        [ "$p" = Running ] && break
        i=$((i + 1)); sleep 15
    done
    [ "$p" = Running ] || die "writer pod never Running"
    KCP "exec acc-writer -- sh -c 'echo acc-s2 > /data/proof.txt'"
    say "rebooting worker VM $WVMID on $WHOST"
    timeout 120 ssh -o BatchMode=yes "root@$WHOST" \
        "qm reboot $WVMID" || true
    i=0; while [ $i -lt 60 ]; do
        p=$(KCP "get pod acc-writer --no-headers" 2>/dev/null \
            | awk '{print $3}')
        [ "$p" = Running ] && break
        i=$((i + 1)); sleep 15
    done
    [ "$p" = Running ] || die "writer pod not back after reboot"
    # the rebooted node's kubelet/CNI can lag the pod
    # Running state; retry the read before calling it loss
    i=0; out=""
    while [ $i -lt 20 ]; do
        out=$(KCP "exec acc-writer -- cat /data/proof.txt" 2>/dev/null)
        [ "$out" = acc-s2 ] && break
        i=$((i + 1)); sleep 15
    done
    [ "$out" = acc-s2 ] || die "data lost after reboot: $out"
    echo "S2 PASS (volume reattached live on $WK8S, data intact)"
}

stage_roll() {
    say "S3 maintenance-window roll onto new image revision"
    before=$(cluster_json | python3 -c '
import json, sys
print(",".join(sorted(n["vmid"] for n in
    json.loads(json.load(sys.stdin)["nodes"]))))')
    rev_before=$(cluster_json | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["template-rev"])')
    closed=$(python3 -c '
import datetime
now = datetime.datetime.now() + datetime.timedelta(hours=3)
print(now.strftime("%H:00") + "-" + now.strftime("%H:30"))')
    pvesh set "/cluster/k8s/$NAME" \
        --maintenance-window "$closed" >/dev/null
    pvesh create "/cluster/k8s/$NAME/roll" \
        > /tmp/$NAME-roll-closed.log 2>&1 || true
    grep -q "outside maintenance window" /tmp/$NAME-roll-closed.log \
        || die "roll was not refused outside its window"
    rev0=$(cluster_json | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["template-rev"])')
    [ "$rev0" = "$rev_before" ] \
        || die "a roll ran despite the closed window"
    say "roll correctly refused outside window $closed"
    pvesh set "/cluster/k8s/$NAME" \
        --maintenance-window "00:00-23:59" >/dev/null
    setsid sh -c "pvesh create /cluster/k8s/$NAME/roll \
        > /tmp/$NAME-roll.log 2>&1" < /dev/null > /dev/null 2>&1 &
    wait_state_leave ready 600
    wait_state ready 5400
    tail -5 /tmp/$NAME-roll.log
    after=$(cluster_json | python3 -c '
import json, sys
print(",".join(sorted(n["vmid"] for n in
    json.loads(json.load(sys.stdin)["nodes"]))))')
    [ "$before" != "$after" ] || die "roll replaced no VM"
    [ "$(nodes_ready)" = 5 ] || die "not 5 Ready after roll"
    rev=$(cluster_json | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["template-rev"])')
    [ "$rev" = $((rev_before + 1)) ] \
        || die "cluster not on template r$((rev_before + 1)) (rev=$rev)"
    KCP "get pods -n kube-system -l component=etcd --no-headers"
    echo "S3 PASS (all nodes replaced onto template r$rev, "
    echo "    window gate enforced, etcd pods healthy)"
}

stage_scale() {
    say "S5 scaler: pending pod grows pool, max reports, idle shrinks"
    alloc=$(KCP "get node -o jsonpath={.items[3].status.allocatable.cpu}")
    alloc_m=$(python3 -c "
a = '$alloc'
print(int(float(a.rstrip('m')) * (1000 if not a.endswith('m') else 1)))")
    req=$((alloc_m - 600))
    [ $req -gt 500 ] || die "worker allocatable too small: $alloc"
    # Fillers pin both workers first: 2 fillers + acc-big at
    # req = alloc-600 exceed 2 workers only when alloc > 1800
    # (2-CPU workers: 1900m), so acc-big deterministically
    # goes Pending instead of scheduling immediately.
    [ "$alloc_m" -gt 1800 ] || die "worker too small for S5: $alloc"
    for f in fill-1 fill-2; do
        KAPPLY "apiVersion: v1
kind: Pod
metadata: {name: $f}
spec:
  containers:
  - name: w
    image: busybox:1.36
    command: ['sleep', '3600']
    resources: {requests: {cpu: '${req}m', memory: '256Mi'}}"
    done
    KAPPLY "apiVersion: v1
kind: Pod
metadata: {name: acc-big}
spec:
  containers:
  - name: w
    image: busybox:1.36
    command: ['sleep', '3600']
    resources: {requests: {cpu: '${req}m', memory: '512Mi'}}"
    i=0; while [ $i -lt 80 ]; do
        n=$(nodes_ready)
        p=$(KCP "get pod acc-big --no-headers" 2>/dev/null \
            | awk '{print $3}')
        [ "$n" = 6 ] && [ "$p" = Running ] && break
        setsid sh -c "pvesh create /cluster/k8s/$NAME/scale \
            > /tmp/$NAME-scale.log 2>&1" \
            < /dev/null > /dev/null 2>&1 &
        sleep 60; i=$((i + 1))
    done
    [ "$(nodes_ready)" = 6 ] || die "scaler did not add a node"
    [ "$p" = Running ] || die "big pod not Running on new node"
    # The grow decision lives in the record (only the scaler
    # writes pool size); the per-pass task log is truncated
    # by every later pass, so asserting on it races the
    # loop's own next iteration.
    size=$(cluster_json | python3 -c '
import json, sys
pools = json.loads(json.load(sys.stdin)["pools"])
print([p["size"] for p in pools if p["name"] == "default"][0])')
    [ "$size" = 3 ] || die "pool did not grow to 3 (size=$size)"
    # pool now at max (3 workers): a pod requesting twice a
    # whole worker can never be hosted, and the pass must say
    # so instead of scaling
    KCP "delete pod acc-big fill-1 fill-2"
    huge=$((alloc_m * 2))
    KAPPLY "apiVersion: v1
kind: Pod
metadata: {name: acc-huge}
spec:
  containers:
  - name: w
    image: busybox:1.36
    command: ['sleep', '3600']
    resources: {requests: {cpu: '${huge}m', memory: '512Mi'}}"
    sleep 150
    setsid sh -c "pvesh create /cluster/k8s/$NAME/scale \
        > /tmp/$NAME-scale2.log 2>&1" < /dev/null > /dev/null 2>&1 &
    sleep 90
    grep -qE "no pool can host|saturated" /tmp/$NAME-scale2.log \
        || die "max/saturated pass did not report"
    tail -2 /tmp/$NAME-scale2.log
    # idle pool shrinks back: remove the pressure, run a pass,
    # the extra worker is retired and the pool returns to 2
    KCP "delete pod acc-huge"
    setsid sh -c "pvesh create /cluster/k8s/$NAME/scale \
        > /tmp/$NAME-scale3.log 2>&1" < /dev/null > /dev/null 2>&1 &
    sleep 420
    tail -3 /tmp/$NAME-scale3.log
    size=$(cluster_json | python3 -c '
import json, sys
pools = json.loads(json.load(sys.stdin)["pools"])
print([p["size"] for p in pools if p["name"] == "default"][0])')
    [ "$size" = 2 ] || die "pool did not shrink to 2 (size=$size)"
    echo "S5 PASS (pool grew 2->3 for a pending pod; at max "
    echo "    the scaler reports instead of scaling; idle "
    echo "    pool shrank 3->2)"
}

stage_upgrade() {
    say "S4 one-minor upgrade 1.35 -> 1.36, quorum preserved"
    setsid sh -c "pvesh create /cluster/k8s/$NAME/upgrade \
        --to 1.36 > /tmp/$NAME-upgrade.log 2>&1" \
        < /dev/null > /dev/null 2>&1 &
    wait_state_leave ready 600
    wait_state ready 7200
    tail -8 /tmp/$NAME-upgrade.log
    vers=$(KCP "get nodes -o jsonpath={.items[*].status.nodeInfo.kubeletVersion}")
    echo "kubelet versions: $vers"
    echo "$vers" | grep -q "v1.35" \
        && die "a node is still on 1.35"
    [ "$(nodes_ready)" = 6 ] || die "not 6 Ready after upgrade"
    KCP "get pods -n kube-system -l component=etcd --no-headers"
    grep -qiE "surge|3->4|quorum" /tmp/$NAME-upgrade.log \
        || say "note: upgrade log has no surge/quorum line"
    echo "S4 PASS (all nodes on 1.36, etcd healthy; surge "
    echo "    evidence in /tmp/$NAME-upgrade.log)"
}

stage_delete() {
    say "S6 delete with orphan audit"
    setsid sh -c "pvesh delete /cluster/k8s/$NAME \
        > /tmp/$NAME-del.log 2>&1" < /dev/null > /dev/null 2>&1 &
    i=0; while [ $i -lt 60 ]; do
        pvesh get /cluster/k8s --output-format json \
            | grep -q "$NAME" || break
        i=$((i + 1)); sleep 30
    done
    tail -3 /tmp/$NAME-del.log
    grep -q "no orphan VMs, disks or users" /tmp/$NAME-del.log \
        || die "delete did not report clean"
    for h in pve1 pve2 pve3; do
        timeout 60 ssh -o BatchMode=yes "root@$h" "qm list" \
            | grep -q "$NAME" && die "orphan VM on $h"
    done
    pveum user list | grep -q "k8s-$NAME" \
        && die "orphan PVE user remains"
    pvesh get /cluster/sdn/vnets --output-format json 2>/dev/null \
        | grep -q "$NAME" && die "orphan SDN VNet remains"
    echo "S6 PASS (no orphan VMs, disks, users, or SDN objects)"
}

# Preflight gate: refuse to start a stage on an incoherent
# lab. A wedged host, dead fabric or mismatched etcd must
# abort cleanly here, never corrupt a stage mid-run (T4.1
# lab findings L1-L3, tasks.md). Cluster-level checks apply
# only when the cluster already exists (not before create).
preflight() {
    say "preflight: corosync, fabric, swap, cluster coherence"
    pvecm status 2>/dev/null | grep -q "Quorate:.*Yes" \
        || die "preflight: corosync not quorate"
    if command -v vtysh >/dev/null; then
        # Established peers show a numeric prefix count in
        # State/PfxRcd; down peers show Idle/Active/Connect.
        bgp=$(vtysh -c "show bgp summary" 2>/dev/null)
        echo "$bgp" | grep -qE "Total number of neighbors [1-9]" \
            || die "preflight: no BGP neighbors"
        echo "$bgp" | grep -qE " (Idle|Active|Connect) " \
            && die "preflight: BGP peer not Established (FRR/BFD?)"
    fi
    swap_used=$(awk '/SwapTotal:/ {t=$2} /SwapFree:/ {f=$2}
        END { if (t > 0) printf "%d", (t - f) * 100 / t;
              else print 0 }' /proc/meminfo)
    [ "$swap_used" -lt 80 ] \
        || die "preflight: swap ${swap_used}% used (host thrashing)"
    pvesh get "/cluster/k8s/$NAME" --output-format json \
        >/dev/null 2>&1 || return 0
    # VIP must answer from the first CP, and etcd membership
    # must match the recorded control-plane count.
    vip=$(CP "grep -o 'server: https://[0-9.]*' \
        /etc/kubernetes/admin.conf | cut -d/ -f3")
    [ -n "$vip" ] || die "preflight: no VIP in admin.conf"
    CP "curl -sk --max-time 20 https://$vip:6443/readyz" \
        | grep -q '^ok' || die "preflight: VIP $vip not ready"
    cps=$(cluster_json | python3 -c '
import json, sys
nodes = json.loads(json.load(sys.stdin)["nodes"])
print(len([n for n in nodes if n["pool"] == "control-plane"]))')
    first_cp=$(KCP "get nodes -l node-role.kubernetes.io/control-plane --no-headers" | awk 'NR==1 {print $1}')
    members=$(KCP "exec -n kube-system etcd-$first_cp -- etcdctl --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key member list 2>/dev/null | grep -c started" || true)
    [ "$members" = "$cps" ] \
        || die "preflight: etcd members $members != recorded CPs $cps"
    say "preflight ok (VIP $vip, etcd $members members)"
}

preflight

case "$STAGE" in
    create) stage_create ;;
    pvc) stage_pvc ;;
    roll) stage_roll ;;
    scale) stage_scale ;;
    upgrade) stage_upgrade ;;
    delete) stage_delete ;;
    *) die "unknown stage $STAGE" ;;
esac
