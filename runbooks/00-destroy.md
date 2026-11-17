# Runbook 00 — Teardown (повне знищення fabric)

Мета: повністю прибрати лабораторний IP CLOS з PVE хоста `192.168.1.19`
(VM 901–904, CT 905/906, bridges `br-c-*`, upload/artifacts). Репозиторій
`sonic/` лишається незмінним — він джерело відтворення (див. `01-restore`).

> **ПРАВИЛО (skill `remote-host-config-approve`):** будь-яка команда з цього
> runbook — **write на PVE**, виконується **тільки після явного approve**
> користувача. Read-only перевірки (крок 1) — без approve.

**Обсяг:** тільки VM 901–904 / CT 905–906 / bridges `br-c-*` / upload /
busybox-template. **НЕ чіпати:** VM 101, CT 100, `vmbr0`, KSM (див. крок 6).

## Передумови

- SSH на PVE: `ssh root@192.168.1.19` (key-auth).
- ID 901–904 = SONiC VM, 905–906 = busybox LXC (статус «не створені» чи
  «створені» не має значення — `--purge` прибирає що існує).

## Крок 1 — Read-only фіксація стану (без approve)

```bash
qm list | grep -E '^ (90[1-6]) '     # які з 901-906 існують
pct list | grep -E '^ (90[56]) '     # LXC (якщо створені)
ls /etc/network/interfaces.d/        # br-c-* stanza files
ls /var/lib/vz/upload/ 2>/dev/null   # sonic-vs* upload (має бути порожньо)
ls /var/lib/vz/template/ | grep -i busybox
free -g                              # RAM ДО (для порівняння після)
```

Зафіксувати вивід (сcreenshot/лог) — це evidence для замітки в `docs/`.

## Крок 2 — Зупинити workload (write)

```bash
pct stop 905 906 2>/dev/null         # LXC, якщо створені
qm  stop 901 902 903 904             # SONiC VM
qm  status 901 902 903 904           # очікувано: stopped / unknown (якщо вже немає)
```

> Порядок важливий: **спочатку workload, потім destroy, потім bridges**.
> Якщо VM не стартували/не мали traffic — bridges все одно прибираються
> після destroy (крок 4).

## Крок 3 — Destroy CT та VM (write, незворотно)

```bash
pct destroy 905 906 --purge 2>/dev/null   # LXC (якщо створені)
qm  destroy 901 902 903 904 --purge       # VM + диски на local-lvm
```

`--purge` = видаляє conf + диски з `local-lvm`. Повернути дані після цього
неможливо. (Розпакований `sonic-vs.img` теж є в `local-lvm` і прибирається
разом з VM — окремих img-файлів на host немає.)

## Крок 4 — Прибрати bridge stanza-файли + restart networking (write)

```bash
rm -f /etc/network/interfaces.d/br-c-*   # 10 файлів: s1l1a/s1l1b/s1l2a/s1l2b/
                                          # s2l1a/s2l1b/s2l2a/s2l2b/l1srv/l2srv
systemctl restart networking
```

Патерн `br-c-*` в цьому каталозі — тільки наші bridges; `vmbr0` стоїть в
головному `/etc/network/interfaces` і **не чіпається**.

## Крок 5 — Остаточні artifacts (write, якщо існують)

```bash
rm -f  /var/lib/vz/upload/sonic-vs*              # upload (зазвичай вже видалений, Task 2 Step 5)
rm -f  /var/lib/vz/template/ct-busybox.tar.gz    # busybox template (якщо Task 5 не стартував — не існує)
rm -rf /tmp/bbx                                  # тимчасовий busybox rootfs (якщо Task 5 Step 1 не завершився)
```

## Крок 6 — KSM: **НЕ видаляти** (за замовчуванням)

`/etc/systemd/system/ksm.service` + masked `ksmtuned` — загальна оптимізація
PVE (корисна для будь-яких VM/CT на хості), а не частині fabric. **Дефолт —
лишити як є.**

Повне rollback KSM — тільки за окремим явним запитом:

```bash
systemctl disable --now ksm.service
rm /etc/systemd/system/ksm.service
systemctl unmask ksmtuned && systemctl start ksmtuned
```

## Verification (read-only)

```bash
qm  list | grep -E '^ (90[1-6]) '    # → порожньо
pct  list | grep -E '^ (90[56]) '    # → порожньо
ip -br link show 'br-c-*' 2>/dev/null # → порожньо (bridges зникли)
ls /etc/network/interfaces.d/        # → без br-c-*
free -g                              # → MemAvailable знову ~+8 GB (4×2 GB VM)
qm list; pct list                    # → 100 (CT) та 101 (VM) лишились без змін
```

## Помилки / відкати

| Симптом | Причина / дія |
|---------|---------------|
| `qm destroy` — "VM already destroyed" | Уже не існує — пропустити |
| `pct stop` — "not found" | CT не створювались — пропустити |
| Bridges лишились після restart | `brctl show`; вручну `brctl delbr br-c-<id>` + ще один `systemctl restart networking` |
| Потрібен rollback **до** destroy | Немає — крок 3 незворотний. Approve = свідомий вибір |

## Що лишається після teardown

- Репозиторій `sonic/` — повний (configs, inventory, docs, runbooks) →
  відтворення: `runbooks/01-restore.md`.
- На PVE: `ksm.service` (enabled), `vmbr0`, VM 101, CT 100 — без змін.
- DHCP-пул `vmbr0` — leases VM'ів самі повертаються в пул, дій не треба.
