#!/bin/sh
# Lab helper: turn this machine into a BGP test client for
# the pve-k8s physical lab (cloud1/2/3). It peers eBGP with
# the three PVE hosts (AS 65000) and accepts the Kubernetes
# public block (192.168.3.0/24) that the SDN EVPN exit
# nodes advertise, so LoadBalancer/VIP reachability can be
# proven from a "laptop" before any production router
# (OPNsense FRR today, VyOS later) is touched.
#
# Requires the frr package. Run as root:
#   sudo tests/lab-bgp-testclient.sh
# Overrides: LOCAL_AS, PEER_AS, PEERS, ROUTER_ID.
set -eu

LOCAL_AS=${LOCAL_AS:-65001}
PEER_AS=${PEER_AS:-65000}
PEERS=${PEERS:-"10.0.2.51 10.0.2.52 10.0.2.53"}
ROUTER_ID=${ROUTER_ID:-$(hostname -I | awk '{print $1}')}

if [ "$(id -u)" != "0" ]; then
    echo "run as root (sudo)" >&2
    exit 1
fi
if ! command -v vtysh >/dev/null; then
    echo "frr is not installed (apt install frr)" >&2
    exit 1
fi

# Enable the BGP and BFD daemons.
sed -i 's/^bgpd=.*/bgpd=yes/; s/^bfdd=.*/bfdd=yes/' /etc/frr/daemons

# One-time backup of any hand-written config.
if [ -f /etc/frr/frr.conf ] && [ ! -f /etc/frr/frr.conf.pre-k8s ]; then
    cp /etc/frr/frr.conf /etc/frr/frr.conf.pre-k8s
fi

{
    echo "frr defaults traditional"
    echo "hostname testclient"
    echo "log syslog informational"
    echo "service integrated-vtysh-config"
    echo "!"
    echo "router bgp $LOCAL_AS"
    echo " bgp router-id $ROUTER_ID"
    echo " no bgp default ipv4-unicast"
    for peer in $PEERS; do
        echo " neighbor $peer remote-as $PEER_AS"
    done
    echo " !"
    echo " address-family ipv4 unicast"
    for peer in $PEERS; do
        echo "  neighbor $peer activate"
    done
    echo " exit-address-family"
    echo "!"
} > /etc/frr/frr.conf

systemctl enable --now frr
sleep 3
systemctl is-active frr
vtysh -c 'show bgp summary' || true
echo "BGP test client configured (AS $LOCAL_AS, router-id $ROUTER_ID)"
