#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PNETLab IOS scorer for WSC2026 Training C2 (100 aspects, 25 points).

The checker deliberately uses operational/dedicated show commands and never
uses ``show running-config``.  Checks requiring Linux endpoints or disruptive
expert actions are reported as SKIP.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
import ipaddress
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "C1"))
from pnetlab_lib import login, logout, join_session, get_nodes  # noqa: E402
from checker_lib import (  # noqa: E402
    BLUE, CYAN, GREEN, NC, PURPLE, RED, YELLOW,
    IOSConsoleSession, build_node_console_map,
    format_ios_output, get_running_session_id_by_substring,
)

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

DEVICES = ["IR1","IR2","CR1","CR2","DS1","DS2","AS1","AS2","IR3","DS3","DS4","BR1","BR2","AS3","AS4"]
OSPF = ["IR1","IR2","CR1","CR2","DS1","DS2","IR3","DS3","DS4"]
SWITCHES = ["DS1","DS2","AS1","AS2","DS3","DS4","AS3","AS4"]
EDGES = ["IR1","IR2","IR3","BR1","BR2"]

ASPECT_DATA = """
A1|.15|Имена устройств соответствуют физической схеме
A2|.15|Domain name camp-c2.local и timezone ALMT UTC+5
A3|.25|Учетная запись admin privilege 15 и enable работают
A4|.2|SSH version 2 и RSA key не менее 2048 bit
A5|.15|На VTY разрешен только SSH
A6|.25|Loopback0 и management SVI адресованы и up/up
A7|.3|Routed links адресованы и работоспособны
A8|.15|L2-коммутаторы используют корректные default gateways
A9|.15|Рабочие интерфейсы имеют descriptions
A10|.25|Конфигурации сохранены
B1|.25|HQ VLAN созданы и правильно названы
B2|.15|DC VLAN созданы и правильно названы
B3|.15|Branch VLAN созданы по VLAN-плану
B4|.2|HQ VTP transparent, domain CAMP-C2
B5|.35|HQ trunks: native 999, allowed 10,40,50,999
B6|.2|DC trunk: native 999, allowed 130,150,999
B7|.2|Branch trunks настроены корректно
B8|.15|На статических trunks отключена DTP negotiation
B9|.35|Po12 собран из G1/0 и G1/1
B10|.2|LACP работает active/active
B11|.2|Po12 работает как требуемый trunk
B12|.35|HQ MST region/revision/VLAN mapping
B13|.25|MST1: DS1 root primary, DS2 secondary
B14|.25|MST2: DS2 root primary, DS1 secondary
B15|.25|DC MST3 и root roles
B16|.3|PortFast и BPDU Guard на endpoint access-портах
B17|.25|Port-security maximum 2 на PC-портах
B18|.25|Secure MAC learning и violation mode
B19|.3|Unused HQ ports в VLAN998 и shutdown
B20|.45|DHCP Snooping и trust-порты
B21|.4|Dynamic ARP Inspection
B22|.55|L2 resilience при отказе member Po12
C1|.3|HQ SVI адреса и up/up
C2|.3|HSRP groups и VIP
C3|.2|VLAN10 roles/priorities
C4|.2|VLAN40 roles/priorities
C5|.2|VLAN50 roles/priorities
C6|.1|HSRP preempt
C7|.3|DS1 tracking двух uplinks decrement 15
C8|.3|DS2 tracking двух uplinks decrement 15
C9|.3|Один отказ uplink не меняет Active
C10|.35|Два отказа uplink вызывают failover
C11|.3|DC SVI и HSRP
C12|.15|DC tracking и management continuity
D1|.3|OSPF process 20 и router-id
D2|.2|Passive-interface default
D3|.25|HQ adjacencies FULL
D4|.2|IR2-IR3 transit area 0
D5|.2|DC adjacencies FULL
D6|.25|HQ routed links area 0
D7|.2|HQ VLAN area 10
D8|.2|DC links/VLAN area 20
D9|.2|Routed links point-to-point
D10|.3|HQ summary 10.80.0.0/16
D11|.3|Area 20 totally stub
D12|.25|DC summary 10.81.0.0/16
D13|.3|IR1 conditional default metric 10
D14|.3|IR2 conditional default metric 100
D15|.2|Нет OSPF neighbors на VLAN
D16|.35|WAN IR1 failover на IR2
E1|.2|IR1-ISP1 eBGP Established
E2|.2|IR2-ISP1 eBGP Established
E3|.2|IR3-ISP1 eBGP Established
E4|.15|BR1-ISP1 eBGP Established
E5|.15|BR2-ISP1 eBGP Established
E6|.2|eBGP timers 10/30 и MD5
E7|.3|HQ/DC edges получают provider routes
E8|.25|Branches получают summaries/default
E9|.35|HQ анонсирует только разрешенные prefixes
E10|.25|DC анонсирует только разрешенные prefixes
E11|.25|Branches анонсируют только site summaries
E12|.5|Нет route leak; HQ WAN resilience
F1|.15|DHCP relay HQ VLAN10
F2|.15|DHCP relay HQ VLAN40
F3|.2|Branch DHCP relay
F4|.1|Нет локальных DHCP pools
F5|.2|PC1 DHCP parameters
F6|.2|PC2 DHCP parameters
F7|.15|PC3 DHCP parameters
F8|.15|PC4 DHCP parameters
F9|.25|Клиенты разрешают три DNS-имени
F10|.25|Cisco синхронизированы с SVR1 NTP
F11|.3|HQ PAT .81/.82
F12|.2|Branch PAT
F13|.35|Static NAT OPS-SRV .89
F14|.35|NAT exemption и HQ failover
G1|.3|VTY source policy
G2|.15|Telnet запрещен
G3|.3|PC2 разрешенный доступ
G4|.35|PC2 guest isolation
G5|.25|User inter-site/Internet connectivity
G6|.25|User SSH restriction
G7|.2|CDP endpoint off, infrastructure on
G8|.35|Syslog на SVR1
G9|.2|Syslog severity/timestamps
G10|.4|SNMPv3 authPriv
G11|.2|SNMP unauthorized source blocked
G12|.45|NetFlow export на SVR1
G13|.35|Acceptance matrix
G14|.25|Final health
""".strip()

