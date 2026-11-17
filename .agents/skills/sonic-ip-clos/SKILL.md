---
name: sonic-ip-clos
description: Operate the SONiC IP CLOS lab on PVE 192.168.1.19 (VM 901-904 + busybox LXC 905/906) — BGP/ECMP status checks, config_db.json + fabric-vnet.sh deploy, AFI/FIB-hang diagnosis, LXC server pings. Use when checking fabric state, deploying/redeploying configs on the SONiC VMs, touching br-c-* bridges, KSM, or reading/editing configs/sonic-*, inventory/fabric.yaml, runbooks/, docs/design-ip-clos.md in this repo.
---

# SONiC IP CLOS — PVE lab operations

## When to use
- Check current fabric state (BGP, ping matrix, ECMP) on PVE `192.168.1.19`.
- Deploy or re-deploy `config_db.json` / `fabric-vnet.sh` on the 4 SONiC VMs.
- Diagnose BGP issues (Idle peers, `% No BGP neighbors found`, FIB `Status: Failed`).
- Manage LXC 905/906 (pct exec, busybox rootfs, rcS networking).
- Read/edit repo artifacts: `configs/sonic-*`, `inventory/fabric.yaml`, `runbooks/*`, `docs/*`, `scripts/*`.

## Language
- Відповідай користувачу українською, якщо не вказано інше.
- YAML-ключі, команди, ідентифікатори, OIDs — англійською, як в репо.

## Hard rules
- **Lab only.** Жодна конфігурація не для production; перед production — повторна перевірка в lab.
- **Write-approve:** будь-яка зміна на PVE/VM/CT (qm/pct/config load/reboot/bridges/ksm) — тільки після явного approve користувача (skill `remote-host-config-approve`). Read-only (`show`, `cat`, `ip`, `vtysh -c "show ..."`, `pct exec ... -- ping`, `qm list`, `pct list`) — без approve.
- **Evidence only:** IP / AS / префікси — з `inventory/fabric.yaml` та репо, не вигадувати.
- Мінімальні дифи в репо; не ре-генерувати UUID/конфіг'и поза запитом. Не git repo.

## Topology & addressing (source of truth: `inventory/fabric.yaml`)

| Роль | PVE ID | PVE name | AS | Lo0 | Mgmt |
|------|--------|----------|----|-----|------|
| spine1 | 901 | sonic-spine1 | 65001 | 10.1.0.1 | 192.168.1.247 |
| spine2 | 902 | sonic-spine2 | 65001 | 10.1.0.2 | 192.168.1.82 |
| **leaf2** | 903 | sonic-leaf1 ⚠️ | 65004 | 10.1.0.4 | 192.168.1.145 |
| **leaf1** | 904 | sonic-leaf2 ⚠️ | 65003 | 10.1.0.3 | 192.168.1.199 |
| srv1 | 905 | lab-srv1 (LXC) | — | 10.1.0.99 | — (`pct exec`) |
| srv2 | 906 | lab-srv2 (LXC) | — | 10.1.0.100 | — (`pct exec`) |

> ⚠️ **SWAP (історичний, зберігається):** PVE 903 = operationally leaf2, PVE 904 = leaf1.
> `configs/sonic-leaf1/` → VM **904**, `configs/sonic-leaf2/` → VM **903**.
> Оперувати за роллю + mgmt IP, не за PVE name.

P2P /31: spine1–leaf1 `10.0.1.0/31` (br-c-s1l2a); spine1–leaf2 `10.0.3.0/31` (br-c-s1l1a);
spine2–leaf1 `10.0.5.0/31` (br-c-s2l2a); spine2–leaf2 `10.0.7.0/31` (br-c-s2l1a);
leaf1–srv1 `10.0.9.0/31` (br-c-l2srv); leaf2–srv2 `10.0.10.0/31` (br-c-l1srv).
Bridges `*b` (s1l1b/s1l2b/s2l1b/s2l2b) — інертні, без IP.

SONiC `master.1273518-6f800f3d4`, FRR 10.7.1. Port map: qm `netN` → `Ethernet{4*(N-1)}` (`net1→Ethernet0` … `net5→Ethernet16`); `net0`/eth0 = mgmt (vmbr0, DHCP).

## Access patterns
- **SSH Mac → VM: тільки через PVE** (direct publickey deny):
  `ssh root@192.168.1.19 "ssh admin@<vm-mgmt-ip> '<cmd>'"`.
- **3-level quoting:** local double-quotes → PVE single-quoted VM command → в VM `\"` для double quotes.
- **LXC:** `pct exec <id> -- <cmd>` — сепаратор `--` ОБОВ'ЯЗКОВИЙ. Без mgmt NIC.
- **vtysh** на VM: `sudo vtysh -c "..."` = контейнерний bgpd. Помилки → STDOUT; тихий вивід = успіх. `show running-config router bgp` — unknown; використовувати `show running-config | grep ...`.
- **admin** читає rendered-файл: `sudo docker exec bgp grep ... /etc/frr/bgpd.conf`.
- **Redis db4** (SONiC): `sudo redis-cli -n 4`; `DEVICE_METADATA|localhost` → `bgp_asn`; `BGP_NEIGHBOR|<ip>` → field **`asn`** (НЕ `peering_asn`). Після HSET — `sudo config save -y`.
- Terminal tool: `cd` = `/Users/omartyny/WORK/sonic`. Локальна модель — малі точкові grep.

