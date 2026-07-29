# Справочные DNS-записи D1

Основная зона DNS в AD: `corp.d1.skills` на `HQ-AD01`.
Резервные/справочные зоны DNS Linux на `DC-LNX02`: `dc.d1.skills`, `cloud.d1.skills`.

Минимальный набор записей:

```text
hq-ad01.corp.d1.skills     A 10.19.20.10
hq-file01.corp.d1.skills   A 10.19.20.20
hq-lnx01.corp.d1.skills    A 10.19.20.30
hq-ws01.corp.d1.skills     A 10.19.10.11
files.corp.d1.skills       CNAME hq-file01.corp.d1.skills.

dc-lnx01.dc.d1.skills      A 10.19.110.11
portal.dc.d1.skills        CNAME dc-lnx01.dc.d1.skills.
dc-lnx02.dc.d1.skills      A 10.19.110.12
dc-win01.dc.d1.skills      A 10.19.110.21
dc-svc01.dc.d1.skills      A 10.19.110.31
dc-cl01.dc.d1.skills       A 10.19.120.11

cloud-service.cloud.d1.skills A 10.19.210.1
cloud-backup.cloud.d1.skills  A 10.19.220.1
```