@dataclass(frozen=True)
class Aspect:
    number: int
    id: str
    mark: float
    title: str

@dataclass
class Result:
    aspect: Aspect
    status: str
    score: float
    passed: int = 0
    total: int = 0
    details: str = ""

ASPECTS: list[Aspect] = []
for n, line in enumerate(ASPECT_DATA.splitlines(), 1):
    aid, mark, title = line.split("|", 2)
    ASPECTS.append(Aspect(n, aid, float(mark), title))
BY_ID = {a.id: a for a in ASPECTS}

LOOPBACKS = {"IR1":"10.255.80.1","IR2":"10.255.80.2","CR1":"10.255.80.11","CR2":"10.255.80.12","DS1":"10.255.80.21","DS2":"10.255.80.22","IR3":"10.255.81.1","DS3":"10.255.81.11","DS4":"10.255.81.12","BR1":"10.255.82.1","BR2":"10.255.83.1"}
MGMT = {"AS1":("Vlan50","10.80.50.21"),"AS2":("Vlan50","10.80.50.22"),"AS3":("Vlan150","10.82.50.21"),"AS4":("Vlan250","10.83.50.21")}
SVI = {"DS1":{10:"10.80.10.11",40:"10.80.40.11",50:"10.80.50.11"},"DS2":{10:"10.80.10.12",40:"10.80.40.12",50:"10.80.50.12"},"DS3":{130:"10.81.130.11",150:"10.81.150.11"},"DS4":{130:"10.81.130.12",150:"10.81.150.12"}}
ROUTED = {
 "IR1":{"GigabitEthernet0/0":"10.80.0.1","GigabitEthernet0/1":"10.80.0.5","GigabitEthernet0/2":"10.80.0.17","GigabitEthernet0/3":"203.0.113.2"},
 "IR2":{"GigabitEthernet0/1":"10.80.0.9","GigabitEthernet0/0":"10.80.0.13","GigabitEthernet0/2":"10.80.0.18","GigabitEthernet0/4":"203.0.113.6","GigabitEthernet0/5":"10.80.0.41"},
 "CR1":{"GigabitEthernet0/0":"10.80.0.2","GigabitEthernet0/3":"10.80.0.10","GigabitEthernet0/2":"10.80.0.21","GigabitEthernet0/1":"10.80.0.25","GigabitEthernet0/4":"10.80.0.29"},
 "CR2":{"GigabitEthernet0/3":"10.80.0.6","GigabitEthernet0/0":"10.80.0.14","GigabitEthernet0/2":"10.80.0.22","GigabitEthernet0/4":"10.80.0.33","GigabitEthernet0/1":"10.80.0.37"},
 "DS1":{"GigabitEthernet0/0":"10.80.0.26","GigabitEthernet0/3":"10.80.0.34"},"DS2":{"GigabitEthernet0/3":"10.80.0.30","GigabitEthernet0/0":"10.80.0.38"},
 "IR3":{"GigabitEthernet0/0":"10.81.0.1","GigabitEthernet0/1":"10.81.0.5","GigabitEthernet0/2":"10.80.0.42","GigabitEthernet0/3":"203.0.113.10"},
 "DS3":{"GigabitEthernet0/0":"10.81.0.2"},"DS4":{"GigabitEthernet0/0":"10.81.0.6"},
 "BR1":{"GigabitEthernet0/0":"203.0.113.14","GigabitEthernet0/1.110":"10.82.10.1","GigabitEthernet0/1.150":"10.82.50.1"},
 "BR2":{"GigabitEthernet0/0":"203.0.113.18","GigabitEthernet0/1.210":"10.83.10.1","GigabitEthernet0/1.250":"10.83.50.1"}}

