# Running configs — SONiC IP CLOS lab (evidence snapshot 2026-11-17)

> **Source of truth:** intended config = `configs/<dev>/config_db.json` (repo:
> `bgp_asn`, `BGP_NEIGHBOR`, `STATIC_ROUTE`). Live FRR config = bgpcfgd render
> (from CONFIG_DB at bgp-container (re)start / DEVICE_METADATA change) +
> `fabric-vnet.sh` vtysh block (neighbors, `bgp default ipv4-unicast`,
> per-neighbor AFI `activate`, p2p/srv networks, `maximum-paths 2`,
> `redistribute static` on leaves). The 2026-11-14 snapshot below is
> **historical** (pre-fix); current live state = 2026-11-17.

## Node summary

| Role | Mgmt | AS | Lo0 | BGP neighbors (remote-as) | Advertised (render + vtysh) |
|------|------|----|-----|---------------------------|------------------------------|
| spine1 | 192.168.1.247 | 65001 | 10.1.0.1/32 | 10.0.1.1 (leaf1, 65003), 10.0.3.1 (leaf2, 65004) | 10.1.0.1/32 (render `network`) |
| spine2 | 192.168.1.82 | 65001 | 10.1.0.2/32 | 10.0.5.1 (leaf1, 65003), 10.0.7.1 (leaf2, 65004) | 10.1.0.2/32 (render `network`) |
| leaf1 | 192.168.1.199 | 65003 | 10.1.0.3/32 | 10.0.1.0 (spine1, 65001), 10.0.5.0 (spine2, 65001) | 10.0.1.0/31, 10.0.5.0/31, 10.0.9.0/31 (vtysh) + statics |
| leaf2 | 192.168.1.145 | 65004 | 10.1.0.4/32 | 10.0.3.0 (spine1, 65001), 10.0.7.0 (spine2, 65001) | 10.0.3.0/31, 10.0.7.0/31, 10.0.10.0/31 (vtysh) + statics |

All 4: FRR 10.7.1. Live config = bgpcfgd render (`router bgp <asn>`, own Lo0
network, `maximum-paths 2`, `no bgp default ipv4-unicast`, built-in route-maps,
timers 180/60 default) + `fabric-vnet.sh` vtysh block (neighbors, AFI, networks,
`redistribute static` on leaves). AS re-plan 2026-11-16: leaves 65002 → 65003/65004.

## Static routes (config_db.json `STATIC_ROUTE` → zebra)

| Node | Static routes |
|------|---------------|
| spine1 | `10.1.0.1/32 blackhole` |
| spine2 | `10.1.0.2/32 blackhole` |
| leaf1 | `10.0.9.0/31 blackhole`, `10.1.0.3/32 blackhole`, `10.1.0.99/32 → 10.0.9.1` |
| leaf2 | `10.0.10.0/31 blackhole`, `10.1.0.4/32 blackhole`, `10.1.0.100/32 → 10.0.10.1` |

(The 2026-11-14 hand-crafted era used `tag 1` statics; current `config_db.json`
has no tag — leaves advertise via vtysh `redistribute static`, spines via
render `network`/`redistribute connected`.)

## Live BGP snapshots (2026-11-14 — historical, pre-fix)

### spine1 (192.168.1.247) — `show ip bgp summary`

```
Neighbor   V   AS     PfxRcd  PfxSnt  State
10.0.1.1  4  65002    3       7      Established   (leaf1a)
10.0.3.1  4  65002    3       7      Established   (leaf2a)
```
Table = 7 routes (own Lo0 + 3 from leaf1 + 3 from leaf2). Sends **7/leaf**.

### spine2 (192.168.1.82) — `show ip bgp summary`

```
Neighbor   V   AS     PfxRcd  PfxSnt  State
10.0.5.1  4  65002    3       1      Established   (leaf1a)
10.0.7.1  4  65002    3       1      Established   (leaf2a)
```
Table = 7 routes (own Lo0 + 3 from leaf1 + 3 from leaf2). Sends **1/leaf** ⚠️.

### leaf1 (192.168.1.199) — `show ip bgp`

