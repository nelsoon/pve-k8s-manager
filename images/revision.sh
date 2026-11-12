# Sourced by build-template.sh (and unit-tested): the image revision
# is never stored in the repo. Each build gets one more than the
# highest existing k8s-node-<minor>-r<N> template for that minor
# and architecture; the first build is r1. Existing templates are
# immutable, so a rebuild always produces a new revision.
#
# usage: next_revision MINOR ARCH < list-of-vm-names
next_revision() {
    _minor_re=$(printf '%s' "$1" | sed 's/\./\\./g')
    if [ "$2" = arm64 ]; then
        _re="^k8s-node-$_minor_re-r[0-9][0-9]*-arm64\$"
    else
        _re="^k8s-node-$_minor_re-r[0-9][0-9]*\$"
    fi
    _max=$(grep -E "$_re" | sed -E 's/^k8s-node-[^-]*-r([0-9]+).*/\1/' \
        | sort -n | tail -1)
    echo $(( ${_max:-0} + 1 ))
}

# Names of every VM/template in the PVE cluster, one per line.
cluster_vm_names() {
    pvesh get /cluster/resources --type vm --output-format json \
        | grep -o '"name":"[^"]*"' | cut -d'"' -f4
}

# Template names from the build history on pmxcfs. A revision is never
# reused, even after every template copy was deleted (a recreated
# cluster rebuilt r1 while r5 and r6 had shipped).
recorded_template_names() {
    _state=${1:-/etc/pve/k8s/template-state.json}
    [ -r "$_state" ] || return 0
    perl -MJSON::PP -e '
        local $/; my $s = eval { decode_json(<STDIN>) } || {};
        for (sort keys %{ $s->{builds} || {} }) {
            my ($minor, $arch, $rev) = m{^([\d.]+)/(\w+)/r(\d+)$} or next;
            print "k8s-node-$minor-r$rev", ($arch eq "arm64" ? "-arm64" : ""), "\n";
        }' < "$_state"
}

