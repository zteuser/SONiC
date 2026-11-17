# Runbook 01 — Restore (відтворення fabric з нуля)

Мета: відтворити лабораторний IP CLOS на PVE `192.168.1.19` з нуля
(після `00-destroy` або на чистому хості) виключно з артефактів репозиторію
`sonic/`: `sonic-vs.img.gz`, `configs/sonic-*/config_db.json`,
`configs/sonic-*/fabric-vnet.sh`, `scripts/create-lxc-servers.sh`,
`inventory/fabric.yaml`.

> **ПРАВИЛО (skill `remote-host-config-approve`):** кожен крок 2–9 — **write
> на PVE/VM/CT**, виконується **тільки після явного approve** користувача.
> Крок 1 (read-only перевірки) — без approve.

## Мапування ID → ролі → конфіг (source of truth: `inventory/fabric.yaml`)

| PVE ID | Роль | conf-каталог (repo) | Mgmt (DHCP, фактичний 2026-11) |
|--------|------|---------------------|--------------------------------|
| 901 | spine1 | `configs/sonic-spine1/` | 192.168.1.247 |
| 902 | spine2 | `configs/sonic-spine2/` | 192.168.1.82 |
| 903 | **leaf2** | `configs/sonic-leaf2/` | 192.168.1.145 |
| 904 | **leaf1** | `configs/sonic-leaf1/` | 192.168.1.199 |
| 905 | srv1 (LXC) | — (rcS в template) | — (`pct exec`) |
| 906 | srv2 (LXC) | — (rcS в template) | — (`pct exec`) |

> ⚠️ **Swap лишається історичним і зберігається навмисно:** PVE 903 =
> leaf2, PVE 904 = leaf1 (bridge-мапування та `config_db.json` прив'язані до
> саме такого розподілу). При відтворенні **НЕ переіменовувати** VM —
> просто застосувати конфіг за таблицею вище.

## Крок 1 — Read-only перевірки (без approve)

```bash
# ID 901-906 вільні
qm list | grep -E '^ (90[1-6]) '          # → порожньо
pct list | grep -E '^ (90[56]) '          # → порожньо
# Resource-бюджет: RAM total ≥ 11 GB, MemAvailable ≥ ~4 GB ДО старту workload,
# local-lvm free ≥ 30 GB
free -g; df -h | grep local
# vmbr0 UP + без br-c-*
ip -br link show vmbr0
ls /etc/network/interfaces.d/ | grep br-c- || echo "no br-c-* (OK)"
# KSM (якщо хост не переformat'ований — має бути enabled)
systemctl is-active ksm.service; cat /sys/kernel/mm/ksm/run
# SSH на PVE: key-auth root
ssh root@192.168.1.19 uname -a
```

Якщо `ksm.service` відсутня (хост чистий) — відновити за рецептом
Task 2 Step 0 плану (`/etc/systemd/system/ksm.service`, oneshot `run=1`,
`enable --now` + `systemctl stop+mask ksmtuned`).

## Крок 2 — Bridges (write): 10 stanza-файлів

На PVE: `/etc/network/interfaces.d/br-c-<id>` для
`s1l1a s1l1b s1l2a s1l2b s2l1a s2l1b s2l2a s2l2b l1srv l2srv`.

Формат stanza (приклад `br-c-s1l2a`):

```
auto br-c-s1l2a
iface br-c-s1l2a inet manual
    bridge_hwtype ether
    bridge_fd 0
    bridge_stp off
    bridge_ports none
```

```bash
systemctl restart networking
ip -br link show 'br-c-*'        # всі 10 UP (state UP)
```

> `br-c-*b` (s1l1b/s1l2b/s2l1b/s2l2b) — інертні (без IP), створюються
> разом для симетрії з порт-мапом; IP на них НЕ задається.

## Крок 3 — Образ + VM 901–904 (write)

