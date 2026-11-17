# Plan: IP CLOS fabric на SONiC в PVE 192.168.1.19

> Інфраструктурний план (не code-TDD). Кожна задача = самодостатній крок з
> чітким критерієм готовності. Read-only перевірки окремим списком.

**Goal:** 2 spines + 2 leaves (SONiC VM) + 2 busybox LXC-сервера в PVE, BGP
underlay з 2-way ECMP, reprodutive config через `config_db.json`.

**Spec:** `docs/design-ip-clos.md`, інвентар `inventory/fabric.yaml`.

## Статус (2026-11-17)

- **Task 4 Step 5 (Verification): PASSED (2026-11-17).** 8/8 BGP Established;
  inter-leaf (leaf1↔leaf2) + srv1↔srv2 — 0% loss; ECMP x2 верифіковано
  (2 kernel nexthops на обох leaves); spine → всі data-кінцевики OK.
  Spine1↔spine2 Lo0 — недосяжно by design (немає spine–spine линку; leaves не
  ре-анонсують eBGP Lo0). Root-причини попереднього FAIL: (1) AFI не
  активовано на vtysh-neighbor'ах (render = `no bgp default ipv4-unicast`;
  фікс = per-neighbor `activate` в `fabric-vnet.sh`); (2) zebra FIB-hang на
  leaf2 (`Status: Failed`; фікс = `docker restart bgp` + re-run script).
  AS re-plan: leaves 65002 → 65003/65004. Деталі: `docs/design-ip-clos.md`.
- **Task 5 (LXC 905/906): DONE (2026-11-15)** — CT створені
  `scripts/create-lxc-servers.sh`; full verify matrix 2026-11-17: srv1↔srv2,
  srv→spine — 0% loss.
- **Task 6 (документація): DONE (2026-11-17)** — design-ip-clos.md ✅,
  running-configs.md ✅, README.md ✅; `runbooks/00-destroy.md` ✅,
  `runbooks/01-restore.md` ✅; `docs/verification-2026-11-17.md` ✅;
  inventory/fabric.yaml оновлено (AS re-plan + статус).
- **Open item (опція A): CLOSED (2026-11-17)** — root cause знайдено і
  виправлено (AFI + FIB-hang, див. Task 4 Step 5).

## Global Constraints

- ПРАВИЛО: будь-яка зміна на PVE / SONiC VM / LXC — **тільки після явного
  approve користувача** (skill `remote-host-config-approve`).
- Read-only дозволено без approve: `show`, `cat`, `ip`, `systemctl status`,
  `qm list`, `pct list`, `pct exec ... ping`.
- RAM вуза: 11 GB → бюджет VM/CT ≤ 8.5 GB (4×2 GB + 2×256 MB).
- Не рухати існуючі VM/CT (100, 101). Тільки нові файли/VM/CT/bridges, без
  overwrite.
- Не виставляти lab-мережу (10.0.0.0/16, 10.1.0.0/24) за межі PVE хоста.

## Review Focus

1. **RAM**: 8.5 GB + host ~1 GB + CT100 ≤1 GB ≈ 10.5 GB з 11.3 + 8 GB swap
   (перевірено 2026-11-12: MemAvailable ≈ 9.7 GB, swap майже порожній).
   Контроль `free -g` після кожного boot; fallback — SONiC offline resize до
   1.5 GB (окремий approve).
2. **Boot**: OVMF відсутні → SeaBIOS. Якщо vs-image не завантажується —
   `apt install qemu-ovmf-pve-boot` (окремий approve).
3. **busybox CT**: PVE CT без ifupdown — інтерфейс піднімається вручну в
   init. Якщо PVE відхиляє rootfs / init не стартує — fallback minimal Debian
   rootfs через `debootstrap` (окремий крок).
