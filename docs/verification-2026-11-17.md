# Verification-звіт — IP CLOS fabric (2026-11-17)

**Вердикт: PASSED.** Фабрика (4 SONiC VM + 2 busybox LXC) повністю
верифікована: BGP 8/8 Established, inter-leaf та srv1↔srv2 — 0% loss,
ECMP x2 на обох leaves. Відкритих блокерів НЕТ.

> **Lab-only.** Результати отримано в лабораторному PVE 192.168.1.19;
> жодна конфігурація не призначена для production.

## Склад і scope

- spine1 (901, AS 65001, 10.1.0.1), spine2 (902, AS 65001, 10.1.0.2)
- leaf1 (904, AS 65003, 10.1.0.3), leaf2 (903, AS 65004, 10.1.0.4)
  — PVE name/VMID переставлені, оперуємо за роллю + mgmt IP
  (192.168.1.199 / 192.168.1.145)
- srv1 (LXC 905, 10.1.0.99, через br-c-l2srv за leaf1)
- srv2 (LXC 906, 10.1.0.100, через br-c-l1srv за leaf2)

## 1. BGP state — 8/8 Established

| Нода | Peers | Стан | PfxRcd/peer | PfxSnt | RIB |
|------|-------|------|-------------|--------|-----|
| leaf1 (904) | 2 (spine1, spine2) | Established | 7 | 12 | 12 |
| leaf2 (903) | 2 (spine1, spine2) | Established | 7 | 12 | 12 |
| spine1 (901) | 2 (leaf1, leaf2) | Established | 5 | 11 | 11 |
| spine2 (902) | 2 (leaf1, leaf2) | Established | 5 | 11 | 11 |

## 2. Ping matrix — 0% loss

| Парa | Результат |
|------|-----------|
| srv1 ↔ srv2 (cross-leaf, через spines) | **OK, 0% loss** |
| srv1 → spine1, spine2 | OK |
| srv2 → spine1, spine2 | OK |
| leaf1 ↔ leaf2 (Lo0 cross-leaf) | OK |
| leaf1/leaf2 → spine1/spine2 (Lo0) | OK |
| spine1/spine2 → leaves, srv1/srv2 (Lo0) | OK |
| spine1 ↔ spine2 (Lo0) | **FAIL — by design** |

> **spine1↔spine2 Lo0 — очікуваний FAIL, не баг.** У fabric немає spine–spine
> линку (4 R2R линки: кожна spine ↔ кожен leaf), а leaves не ре-анонсують
> eBGP Lo0-рути спінів один одному (RFC 4271, eBGP). Задокументовано в
> `docs/design-ip-clos.md`.

## 3. ECMP x2 — верифіковано в kernel FIB

| Нода | Префікс | Nexthops (kernel) | Статус zebra |
|------|---------|-------------------|--------------|
| leaf1 (904) | `10.1.0.4/32` (spine2… leaf1→leaf2 Lo0) | 10.0.1.0/eth1 + 10.0.5.0/eth3 | Installed |
| leaf2 (903) | `10.1.0.3/32` | 10.0.3.0/eth1 + 10.0.7.0/eth3 | Installed |

- Зebra (`show ip route <prefix>`): nexthops зі статусом `*`,
  BGP RIB «2 available, both multipath».
- `maximum-paths 2` активний на всіх 4 VM (з `constants.yml`, sed 514→2 —
  Task 4 Step 0; переживає reboot та docker restart).
- **Метод верифікації:** `ip -4 route show <prefix>` (повний запис) або
  зebra `show ip route`. НЕ `ip -4 route | grep bgp` (truncує multipath
  continuation lines) і НЕ `ip route get` (завжди показує 1 nexthop).

## 4. Root-причини попереднього FAIL (зафіксовано 2026-11-17)

### (1) AFI не активовано на vtysh-neighbor'ах

- Render (`bgpcfgd`, standard template) містить `no bgp default ipv4-unicast`
  → створені через vtysh neighbor'и без AFI → `show ip bgp summary` давав
  `% No BGP neighbors found`, state Idle/Opens 0.
- Глобальний `bgp default ipv4-unicast` **НЕ** retro-активує existing peers
  (FRR 10.7.1, емпірично) → робочий фікс — per-neighbor `activate` під
  `address-family ipv4`.
- Закріплено в `configs/sonic-*/fabric-vnet.sh` (усі 4 ноди), header
  скрипту документає pitfall.

### (2) zebra FIB-hang (leaf2; раніше також spine2)

- Симптом: BGP RIB наповнений, зebra RIB `Status: Failed` (nexthops `r`
  замість `*`), kernel FIB = 0 BGP-маршрутів.
- Фікс: `sudo docker restart bgp` + re-run `/usr/local/lib/fabric-vnet.sh`
  → `Status: Installed`.
- **Можливий рецидив** на будь-якому ноді після (re)start контейнера bgp —
  перевірка: `sudo vtysh -c "show ip route <prefix>"` + `ip -4 route show <prefix>`.

## 5. Персистентність

- `config_db.json` — `config load/save -y` на всіх 4 VM; переживає reboot.
- `fabric-vnet.sh` — `/usr/local/lib/` на кожній VM; запуск після reboot
  потребує ручного виклику (не wired до boot у цьому lab).
- `constants.yml` sed 514→2 — host rootfs VM, переживає reboot.
- LXC 905/906 — `scripts/create-lxc-servers.sh` (idempotent rcS), перевірено
  2026-11-15 (destroy + re-run → CT перестворені коректно).

## 6. Residual / відкриті позиції

- spine1↔spine2 недосяжність — by design (п. 2), не чинити.
- FIB-hang рецидив — процедурний, п. 4(2) + runbook-підказка.
- Mgmt IP VM — DHCP (можуть змінитися після reboot/reimage); fabric-конфіг
  від них не залежить.
- Жодних відкритих блокерів.