class Scorer:
    def __init__(self, consoles, creds):
        self.consoles = consoles; self.creds = creds; self.sessions = {}; self.cache = {}; self.results = []
    def connect(self):
        for dev in ["ISP1"] + DEVICES:
            if dev not in self.consoles: continue
            host, port = self.consoles[dev]
            s = IOSConsoleSession(host, port, self.creds.get("enable_password"), dev,
                device_username=self.creds.get("device_username"), device_password=self.creds.get("device_password"))
            try: s.connect(); self.sessions[dev] = s
            except Exception as exc: print(f"{YELLOW}[!] {dev}: {exc}{NC}")
    def close(self):
        for s in self.sessions.values(): s.close()
    def cmd(self, dev, command):
        key=(dev,command)
        if key not in self.cache:
            if dev not in self.sessions: self.cache[key]=""
            else:
                raw=self.sessions[dev].exec(command)
                self.cache[key]=format_ios_output(raw,command)
            print(f"{BLUE}{dev}# {command}{NC}\n{self.cache[key] or '(пустой вывод)'}")
        return self.cache[key]
    def ratio(self, aid, tests, details=""):
        a=BY_ID[aid]; vals=[bool(x) for x in tests]; p=sum(vals); t=len(vals)
        status="PASS" if t and p==t else "PART" if p else "FAIL"
        self.results.append(Result(a,status,a.mark*p/t if t else 0,p,t,details))
    def skip(self, aid, why): self.results.append(Result(BY_ID[aid],"SKIP",0,details=why))
    @staticmethod
    def has_all(text,*parts): return all(re.search(p,text,re.I|re.M) for p in parts)
    @staticmethod
    def print_expected(aspect):
        print(f"{CYAN}Ожидаемый результат:{NC}")
        print(f"  {aspect.title}.")
        print(f"  Максимальный балл: {aspect.mark:.3f}")
    @staticmethod
    def print_result(result):
        color={"PASS":GREEN,"PART":PURPLE,"FAIL":RED,"SKIP":YELLOW}[result.status]
        fraction=f" ({result.passed}/{result.total})" if result.total else ""
        print(f"\n{CYAN}Результат аспекта:{NC}")
        print(
            f"{color}[{result.status}] {result.aspect.id} "
            f"{result.score:.3f}/{result.aspect.mark:.3f}{fraction} — "
            f"{result.aspect.title}{NC}"
        )
        if result.details:
            print(f"  {result.details}")
    def ip_ok(self, dev, iface, ip):
        out=self.cmd(dev,"show ip interface brief")
        short=iface.replace("GigabitEthernet","Gi").replace("Loopback","Lo")
        return bool(re.search(rf"^(?:{re.escape(iface)}|{re.escape(short)})\s+{re.escape(ip)}\s+\S+\s+\S+\s+up\s+up\s*$",out,re.I|re.M))
    @staticmethod
    def pause_after_aspect(aspect_id):
        try:
            input(f"{YELLOW}\nАспект {aspect_id} завершен. Нажмите Enter для следующего аспекта...{NC}")
        except EOFError:
            pass
    def run(self, start, pause=True):
        plan=[a for a in ASPECTS if a.number >= start]
        for index,a in enumerate(plan):
            print(f"\n{PURPLE}{'='*90}\n{a.number:03d} {a.id} — {a.title}\n{'='*90}{NC}")
            self.print_expected(a)
            result_count=len(self.results)
            try: self.check(a.id)
            except Exception as exc: self.results.append(Result(a,"FAIL",0,details=f"Ошибка checker: {exc}"))
            if len(self.results) == result_count:
                self.results.append(Result(a,"FAIL",0,details="Проверка не сформировала результат"))
            self.print_result(self.results[-1])
            if pause and index < len(plan)-1:
                self.pause_after_aspect(a.id)
    def check(self, aid):
        # Basic
        if aid=="A1": return self.ratio(aid,[bool(re.search(rf"(?mi)^{d}\s+uptime is",self.cmd(d,"show version | include uptime"))) for d in DEVICES])
        if aid=="A2": return self.ratio(aid,[all("camp-c2.local" in self.cmd(d,"show hosts").lower() for d in DEVICES),all(self.has_all(self.cmd(d,"show clock detail"),r"ALMT",r"(?:UTC|GMT).*5|5.*hours") for d in DEVICES)])
        if aid=="A3": return self.ratio(aid,["15" in self.cmd(d,"show privilege") for d in DEVICES],"Console login uses configured admin credentials")
        if aid=="A4": return self.ratio(aid,[self.has_all(self.cmd(d,"show ip ssh")+self.cmd(d,"show crypto key mypubkey rsa"),r"version 2",r"(?:2048|3072|4096) bits") for d in DEVICES])
        if aid=="A5": return self.skip(aid,"Требует SSH/Telnet tests с JUDGE-SRV")
        if aid=="A6":
            tests=[self.ip_ok(d,"Loopback0",ip) for d,ip in LOOPBACKS.items()]
            tests += [self.ip_ok(d,i,ip) for d,(i,ip) in MGMT.items()]
            return self.ratio(aid,tests)
        if aid=="A7": return self.ratio(aid,[self.ip_ok(d,i,ip) for d,v in ROUTED.items() for i,ip in v.items()])
        if aid=="A8": return self.ratio(aid,[self.has_all(self.cmd(d,"show ip route 0.0.0.0"),re.escape(gw)) for d,gw in {"AS1":"10.80.50.1","AS2":"10.80.50.1","AS3":"10.82.50.1","AS4":"10.83.50.1"}.items()])
        if aid=="A9": return self.ratio(aid,[len([x for x in self.cmd(d,"show interfaces description").splitlines() if re.search(r"\bup\s+up\b",x,re.I) and re.search(r"\s\S.{2,}$",x)])>0 for d in DEVICES])
        if aid=="A10": return self.ratio(aid,[d.lower() in self.cmd(d,"show startup-config | include hostname").lower() for d in DEVICES])
        # VLAN/VTP/trunk/MST/L2
        vlans={"B1":({d:{10:"STAFF",40:"GUEST",50:"MGMT",998:"UNUSED",999:"NATIVE"} for d in ["DS1","DS2","AS1","AS2"]}),"B2":({d:{130:"SERVICES",150:"MGMT",999:"NATIVE"} for d in ["DS3","DS4"]}),"B3":{"AS3":{110:"",150:"",999:""},"AS4":{210:"",250:"",999:""}}}
        if aid in vlans:
            return self.ratio(aid,[bool(re.search(rf"(?m)^\s*{v}\s+{re.escape(n)}",self.cmd(d,"show vlan brief"),re.I)) for d,vs in vlans[aid].items() for v,n in vs.items()])
        if aid=="B4": return self.ratio(aid,[self.has_all(self.cmd(d,"show vtp status"),r"transparent",r"CAMP-C2") for d in ["DS1","DS2","AS1","AS2"]])
        if aid in {"B5","B6","B7","B11"}:
            groups={"B5":(["DS1","DS2","AS1","AS2"],[10,40,50,999]),"B6":(["DS3","DS4"],[130,150,999]),"B7":(["AS3","AS4"],None),"B11":(["DS1","DS2"],[10,40,50,999])}; ds,want=groups[aid]
            tests=[]
            for d in ds:
                o=self.cmd(d,"show interfaces trunk"); allowed=([110,150,999] if d=="AS3" else [210,250,999]) if want is None else want
                tests.append("999" in o and all(str(x) in o for x in allowed) and (aid!="B11" or re.search(r"Po12|Port-channel12",o,re.I)))
            return self.ratio(aid,tests)
        if aid=="B8": return self.skip(aid,"Требует точной карты физических trunk-портов; проверяется экспертом через show interfaces <port> switchport")
        if aid=="B9": return self.ratio(aid,[self.has_all(self.cmd(d,"show etherchannel summary"),r"Po12\(SU\)",r"Gi1/0\(P\)",r"Gi1/1\(P\)") for d in ["DS1","DS2"]])
        if aid=="B10": return self.ratio(aid,[self.has_all(self.cmd(d,"show lacp neighbor"),r"Gi1/0",r"Gi1/1") for d in ["DS1","DS2"]])
        if aid=="B12": return self.ratio(aid,[self.has_all(self.cmd(d,"show spanning-tree mst configuration"),r"AURORA-C2",r"Revision\s+2",r"1\s+10,?50",r"2\s+40") for d in ["DS1","DS2","AS1","AS2"]])
        if aid in {"B13","B14"}:
            inst="1" if aid=="B13" else "2"; root="DS1" if aid=="B13" else "DS2"; other="DS2" if aid=="B13" else "DS1"
            return self.ratio(aid,["This bridge is the root" in self.cmd(root,f"show spanning-tree mst {inst}"),"This bridge is the root" not in self.cmd(other,f"show spanning-tree mst {inst}")])
        if aid=="B15": return self.ratio(aid,[self.has_all(self.cmd(d,"show spanning-tree mst configuration"),r"AURORA-C2",r"3\s+130,?150") for d in ["DS3","DS4"]]+["This bridge is the root" in self.cmd("DS3","show spanning-tree mst 3")])
        if aid in {"B16","B17","B18","B19"}: return self.skip(aid,"Нужна однозначная карта endpoint/unused-портов из графической топологии")
        if aid=="B20": return self.ratio(aid,[any(str(v) in self.cmd(d,"show ip dhcp snooping") for v in ([10,40] if d in ["AS1","AS2","DS1","DS2"] else [110] if d=="AS3" else [210])) for d in ["DS1","DS2","AS1","AS2","AS3","AS4"]])
        if aid=="B21": return self.ratio(aid,["enabled" in self.cmd(d,"show ip arp inspection").lower() or re.search(r"\b(10|40|110|210)\b",self.cmd(d,"show ip arp inspection")) for d in ["DS1","DS2","AS1","AS2","AS3","AS4"]])
        if aid=="B22": return self.skip(aid,"Disruptive test: continuous PC1 ping and controlled Po12 member shutdown")
        # HSRP
        if aid=="C1": return self.ratio(aid,[self.ip_ok(d,f"Vlan{v}",ip) for d in ["DS1","DS2"] for v,ip in SVI[d].items()])
        if aid=="C2": return self.ratio(aid,[self.has_all(self.cmd(d,"show standby brief"),rf"Vl{v}.*\b{v}\b",re.escape(f"10.80.{v}.1")) for d in ["DS1","DS2"] for v in [10,40,50]])
        if aid in {"C3","C4","C5"}:
            v={"C3":10,"C4":40,"C5":50}[aid]; active="DS2" if v==40 else "DS1"; standby="DS1" if active=="DS2" else "DS2"
            return self.ratio(aid,[self.has_all(self.cmd(active,f"show standby vlan {v} brief"),r"Active",r"120"),self.has_all(self.cmd(standby,f"show standby vlan {v} brief"),r"Standby",r"100")])
        if aid=="C6": return self.ratio(aid,["preemption enabled" in self.cmd(d,f"show standby vlan {v}").lower() for d in ["DS1","DS2","DS3","DS4"] for v in ([10,40,50] if d in ["DS1","DS2"] else [130,150])])
        if aid in {"C7","C8"}:
            dev="DS1" if aid=="C7" else "DS2"; out=self.cmd(dev,"show standby")
            return self.ratio(aid,[len(re.findall(r"Track|tracking",out,re.I))>=2,"15" in out])
        if aid in {"C9","C10","C12"}: return self.skip(aid,"Disruptive HSRP tracking/failover test")
        if aid=="C11": return self.ratio(aid,[self.ip_ok(d,f"Vlan{v}",ip) for d in ["DS3","DS4"] for v,ip in SVI[d].items()]+["Active" in self.cmd("DS3","show standby brief"),"Standby" in self.cmd("DS4","show standby brief")])
        # OSPF
        if aid=="D1": return self.ratio(aid,[self.has_all(self.cmd(d,"show ip ospf"),r"Routing Process.*20",re.escape(LOOPBACKS[d])) for d in OSPF])
        if aid=="D2": return self.ratio(aid,["Passive Interface(s)" in self.cmd(d,"show ip protocols") for d in OSPF])
        if aid in {"D3","D4","D5"}:
            ds={"D3":["IR1","IR2","CR1","CR2","DS1","DS2"],"D4":["IR2","IR3"],"D5":["IR3","DS3","DS4"]}[aid]
            return self.ratio(aid,["FULL" in self.cmd(d,"show ip ospf neighbor") for d in ds])
        if aid in {"D6","D7","D8","D9"}:
            area={"D6":"0","D7":"10","D8":"20"}.get(aid); ds=OSPF if aid in {"D6","D9"} else ["DS1","DS2"] if aid=="D7" else ["IR3","DS3","DS4"]
            return self.ratio(aid,[("POINT_TO_POINT" in self.cmd(d,"show ip ospf interface brief") if aid=="D9" else bool(re.search(rf"\b{area}\b",self.cmd(d,"show ip ospf interface brief")))) for d in ds])
        if aid in {"D10","D12"}:
            prefix="10.80.0.0" if aid=="D10" else "10.81.0.0"; ds=["IR3"] if aid=="D10" else ["IR1","IR2"]
            return self.ratio(aid,[prefix in self.cmd(d,"show ip route ospf") for d in ds])
        if aid=="D11": return self.ratio(aid,["O*IA" in self.cmd(d,"show ip route ospf") and "0.0.0.0" in self.cmd(d,"show ip route ospf") for d in ["DS3","DS4"]])
        if aid in {"D13","D14"}:
            dev="IR1" if aid=="D13" else "IR2"; metric="10" if aid=="D13" else "100"
            return self.ratio(aid,["B*" in self.cmd(dev,"show ip route 0.0.0.0"),metric in self.cmd("CR1","show ip ospf database external 0.0.0.0")])
        if aid=="D15": return self.ratio(aid,[not re.search(r"Vl(?:10|40|50|130|150)\b",self.cmd(d,"show ip ospf neighbor"),re.I) for d in ["DS1","DS2","DS3","DS4"]])
        if aid=="D16": return self.skip(aid,"Disruptive IR1 WAN failover test")
        # BGP
        peers={"E1":("IR1","203.0.113.1"),"E2":("IR2","203.0.113.5"),"E3":("IR3","203.0.113.9"),"E4":("BR1","203.0.113.13"),"E5":("BR2","203.0.113.17")}
        if aid in peers:
            d,p=peers[aid]; o=self.cmd(d,"show bgp ipv4 unicast summary"); return self.ratio(aid,[bool(re.search(rf"^{re.escape(p)}\s+\S+\s+65000\s+.*\s\d+\s*$",o,re.M))])
        if aid=="E6": return self.ratio(aid,[self.has_all(self.cmd(d,f"show bgp ipv4 unicast neighbors {p}"),r"hold time is 30",r"keepalive interval is 10") for d,p in peers.values()])
        if aid=="E7": return self.ratio(aid,[all(p in self.cmd(d,"show ip route bgp") for p in ["0.0.0.0","10.82.0.0","10.83.0.0"]) for d in ["IR1","IR2","IR3"]])
        if aid=="E8": return self.ratio(aid,[all(p in self.cmd(d,"show ip route bgp") for p in (["0.0.0.0","10.80.0.0","10.81.0.0","10.83.0.0"] if d=="BR1" else ["0.0.0.0","10.80.0.0","10.81.0.0","10.82.0.0"])) for d in ["BR1","BR2"]])
        if aid in {"E9","E10","E11"}:
            expected={"E9":["10.80.0.0/16","198.51.100.80/29"],"E10":["10.81.0.0/16","198.51.100.88/29"],"E11":["10.82.0.0/16","10.83.0.0/16"]}[aid]; o=self.cmd("ISP1","show bgp ipv4 unicast")
            return self.ratio(aid,[p in o for p in expected])
        if aid=="E12": return self.skip(aid,"Disruptive WAN resilience test plus exact ISP route-leak audit")
        # Services/NAT
        if aid in {"F1","F2"}:
            v=10 if aid=="F1" else 40; return self.ratio(aid,["10.81.130.10" in self.cmd(d,f"show ip interface vlan {v}") for d in ["DS1","DS2"]])
        if aid=="F3": return self.ratio(aid,["10.81.130.10" in self.cmd("BR1","show ip interface GigabitEthernet0/1.110"),"10.81.130.10" in self.cmd("BR2","show ip interface GigabitEthernet0/1.210")])
        if aid=="F4": return self.ratio(aid,[not re.search(r"Pool\s+\S+",self.cmd(d,"show ip dhcp pool"),re.I) for d in OSPF+EDGES if d in self.sessions])
        if aid in {"F5","F6","F7","F8","F9"}: return self.skip(aid,"Требует команд на Linux PC1-PC4")
        if aid=="F10": return self.ratio(aid,[self.has_all(self.cmd(d,"show ntp associations")+self.cmd(d,"show ntp status"),r"10.81.130.10",r"Clock is synchronized") for d in DEVICES])
        if aid=="F11": return self.ratio(aid,["198.51.100.81" in self.cmd("IR1","show ip nat translations"),"198.51.100.82" in self.cmd("IR2","show ip nat translations")])
        if aid=="F12": return self.ratio(aid,["Total active translations" in self.cmd(d,"show ip nat statistics") for d in ["BR1","BR2"]])
        if aid=="F13": return self.ratio(aid,[self.has_all(self.cmd("IR3","show ip nat translations"),r"198.51.100.89",r"10.81.130.10")],"HTTP /healthz=OK-C2 still requires ISP-side confirmation")
        if aid=="F14": return self.skip(aid,"Requires generated inter-site sessions and disruptive IR1 failover")
        # Security/telemetry
        if aid in {"G1","G2","G3","G4","G5","G6","G11","G13"}: return self.skip(aid,"Requires positive/negative tests from Linux JUDGE/PC endpoints")
        if aid=="G7": return self.ratio(aid,[len(re.findall(r"\b(?:IR|CR|DS|AS|BR)\d\b",self.cmd(d,"show cdp neighbors")))>0 for d in DEVICES])
        if aid=="G8": return self.ratio(aid,["10.81.130.10" in self.cmd(d,"show logging") for d in DEVICES])
        if aid=="G9": return self.ratio(aid,[self.has_all(self.cmd(d,"show logging"),r"warnings",r"timestamp|msec") for d in DEVICES])
        if aid=="G10": return self.ratio(aid,[self.has_all(self.cmd(d,"show snmp user c2snmp"),r"authPriv|priv",r"SHA",r"AES") for d in DEVICES],"IOS-side user validation; manager polling requires SVR tests")
        if aid=="G12": return self.ratio(aid,[self.has_all(self.cmd(d,"show ip flow export")+self.cmd(d,"show flow exporter"),r"10.81.130.10",r"2055") for d in EDGES])
        if aid=="G14": return self.ratio(aid,["FULL" in self.cmd(d,"show ip ospf neighbor") for d in OSPF]+[bool(re.search(r"\s\d+\s*$",self.cmd(d,"show bgp ipv4 unicast summary"),re.M)) for d in EDGES])
        raise KeyError(aid)
    def report(self):
        totals=defaultdict(float); maximums=defaultdict(float)
        print(f"\n{PURPLE}{'#'*90}\nC2 Marking Scheme Report\n{'#'*90}{NC}")
        for r in self.results:
            totals[r.aspect.id[0]]+=r.score; maximums[r.aspect.id[0]]+=r.aspect.mark
            color={"PASS":GREEN,"PART":PURPLE,"FAIL":RED,"SKIP":YELLOW}[r.status]
            frac=f" ({r.passed}/{r.total})" if r.total else ""
            print(f"{color}[{r.status:4}] {r.aspect.number:03d} {r.aspect.id:3} {r.score:.3f}/{r.aspect.mark:.3f}{frac} — {r.aspect.title}{NC}")
            if r.details: print("       "+r.details)
        print(f"\n{PURPLE}Итоги:{NC}")
        for c in "ABCDEFG": print(f"  {c}: {totals[c]:.3f}/{maximums[c]:.3f}")
        print(f"{CYAN}TOTAL: {sum(totals.values()):.3f}/{sum(maximums.values()):.3f}{NC}")

