#!/usr/bin/env bash
# Task 5: busybox LXC 905 (lab-srv1) + 906 (lab-srv2) on PVE node.
# Run ON the PVE host as root:  bash create-lxc-servers.sh
# Approved scope: 2026-11-14 ("approve", Tasks 2–5 scope).
#
# MAPPING per inventory/fabric.yaml (live-verified 2026-11-14). The bridge
# names in plan Task 5 Step 2 are STALE (pre-swap) — do not use them:
#   905 lab-srv1 -> bridge br-c-l2srv, 10.0.9.1/31,  gw 10.0.9.0   (leaf1, 199)
#   906 lab-srv2 -> bridge br-c-l1srv, 10.0.10.1/31, gw 10.0.10.0 (leaf2, 145)
set -euo pipefail
H=$(hostname)
log() { echo "[$H] $*"; }

BUSYBOX=/bin/busybox
[ -x "$BUSYBOX" ] || { log "FATAL: $BUSYBOX not found"; exit 1; }
ROOTFS=/tmp/bbx/rootfs
TPL=/var/lib/vz/template/ct-busybox.tar.gz

# ---------- 1. busybox rootfs ----------
rm -rf /tmp/bbx
mkdir -p "$ROOTFS"/{bin,sbin,usr/bin,etc/init.d,proc,sys,dev,tmp,root}
install -m 755 "$BUSYBOX" "$ROOTFS/bin/busybox"
cd "$ROOTFS"
# host busybox is dynamically linked -> copy its libs + interpreter into rootfs
for lib in $(ldd "$BUSYBOX" | awk -F' => ' '/ => /{print $2}' | awk '{print $1}'); do
  [ -f "$lib" ] || continue
  mkdir -p "$ROOTFS/$(dirname "$lib")"
  cp -f "$lib" "$ROOTFS/$lib"
done
interp=$(ldd "$BUSYBOX" | grep -oE '/[^ ]*ld-linux[^ ]*' | head -1 || true)
if [ -n "$interp" ] && [ -f "$interp" ]; then
  mkdir -p "$ROOTFS/$(dirname "$interp")"
  cp -f "$interp" "$ROOTFS/$interp"
fi
log "libs: $(find "$ROOTFS/lib" "$ROOTFS/lib64" -type f 2>/dev/null | tr '\n' ' ')"
cd "$ROOTFS"
for a in sh ip ping hostname mount umount ls cat echo sleep ps nc traceroute id uname grep sed date vi wc top ifconfig kill; do
  ln -sf busybox "bin/$a"
done
ln -sf /bin/busybox sbin/init
printf 'root::0:0:root:/root:/bin/sh\n' > etc/passwd
printf 'root::0:\n' > etc/group
printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > etc/hosts
echo lab-srv1 > etc/hostname
cat > etc/inittab <<'EOF'
::sysinit:/etc/init.d/rcS
tty1::respawn:/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
cat > etc/init.d/rcS <<'EOF'
#!/bin/sh
# minimal busybox CT init: guarded mounts + per-CT net (lab-srv1/lab-srv2)
# Idempotent: flush stale addrs/routes before re-applying (safe to re-run when
# the CT is reconfigured, e.g. hostname corrected after an unmanaged boot).
mount -t proc  proc /proc  2>/dev/null || true
mount -t sysfs sysfs /sys   2>/dev/null || true
mount -t tmpfs tmpfs /tmp   2>/dev/null || true
HN=$(cat /etc/hostname 2>/dev/null || echo lab-srv)
hostname "$HN"
ip link set lo up 2>/dev/null || true
ip addr flush dev lo 2>/dev/null || true
ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true
ip addr flush dev eth0 2>/dev/null || true
ip route del default 2>/dev/null || true
case "$HN" in
  lab-srv1)
    ip addr add 10.1.0.99/32  dev lo   2>/dev/null || true
    ip addr add 10.0.9.1/31   dev eth0 2>/dev/null || true
    ip link set eth0 up
    ip route add default via 10.0.9.0 2>/dev/null || true
    ;;
  *)
    ip addr add 10.1.0.100/32 dev lo   2>/dev/null || true
    ip addr add 10.0.10.1/31  dev eth0 2>/dev/null || true
    ip link set eth0 up
    ip route add default via 10.0.10.0 2>/dev/null || true
    ;;
esac
EOF
chmod 755 etc/init.d/rcS
tar -C "$ROOTFS" -czf "$TPL" .
log "template: $TPL ($(du -h "$TPL" | cut -f1))"