```bash
# 3.1 Upload образу (з репозиторію; ~gz) на PVE
#     локально: sonic/sonic-vs.img.gz
scp sonic-vs.img.gz root@192.168.1.19:/var/lib/vz/upload/

# на PVE:
cd /var/lib/vz/upload
gunzip -f sonic-vs.img.gz              # → sonic-vs.img (~4 GB)

# 3.2 Базова VM 901 (spine1) + import диска
qm create 901 --name sonic-spine1 --memory 2048 --cores 2 \
  --net0 bridge=vmbr0
qm importdisk 901 /var/lib/vz/upload/sonic-vs.img local-lvm --format raw
qm set 901 --scsi0 local-lvm:vm-901-disk-0

# 3.3 NIC-мапування 901 (spine1): net1..net4
qm set 901 --net1 bridge=br-c-s1l1a --net2 bridge=br-c-s1l1b \
           --net3 bridge=br-c-s1l2a --net4 bridge=br-c-s1l2b

# 3.4 Full-clone 902-904 (disk copy; OVMF відсутні → SeaBIOS, дефолт)
qm clone 901 902 --full --name sonic-spine2
qm clone 901 903 --full --name sonic-leaf1
qm clone 901 904 --full --name sonic-leaf2

# 3.5 NIC-мапування clone'ів (net0 vmbr0 залишається)
#     902 spine2:
qm set 902 --net1 bridge=br-c-s2l1a --net2 bridge=br-c-s2l1b \
           --net3 bridge=br-c-s2l2a --net4 bridge=br-c-s2l2b
#     903 leaf2 (PVE name sonic-leaf1 — SWAP, не чіпати):
qm set 903 --net1 bridge=br-c-s1l1a --net2 bridge=br-c-s1l1b \
           --net3 bridge=br-c-s2l1a --net4 bridge=br-c-s2l1b \
           --net5 bridge=br-c-l1srv
#     904 leaf1 (PVE name sonic-leaf2 — SWAP, не чіпати):
qm set 904 --net1 bridge=br-c-s1l2a --net2 bridge=br-c-s1l2b \
           --net3 bridge=br-c-s2l2a --net4 bridge=br-c-s2l2b \
           --net5 bridge=br-c-l2srv

# 3.6 Upload прибрати (disk уже в local-lvm)
rm -f /var/lib/vz/upload/sonic-vs.img*

qm start 901 902 903 904
```

Verification (read-only): `qm status 901..904` = running;
`free -g` — MemAvailable ≥ ~2 GB.

## Крок 4 — SSH + ECMP-база (write, на кожній з 4 VM)

```bash
# 4.1 mgmt IP = DHCP (192.168.1.0/24). Зафіксувати фактичні IP і
#     оновити inventory/fabric.yaml (mgmt_ip), якщо відрізняються.
#     (fabric-конфіг від mgmt IP не залежить; лише зручність SSH.)

# 4.2 SSH key-auth з PVE → admin (SONiC user: admin, key-auth)
#     з PVE:
scp /root/.ssh/id_rsa.pub admin@<vm-mgmt-ip>:/home/admin/.ssh/authorized_keys
#     на VM: chmod 700 /home/admin/.ssh; chmod 600 authorized_keys

# 4.3 ECMP-база (Task 4 Step 0): constants.yml 514→2 + ре-рендер bgpd.conf
sudo sed -i 's/ipv4: 514/ipv4: 2/; s/ipv6: 514/ipv6: 2/' /etc/sonic/constants.yml
sudo docker restart bgp
sudo vtysh -c "show running-config" | grep maximum-paths
#     → maximum-paths 2 (ipv4 + ipv6)
```

## Крок 5 — Конфігурація fabric (write, на кожній з 4 VM)

```bash
# Для кожного пристрою X ∈ {spine1, spine2, leaf1, leaf2} (за таблицею кроку 1):
#   scp configs/sonic-X/config_db.json  → admin@<vm>:/tmp/config_db.json
#   scp configs/sonic-X/fabric-vnet.sh  → admin@<vm>:/tmp/fabric-vnet.sh

# на VM:
sudo cp /etc/sonic/config_db.json /etc/sonic/config_db.json.bak   # backup перед першим load
sudo config load -y /tmp/config_db.json
sudo config save -y
sudo reboot
# після boot:
sudo cp /tmp/fabric-vnet.sh /usr/local/lib/fabric-vnet.sh
sudo chmod 755 /usr/local/lib/fabric-vnet.sh
sudo /usr/local/lib/fabric-vnet.sh
```

