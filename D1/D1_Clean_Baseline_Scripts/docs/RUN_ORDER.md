# Порядок развёртывания чистой базовой конфигурации D1

## 1. Сетевые устройства Cisco

Вставьте или импортируйте конфигурации в следующем порядке:

1. `Internet_clean_baseline.ios`
2. `MPLS_clean_baseline.ios`
3. `DC1_clean_baseline.ios`
4. `DC2_clean_baseline.ios`
5. `DC-GW_clean_baseline.ios`
6. `Switch_clean_baseline.ios`
7. `HQ-GW1_clean_baseline.ios`
8. `HQ-GW2_clean_baseline.ios`
9. `HQ-SW_clean_baseline.ios`
10. `HQ-SW-D_clean_baseline.ios`
11. `HQ-R_clean_baseline.ios`

После применения сетевых конфигураций проверьте соседей OSPF и таблицы маршрутизации, прежде чем настраивать серверы.

## 2. Узлы Windows

Запустите PowerShell от имени администратора:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\00_D1_common_windows_prepare.ps1 -NodeName HQ-AD01
# Если имя компьютера было изменено, перезагрузите его, затем выполните:
.\10_HQ-AD01_prepare_ad_dns_dhcp.ps1
```

Затем подготовьте остальные узлы Windows:

```powershell
.\00_D1_common_windows_prepare.ps1 -NodeName HQ-FILE01
.\20_HQ-FILE01_prepare_file_iis.ps1

.\00_D1_common_windows_prepare.ps1 -NodeName HQ-WS01
.\30_HQ-WS01_prepare_client.ps1

.\00_D1_common_windows_prepare.ps1 -NodeName DC-Win01
.\40_DC-Win01_prepare_app.ps1
```

## 3. Узлы Debian

Выполните на каждом узле Debian от имени root:

```bash
./00_d1_linux_common_prepare.sh DC-LNX01
./10_DC-LNX01_prepare_web_portal.sh
```

Для каждого узла используйте скрипт, соответствующий его имени и роли:

- `DC-LNX01` → веб-портал;
- `DC-LNX02` → резервный DNS/справочные зоны;
- `DC-SVC01` → служба системного журнала/мониторинга;
- `DC-CL01` → клиентские инструменты Debian;
- `HQ-LNX01` → агент резервного копирования/мониторинга.

## 4. Проверка

Запустите:

- Cisco: команды из `validation/validate_cisco_clean_baseline.txt`;
- Linux: `validation/validate_linux_clean_baseline.sh`;
- Windows: `validation/validate_windows_clean_baseline.ps1`.
