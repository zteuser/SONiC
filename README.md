# sonic — IP CLOS fabric on SONiC

Лабораторний IP CLOS (2 spines + 2 leaves + 2 LXC-сервера) на SONiC, розгорнутий
у Proxmox VE. Сервери — мінімальні busybox LXC-контейнери (PVE CT), по одному
за кожним leaf.

## Компоненти

| ID | Назва | Роль | OS | Тип | vCPU | RAM |
|----|-------|------|-----|-----|------|-----|
| 901 | sonic-spine1 | spine | SONiC vs | VM | 2 | 2 GB |
| 902 | sonic-spine2 | spine | SONiC vs | VM | 2 | 2 GB |
| 903 | sonic-leaf1 | leaf | SONiC vs | VM | 2 | 2 GB |
| 904 | sonic-leaf2 | leaf | SONiC vs | VM | 2 | 2 GB |
| 905 | lab-srv1 | server | busybox | LXC | 1 | 256 MB |
| 906 | lab-srv2 | server | busybox | LXC | 1 | 256 MB |

- PVE node: `192.168.1.19` (PVE 9.2, 12 CPU / 11 GB RAM, storage `local-lvm`)
- Management: SONiC VM — DHCP на `vmbr0`; LXC — керування через `pct exec`/console
  (без mgmt NIC)
- Data plane: P2P Linux bridges на хості PVE (`br-c-*`): 4 активні fabric
  линки (1 на spine–leaf пару) + 2 server линки; ECMP x2 на рівні leaf
  (2 spines)

> **PRAVILLO:** оперувати за оперативною роллю + mgmt IP, НЕ за PVE name/VMID.
> PVE 903 ("sonic-leaf1") = operationally **leaf2** (145); PVE 904
> ("sonic-leaf2") = operationally **leaf1** (199) — **names swapped** (див.
> `inventory/fabric.yaml`).

## RAM бюджет (вуз 11.3 GB + 8 GB swap)

- 4 × 2 GB (SONiC) = 8 GB
- 2 × 256 MB (LXC) = 0.5 GB
- host ≈ 1 GB, CT 100 ≤ 1 GB → **сумарно ≈ 10.5 GB** (перевірено 2026-11-12).
  Fallback: SONiC → 1.5 GB (сумарно ≈ 8.5 GB).

## Структура репозиторію

```
sonic/
├── sonic-vs.img.gz              # образ SONiC vs (source)
├── README.md
├── docs/
│   ├── design-ip-clos.md
│   └── plans/2026-11-12-pve-clos-deploy.md
├── inventory/
│   └── fabric.yaml
├── configs/                     # config_db.json + fabric-vnet.sh на пристрій
├── scripts/                     # gen_config_db.py, create-lxc-servers.sh
└── runbooks/                    # покрокові runbook'и
```

## Стан (2026-11-17)

- [x] Дизайн та план
- [x] PVE host: bridges + VM provision (4 VM up)
- [x] LXC сервери 905/906 (busybox) — створені та верифіковані (Task 5);
  скрипт: `scripts/create-lxc-servers.sh`
- [x] SONiC fabric: BGP underlay — **8/8 Established**; **inter-leaf +
  srv1↔srv2 + ECMP x2 верифіковано** (root-причини попереднього FAIL: AFI +
  zebra FIB-hang — фіксовано; AS re-plan: leaves 65003/65004; див.
  `docs/design-ip-clos.md` «Поточний стан»)

Документація: `docs/design-ip-clos.md`, `docs/running-configs.md`,
`docs/verification-2026-11-17.md`, план: `docs/plans/2026-11-12-pve-clos-deploy.md`,
runbook'и: `runbooks/00-destroy.md`, `runbooks/01-restore.md`.
