#!/bin/sh
# SONiC-vs IP CLOS fabric: kernel vnet point-to-point /31 addresses plus the
# FRR eBGP session settings the bgpcfgd render does not carry (leaf2).
# SAI data plane is dark in vs (AF_PACKET re-ingest loop); L3 runs in the
# guest kernel on PVE vnet interfaces. Idempotent; safe to re-run.
#
# Links (PVE bridge -> subnet):
#   eth1 (br-c-s1l1a) 10.0.3.1/31   <-> spine1 eth1
#   eth3 (br-c-s2l1a) 10.0.7.1/31   <-> spine2 eth1
#   eth5 (br-c-l1srv)  10.0.10.0/31 <-> LXC srv2 10.0.10.1
#
# bgpcfgd re-renders /etc/sonic/frr/bgpd.conf from CONFIG_DB on any CONFIG_DB
# change (and at bgp container start) and restarts bgpd. The standard
# template renders the local AS (DEVICE_METADATA.bgp_asn), the Lo0 network
# and maximum-paths, but NOT the BGP neighbors, the kernel-only P2P/srv /31
# networks or static redistribution (srv Lo0 /32s); it also sets
# "no bgp default ipv4-unicast", which leaves v4 peers without an active
# AFI (show ip bgp summary then falsely says "No BGP neighbors found");
# the default flag does NOT retro-activate existing peers, so each peer is
# explicitly activated under "address-family ipv4" as well.
# This script re-applies all of it after every (re)start. It is a oneshot
# service at VM boot and must be re-run manually after any CONFIG_DB change.

ip link set eth1 up 2>/dev/null
ip addr add 10.0.3.1/31 dev eth1 2>/dev/null
ip link set eth3 up 2>/dev/null
ip addr add 10.0.7.1/31 dev eth3 2>/dev/null
ip link set eth5 up 2>/dev/null
ip addr add 10.0.10.0/31 dev eth5 2>/dev/null

# Wait until bgpd answers vtysh (either state: with neighbors, or the
# "No BGP neighbors found" banner right after a bgpcfgd re-render), then
# (re)apply the render-missing parts below.
i=0
while [ $i -lt 45 ]; do
    if vtysh -c "show ip bgp summary" 2>/dev/null | grep -q -E "BGP router identifier|No BGP neighbors"; then
        break
    fi
    i=$((i + 1))
    sleep 2
done
vtysh -c "configure terminal" -c "router bgp 65004" -c "bgp default ipv4-unicast" -c "neighbor 10.0.3.0 remote-as 65001" -c "neighbor 10.0.7.0 remote-as 65001" -c "maximum-paths 2" -c "network 10.0.3.0/31" -c "network 10.0.7.0/31" -c "network 10.0.10.0/31" -c "address-family ipv4" -c "neighbor 10.0.3.0 activate" -c "neighbor 10.0.7.0 activate" -c "exit-address-family" -c "redistribute static" -c "end" 2>/dev/null

exit 0