4. **DHCP mgmt**: 4 SONiC VM клієнти в 192.168.1.0/24 — якщо пул роутера
   маленький, mgmt IP не отримаються (static mgmt — follow-up). LXC без mgmt NIC.
5. **Схема BGP в config_db**: ✅ ВИЗНАЧЕНО (2026-11-13, VM 901): в цьому білді
   НЄ `BGP_GLOBALS` і НЄ `config bgp network`. Розсилок = `STATIC_ROUTE`
   (auto-redistribute в bgpcfgd). ECMP = `/etc/sonic/constants.yml`
   `bgp.maximum_paths.ipv4/ipv6: 2` (дефолт 514 відхиляється FRR).
6. **Port map vs-платформи**: NIC idx → EthernetX. Якщо порядок відрізняється —
   оновити `inventory/fabric.yaml` та config'и, НЕ перебудовувати bridges.

---

### Task 1: Репозиторій, дизайн, інвентар, план ✅

**Files:** `README.md`, `docs/design-ip-clos.md`,
`docs/plans/2026-11-12-pve-clos-deploy.md`, `inventory/fabric.yaml`

- [x] Крок: створено; approve не потрібен (local)
- [x] Варіант 2 busybox LXC (905/906) замість 1 Debian VM — внесено в дизайн/інвентар

---

### Task 2: PVE host — bridges + import образу

**Files (на PVE):**
- Create: `/etc/network/interfaces.d/br-c-s1l1a`, `br-c-s1l1b`, `br-c-s1l2a`,
  `br-c-s1l2b`, `br-c-s2l1a`, `br-c-s2l1b`, `br-c-s2l2a`, `br-c-s2l2b`,
  `br-c-l1srv`, `br-c-l2srv` (10 stanza-файлів)
- Create: `/var/lib/vz/upload/sonic-vs.img.gz` (upload) → розпакувати →
  `qm importdisk` на `local-lvm`

**Approve:** ПОВИНЕН (крок 0 KSM — уже approved і done)

- [x] **Step 0 (KSM, done 2026-11-12):** PVE 9.2 не має вбудованого ksm-юніта →
      створено новий `/etc/systemd/system/ksm.service` (oneshot, `run=1`),
      `enable --now`. **CORRECTION 2026-11-13:** `run` скидав в 0 кожні 60с —
      причина: демон `ksmtuned` (встановлений разом з PVE) вимикає KSM, коли
      вільна пам'ять понад threshold. `systemctl stop+mask ksmtuned` (approve A),
      `ksm.service` тепер утримує `run=1`. Verify: `run=1` після 75с, `ksmtuned` masked.

- [x] **Step 1:** ID 901-906 вільні; local-lvm ≥ 30 GB free — підтверджено.
- [x] **Step 2:** 10 bridge-файлів створені, UP.
- [x] **Step 3:** Upload + gunzip (sonic-vs.img ≈4 GB).
- [x] **Step 4:** `qm create 901` + import на local-lvm; 902-904 = full clone.
- [x] **Step 5:** upload-файл видалений після import.
- [ ] **Rollback:** `qm destroy 901 --purge`, `rm /etc/network/interfaces.d/br-c-*`,
      `rm -rf /var/lib/vz/upload/sonic-vs*`.

---

### Task 3: Підняти 4 SONiC VM, зафіксувати mgmt IP / версію / port map

**Files:** `inventory/fabric.yaml` (оновлення), `runbooks/03-first-boot.md`

**Approve:** ПОВИНЕН (qm create/clone/set/start)

- [x] **Step 1:** qm set/clone 901→902/903/904, net1..N за інвентарем.
- [x] **Step 2:** 4 VM running; mgmt IP (DHCP) зафіксовані в `inventory/fabric.yaml`:
      901=192.168.1.247, 902=192.168.1.82, 903=192.168.1.199, 904=192.168.1.145.
      SSH key-auth з PVE (`/root/.ssh/id_rsa.pub` в `/home/admin/.ssh/authorized_keys`).