## bgpcfgd behavior (empirical, this build)
- Render-файл (`/etc/frr/bgpd.conf`, bind-mount) = `router bgp <asn>` (з DEVICE_METADATA) + own Lo0 network + `maximum-paths 2` (з `constants.yml`) + `no bgp default ipv4-unicast` + built-in route-maps + умовна `redistribute connected`.
- **НЕ рендерить:** BGP_NEIGHBOR, p2p networks, AFI, `redistribute static`.
- Re-render trigger: зміна DEVICE_METADATA **або** (re)start контейнера `bgp`. Зміна BGP_NEIGHBOR — **не** триггерить.
- **Sed render-файлу марний** — re-render пересилить при restart контейнера. Neighbor'и живуть тільки в running-config + `fabric-vnet.sh`.

## Pitfalls (verified, FRR 10.7.1 / PVE 9.2)
- **AFI:** глобальний `bgp default ipv4-unicast` НЕ retro-активує existing peers → обов'язкова per-neighbor `activate` під `address-family ipv4` (в `fabric-vnet.sh`). `show ip bgp summary` → `% No BGP neighbors found` коли AFI не активовано — перевіряти `show ip bgp neighbor <ip>`.
- **FIB-hang:** BGP RIB full + зebra RIB `Status: Failed` (nexthops `r` не `*`) + kernel 0 BGP-маршрутів → `sudo docker restart bgp` + re-run `sudo /usr/local/lib/fabric-vnet.sh`. Може рецидивувати на будь-якому ноді після (re)start bgp-контейнера.
- **ECMP verify:** `ip -4 route show <prefix>` (повний запис) або зebra `show ip route <prefix>`. НЕ `ip -4 route | grep bgp` (truncує multipath continuation lines) і НЕ `ip route get <dst>` (завжди 1 nexthop).
- **`maximum-paths ebgp 2`** = Unknown command в цьому FRR; plain `maximum-paths 2` вмикає eBGP multipath (1-514, дефолт в constants.yml 514 відхиляється FRR → sed 514→2).
- **PVE LXC:** `pct create` без `--name`; unmanaged template → PVE НЕ пише `/etc/hostname`; `sbin/init` — абсолютний symlink в `/bin/busybox`.
- **KSM:** `/etc/systemd/system/ksm.service` (oneshot `run=1`) + masked `ksmtuned` — загальна оптимізація PVE, не частини fabric; при teardown НЕ прибирати за замовчуванням.
- **Не чіпати:** VM 101, CT 100 (user), `vmbr0`.
- Паралельні terminal-виклики повертаються в перемішаному порядку — label-ити вивід (L1-/S1-/S2-/L2-), звіряти за змістом.

## Deploy paths (write, needs approve)
- **fabric-vnet.sh:** `scp` Mac→`root@PVE:/tmp/fv-<dev>.sh` → PVE: `scp /tmp/fv-<dev>.sh admin@<vm>:/tmp/fv.sh && ssh admin@<vm> 'sudo cp /tmp/fv.sh /usr/local/lib/fabric-vnet.sh && sudo chmod 755 /usr/local/lib/fabric-vnet.sh'` → VM: `sudo /usr/local/lib/fabric-vnet.sh`.
- **config_db.json:** scp на VM → `sudo cp /etc/sonic/config_db.json /etc/sonic/config_db.json.bak` → `sudo config load -y /tmp/config_db.json` → `sudo config save -y` → `sudo reboot`.
- **LXC:** `scripts/create-lxc-servers.sh` на PVE (builds busybox template `/var/lib/vz/template/ct-busybox.tar.gz` + `pct create 905/906`, idempotent rcS).
- **Bridges:** stanza-файли `/etc/network/interfaces.d/br-c-<id>` + `systemctl restart networking`.

## Expected healthy state (verify matrix)
- BGP **8/8 Established** (2 peers/нода); PfxRcd: leaf 7/spine, spine 5/leaf.
- Ping 0% loss: srv1↔srv2, srv→обидва spines, leaf1↔leaf2 Lo0, leaf↔spine, spine→leaf/srv.
- ECMP x2 в kernel FIB: leaf1 `10.1.0.4/32` = nexthop 10.0.1.0/eth1 + 10.0.5.0/eth3; leaf2 `10.1.0.3/32` = nexthop 10.0.3.0/eth1 + 10.0.7.0/eth3; зebra `Status: Installed`.
- **spine1↔spine2 Lo0 = FAIL by design** (немає spine–spine линку; eBGP не ре-анонсує Lo0) — НЕ баг, не чинити.

## Key repo artifacts
- `configs/sonic-{spine1,spine2,leaf1,leaf2}/config_db.json` + `fabric-vnet.sh` — source of truth для deploy.
- `inventory/fabric.yaml` — addressing/AS/NIC map (оновлювати після змін).
- `scripts/gen_config_db.py`, `scripts/create-lxc-servers.sh`.
- `runbooks/00-destroy.md`, `runbooks/01-restore.md` — teardown/restore.
- `docs/design-ip-clos.md` (дизайн + «Поточний стан» + pitfalls), `docs/running-configs.md` (snapshot), `docs/verification-2026-11-17.md` (verification-звіт), `docs/plans/2026-11-12-pve-clos-deploy.md` (план, статус).
- `sonic-vs.img.gz` — source-образ для restore.

## Workflow
1. Open `inventory/fabric.yaml` + relevant `configs/sonic-*/` — mirror before acting.
2. Read-only checks first (vtysh summary, kernel FIB, pct exec ping).
3. For writes — state exact commands, wait for approve, then execute + verify.
4. After any bgp-container restart / VM reboot — перевірити FIB (`ip -4 route show <prefix>`, зebra `Status`); при `Failed` — FIB-hang fix.
5. Update `inventory/fabric.yaml` / `docs/` when addressing, AS, status change.
6. Якщо сумнів у семантиці FRR/SONiC/PVE — вказати на схожий in-repo об'єкт, не вигадувати.