```
Network          Next Hop     Path
*> 10.0.9.0/31   0.0.0.0      (own)
*> 10.1.0.1/32   10.0.1.0     65001 i   (spine1 Lo0)
*> 10.1.0.2/32   10.0.5.0     65001 i   (spine2 Lo0)
*> 10.1.0.3/32   0.0.0.0      (own)
*> 10.1.0.99/32  10.0.9.1     ?         (srv1, static)
```
**5 routes. PfxRcd = 1/spine. MISSING: 10.0.10.0/31, 10.1.0.4/32, 10.1.0.100/32 (leaf2).**
`show ip bgp 10.1.0.4` / `10.0.10.0` → `% Network not in table`.

### leaf2 (192.168.1.145) — `show ip bgp`

Symmetric to leaf1: 5 routes (own 3 + 2 spine Lo0 + srv2 static).
**PfxRcd = 1/spine. MISSING: 10.0.9.0/31, 10.1.0.3/32, 10.1.0.99/32 (leaf1).**
`show ip bgp 10.1.0.3` / `10.0.9.0` → `% Network not in table`.

## Finding (CLOSED 2026-11-17)

Two independent root causes behind the 2026-11-14/15 "inter-leaf broken" state:

1. **AFI not activated.** The bgpcfgd standard template renders
   `no bgp default ipv4-unicast`; v4 neighbors added via vtysh came up without
   an active AFI — `show ip bgp summary` falsely printed "% No BGP neighbors
   found" while the peers existed (state Idle, Opens 0). The global
   `bgp default ipv4-unicast` does NOT retro-activate existing peers
   (FRR 10.7.1). Fix: per-neighbor `activate` under `address-family ipv4` in
   all 4 `fabric-vnet.sh`.
2. **zebra FIB-hang.** leaf2 (and earlier spine2) kept a populated BGP RIB
   while zebra RIB = `Status: Failed` and the kernel FIB had 0 BGP routes.
   Fix: `sudo docker restart bgp` + re-run `fabric-vnet.sh` → `Status: Installed`.

Live state after fixes (2026-11-17): 8/8 Established; leaf PfxRcd 7/spine,
spine PfxRcd 5/leaf; inter-leaf + srv1↔srv2 pings 0% loss; **ECMP x2
verified** (kernel: 2 nexthops for 10.1.0.4 on leaf1 and 10.1.0.3 on leaf2).
In this FRR build plain `maximum-paths 2` enables eBGP multipath
(`maximum-paths ebgp` is an unknown command). Expected non-reachability:
spine1↔spine2 Lo0 (no spine–spine link; leaves do not re-advertise eBGP
Lo0 routes).

## Per-node FRR config delta (current: render + vtysh)

`/etc/sonic/frr/bgpd.conf` (host; bind-mount `/etc/frr/bgpd.conf` in the bgp
container) is **render-only**: `router bgp <asn>`, own Lo0 network,
`maximum-paths 2`, `no bgp default ipv4-unicast`, built-in route-maps. It does
NOT carry BGP_NEIGHBOR, the p2p/srv networks, AFI activation or
`redistribute static` — those are applied by `/usr/local/lib/fabric-vnet.sh`
(vtysh; oneshot at VM boot, re-run after any CONFIG_DB change / bgp restart):

| Node (AS) | vtysh neighbors (remote-as) | vtysh networks | Extra |
|-----------|------------------------------|----------------|-------|
| spine1 (65001) | 10.0.1.1 (65003), 10.0.3.1 (65004) | 10.0.1.0/31, 10.0.3.0/31 | AFI activate ×2 |
| spine2 (65001) | 10.0.5.1 (65003), 10.0.7.1 (65004) | 10.0.5.0/31, 10.0.7.0/31 | AFI activate ×2 |
| leaf1 (65003) | 10.0.1.0 (65001), 10.0.5.0 (65001) | 10.0.1.0/31, 10.0.5.0/31, 10.0.9.0/31 | AFI activate ×2, `redistribute static` |
| leaf2 (65004) | 10.0.3.0 (65001), 10.0.7.0 (65001) | 10.0.3.0/31, 10.0.7.0/31, 10.0.10.0/31 | AFI activate ×2, `redistribute static` |

All 4 also set `bgp default ipv4-unicast` + `maximum-paths 2` via vtysh
(idempotent). Re-provisioning source of truth: `configs/<dev>/config_db.json`
+ `configs/<dev>/fabric-vnet.sh` (+ `fabric-vnet.service` on the VMs).