- [x] **Step 3:** Версія `master.1273518-6f800f3d4`; port map: qm netN →
      Ethernet{4*(N-1)} (net1→Ethernet0 ... net5→Ethernet16), eth0=mgmt.
- [x] **Step 4:** RAM-контроль: available ≥ 2.2 GB після 4 VM (див. verification).
- [ ] **Verification:** 4 VM running; 4 mgmt IP по SSH; версія + port map
      зафіксовані.

---

### Task 4: Конфігурація fabric (BGP underlay + ECMP)

**Files:** `configs/sonic-{spine1,spine2,leaf1,leaf2}/config_db.json`,
`runbooks/04-fabric-config.md`

**Approve:** ПОВИНЕН (config load/save + reboot на 4 VM) — APPROVED (Tasks 2–5 scope)

- [x] **Step 0 (ECMP base, done 2026-11-13):** `maximum-paths` не рендериться в
      running-config, бо `constants.yml` має `ipv4/ipv6: 514`, а FRR відхиляє 514
      (help показує 1-514, runtime-ліміт нижчий; `maximum-paths 2` приймається).
      Фікс: `sed 514→2` в `/etc/sonic/constants.yml` на всіх 4 VM + `docker
      restart bgp` (docker_init.sh перерендерить `/etc/frr/bgpd.conf`). Verify:
      `vtysh -c "show running-config" | grep maximum-paths` → `maximum-paths 2` (v4+v6).
      Персистентність: файл на host rootfs VM; переживає reboot та docker restart.