> `fabric-vnet.sh` = oneshot: p2p IP → wait-loop BGP → vtysh (neighbor'и,
> per-neighbor `activate` в `address-family ipv4` — **AFI-fix**,
> `maximum-paths 2`, networks, `redistribute static` на leaves).
> Header скрипту документає AFI-pitfall (FRR 10.7.1: глобальний
> `bgp default ipv4-unicast` НЕ retro-активує peers).
> `config_db.json`: hostname/type/`bgp_asn` (65001/65001/65003/65004),
> LOOPBACK, p2p INTERFACE, `BGP_NEIGHBOR`, `STATIC_ROUTE`.

## Крок 6 — LXC 905/906 (write, на PVE)

```bash
# скрипт з репо: scripts/create-lxc-servers.sh
scp scripts/create-lxc-servers.sh root@192.168.1.19:/tmp/
ssh root@192.168.1.19 'bash /tmp/create-lxc-servers.sh'
```

Скрипт: будує busybox rootfs template
(`/var/lib/vz/template/ct-busybox.tar.gz`, ~1.5 MB) → `pct create 905/906`
(256 MB RAM, 1 core, `--ostype unmanaged`, net0 → `br-c-l2srv` /
`br-c-l1srv` відповідно) → idempotent `rcS` задає lo/p2p/gw за hostname.

PVE 9 quirks (зафіксовано): без `--name`; PVE не пише `/etc/hostname` для
unmanaged — скрипт ставить його після старту; `pct exec` потребує `--`.

## Крок 7 — Verification (read-only; матриця: `docs/verification-2026-11-17.md`)

```bash
# на кожній VM:
sudo vtysh -c "show ip bgp summary"          # 2/2 Established на кожному
# leaf1 (904): ECMP — 2 nexthops на 10.1.0.4:
ip -4 route show 10.1.0.4/32                 # 10.0.1.0/eth1 + 10.0.5.0/eth3
# leaf2 (903): ECMP — 2 nexthops на 10.1.0.3:
ip -4 route show 10.1.0.3/32                 # 10.0.3.0/eth1 + 10.0.7.0/eth3

# ping matrix (з PVE: pct exec ... -- ping; з VM: ping)
pct exec 905 -- ping -c2 10.1.0.100          # srv1 → srv2 (cross-leaf)
pct exec 906 -- ping -c2 10.1.0.99           # srv2 → srv1
pct exec 905 -- ping -c2 10.1.0.2            # srv1 → spine2
pct exec 906 -- ping -c2 10.1.0.1            # srv2 → spine1
# leaf↔leaf Lo0, leaf→spine, spine→srv Lo0 — з VM
```

**Очікуваний результат:** все 0% loss; **spine1↔spine2 Lo0 = FAIL by design**
(немає spine–spine линку; leaves не ре-анонсують eBGP Lo0) — НЕ баг.

**Pitfall (FIB-hang):** якщо зebra `show ip route <prefix>` →
`Status: Failed` (nexthops `r`) при наповненому BGP RIB →
`sudo docker restart bgp` + re-run `sudo /usr/local/lib/fabric-vnet.sh`.
Перевіряти kernel: `ip -4 route show <prefix>` (НЕ `grep bgp` — truncує
multipath; НЕ `ip route get` — завжди 1 nexthop).

## Крок 8 — Остаточна фіксація

- Оновити `inventory/fabric.yaml` (mgmt IP, статуси), якщо DHCP дав інші IP.
- Записати результат в `docs/verification-<date>.md` (копія шаблону
  2026-11-17).

## Помилки / відкати

| Симптом | Причина / дія |
|---------|---------------|
| VM не стартує (boot loop) | SeaBIOS (OVMF відсутні) — перевірити console; як fallback `apt install qemu-ovmf-pve-boot` (окремий approve) |
| Mgmt IP не отримано (DHCP) | Пул роутера 192.168.1.0/24 — перевірити leases; статичний mgmt = follow-up |
| CT не стартує (unmanaged) | Перевірити `sbin/init` symlink + rcS; fallback minimal Debian rootfs (окремий крок) |
| `config load` відхилений | Порівняти PORT table з інвентарем (32 entry, byte-identical) |
| BGP Idle / `% No BGP neighbors` | AFI — пере-застосувати `fabric-vnet.sh` (AFI-fix) |
| FIB `Status: Failed` | FIB-hang — п. «Pitfall» кроку 7 |

## Відкат partial (якщо restore не завершено)

`runbooks/00-destroy.md` — повне знищення (крок 2+). KSM при цьому НЕ
прибирається (окрема оптимізація хоста).