def args():
    p=argparse.ArgumentParser(description="WSC2026 C2 PNETLab IOS scorer")
    p.add_argument("--start",default="A",help="A-G, aspect ID (C7) or ordinal 1-100")
    p.add_argument("--lab",default="module-c",help="substring of running PNETLab lab name")
    p.add_argument("--no-pause",action="store_true",help="не ждать Enter после каждого аспекта")
    return p.parse_args()
def start_number(s):
    s=s.upper()
    if s.isdigit() and 1<=int(s)<=100:return int(s)
    if s in BY_ID:return BY_ID[s].number
    found=next((a.number for a in ASPECTS if a.id.startswith(s)),None)
    if found:return found
    raise ValueError("use A-G, A1-G14 or 1-100")
def main():
    a=args(); start=start_number(a.start)
    with open(HERE/"creds.json",encoding="utf-8") as f: creds=json.load(f)
    url=creds["pnet_url"]; cookie=login(url,creds["username"],creds["password"])
    try:
        sid=get_running_session_id_by_substring(url,cookie,a.lab); join_session(url,sid,cookie)
        consoles=build_node_console_map(get_nodes(url,cookie).json())
        scorer=Scorer(consoles,creds)
        try: scorer.connect(); scorer.run(start,pause=not a.no_pause); scorer.report()
        finally: scorer.close()
    finally:
        try: logout(url)
        except Exception: pass
if __name__=="__main__": main()