# ---------- 2. create + start CTs ----------
create_ct() { # <id> <name> <bridge>
  if pct status "$1" >/dev/null 2>&1; then
    log "CT $1 already exists — skip create"
    return 0
  fi
  # NOTE: no --name: PVE 9 LXC has no top-level 'name' param (only netconf 'name');
  # passing it makes Getopt misparse and corrupts --nameserver -> 400 invalid format.
  # CT display name == hostname, set via --hostname below.
  pct create "$1" "$TPL" --ostype unmanaged --memory 256 --cores 1 \
    --hostname "$2" --nameserver 192.168.1.1 --rootfs local-lvm:1 \
    --net0 "name=eth0,bridge=$3"
  pct start "$1"
  # PVE does NOT write /etc/hostname for 'unmanaged' templates, so BOTH CTs
  # first boot as the template default (lab-srv1) -> 906 would come up with
  # srv1's addrs on leaf2's L2. Set the real hostname, then re-run the
  # idempotent rcS to apply THIS CT's addresses/route. ('--' required: pct
  # exec eats any dash-prefixed arg otherwise; /etc/init.d/rcS has no dashes.)
  sleep 2
  pct exec "$1" -- sh -c "echo '$2' > /etc/hostname"
  pct exec "$1" /etc/init.d/rcS
}
log "--- RAM before ---"; free -g
create_ct 905 lab-srv1 br-c-l2srv
create_ct 906 lab-srv2 br-c-l1srv
sleep 5
pct status 905
pct status 906
log "--- hostname inside CTs ---"
pct exec 905 cat /etc/hostname
pct exec 906 cat /etc/hostname
log "--- addr/route 905 ---"
pct exec 905 ip addr show
pct exec 905 ip route
log "--- addr/route 906 ---"
pct exec 906 ip addr show
pct exec 906 ip route

# ---------- 3. verification ----------
ck() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then log "OK   $d"; else log "FAIL $d"; fi
}
# NOTE (2026-11-15): fabric underlay is INCOMPLETE — inter-leaf prefixes and
# some spine-Lo0 routes are not installed on the leaves (docs/design-ip-clos.md
# «Поточний стан»). The reliable Task-5 signal = own-leaf + own-lo pings.
# Cross-leaf pings are EXPECTED to fail; spine pings MAY also fail until the
# underlay is fixed (separate, unapproved scope).
log "--- end-to-end (busybox CT) ---"
ck "905 ping spine1 10.1.0.1 [may fail — underlay]" pct exec 905 -- ping -c2 -W2 10.1.0.1
ck "905 ping spine2 10.1.0.2 [may fail — underlay]" pct exec 905 -- ping -c2 -W2 10.1.0.2
ck "905 ping leaf1  10.1.0.3"         pct exec 905 -- ping -c2 -W2 10.1.0.3
ck "905 ping own lo 10.1.0.99"        pct exec 905 -- ping -c2 -W2 10.1.0.99
ck "905 ping leaf2  10.1.0.4 (EXPECT FAIL — inter-leaf open)" pct exec 905 -- ping -c2 -W2 10.1.0.4
ck "905 ping srv2   10.1.0.100 (EXPECT FAIL — inter-leaf open)" pct exec 905 -- ping -c2 -W2 10.1.0.100
ck "906 ping spine2 10.1.0.2 [may fail — underlay]" pct exec 906 -- ping -c2 -W2 10.1.0.2
ck "906 ping spine1 10.1.0.1 [may fail — underlay]" pct exec 906 -- ping -c2 -W2 10.1.0.1
ck "906 ping leaf2  10.1.0.4"         pct exec 906 -- ping -c2 -W2 10.1.0.4
ck "906 ping own lo 10.1.0.100"       pct exec 906 -- ping -c2 -W2 10.1.0.100
ck "906 ping leaf1  10.1.0.3 (EXPECT FAIL — inter-leaf open)" pct exec 906 -- ping -c2 -W2 10.1.0.3

log "--- leaf1 (199): srv1 prefix ---"
ssh -o BatchMode=yes admin@192.168.1.199 \
  "vtysh -c 'show ip bgp 10.1.0.99' | head -10; sudo -n ping -c2 -W2 10.0.9.1 2>/dev/null | tail -1 || echo 'ping: no sudo (informational)'" \
  || log "leaf1 guest check failed"
log "--- spine1 (247): srv routes/ping ---"
ssh -o BatchMode=yes admin@192.168.1.247 \
  "vtysh -c 'show ip bgp 10.1.0.99' | head -10; vtysh -c 'show ip bgp 10.1.0.100' | head -10; sudo -n ping -c2 -W2 10.1.0.99 2>/dev/null | tail -1 || echo 'ping: no sudo'; sudo -n ping -c2 -W2 10.1.0.100 2>/dev/null | tail -1 || echo 'ping: no sudo'" \
  || log "spine1 guest check failed"
log "--- RAM after ---"
free -g
log "DONE"