- [x] **Step 1:** Схема BGP визначена (див. Review Focus #5): без `BGP_GLOBALS`;
      advertise = `STATIC_ROUTE` (bgpcfgd auto-redistribute, ROUTE_ADVERTISE_ENABLE_TAG=1);
      `config route add` в CLI не підтримує blackhole → тільки config_db.
- [x] **Step 2:** 4 `config_db.json` згенеровані `scripts/gen_config_db.py`
      (hostname/type/bgp_asn в DEVICE_METADATA, LOOPBACK, INTERFACE — лише used
      ports, BGP_NEIGHBOR 4/each (hold 90/keep 30), STATIC_ROUTE; PORT/FLEX_COUNTER/
      DEVICE_NEIGHBOR без змін).
- [x] **Step 3:** Apply на 901: backup `.bak`, `config load -y`, `config save -y`,
      reboot (2026-11-13 ~08:17 UTC).
- [x] **Step 4:** Apply на 902-904 (parallel, reboot ~08:19 UTC).
- [x] **Step 5: Verification (2026-11-17, PASSED):**
      - `show ip bgp summary`: 2/2 Established на кожному (8/8 на fabric);
      - leaf1: `10.1.0.4` → 2 next-hop (10.0.1.0/eth1 + 10.0.5.0/eth3) — ECMP;
        leaf2: `10.1.0.3` → 2 next-hop — ECMP;
      - ping: srv1↔srv2, leaf1↔leaf2, srv→spine, spine→leaf/srv — 0% loss;
      - spine1↔spine2 Lo0 — **недосяжно by design** (оцінока плану перевищила
        реалістичні очікування: немає spine–spine линку, leaves не
        ре-анонсують eBGP Lo0-рути).
- [ ] **Rollback:** `config load -y /etc/sonic/config_db.json.bak` + reboot.

---

### Task 5: Два busybox LXC-сервера + end-to-end ✅ (2026-11-15)

**Files:** `scripts/create-lxc-servers.sh` (реалізація), `inventory/fabric.yaml`
(status), `docs/design-ip-clos.md` (evidence + PVE quirks)

**Approve:** ПОВИНЕН (pct create, запуск CT, конфіг мережі всередині CT) — APPROVED (Tasks 2–5 scope)

> ⚠️ Bridge-назви в оригінальному Step 2 **STALE** (pre-swap). Фактичне
> мапування: 905 lab-srv1 → `br-c-l2srv`; 906 lab-srv2 → `br-c-l1srv`.

- [x] **Step 1:** Build minimal busybox rootfs template на PVE (скриптом):
      dynamic busybox + libs (`libc.so.6`, `libresolv.so.2`) + `ld-linux-x86-64.so.2`;
      `sbin/init` → **абсолютний** `/bin/busybox`; `etc/init.d/rcS` **idempotent**
      (flush addrs/route перед re-apply; per-CT галужка за `/etc/hostname`);
      `tar czf /var/lib/vz/template/ct-busybox.tar.gz` (~1.5 MB).
- [x] **Step 2:** `pct create 905 <tpl> --ostype unmanaged --memory 256 --cores 1
      --hostname lab-srv1 --nameserver 192.168.1.1 --rootfs local-lvm:1
      --net0 name=eth0,bridge=br-c-l2srv`; `pct create 906 ... --hostname lab-srv2
      --net0 ... bridge=br-c-l1srv`. `pct start`. Після старту — set
      `/etc/hostname` (PVE НЕ пише його для unmanaged) + re-run idempotent rcS.
      **Без `--name`** (такого top-level параметра немає — див. PVE quirks).
- [x] **Step 3:** Мережа всередині CT — в rcS (за hostname):
      - 905: lo `10.1.0.99/32`; eth0 `10.0.9.1/31`; default via `10.0.9.0`.
      - 906: lo `10.1.0.100/32`; eth0 `10.0.10.1/31`; default via `10.0.10.0`.
- [x] **Step 4:** **Verification** (CT-side `pct exec <id> -- ping` + reverse):
      - 905 → leaf1 (10.1.0.3) OK; 905 → own lo (10.1.0.99) OK; 905 → spine1 OK.
      - 906 → leaf2 (10.1.0.4) OK; 906 → own lo (10.1.0.100) OK.
      - Reverse: leaf1 → 10.0.9.1 (srv1) OK; spine1 → 10.1.0.99 (srv1 Lo0) OK;
        на spine1 BGP-рути до обох srv Lo0 (.99/.100) присутні.
      - **Known FAIL (out of scope):** 905 → spine2; 906 → spine1/spine2;
        cross-leaf (srv1↔srv2, leaf1↔leaf2) — incomplete underlay
        (Task 4 Step 5 / inter-leaf блокер). Довідка: `docs/design-ip-clos.md`
        «Поточний стан» (таблиця «LXC end-to-end»).
- [x] **Reproducibility:** destroy 905/906 + re-run скрипта → обидва CT
      перестворені коректно (906 = `lab-srv2`, а не дефолт template `lab-srv1`).
      Верифіковано 2026-11-15.
- [ ] **Fallback:** не потрібен (busybox CT стартує стійко). Якщо — minimal Debian
      rootfs через `debootstrap` (~100 MB, ifupdown) — окремий крок/approve.
- [ ] **Rollback:** `pct destroy 905 906 --purge`, `rm /var/lib/vz/template/ct-busybox.tar.gz`.

> **PVE 9 LXC quirks (виявлено):** `pct create` без `--name`; unmanaged template
> → PVE НЕ пише `/etc/hostname`; `pct exec` потребує `--` для dash-аргументів;
> `sbin/init` — абсолютний symlink. Деталі: `docs/design-ip-clos.md` «PVE 9 LXC quirks».

---

### Task 6: Документація + wrap-up ✅ (2026-11-17)

- [x] `runbooks/00-destroy.md` — повний teardown (VM 901-904, CT 905/906,
      bridges, upload, template).
- [x] `runbooks/01-restore.md` — відтворення fabric з нуля.
- [x] Оновити `README.md` (статус) та `inventory/fabric.yaml`.
- [x] Verification-звіти Task 4/5 → `docs/verification-2026-11-17.md`.
