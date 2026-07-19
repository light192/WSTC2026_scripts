# Проверка эталонного решения

Команды выполняются до запуска автоматического checker. Любой временный
`shutdown` в failover-тестах необходимо вернуть командой `no shutdown`.

## Общая проверка на всех 15 Cisco

```text
show ip interface brief
show interfaces description
show hosts
show clock detail
show ip ssh
show ntp associations
show ntp status
show logging
show snmp user c2snmp
show startup-config | include hostname
```

Ожидаются правильные адреса/up-up, domain `camp-c2.local`, ALMT UTC+5, SSHv2,
NTP peer `10.81.130.10`, Syslog `10.81.130.10 warnings`, SNMP authPriv.

## HQ Layer 2

На DS1/DS2/AS1/AS2:

```text
show vlan brief
show interfaces trunk
show spanning-tree mst configuration
show ip dhcp snooping
show ip arp inspection
```

Дополнительно на DS1/DS2:

```text
show etherchannel summary
show lacp neighbor
show spanning-tree mst 1
show spanning-tree mst 2
```

Po12 должен быть `SU`, G1/0 и G1/1 — `(P)`. MST1 root DS1, MST2 root DS2.
На DS3/DS4 MST3 root DS3, secondary DS4.

## HSRP

```text
show standby brief
show track
```

- DS1 Active VLAN10/50 priority 120; DS2 Active VLAN40 priority 120.
- DS3 Active VLAN130/150 priority 120.
- HQ каждый uplink снижает priority на 15; DC uplink — на 30.

## OSPF

```text
show ip ospf neighbor
show ip ospf interface brief
show ip ospf database summary
show ip ospf database external 0.0.0.0
show ip route ospf
```

Все routed links P2P. HQ summary `10.80.0.0/16`, DC summary `10.81.0.0/16`.
Area20 totally stub: DS3/DS4 не имеют external LSA и получают default от IR3.
В HQ default LSA IR1 metric 10, IR2 metric 100.

## BGP и отсутствие утечек

На IR1/IR2/IR3/BR1/BR2:

```text
show bgp ipv4 unicast summary
show bgp ipv4 unicast
show ip route bgp
show ip route static
```

Все peers Established, timers 10/30. На ISP1 допустимы только:

- AS65220: `10.80.0.0/16`, `198.51.100.80/29`;
- AS65230: `10.81.0.0/16`, `198.51.100.88/29`;
- AS65241: `10.82.0.0/16`;
- AS65242: `10.83.0.0/16`.

Loopback /32, VLAN /24 и routed /30 на ISP1 отсутствуют.

## NAT

После трафика из `hosts/PC1-PC4.txt`:

```text
show ip nat translations
show ip nat statistics
show ip flow export
```

- IR1 HQ PAT — `198.51.100.81`; после IR1 WAN failure IR2 — `.82`.
- BR1/BR2 PAT используют WAN interface `.14`/`.18`.
- IR3 static TCP/80 mapping `10.81.130.10:80` ↔ `198.51.100.89:80`.
- Межсайтовые private-to-private flows не должны переводиться NAT.

## Контролируемые отказы

1. Shutdown одного G1/0 или G1/1 в Po12: Po12 остается up, ping теряет не более
   двух пакетов; затем `no shutdown` и оба member возвращаются `(P)`.
2. Shutdown одного routed uplink активного DS: HSRP Active не меняется.
3. Shutdown обоих uplink активного DS: второй DS становится Active.
4. Shutdown IR1 G0/3: BGP default IR1 и OSPF default metric 10 исчезают, новые
   HQ Internet-сессии создают PAT `.82` на IR2. Затем вернуть IR1 G0/3.

В конце повторить health commands и выполнить:

```powershell
python .\c2_check_ios.py
```
