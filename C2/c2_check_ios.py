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
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import ipaddress
import json
from pathlib import Path
import re
import shlex
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "C1"))
from pnetlab_lib import login, logout, join_session, get_nodes  # noqa: E402
from checker_lib import (  # noqa: E402
    BLUE, CYAN, GREEN, NC, PURPLE, RED, YELLOW,
    IOSConsoleSession, build_node_console_map,
    format_ios_output, get_running_session_id_by_substring,
)
from host_lib import LinuxSSHSession, VPCSSession  # noqa: E402

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

DEVICES = ["IR1","IR2","CR1","CR2","DS1","DS2","AS1","AS2","IR3","DS3","DS4","BR1","BR2","AS3","AS4"]
OSPF = ["IR1","IR2","CR1","CR2","DS1","DS2","IR3","DS3","DS4"]
SWITCHES = ["DS1","DS2","AS1","AS2","DS3","DS4","AS3","AS4"]
EDGES = ["IR1","IR2","IR3","BR1","BR2"]
ENDPOINT_PORTS = {
    "AS1":"GigabitEthernet0/2",  # PC1
    "AS2":"GigabitEthernet0/2",  # PC2
    "AS3":"GigabitEthernet0/1",  # PC3
    "AS4":"GigabitEthernet0/1",  # PC4
    "DS3":"GigabitEthernet0/2",  # SVR1
    "DS4":"GigabitEthernet0/2",  # SVR2
}
PC_PORTS = {d:p for d,p in ENDPOINT_PORTS.items() if d.startswith("AS")}
HQ_USED_PORTS = {
    "DS1":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2","GigabitEthernet0/3","GigabitEthernet1/0","GigabitEthernet1/1"},
    "DS2":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2","GigabitEthernet0/3","GigabitEthernet1/0","GigabitEthernet1/1"},
    "AS1":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2"},
    "AS2":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2"},
}

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

HOST_CHECK_INSTRUCTIONS = {
 "B21":"С PC1-PC4 выполнить ping своего gateway; ping проходит, а DAI forwarded counters растут без drops легитимного ARP.",
 "F9":"На PC1-PC4: `dig +short ops.c2.skill39.local`, `dig +short judge.c2.skill39.local`, `dig +short internet-test.c2.skill39.local`. Ожидаются 10.81.130.10, 10.81.150.10, 198.51.100.100.",
 "G1":"JUDGE-SRV и management host: SSH к representative Cisco разрешен. С PC user VLAN тот же TCP/22 должен быть заблокирован.",
 "G2":"JUDGE-SRV и user PC: `nc -zvw3 <Cisco-IP> 23` должен завершиться отказом/timeout; SSH с разрешенного источника продолжает работать.",
 "G3":"PC2: обновить DHCP, выполнить DNS lookup, ping 10.81.130.10 и 198.51.100.100. Все разрешенные проверки должны пройти.",
 "G4":"PC2: ping/TCP tests к 10.81.150.10, management host, PC1, PC3 и PC4. Все попытки должны быть заблокированы.",
 "G5":"Проверить матрицу: PC1→PC3/PC4/SVR1/Internet; PC3→PC1/SVR1/Internet; PC4→PC1/SVR1/Internet. Разрешенные пути должны работать.",
 "G6":"С PC1/PC3/PC4 выполнить `nc -zvw3 <Cisco-or-SVR-IP> 22` к Cisco, 10.81.130.10 и 10.81.150.10. Все TCP/22 должны блокироваться.",
 "G8":"Сгенерировать interface up/down event. На SVR1 проверить syslog: сообщение должно прийти от проверяемого устройства с корректным source address.",
 "G9":"На SVR1 открыть принятое syslog-сообщение: severity не ниже warnings и timestamp содержит milliseconds.",
 "G10":"С SVR1 и SVR2 выполнить SNMPv3 walk пользователя c2snmp в authPriv к 1.3.6.1.2.1.1; оба manager должны получить ответ.",
 "G11":"С PC1 выполнить SNMPv3 query с корректными credentials — ожидается timeout. Сразу повторить с SVR1 — ожидается успешный ответ.",
 "G12":"Сгенерировать трафик через IR1/IR2/IR3/BR1/BR2; на SVR1 подтвердить получение NetFlow records UDP/2055 от каждого edge.",
}

LOOPBACKS = {"IR1":"10.255.80.1","IR2":"10.255.80.2","CR1":"10.255.80.11","CR2":"10.255.80.12","DS1":"10.255.80.21","DS2":"10.255.80.22","IR3":"10.255.81.1","DS3":"10.255.81.11","DS4":"10.255.81.12","BR1":"10.255.82.1","BR2":"10.255.83.1"}
MGMT = {"AS1":("Vlan50","10.80.50.21"),"AS2":("Vlan50","10.80.50.22"),"AS3":("Vlan150","10.82.50.21"),"AS4":("Vlan250","10.83.50.21")}
SVI = {"DS1":{10:"10.80.10.11",40:"10.80.40.11",50:"10.80.50.11"},"DS2":{10:"10.80.10.12",40:"10.80.40.12",50:"10.80.50.12"},"DS3":{130:"10.81.130.11",150:"10.81.150.11"},"DS4":{130:"10.81.130.12",150:"10.81.150.12"}}
ROUTED = {
 "IR1":{"GigabitEthernet0/0":"10.80.0.1","GigabitEthernet0/1":"10.80.0.5","GigabitEthernet0/2":"10.80.0.17","GigabitEthernet0/3":"203.0.113.2"},
 # The published physical diagram is authoritative for interface placement:
 # IR2 G0/3 faces ISP1 and G0/4 faces IR3.  The prose table that says G0/4
 # and G0/5 conflicts with both the diagram and the supplied PNETLab lab.
 "IR2":{"GigabitEthernet0/1":"10.80.0.9","GigabitEthernet0/0":"10.80.0.13","GigabitEthernet0/2":"10.80.0.18","GigabitEthernet0/3":"203.0.113.6","GigabitEthernet0/4":"10.80.0.41"},
 "CR1":{"GigabitEthernet0/0":"10.80.0.2","GigabitEthernet0/3":"10.80.0.10","GigabitEthernet0/2":"10.80.0.21","GigabitEthernet0/1":"10.80.0.25","GigabitEthernet0/4":"10.80.0.29"},
 "CR2":{"GigabitEthernet0/3":"10.80.0.6","GigabitEthernet0/0":"10.80.0.14","GigabitEthernet0/2":"10.80.0.22","GigabitEthernet0/4":"10.80.0.33","GigabitEthernet0/1":"10.80.0.37"},
 "DS1":{"GigabitEthernet0/0":"10.80.0.26","GigabitEthernet0/3":"10.80.0.34"},"DS2":{"GigabitEthernet0/3":"10.80.0.30","GigabitEthernet0/0":"10.80.0.38"},
 "IR3":{"GigabitEthernet0/0":"10.81.0.1","GigabitEthernet0/1":"10.81.0.5","GigabitEthernet0/2":"10.80.0.42","GigabitEthernet0/3":"203.0.113.10"},
 "DS3":{"GigabitEthernet0/0":"10.81.0.2"},"DS4":{"GigabitEthernet0/0":"10.81.0.6"},
 "BR1":{"GigabitEthernet0/0":"203.0.113.14","GigabitEthernet0/1.110":"10.82.10.1","GigabitEthernet0/1.150":"10.82.50.1"},
 "BR2":{"GigabitEthernet0/0":"203.0.113.18","GigabitEthernet0/1.210":"10.83.10.1","GigabitEthernet0/1.250":"10.83.50.1"}}

class Scorer:
    def __init__(self, consoles, creds, disruptive=True):
        self.consoles = consoles; self.creds = creds; self.sessions = {}; self.cache = {}; self.results = []
        self.disruptive = disruptive
        self.current_aspect = ""
        self.command_devices = []
        self.command_records = []
        self.live_device = None
        self.host_sessions = {}
        self.host_errors = {}
    def connect(self):
        for dev in ["ISP1"] + DEVICES:
            if dev not in self.consoles: continue
            host, port = self.consoles[dev]
            s = IOSConsoleSession(host, port, self.creds.get("enable_password"), dev,
                device_username=self.creds.get("device_username"), device_password=self.creds.get("device_password"))
            try: s.connect(); self.sessions[dev] = s
            except Exception as exc: print(f"{YELLOW}[!] {dev}: {exc}{NC}")
        for dev in ["PC1","PC2","PC3","PC4"]:
            if dev not in self.consoles: continue
            host,port=self.consoles[dev];session=VPCSSession(host,port,dev)
            try:session.connect();self.host_sessions[dev]=session
            except Exception as exc:self.host_errors[dev]=str(exc);print(f"{YELLOW}[!] {dev} VPCS: {exc}{NC}")
        for dev in ["SVR1","SVR2"]:
            if dev not in self.consoles: continue
            host,port=self.consoles[dev]
            session=LinuxSSHSession(host,port,dev,self.creds.get("server_username","student"),self.creds.get("server_password","StudentPass"))
            try:session.connect();self.host_sessions[dev]=session
            except Exception as exc:self.host_errors[dev]=str(exc);print(f"{YELLOW}[!] {dev} SSH: {exc}{NC}")
    def close(self):
        for s in self.sessions.values(): s.close()
        for s in self.host_sessions.values(): s.close()
    def record_command(self,dev,command,output):
        """Record evidence; device blocks are printed together with their verdict."""
        self.command_devices.append(dev)
        self.command_records.append((dev,command,output))
        if self.live_device != dev:
            print(f"{BLUE}[{dev}] проверка...{NC}",flush=True)
            self.live_device=dev
    def host_cmd(self,dev,command,timeout=15):
        session=self.host_sessions.get(dev)
        if session is None:raise RuntimeError(f"Нет host-сессии {dev}: {self.host_errors.get(dev,'node/console не найдена')}")
        output=session.exec(command,timeout=timeout)
        self.record_command(dev,command,output)
        return output
    def vpcs_ip(self,dev):
        out=self.host_cmd(dev,"show ip")
        ip_match=re.search(r"IP/MASK\s*:\s*([0-9.]+)/(\d+)",out,re.I)
        gw=re.search(r"GATEWAY\s*:\s*([0-9.]+)",out,re.I)
        dns=re.search(r"DNS\s*:\s*([0-9.]+)",out,re.I)
        return out,(ip_match.group(1) if ip_match else ""),(int(ip_match.group(2)) if ip_match else 0),(gw.group(1) if gw else ""),(dns.group(1) if dns else "")
    def vpcs_dhcp_lease(self,dev,timeout=60):
        self.host_cmd(dev,"ip dhcp",timeout=timeout)
        deadline=time.monotonic()+timeout;last=("","",0,"","")
        while time.monotonic()<deadline:
            last=self.vpcs_ip(dev)
            if last[1] and last[1]!="0.0.0.0" and last[2]>0:return last
            time.sleep(3)
        return last
    def vpcs_ping(self,dev,target,count=2):
        timeout=max(15,count*5+10)
        out=self.host_cmd(dev,f"ping {target} -c {count}",timeout=timeout)
        if not out.strip():
            # Some VPCS builds do not return the first ping output while ARP
            # and the route reconverge; retry once after the console is idle.
            time.sleep(3)
            out=self.host_cmd(dev,f"ping {target} -c {count}",timeout=timeout)
        success=bool(re.search(r"\b(?:bytes from|icmp_seq=|\d+\.\d+\.\d+\.\d+.*ms|0% packet loss)\b",out,re.I))
        return success,out
    def linux_tcp_probe(self,dev,ip,port,record_label=None):
        command=("python3 -c \"import socket; s=socket.socket(); s.settimeout(4); "
                 f"ok=s.connect_ex(('{ip}',{port}))==0; "
                 f"print('{ip}:{port}', 'OPEN' if ok else 'CLOSED'); s.close()\"")
        session=self.host_sessions.get(dev)
        if session is None:raise RuntimeError(f"Нет host-сессии {dev}: {self.host_errors.get(dev,'недоступна')}")
        output=session.exec(command,timeout=7)
        label=record_label or dev
        self.record_command(label,f"{dev}$ TCP probe {ip}:{port}",output)
        return bool(re.search(rf"(?m)^{re.escape(ip)}:{port}\s+OPEN\s*$",output))
    def linux_ping(self,dev,ip,count=3):
        output=self.host_cmd(dev,f"ping -c {count} -W 2 {ip}",timeout=count*3+3)
        match=re.search(r"(\d+)\s+(?:packets )?received",output,re.I)
        return bool(match and int(match.group(1))>0)
    def judge_ios_ssh_privilege(self,target_label,ip,enable_cycle=True):
        session=self.host_sessions.get("SVR2")
        if session is None:raise RuntimeError(f"Нет host-сессии SVR2: {self.host_errors.get('SVR2','недоступна')}")
        password=self.creds.get("device_password") or self.creds.get("enable_password") or "Skill39@C2"
        # OpenSSH askpass supplies the login password; stdin supplies IOS CLI
        # commands and the enable password after `disable`.
        cli=(f"show privilege\\ndisable\\nenable\\n{password}\\nshow privilege\\nexit\\n"
             if enable_cycle else "show privilege\\nexit\\n")
        script=("tmp=$(mktemp); "
                f"printf '#!/bin/sh\\necho %s\\n' {shlex.quote(password)} >\"$tmp\"; chmod 700 \"$tmp\"; "
                f"printf '{cli}' | "
                "DISPLAY=:1 SSH_ASKPASS=\"$tmp\" SSH_ASKPASS_REQUIRE=force "
                f"timeout 15 ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
                f"-o ConnectTimeout=5 admin@{ip}; rc=$?; rm -f \"$tmp\"; exit $rc")
        output=session.exec(script,timeout=20)
        useful="\n".join(line for line in output.splitlines() if re.search(r"privilege|Permission denied|Authentication failed|timed out|refused",line,re.I))
        description="show privilege; disable; enable; show privilege" if enable_cycle else "show privilege"
        self.record_command(target_label,f"SVR2$ ssh admin@{ip} ({description})",useful or output[-500:])
        needed=2 if enable_cycle else 1
        return len(re.findall(r"Current privilege level is 15",output,re.I))>=needed and not re.search(r"Permission denied|Authentication failed",output,re.I)
    def wait_hsrp(self,dev,vlan,role,priority=None,timeout=30):
        deadline=time.monotonic()+timeout;last=""
        while time.monotonic()<deadline:
            last=self.cmd(dev,f"show standby vlan {vlan} brief",refresh=True)
            role_ok=bool(re.search(rf"\b{role}\b",last,re.I))
            priority_ok=priority is None or bool(re.search(rf"\b{priority}\b",last))
            if role_ok and priority_ok:return True,last
            time.sleep(3)
        return False,last
    @staticmethod
    def ospf_external_lsa(text,router_id,metric):
        blocks=re.split(r"(?=\n?\s*LS age:)",text)
        for block in blocks:
            if re.search(rf"Advertising Router:\s*{re.escape(router_id)}\b",block,re.I) and re.search(rf"Metric:\s*{metric}\b",block,re.I):
                return True
        return False
    @staticmethod
    def bgp_peer_established(text,peer,remote_as=65000):
        """Recognize an established peer without depending on IOS spacing/CRLF."""
        clean=re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text).replace("\r", "")
        for line in clean.splitlines():
            fields=line.split()
            if len(fields)>=3 and fields[0]==peer and fields[2]==str(remote_as):
                # In IOS summary a numeric final field is State/PfxRcd; words
                # such as Idle/Active/Connect mean the session is not up.
                return fields[-1].isdigit()
        return False
    @staticmethod
    def bgp_prefixes_from_as(text,asn):
        """Return NLRI whose path contains ASN, including wrapped IOS rows."""
        prefixes=set(); current=None
        for line in text.replace("\r", "").splitlines():
            match=re.search(r"\b(\d+(?:\.\d+){3}/\d+)\b",line)
            if match:
                current=match.group(1)
            if current and re.search(rf"(?<!\d){re.escape(str(asn))}(?!\d)",line):
                prefixes.add(current)
        return prefixes
    def filtered_command(self, command):
        """Add narrow IOS output filters without changing checker semantics."""
        if "|" in command:
            return command
        filters = [
            (r"^show hosts$", r"Default domain|domain name|Name/address lookup"),
            (r"^show clock detail$", r"ALMT|UTC|GMT|Time source"),
            (r"^show privilege$", r"Current privilege"),
            (r"^show ip ssh$", r"SSH Enabled|version|Authentication timeout"),
            (r"^show crypto key", r"Key name|Usage|bits|Modulus"),
            (r"^show interfaces description$", r"up|down|admin"),
            (r"^show interfaces status$", r"^Gi|^GigabitEthernet"),
            (r"^show vtp status$", r"Operating Mode|Domain Name"),
            (r"^show interfaces trunk$", r"trunking|native|Vlans allowed|Po12|Gi"),
            (r"^show interfaces \S+ switchport$", r"Name:|Administrative Mode|Operational Mode|Negotiation of Trunking"),
            (r"^show etherchannel summary$", r"Po12|Gi1/0|Gi1/1"),
            (r"^show lacp neighbor$", r"Gi1/0|Gi1/1|Partner|System"),
            (r"^show spanning-tree mst configuration$", r"Name|Revision|^[ ]*[123][ ]"),
            (r"^show spanning-tree mst \d+$", r"root|Root ID|Bridge ID|priority"),
            (r"^show spanning-tree interface \S+ detail$", r"Portfast|portfast|BPDU|Bpdu|edge"),
            (r"^show port-security interface \S+$", r"Port Security|Port Status|Violation Mode|Maximum MAC|Sticky MAC|Last Source"),
            (r"^show ip dhcp snooping$", r"enabled|configured on|Trusted|10|40|110|210|Gi|Po"),
            (r"^show ip dhcp snooping binding$", r"MacAddress|10\.80\.10\.|10\.80\.40\.|10\.82\.10\.|10\.83\.10\.|Gi"),
            (r"^show ip arp inspection$", r"enabled|10|40|110|210|forward|drop"),
            (r"^show standby", r"Vl|Active|Standby|Priority|Preemption|Track|Virtual IP"),
            (r"^show ip ospf$", r"Routing Process|Router ID|stub|Area"),
            (r"^show ip protocols$", r"Routing Protocol|Passive Interface|Gigabit|Vlan"),
            (r"^show ip ospf neighbor$", r"FULL|Neighbor ID"),
            (r"^show ip ospf interface brief$", r"Area|POINT_TO_POINT|Gi|Vl"),
            (r"^show ip route ospf$", r"10\.80\.|10\.81\.|0\.0\.0\.0"),
            (r"^show bgp ipv4 unicast summary$", r"Neighbor|203\.0\.113\."),
            (r"^show bgp ipv4 unicast neighbors", r"BGP neighbor|remote AS|hold time|keepalive"),
            (r"^show ip route bgp$", r"0\.0\.0\.0|10\.8[0-3]\.0\.0"),
            # Keep the full BGP table for E9-E11.  Some IOS builds interpret
            # the grouped alternation in an `include` expression differently
            # and return only the Network header, hiding valid NLRI.
            (r"^show ip dhcp pool$", r"Pool|Leased|Total"),
            (r"^show ntp associations$", r"10\.81\.130\.10|address"),
            (r"^show ntp status$", r"Clock is|reference"),
            (r"^show ip nat translations$", r"198\.51\.100\.(81|82|89)|10\.81\.130\.10"),
            (r"^show ip nat statistics$", r"Total active|Outside interfaces|Inside interfaces"),
            (r"^show cdp neighbors$", r"Device ID|IR|CR|DS|AS|BR"),
            (r"^show logging$", r"10\.81\.130\.10|warnings|timestamp|msec"),
            (r"^show snmp user", r"User name|Authentication Protocol|Privacy Protocol|security level|authPriv"),
            (r"^show ip flow export$", r"10\.81\.130\.10|2055|Source|export"),
            (r"^show flow exporter$", r"10\.81\.130\.10|2055|Source|export"),
        ]
        for pattern, include in filters:
            if re.match(pattern, command, re.I):
                return f"{command} | include {include}"
        return command
    def cmd(self, dev, command, refresh=False):
        command=self.filtered_command(command)
        key=(dev,command)
        if refresh:
            self.cache.pop(key,None)
        if key not in self.cache:
            if dev not in self.sessions: self.cache[key]=""
            else:
                raw=self.sessions[dev].exec(command)
                self.cache[key]=format_ios_output(raw,command)
        self.record_command(dev,command,self.cache[key])
        return self.cache[key]
    def print_device_results(self, values, explicit_labels=None):
        devices=self.command_devices
        if not devices:
            return
        labels=[]
        if explicit_labels is not None:
            labels=list(explicit_labels)
        elif values and len(devices) % len(values) == 0:
            width=len(devices)//len(values)
            labels=[devices[(i+1)*width-1] for i in range(len(values))]
        elif len(values)==len(dict.fromkeys(devices)):
            labels=list(dict.fromkeys(devices))
        elif len(set(devices))==1:
            labels=[devices[0]]*len(values)
        grouped=defaultdict(list)
        order=[]
        for dev,_,_ in self.command_records:
            if dev not in order: order.append(dev)
        for dev,value in zip(labels,values): grouped[dev].append(bool(value))
        records=defaultdict(list)
        for dev,command,output in self.command_records:
            records[dev].append((command,output))
        print(f"\n{CYAN}Информация и результаты по устройствам:{NC}",flush=True)
        for dev in order:
            device_values=grouped.get(dev,[])
            if device_values:
                passed=sum(device_values); total=len(device_values)
                status="PASS" if passed==total else "PART" if passed else "FAIL"
            else:
                passed=sum(values); total=len(values)
                status="PASS" if passed==total else "PART" if passed else "FAIL"
            color={"PASS":GREEN,"PART":PURPLE,"FAIL":RED}[status]
            print(f"\n{BLUE}--- {dev} ---{NC}",flush=True)
            for command,output in records[dev]:
                print(f"{BLUE}{dev}# {command}{NC}",flush=True)
                print(output or "(пустой вывод)",flush=True)
            # Keep the verdict adjacent to this device's evidence.
            print(f"{color}>>> {dev}: {status} ({passed}/{total}){NC}",flush=True)
            sys.stdout.flush()
    def ratio(self, aid, tests, details="", labels=None):
        a=BY_ID[aid]; vals=[bool(x) for x in tests]; p=sum(vals); t=len(vals)
        self.print_device_results(vals,labels)
        status="PASS" if t and p==t else "PART" if p else "FAIL"
        self.results.append(Result(a,status,a.mark*p/t if t else 0,p,t,details))
    def skip(self, aid, why): self.results.append(Result(BY_ID[aid],"SKIP",0,details=why))
    @staticmethod
    def has_all(text,*parts): return all(re.search(p,text,re.I|re.M) for p in parts)
    @staticmethod
    def mst_state(text):
        """Return (is_root, bridge_mac, root_mac, base_priority) for IOS MST output."""
        bridge=re.search(r"(?mi)^Bridge\s+(?:ID\s+)?address\s+(\S+).*?priority\s+\d+(?:\s+\((\d+)\s+sysid)",text)
        root=re.search(r"(?mi)^Root\s+(?:ID\s+)?address\s+(\S+)",text)
        bridge_mac=bridge.group(1).lower() if bridge else None
        root_mac=root.group(1).lower() if root else None
        base_priority=int(bridge.group(2)) if bridge and bridge.group(2) else None
        explicit=bool(re.search(r"(?i)This bridge is (?:the )?root",text))
        # Some IOSvL2 releases omit Root address entirely on the root bridge.
        is_root=explicit or bool(bridge_mac and (root_mac is None or root_mac==bridge_mac))
        return is_root,bridge_mac,root_mac,base_priority
    @staticmethod
    def print_expected(aspect):
        print(f"{CYAN}Ожидаемый результат:{NC}")
        print(f"  {aspect.title}.")
        print(f"  Максимальный балл: {aspect.mark:.3f}")
    @staticmethod
    def print_result(result):
        color={"PASS":GREEN,"PART":PURPLE,"FAIL":RED,"SKIP":YELLOW}[result.status]
        fraction=f" ({result.passed}/{result.total})" if result.total else ""
        print(f"\n{CYAN}Результат аспекта:{NC}",flush=True)
        print(
            f"{color}[{result.status}] {result.aspect.id} "
            f"{result.score:.3f}/{result.aspect.mark:.3f}{fraction} — "
            f"{result.aspect.title}{NC}"
        ,flush=True)
        if result.details:
            print(f"  {result.details}")
        instruction=HOST_CHECK_INSTRUCTIONS.get(result.aspect.id)
        if instruction:
            print(f"{YELLOW}Ручная проверка с хоста:{NC}")
            print(f"  {instruction}")
    def ip_ok(self, dev, iface, ip):
        out=self.cmd(dev,rf"show ip interface brief | include ^{re.escape(iface)}[ ]")
        short=iface.replace("GigabitEthernet","Gi").replace("Loopback","Lo")
        return bool(re.search(rf"^(?:{re.escape(iface)}|{re.escape(short)})\s+{re.escape(ip)}\s+\S+\s+\S+\s+up\s+up\s*$",out,re.I|re.M))
    def configure_interface_state(self,dev,interface,shutdown):
        """Change one interface and always leave IOS in privileged EXEC mode."""
        session=self.sessions.get(dev)
        if session is None: raise RuntimeError(f"Нет консольной сессии {dev}")
        action="shutdown" if shutdown else "no shutdown"
        print(f"{YELLOW}[!] {dev} {interface}: {action}{NC}",flush=True)
        session.exec("configure terminal")
        session.exec(f"interface {interface}")
        session.exec(action)
        session.exec("end")
        # Operational caches are invalid after a topology change.
        self.cache.clear()
    def privileged_exec(self,dev,command):
        session=self.sessions.get(dev)
        if session is None: raise RuntimeError(f"Нет консольной сессии {dev}")
        print(f"{BLUE}{dev}# {command}{NC}",flush=True)
        output=format_ios_output(session.exec(command),command)
        print(output or "(команда выполнена без вывода)",flush=True)
        self.cache.clear()
        return output
    def ios_http_get(self,dev,ip,path,timeout=15):
        """Use an IOS telnet client as an ISP-side raw HTTP/1.0 client."""
        session=self.sessions.get(dev)
        if session is None or session.sock is None:raise RuntimeError(f"Нет IOS console {dev}")
        sock=session.sock
        session._read_until_idle(idle_timeout=.2,max_wait=.6)
        sock.sendall(f"telnet {ip} 80\r\n".encode())
        first=session._read_until_idle(idle_timeout=.5,max_wait=6)
        response=first
        if re.search(r"Open|Connected",first,re.I):
            sock.sendall(f"GET {path} HTTP/1.0\r\nHost: {ip}\r\nConnection: close\r\n\r\n".encode())
            response+=session._read_until_idle(idle_timeout=1,max_wait=timeout)
        # Escape a telnet session if the remote endpoint did not close it.
        try:
            sock.sendall(b"\x1ex\r\n")
            session._read_until_idle(idle_timeout=.3,max_wait=2)
        except OSError:pass
        useful="\n".join(line for line in response.replace("\r","").splitlines() if re.search(r"HTTP/|OK-C2|Open|Connected|refused|timed out",line,re.I))
        self.record_command(dev,f"telnet {ip} 80 + GET {path}",useful or response[-1000:])
        self.cache.clear()
        return response
    @staticmethod
    def pause_after_aspect(aspect_id):
        try:
            input(f"{YELLOW}\nАспект {aspect_id} завершен. Нажмите Enter для следующего аспекта...{NC}")
        except EOFError:
            pass
    def run(self, start, pause=True):
        plan=[a for a in ASPECTS if a.number >= start]
        for index,a in enumerate(plan):
            self.current_aspect=a.id
            self.command_devices=[]
            self.command_records=[]
            self.live_device=None
            print(f"\n{PURPLE}{'='*90}\n{a.number:03d} {a.id} — {a.title}\n{'='*90}{NC}")
            self.print_expected(a)
            print(f"\n{CYAN}Проверка по устройствам:{NC}",flush=True)
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
        if aid=="A2":
            # IOSv show clock detail prints the configured timezone label (ALMT),
            # but does not print its numeric UTC offset.  Requiring a literal
            # "UTC+5" here produces a false FAIL on a correct configuration.
            return self.ratio(aid,[
                "camp-c2.local" in self.cmd(d,"show hosts").lower()
                and bool(re.search(r"(?m)^[.*]?\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\s+ALMT\b",self.cmd(d,"show clock detail"),re.I))
                for d in DEVICES
            ])
        if aid=="A3":
            addresses={**LOOPBACKS,**{d:value[1] for d,value in MGMT.items()}}
            tests=[];labels=[]
            try:
                for d in DEVICES:
                    ip=addresses[d]
                    tests.append(self.judge_ios_ssh_privilege(d,ip));labels.append(d)
                return self.ratio(aid,tests,"Реальный SSH login с JUDGE-SRV + disable/enable cycle",labels=labels)
            except Exception as exc:return self.skip(aid,f"Автоматический SSH с SVR2 недоступен: {exc}")
        if aid=="A4": return self.ratio(aid,[self.has_all(self.cmd(d,"show ip ssh")+self.cmd(d,"show crypto key mypubkey rsa"),r"version 2",r"(?:2048|3072|4096) bits") for d in DEVICES])
        if aid=="A5":
            addresses={**LOOPBACKS,**{d:value[1] for d,value in MGMT.items()}}
            tests=[];labels=[];details=[]
            try:
                for d in DEVICES:
                    ip=addresses[d]
                    ssh=self.judge_ios_ssh_privilege(d,ip,enable_cycle=False)
                    telnet_open=self.linux_tcp_probe("SVR2",ip,23,record_label=d)
                    tests.append(ssh and not telnet_open);labels.append(d)
                    details.append(f"{d}: SSH={'OK' if ssh else 'FAIL'}, Telnet={'OPEN' if telnet_open else 'CLOSED'}")
                return self.ratio(aid,tests,"; ".join(details),labels=labels)
            except Exception as exc:return self.skip(aid,f"SVR2 SSH console недоступна: {exc}")
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
        if aid=="B8":
            tests=[]; labels=[]; checked=[]; unsupported=[]
            for d in SWITCHES:
                trunk_output=self.cmd(d,"show interfaces trunk")
                ports=[]
                for line in trunk_output.splitlines():
                    match=re.match(r"^\s*\S*?((?:GigabitEthernet|Gi)\d+(?:/\d+)+|(?:Port-channel|Po)\d+)\s+.*\btrunking\b",line,re.I)
                    if match and match.group(1) not in ports:
                        ports.append(match.group(1))
                for port in ports:
                    out=self.cmd(d,f"show interfaces {port} switchport")
                    if not re.search(r"Negotiation of Trunking\s*:",out,re.I):
                        unsupported.append(f"{d}:{port}")
                        continue
                    tests.append(self.has_all(out,r"Administrative Mode\s*:\s*trunk",r"Negotiation of Trunking\s*:\s*Off"))
                    labels.append(d); checked.append(f"{d}:{port}")
            if not tests:
                return self.skip(aid,"На operational trunk-портах IOS не возвращает поле Negotiation of Trunking")
            details="Проверены: "+", ".join(checked)
            if unsupported: details += "; поле DTP не поддерживается: "+", ".join(unsupported)
            return self.ratio(aid,tests,details,labels=labels)
        if aid=="B9": return self.ratio(aid,[self.has_all(self.cmd(d,"show etherchannel summary"),r"Po12\(SU\)",r"Gi1/0\(P\)",r"Gi1/1\(P\)") for d in ["DS1","DS2"]])
        if aid=="B10": return self.ratio(aid,[self.has_all(self.cmd(d,"show lacp neighbor"),r"Gi1/0",r"Gi1/1") for d in ["DS1","DS2"]])
        if aid=="B12": return self.ratio(aid,[self.has_all(self.cmd(d,"show spanning-tree mst configuration"),r"AURORA-C2",r"Revision\s+2",r"1\s+10,?50",r"2\s+40") for d in ["DS1","DS2","AS1","AS2"]])
        if aid in {"B13","B14"}:
            inst="1" if aid=="B13" else "2"; root="DS1" if aid=="B13" else "DS2"; other="DS2" if aid=="B13" else "DS1"
            root_state=self.mst_state(self.cmd(root,f"show spanning-tree mst {inst}"))
            other_state=self.mst_state(self.cmd(other,f"show spanning-tree mst {inst}"))
            root_ok=root_state[0] and root_state[3]==24576
            other_ok=(not other_state[0] and other_state[3]==28672
                      and root_state[1] is not None and other_state[2]==root_state[1])
            return self.ratio(aid,[root_ok,other_ok],labels=[root,other])
        if aid=="B15":
            config={d:self.has_all(self.cmd(d,"show spanning-tree mst configuration"),r"AURORA-C2",r"Revision\s+2",r"3\s+130,?150") for d in ["DS3","DS4"]}
            ds3=self.mst_state(self.cmd("DS3","show spanning-tree mst 3"))
            ds4=self.mst_state(self.cmd("DS4","show spanning-tree mst 3"))
            ds3_role=ds3[0] and ds3[3]==24576
            ds4_role=(not ds4[0] and ds4[3]==28672 and ds3[1] is not None and ds4[2]==ds3[1])
            return self.ratio(aid,[config["DS3"],ds3_role,config["DS4"],ds4_role],
                              "MST3 mapping + DS3 primary 24576 + DS4 secondary 28672",
                              labels=["DS3","DS3","DS4","DS4"])
        if aid=="B16":
            tests=[]; labels=[]
            for d,port in ENDPOINT_PORTS.items():
                out=self.cmd(d,f"show spanning-tree interface {port} detail")
                portfast=bool(re.search(r"(?:Portfast|portfast|edge).*(?:enabled|mode)|in the portfast mode",out,re.I))
                guard=bool(re.search(r"(?:BPDU|Bpdu)\s*guard.*(?:enabled|Yes)|guard.*BPDU.*enabled",out,re.I))
                tests.append(portfast and guard); labels.append(d)
            return self.ratio(aid,tests,"Endpoint-порты PC1-PC4, SVR1 и SVR2",labels=labels)
        if aid=="B17":
            tests=[]; labels=[]
            for d,port in PC_PORTS.items():
                out=self.cmd(d,f"show port-security interface {port}")
                enabled=bool(re.search(r"Port Security\s*:\s*Enabled",out,re.I))
                status=bool(re.search(r"Port Status\s*:\s*Secure-(?:up|shutdown)",out,re.I))
                maximum=bool(re.search(r"Maximum MAC Addresses\s*:\s*2\b",out,re.I))
                tests.append(enabled and status and maximum); labels.append(d)
            return self.ratio(aid,tests,"PC1-PC4 access-порты",labels=labels)
        if aid=="B18":
            tests=[]; labels=[]
            for d,port in PC_PORTS.items():
                out=self.cmd(d,f"show port-security interface {port}")
                mode=bool(re.search(r"Violation Mode\s*:\s*(?:Restrict|Shutdown)",out,re.I))
                sticky=re.search(r"Sticky MAC Addresses\s*:\s*(\d+)",out,re.I)
                last=re.search(r"Last Source Address\s*:\s*([0-9a-f.:-]+)",out,re.I)
                learned=bool(sticky and int(sticky.group(1))>0) or bool(last and not re.fullmatch(r"[0.:-]+",last.group(1)))
                tests.append(mode and learned); labels.append(d)
            return self.ratio(aid,tests,"Secure MAC и violation mode на PC1-PC4",labels=labels)
        if aid=="B19":
            tests=[]; labels=[]; checked=[]
            for d,used in HQ_USED_PORTS.items():
                out=self.cmd(d,"show interfaces status")
                found=[]
                for line in out.splitlines():
                    match=re.match(r"^\s*((?:Gi|GigabitEthernet)\S+)\s+(.+)$",line,re.I)
                    if not match: continue
                    raw_port=match.group(1)
                    port=("GigabitEthernet"+raw_port[2:]) if re.match(r"(?i)^Gi\d",raw_port) else raw_port
                    if port in used: continue
                    found.append(port); remainder=match.group(2)
                    tests.append(bool(re.search(r"\bdisabled\b",remainder,re.I) and re.search(r"\b998\b",remainder)))
                    labels.append(d); checked.append(f"{d}:{port}")
                if not found:
                    # Do not silently award a device if its status output could
                    # not be parsed or the image exposes no spare ports.
                    tests.append(False); labels.append(d)
            return self.ratio(aid,tests,"Проверены unused HQ ports: "+", ".join(checked),labels=labels)
        if aid=="B20":
            pc_data={}; renew_errors=[]
            for pc in ["PC1","PC2","PC3","PC4"]:
                try:
                    pc_data[pc]=self.vpcs_dhcp_lease(pc,60)[1]
                    # Give DHCP Snooping a moment to install the binding after ACK.
                    time.sleep(2)
                except Exception as exc:
                    pc_data[pc]="";renew_errors.append(f"{pc}: {exc}")
            expected_vlans={"DS1":{10,40},"DS2":{10,40},"AS1":{10,40},"AS2":{10,40},"AS3":{110},"AS4":{210}}
            allowed_trust={
                "DS1":{"Gi0/1","Gi0/2","Gi1/0","Gi1/1","Po12"},
                "DS2":{"Gi0/1","Gi0/2","Gi1/0","Gi1/1","Po12"},
                "AS1":{"Gi0/0","Gi0/1"},"AS2":{"Gi0/0","Gi0/1"},
                "AS3":{"Gi0/0"},"AS4":{"Gi0/0"},
            }
            required_trust={"DS1":set(),"DS2":set(),"AS1":{"Gi0/0","Gi0/1"},"AS2":{"Gi0/0","Gi0/1"},"AS3":{"Gi0/0"},"AS4":{"Gi0/0"}}
            clients={"AS1":("PC1","Gi0/2"),"AS2":("PC2","Gi0/2"),"AS3":("PC3","Gi0/1"),"AS4":("PC4","Gi0/1")}
            tests=[];labels=[];details=[]
            for d in ["DS1","DS2","AS1","AS2","AS3","AS4"]:
                out=self.cmd(d,"show ip dhcp snooping",refresh=True)
                enabled="snooping is enabled" in out.lower()
                vlan_ok=all(re.search(rf"\b{v}\b",out) for v in expected_vlans[d])
                trusted=set()
                for line in out.splitlines():
                    match=re.match(r"^\s*((?:Gi|Po)\S+)\s+yes\b",line,re.I)
                    if match:
                        port=match.group(1)
                        if port.lower().startswith("gigabitethernet"):port="Gi"+port[len("GigabitEthernet"):]
                        if port.lower().startswith("port-channel"):port="Po"+port[len("Port-channel"):]
                        trusted.add(port)
                trust_ok=trusted <= allowed_trust[d] and required_trust[d] <= trusted
                binding_ok=True
                if d in clients:
                    pc,client_port=clients[d];binding=self.cmd(d,"show ip dhcp snooping binding",refresh=True)
                    ip=pc_data.get(pc,"")
                    full_port="GigabitEthernet"+client_port[2:] if client_port.startswith("Gi") else client_port
                    binding_ok=bool(ip and ip in binding and (client_port in binding or full_port in binding))
                    # A client-facing port must never be trusted.
                    trust_ok=trust_ok and client_port not in trusted
                ok=enabled and vlan_ok and trust_ok and binding_ok
                tests.append(ok);labels.append(d)
                details.append(f"{d}: VLAN={'OK' if enabled and vlan_ok else 'FAIL'}, trust={'OK' if trust_ok else 'FAIL'}, binding={'OK' if binding_ok else 'FAIL'}")
            if renew_errors:details.append("DHCP renew errors: "+"; ".join(renew_errors))
            return self.ratio(aid,tests,"; ".join(details),labels=labels)
        if aid=="B21": return self.ratio(aid,["enabled" in self.cmd(d,"show ip arp inspection").lower() or re.search(r"\b(10|40|110|210)\b",self.cmd(d,"show ip arp inspection")) for d in ["DS1","DS2","AS1","AS2","AS3","AS4"]])
        if aid=="B22":
            if not self.disruptive:return self.skip(aid,"Отключено параметром --skip-disruptive")
            pc_session=self.host_sessions.get("PC1")
            if pc_session is None:return self.skip(aid,f"PC1 VPCS console недоступна: {self.host_errors.get('PC1','нет сессии')}")
            baseline=False;during=False;loss_ok=False;restored=False;failed=False;ping_output=""
            executor=ThreadPoolExecutor(max_workers=1)
            future=None
            try:
                initial=self.cmd("DS1","show etherchannel summary",refresh=True)
                baseline=self.has_all(initial,r"Po12\(SU\)",r"Gi1/0\(P\)",r"Gi1/1\(P\)")
                future=executor.submit(pc_session.exec,"ping 10.81.130.10 -c 20",30)
                time.sleep(3)
                failed=True
                self.configure_interface_state("DS1","GigabitEthernet1/0",True)
                time.sleep(3)
                state=self.cmd("DS1","show etherchannel summary",refresh=True)
                during=self.has_all(state,r"Po12\(SU\)",r"Gi1/1\(P\)")
                ping_output=future.result(timeout=35)
                summary=re.search(r"(\d+)\s+packets transmitted,\s*(\d+)\s+packets received",ping_output,re.I)
                if summary:
                    sent,received=map(int,summary.groups());loss_ok=sent-received<=2
                else:
                    replies=len(re.findall(r"\b(?:bytes from|icmp_seq=|\d+\.\d+\.\d+\.\d+.*ms)\b",ping_output,re.I))
                    loss_ok=replies>=18
            finally:
                if failed:
                    try:
                        self.configure_interface_state("DS1","GigabitEthernet1/0",False)
                        deadline=time.monotonic()+25
                        while time.monotonic()<deadline:
                            state=self.cmd("DS1","show etherchannel summary",refresh=True)
                            if self.has_all(state,r"Po12\(SU\)",r"Gi1/0\(P\)",r"Gi1/1\(P\)"):
                                restored=True;break
                            time.sleep(3)
                    except Exception as exc:print(f"{RED}[!] Restore DS1 G1/0: {exc}{NC}",flush=True)
                if future and future.done() and not ping_output:
                    try:ping_output=future.result()
                    except Exception:pass
                executor.shutdown(wait=False,cancel_futures=True)
            self.record_command("PC1","ping 10.81.130.10 -c 20",ping_output)
            details=(f"baseline={'OK' if baseline else 'FAIL'}, one-member Po12={'OK' if during else 'FAIL'}, "
                     f"loss<=2={'OK' if loss_ok else 'FAIL'}, restore={'OK' if restored else 'FAIL'}")
            return self.ratio(aid,[baseline,during,loss_ok,restored],details,
                              labels=["DS1","DS1","PC1","DS1"])
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
        if aid=="C9":
            if not self.disruptive:return self.skip(aid,"Отключено параметром --skip-disruptive")
            scenarios=[("DS1","DS2",10,"PC1","GigabitEthernet0/0"),("DS2","DS1",40,"PC2","GigabitEthernet0/3")]
            tests=[];labels=[];details=[]
            for active,standby,vlan,pc,uplink in scenarios:
                role_ok=False;ping_ok=False;restored=True
                try:
                    before,_=self.wait_hsrp(active,vlan,"Active",120,10)
                    self.configure_interface_state(active,uplink,True)
                    role_ok,_=self.wait_hsrp(active,vlan,"Active",105,40)
                    standby_ok,_=self.wait_hsrp(standby,vlan,"Standby",100,25)
                    time.sleep(5)
                    pc_ip=self.vpcs_ip(pc)[1]
                    ping_ok=bool(pc_ip) and self.linux_ping("SVR1",pc_ip,5)
                    role_ok=before and role_ok and standby_ok
                finally:
                    try:self.configure_interface_state(active,uplink,False)
                    except Exception as exc:restored=False;print(f"{RED}[!] Restore {active} {uplink}: {exc}{NC}")
                tests.append(role_ok and ping_ok and restored);labels.append(active)
                details.append(f"{active}/VLAN{vlan}: role105={'OK' if role_ok else 'FAIL'}, ping={'OK' if ping_ok else 'FAIL'}, restore={'OK' if restored else 'FAIL'}")
            return self.ratio(aid,tests,"; ".join(details),labels=labels)
        if aid=="C10":
            if not self.disruptive:return self.skip(aid,"Отключено параметром --skip-disruptive")
            scenarios=[("DS1","DS2",10,"PC1",["GigabitEthernet0/0","GigabitEthernet0/3"]),("DS2","DS1",40,"PC2",["GigabitEthernet0/3","GigabitEthernet0/0"])]
            tests=[];labels=[];details=[]
            for old_active,new_active,vlan,pc,uplinks in scenarios:
                failed=[];failover_ok=False;ping_ok=False;restored=True
                try:
                    before,_=self.wait_hsrp(old_active,vlan,"Active",120,10)
                    for uplink in uplinks:self.configure_interface_state(old_active,uplink,True);failed.append(uplink)
                    old_90,_=self.wait_hsrp(old_active,vlan,"Standby",90,45)
                    new_role,_=self.wait_hsrp(new_active,vlan,"Active",100,45)
                    time.sleep(5)
                    pc_ip=self.vpcs_ip(pc)[1]
                    ping_ok=bool(pc_ip) and self.linux_ping("SVR1",pc_ip,5)
                    failover_ok=before and old_90 and new_role
                finally:
                    for uplink in reversed(failed):
                        try:self.configure_interface_state(old_active,uplink,False)
                        except Exception as exc:restored=False;print(f"{RED}[!] Restore {old_active} {uplink}: {exc}{NC}")
                    if restored:self.wait_hsrp(old_active,vlan,"Active",120,30)
                tests.append(failover_ok and ping_ok and restored);labels.append(old_active)
                details.append(f"{old_active}/VLAN{vlan}: failover90={'OK' if failover_ok else 'FAIL'}, ping={'OK' if ping_ok else 'FAIL'}, restore={'OK' if restored else 'FAIL'}")
            return self.ratio(aid,tests,"; ".join(details),labels=labels)
        if aid=="C12":
            if not self.disruptive:return self.skip(aid,"Отключено параметром --skip-disruptive")
            ds3_out=self.cmd("DS3","show standby",refresh=True)
            ds4_out=self.cmd("DS4","show standby",refresh=True)
            ds3_track=len(re.findall(r"Track|tracking",ds3_out,re.I))>=2 and "30" in ds3_out
            ds4_track=len(re.findall(r"Track|tracking",ds4_out,re.I))>=2 and "30" in ds4_out
            before_host=False;after_host=False;roles=False;restored=True
            try:
                before_host=self.linux_ping("SVR2","10.80.50.21") and self.linux_tcp_probe("SVR2","10.80.50.21",22)
                self.configure_interface_state("DS3","GigabitEthernet0/0",True)
                ds3_130,_=self.wait_hsrp("DS3",130,"Standby",90,30)
                ds3_150,_=self.wait_hsrp("DS3",150,"Standby",90,30)
                ds4_130,_=self.wait_hsrp("DS4",130,"Active",100,30)
                ds4_150,_=self.wait_hsrp("DS4",150,"Active",100,30)
                roles=ds3_130 and ds3_150 and ds4_130 and ds4_150
                after_host=self.linux_ping("SVR2","10.80.50.21") and self.linux_tcp_probe("SVR2","10.80.50.21",22)
            finally:
                try:
                    self.configure_interface_state("DS3","GigabitEthernet0/0",False)
                    back130,_=self.wait_hsrp("DS3",130,"Active",120,30)
                    back150,_=self.wait_hsrp("DS3",150,"Active",120,30)
                    restored=back130 and back150
                except Exception as exc:
                    restored=False;print(f"{RED}[!] Restore DS3 G0/0: {exc}{NC}",flush=True)
            details=(f"DS3 track30={'OK' if ds3_track else 'FAIL'}, DS4 track30={'OK' if ds4_track else 'FAIL'}, "
                     f"failover={'OK' if roles else 'FAIL'}, management before/after={'OK' if before_host and after_host else 'FAIL'}, "
                     f"restore={'OK' if restored else 'FAIL'}")
            return self.ratio(aid,[ds3_track,ds4_track,roles,before_host and after_host and restored],details,
                              labels=["DS3","DS4","DS3","SVR2"])
        if aid=="C11": return self.ratio(aid,[self.ip_ok(d,f"Vlan{v}",ip) for d in ["DS3","DS4"] for v,ip in SVI[d].items()]+["Active" in self.cmd("DS3","show standby brief"),"Standby" in self.cmd("DS4","show standby brief")])
        # OSPF
        if aid=="D1": return self.ratio(aid,[self.has_all(self.cmd(d,"show ip ospf"),r"Routing Process.*20",re.escape(LOOPBACKS[d])) for d in OSPF])
        if aid=="D2": return self.ratio(aid,["Passive Interface(s)" in self.cmd(d,"show ip protocols") for d in OSPF])
        if aid in {"D3","D4","D5"}:
            ds={"D3":["IR1","IR2","CR1","CR2","DS1","DS2"],"D4":["IR2","IR3"],"D5":["IR3","DS3","DS4"]}[aid]
            return self.ratio(aid,["FULL" in self.cmd(d,"show ip ospf neighbor") for d in ds])
        if aid in {"D6","D7","D8","D9"}:
            area={"D6":"0","D7":"10","D8":"20"}.get(aid); ds=OSPF if aid in {"D6","D9"} else ["DS1","DS2"] if aid=="D7" else ["IR3","DS3","DS4"]
            if aid=="D9":
                tests=[]; labels=[]
                for d in ds:
                    out=self.cmd(d,"show ip ospf interface brief")
                    routed_lines=[line for line in out.splitlines() if re.match(r"^\s*(?:Gi|GigabitEthernet)\d",line,re.I)]
                    tests.append(bool(routed_lines) and all(re.search(r"\b(?:P2P|POINT_TO_POINT)\b",line,re.I) for line in routed_lines))
                    labels.append(d)
                return self.ratio(aid,tests,"Все OSPF routed Gi-интерфейсы имеют state P2P",labels=labels)
            return self.ratio(aid,[bool(re.search(rf"\b{area}\b",self.cmd(d,"show ip ospf interface brief"))) for d in ds])
        if aid in {"D10","D12"}:
            prefix="10.80.0.0" if aid=="D10" else "10.81.0.0"; ds=["IR3"] if aid=="D10" else ["IR1","IR2"]
            return self.ratio(aid,[prefix in self.cmd(d,"show ip route ospf") for d in ds])
        if aid=="D11": return self.ratio(aid,["O*IA" in self.cmd(d,"show ip route ospf") and "0.0.0.0" in self.cmd(d,"show ip route ospf") for d in ["DS3","DS4"]])
        if aid in {"D13","D14"}:
            dev="IR1" if aid=="D13" else "IR2"; metric="10" if aid=="D13" else "100"
            return self.ratio(aid,["B*" in self.cmd(dev,"show ip route 0.0.0.0"),metric in self.cmd("CR1","show ip ospf database external 0.0.0.0")])
        if aid=="D15": return self.ratio(aid,[not re.search(r"Vl(?:10|40|50|130|150)\b",self.cmd(d,"show ip ospf neighbor"),re.I) for d in ["DS1","DS2","DS3","DS4"]])
        if aid=="D16":
            if not self.disruptive:return self.skip(aid,"Отключено параметром --skip-disruptive")
            baseline_default=False;baseline_lsa=False;withdrawn=False;backup=False;connectivity=False;restored=False
            failed=False
            try:
                ir1_route=self.cmd("IR1","show ip route 0.0.0.0",refresh=True)
                database=self.cmd("CR1","show ip ospf database external 0.0.0.0",refresh=True)
                baseline_default=bool(re.search(r"Known via \"bgp|\bB\*",ir1_route,re.I))
                baseline_lsa=self.ospf_external_lsa(database,"10.255.80.1",10)
                failed=True
                self.configure_interface_state("IR1","GigabitEthernet0/3",True)
                print(f"{YELLOW}[!] Ожидание withdrawal primary default и сходимости OSPF...{NC}",flush=True)
                deadline=time.monotonic()+50
                while time.monotonic()<deadline:
                    time.sleep(5)
                    ir1_route=self.cmd("IR1","show ip route 0.0.0.0",refresh=True)
                    database=self.cmd("CR1","show ip ospf database external 0.0.0.0",refresh=True)
                    withdrawn=(not re.search(r"Known via \"bgp|\bB\*",ir1_route,re.I)
                               and not self.ospf_external_lsa(database,"10.255.80.1",10))
                    backup=self.ospf_external_lsa(database,"10.255.80.2",100)
                    if withdrawn and backup:break
                ping=self.cmd("DS1","ping 198.51.100.100 source 10.80.10.11 repeat 5 timeout 2",refresh=True)
                success=re.search(r"Success rate is (\d+) percent",ping,re.I)
                connectivity=bool(success and int(success.group(1))>0)
            finally:
                if failed:
                    try:
                        self.configure_interface_state("IR1","GigabitEthernet0/3",False)
                        print(f"{YELLOW}[!] Ожидание возврата primary BGP/OSPF default...{NC}",flush=True)
                        deadline=time.monotonic()+50
                        while time.monotonic()<deadline:
                            time.sleep(5)
                            route=self.cmd("IR1","show ip route 0.0.0.0",refresh=True)
                            database=self.cmd("CR1","show ip ospf database external 0.0.0.0",refresh=True)
                            if re.search(r"Known via \"bgp|\bB\*",route,re.I) and self.ospf_external_lsa(database,"10.255.80.1",10):
                                restored=True;break
                    except Exception as exc:print(f"{RED}[!] Restore IR1 G0/3: {exc}{NC}",flush=True)
            details=(f"baseline BGP/LSA10={'OK' if baseline_default and baseline_lsa else 'FAIL'}, "
                     f"withdraw={'OK' if withdrawn else 'FAIL'}, LSA100={'OK' if backup else 'FAIL'}, "
                     f"HQ ping={'OK' if connectivity else 'FAIL'}, restore={'OK' if restored else 'FAIL'}")
            return self.ratio(aid,[baseline_default and baseline_lsa,withdrawn,backup and connectivity,restored],details,
                              labels=["IR1","IR1","IR2","IR1"])
        # BGP
        peers={"E1":("IR1","203.0.113.1"),"E2":("IR2","203.0.113.5"),"E3":("IR3","203.0.113.9"),"E4":("BR1","203.0.113.13"),"E5":("BR2","203.0.113.17")}
        if aid in peers:
            d,p=peers[aid]; o=self.cmd(d,"show bgp ipv4 unicast summary"); return self.ratio(aid,[self.bgp_peer_established(o,p)])
        if aid=="E6": return self.ratio(aid,[self.has_all(self.cmd(d,f"show bgp ipv4 unicast neighbors {p}"),r"hold time is 30",r"keepalive interval is 10") for d,p in peers.values()])
        if aid=="E7":
            expected=["0.0.0.0/0","10.82.0.0/16","10.83.0.0/16"]
            tests=[];labels=[];details=[]
            for d in ["IR1","IR2","IR3"]:
                out=self.cmd(d,"show ip route bgp")
                present=[];missing=[]
                for prefix in expected:
                    # IOS may print default as 0.0.0.0/0 or in a gateway line;
                    # route presence still requires a B/B* route entry.
                    if prefix=="0.0.0.0/0":
                        found=bool(re.search(r"(?m)^\s*B\*?\s+0\.0\.0\.0/0\b",out))
                    else:
                        found=bool(re.search(rf"(?m)^\s*B\*?\s+{re.escape(prefix)}\b",out))
                    (present if found else missing).append(prefix)
                tests.append(not missing);labels.append(d)
                details.append(f"{d}: получены [{', '.join(present) or 'нет'}]; НЕ получены [{', '.join(missing) or 'нет'}]")
            return self.ratio(aid,tests,"; ".join(details),labels=labels)
        if aid=="E8": return self.ratio(aid,[all(p in self.cmd(d,"show ip route bgp") for p in (["0.0.0.0","10.80.0.0","10.81.0.0","10.83.0.0"] if d=="BR1" else ["0.0.0.0","10.80.0.0","10.81.0.0","10.82.0.0"])) for d in ["BR1","BR2"]])
        if aid in {"E9","E10","E11"}:
            expected={"E9":["10.80.0.0/16","198.51.100.80/29"],"E10":["10.81.0.0/16","198.51.100.88/29"],"E11":["10.82.0.0/16","10.83.0.0/16"]}[aid]
            origin={"E9":"AS65220 (HQ)","E10":"AS65230 (DC)","E11":"AS65241/AS65242 (BR1/BR2)"}[aid]
            tests=[];present=[];missing=[]
            for prefix in expected:
                out=self.cmd("ISP1",f"show bgp ipv4 unicast {prefix}",refresh=True)
                found=bool(re.search(rf"BGP routing table entry for\s+{re.escape(prefix)}(?:,|\s|$)",out,re.I))
                tests.append(found)
                (present if found else missing).append(prefix)
            details=(f"ISP1 от {origin}: получены [{', '.join(present) or 'нет'}]; "
                     f"НЕ получены [{', '.join(missing) or 'нет'}]")
            return self.ratio(aid,tests,details,labels=["ISP1"]*len(expected))
        if aid=="E12":
            # Audit every ISP route whose AS path contains the HQ AS.  Only
            # the two explicitly permitted HQ NLRI may be present.
            convergence_timeout=120
            advertised=set()
            print(f"{YELLOW}[!] Ожидание исходной сходимости BGP (до {convergence_timeout} секунд)...{NC}",flush=True)
            deadline=time.monotonic()+convergence_timeout
            while time.monotonic()<deadline:
                leak_out=self.cmd("ISP1","show bgp ipv4 unicast",refresh=True)
                advertised=self.bgp_prefixes_from_as(leak_out,65220)
                if "10.80.0.0/16" in advertised:
                    break
                time.sleep(5)
            allowed={"10.80.0.0/16","198.51.100.80/29"}
            no_leak=bool(advertised) and advertised <= allowed and "10.80.0.0/16" in advertised
            if not self.disruptive:
                state="PASS" if no_leak else "FAIL"
                return self.skip(aid,f"Route-leak audit: {state}; WAN failover отключен параметром --skip-disruptive")
            failover_route=False; failover_ping=False; ir2_alive=False; restored=False
            try:
                self.configure_interface_state("IR1","GigabitEthernet0/3",True)
                print(f"{YELLOW}[!] Ожидание сходимости BGP после отключения IR1 WAN (до {convergence_timeout} секунд)...{NC}",flush=True)
                deadline=time.monotonic()+convergence_timeout
                while time.monotonic()<deadline:
                    time.sleep(5)
                    route=self.cmd("ISP1","show bgp ipv4 unicast 10.80.0.0/16",refresh=True)
                    summary=self.cmd("IR2","show bgp ipv4 unicast summary",refresh=True)
                    failover_route="203.0.113.6" in route and "65220" in route
                    ir2_alive=self.bgp_peer_established(summary,"203.0.113.5")
                    if failover_route and ir2_alive: break
                ping=self.cmd("ISP1","ping 10.80.0.13 repeat 3 timeout 1",refresh=True)
                success=re.search(r"Success rate is (\d+) percent",ping,re.I)
                failover_ping=bool(success and int(success.group(1))>0)
            finally:
                try:
                    self.configure_interface_state("IR1","GigabitEthernet0/3",False)
                    print(f"{YELLOW}[!] Ожидание восстановления eBGP IR1 (до {convergence_timeout} секунд)...{NC}",flush=True)
                    deadline=time.monotonic()+convergence_timeout
                    while time.monotonic()<deadline:
                        time.sleep(5)
                        summary=self.cmd("IR1","show bgp ipv4 unicast summary",refresh=True)
                        if self.bgp_peer_established(summary,"203.0.113.1"):
                            restored=True; break
                except Exception as exc:
                    print(f"{RED}[!] Не удалось подтвердить восстановление IR1 WAN: {exc}{NC}",flush=True)
            details=(f"ISP HQ NLRI: {', '.join(sorted(advertised)) or 'не найдены'}; "
                     f"IR2 route={'OK' if failover_route else 'FAIL'}, ping={'OK' if failover_ping else 'FAIL'}, "
                     f"IR1 restore={'OK' if restored else 'FAIL'}")
            return self.ratio(aid,[no_leak,ir2_alive and failover_route,failover_ping,restored],details,
                              labels=["ISP1","IR2","ISP1","IR1"])
        # Services/NAT
        if aid in {"F1","F2"}:
            v=10 if aid=="F1" else 40; return self.ratio(aid,["10.81.130.10" in self.cmd(d,f"show ip interface vlan {v}") for d in ["DS1","DS2"]])
        if aid=="F3": return self.ratio(aid,["10.81.130.10" in self.cmd("BR1","show ip interface GigabitEthernet0/1.110"),"10.81.130.10" in self.cmd("BR2","show ip interface GigabitEthernet0/1.210")])
        if aid=="F4":
            tests=[]; labels=[]
            for d in dict.fromkeys(OSPF+EDGES):
                if d not in self.sessions: continue
                out=self.cmd(d,"show ip dhcp pool")
                useful=[]
                for line in out.splitlines():
                    stripped=line.strip()
                    if not stripped: continue
                    if re.search(r"show\s+ip\s+dhcp\s+pool",stripped,re.I): continue
                    if re.fullmatch(r"\S+[#>]",stripped): continue
                    useful.append(line)
                # A configured IOS DHCP pool starts with "Pool <name> :".
                # Headers such as "Total addresses" are not pool definitions.
                configured=any(re.match(r"^\s*Pool\s+\S+\s*:",line,re.I) for line in useful)
                tests.append(not configured); labels.append(d)
            return self.ratio(aid,tests,"Эхо команды и IOS prompts исключены; ищутся только реальные Pool <name> :",labels=labels)
        if aid in {"F5","F6","F7","F8"}:
            dev={"F5":"PC1","F6":"PC2","F7":"PC3","F8":"PC4"}[aid]
            network={"PC1":"10.80.10.","PC2":"10.80.40.","PC3":"10.82.10.","PC4":"10.83.10."}[dev]
            gateway={"PC1":"10.80.10.1","PC2":"10.80.40.1","PC3":"10.82.10.1","PC4":"10.83.10.1"}[dev]
            try:
                _,ip,prefix,gw,dns=self.vpcs_dhcp_lease(dev,60)
                last=int(ip.rsplit(".",1)[1]) if ip.startswith(network) else -1
                ok=100<=last<=199 and prefix==24 and gw==gateway and dns=="10.81.130.10"
                return self.ratio(aid,[ok],f"IP={ip}/{prefix}, gateway={gw}, DNS={dns}",labels=[dev])
            except Exception as exc:return self.skip(aid,f"VPCS console недоступна: {exc}")
        if aid=="F9":
            checks=[("ops.c2.skill39.local","10.81.130.10"),("judge.c2.skill39.local","10.81.150.10"),("internet-test.c2.skill39.local","198.51.100.100")]
            tests=[];labels=[]
            try:
                for dev in ["PC1","PC2","PC3","PC4"]:
                    for name,ip in checks:
                        _,out=self.vpcs_ping(dev,name,1);tests.append(ip in out);labels.append(dev)
                return self.ratio(aid,tests,"DNS проверен через разрешение имен командой VPCS ping",labels=labels)
            except Exception as exc:return self.skip(aid,f"VPCS console недоступна: {exc}")
        if aid=="F10": return self.ratio(aid,[self.has_all(self.cmd(d,"show ntp associations")+self.cmd(d,"show ntp status"),r"10.81.130.10",r"Clock is synchronized") for d in DEVICES])
        if aid=="F11":
            primary_ping=False; primary_nat=False
            backup_ping=False; backup_nat=False; restored=True
            # DS1's VLAN10 address is inside the exact HQ PAT source subnet,
            # so this creates a real transit flow through the active edge.
            self.privileged_exec("IR1","clear ip nat translation *")
            ping=self.cmd("DS1","ping 198.51.100.100 source 10.80.10.11 repeat 5 timeout 1",refresh=True)
            success=re.search(r"Success rate is (\d+) percent",ping,re.I)
            primary_ping=bool(success and int(success.group(1))>0)
            translations=self.cmd("IR1","show ip nat translations",refresh=True)
            primary_nat="198.51.100.81" in translations and "10.80.10.11" in translations
            if not self.disruptive:
                return self.ratio(aid,[primary_nat,False],
                    "Primary PAT проверен; backup PAT требует failover (отключен --skip-disruptive)",labels=["IR1","IR2"])
            try:
                self.configure_interface_state("IR1","GigabitEthernet0/3",True)
                self.privileged_exec("IR2","clear ip nat translation *")
                print(f"{YELLOW}[!] Ожидание HQ default route через IR2...{NC}",flush=True)
                deadline=time.monotonic()+40
                while time.monotonic()<deadline:
                    time.sleep(5)
                    route=self.cmd("DS1","show ip route 0.0.0.0",refresh=True)
                    if "10.80.0." in route: break
                ping=self.cmd("DS1","ping 198.51.100.100 source 10.80.10.11 repeat 5 timeout 1",refresh=True)
                success=re.search(r"Success rate is (\d+) percent",ping,re.I)
                backup_ping=bool(success and int(success.group(1))>0)
                translations=self.cmd("IR2","show ip nat translations",refresh=True)
                backup_nat="198.51.100.82" in translations and "10.80.10.11" in translations
            finally:
                try:
                    self.configure_interface_state("IR1","GigabitEthernet0/3",False)
                except Exception as exc:
                    restored=False
                    print(f"{RED}[!] Ошибка восстановления IR1 G0/3: {exc}{NC}",flush=True)
            details=(f"IR1 ping={'OK' if primary_ping else 'FAIL'}, PAT .81={'OK' if primary_nat else 'FAIL'}; "
                     f"IR2 ping={'OK' if backup_ping else 'FAIL'}, PAT .82={'OK' if backup_nat else 'FAIL'}; "
                     f"restore={'OK' if restored else 'FAIL'}")
            return self.ratio(aid,[primary_nat,backup_nat and restored],details,
                              labels=["IR1","IR2"])
        if aid=="F12":
            tests=[];labels=[]
            try:
                for pc,router in [("PC3","BR1"),("PC4","BR2")]:
                    pc_ip=self.vpcs_dhcp_lease(pc,60)[1]
                    self.privileged_exec(router,"clear ip nat translation *")
                    self.vpcs_ping(pc,"198.51.100.100",5)
                    nat=self.cmd(router,r"show ip nat translations | include 10\.82\.10\.|10\.83\.10\.|203\.0\.113\.(14|18)",refresh=True)
                    expected_global="203.0.113.14" if router=="BR1" else "203.0.113.18"
                    translated=bool(pc_ip and pc_ip in nat and expected_global in nat)
                    tests.append(translated);labels.append(router)
                return self.ratio(aid,tests,"DHCP lease получен; PAT оценивается по inside local/global, ping используется для генерации трафика",labels=labels)
            except Exception as exc:return self.skip(aid,f"VPCS console недоступна: {exc}")
        if aid=="F13":
            try:
                response=self.ios_http_get("ISP1","198.51.100.89","/healthz")
                http_ok=bool(re.search(r"(?m)^OK-C2\s*$",response.replace("\r","")))
                nat=self.cmd("IR3","show ip nat translations",refresh=True)
                mapping=self.has_all(nat,r"198\.51\.100\.89",r"10\.81\.130\.10")
                return self.ratio(aid,[http_ok,mapping],
                    f"ISP-side HTTP={'OK-C2' if http_ok else 'FAIL'}, IR3 mapping={'OK' if mapping else 'FAIL'}",
                    labels=["ISP1","IR3"])
            except Exception as exc:return self.ratio(aid,[False],f"ISP-side HTTP test error: {exc}",labels=["ISP1"])
        if aid=="F14":
            private_tests=[]; private_details=[]
            failover_ok=False; restored=True
            try:
                pc1_ip=self.vpcs_dhcp_lease("PC1",60)[1]
                pc3_ip=self.vpcs_dhcp_lease("PC3",60)[1]
                pc4_ip=self.vpcs_dhcp_lease("PC4",60)[1]
                self.privileged_exec("IR1","clear ip nat translation *")
                self.privileged_exec("IR2","clear ip nat translation *")
                for name,target in [("PC3",pc3_ip),("PC4",pc4_ip),("OPS-SRV","10.81.130.10")]:
                    reachable=bool(target) and self.vpcs_ping("PC1",target,5)[0]
                    ir1_nat=self.cmd("IR1","show ip nat translations",refresh=True)
                    ir2_nat=self.cmd("IR2","show ip nat translations",refresh=True)
                    translated=any(pc1_ip and target and pc1_ip in line and target in line
                                   for line in (ir1_nat+"\n"+ir2_nat).splitlines())
                    private_tests.append(reachable and not translated)
                    private_details.append(f"{name}: ping={'OK' if reachable else 'FAIL'}, NAT exemption={'OK' if not translated else 'FAIL'}")
                if not self.disruptive:
                    return self.ratio(aid,private_tests+[False],
                        "; ".join(private_details)+"; failover отключен --skip-disruptive",
                        labels=["PC1"]*3+["IR2"])
                try:
                    self.configure_interface_state("IR1","GigabitEthernet0/3",True)
                    self.privileged_exec("IR2","clear ip nat translation *")
                    print(f"{YELLOW}[!] Ожидание сходимости HQ WAN через IR2 (до 60 секунд)...{NC}",flush=True)
                    deadline=time.monotonic()+60
                    while time.monotonic()<deadline:
                        time.sleep(5)
                        self.vpcs_ping("PC1","198.51.100.100",2)
                        translations=self.cmd("IR2","show ip nat translations",refresh=True)
                        if pc1_ip and pc1_ip in translations and "198.51.100.82" in translations:
                            failover_ok=True
                            break
                finally:
                    try:
                        self.configure_interface_state("IR1","GigabitEthernet0/3",False)
                    except Exception as exc:
                        restored=False
                        print(f"{RED}[!] Ошибка восстановления IR1 G0/3: {exc}{NC}",flush=True)
                details=("; ".join(private_details)+
                         f"; IR2 failover PAT .82={'OK' if failover_ok else 'FAIL'}, restore={'OK' if restored else 'FAIL'}")
                return self.ratio(aid,private_tests+[failover_ok and restored],details,
                                  labels=["PC1"]*3+["IR2"])
            except Exception as exc:
                return self.ratio(aid,private_tests+[False],f"F14 automation error: {exc}; restore={'OK' if restored else 'FAIL'}",
                                  labels=["PC1"]*len(private_tests)+["IR2"])
        # Security/telemetry
        if aid=="G3":
            try:
                _,ip,prefix,gw,dns=self.vpcs_ip("PC2")
                dns_ok=self.vpcs_ping("PC2","ops.c2.skill39.local",1)[0]
                svr_ok=self.vpcs_ping("PC2","10.81.130.10",2)[0]
                net_ok=self.vpcs_ping("PC2","198.51.100.100",2)[0]
                return self.ratio(aid,[bool(ip),dns_ok,svr_ok,net_ok],labels=["PC2"]*4)
            except Exception as exc:return self.skip(aid,f"PC2 console недоступна: {exc}")
        if aid=="G4":
            try:
                ips={d:self.vpcs_ip(d)[1] for d in ["PC1","PC3","PC4"]}
                targets=["10.81.150.10","10.80.50.11",ips["PC1"],ips["PC3"],ips["PC4"]]
                return self.ratio(aid,[not self.vpcs_ping("PC2",t,2)[0] for t in targets],"Все запрещенные ICMP destinations должны быть недоступны",labels=["PC2"]*len(targets))
            except Exception as exc:return self.skip(aid,f"VPCS console недоступна: {exc}")
        if aid=="G5":
            try:
                ips={d:self.vpcs_ip(d)[1] for d in ["PC1","PC3","PC4"]};tests=[];labels=[]
                matrix={"PC1":[ips["PC3"],ips["PC4"],"10.81.130.10","198.51.100.100"],"PC3":[ips["PC1"],"10.81.130.10","198.51.100.100"],"PC4":[ips["PC1"],"10.81.130.10","198.51.100.100"]}
                for dev,targets in matrix.items():
                    for target in targets:tests.append(self.vpcs_ping(dev,target,2)[0]);labels.append(dev)
                return self.ratio(aid,tests,"Разрешенная inter-site/OPS/Internet ICMP matrix",labels=labels)
            except Exception as exc:return self.skip(aid,f"VPCS console недоступна: {exc}")
        if aid=="G10":
            command="snmpwalk -v3 -l authPriv -u c2snmp -a SHA -A 'C2Auth@2026' -x AES -X 'C2Priv@2026' -t 3 -r 0 {ip} 1.3.6.1.2.1.1"
            tests=[];labels=[]
            try:
                targets=list(LOOPBACKS.values())+[value[1] for value in MGMT.values()]
                for host in ["SVR1","SVR2"]:
                    for ip in targets:
                        out=self.host_cmd(host,command.format(ip=ip),timeout=10)
                        tests.append("1.3.6.1.2.1.1" in out or "SNMPv2-MIB::sys" in out);labels.append(host)
                return self.ratio(aid,tests,"SNMPv3 authPriv polling from both permitted managers",labels=labels)
            except Exception as exc:return self.skip(aid,f"SSH/snmpwalk недоступен: {exc}")
        if aid=="G1":
            try:
                targets=[LOOPBACKS[d] for d in ["IR1","IR3","BR1"]]+[MGMT["AS1"][1],MGMT["AS3"][1]]
                return self.ratio(aid,[self.linux_tcp_probe("SVR2",ip,22) for ip in targets],"Positive SSH policy from JUDGE-SRV; user negative tests remain in manual instruction",labels=["SVR2"]*len(targets))
            except Exception as exc:return self.skip(aid,f"SVR2 SSH console недоступна: {exc}")
        if aid=="G2":
            try:
                targets=[LOOPBACKS[d] for d in ["IR1","CR1","DS1","IR3","BR1"]]
                return self.ratio(aid,[not self.linux_tcp_probe("SVR2",ip,23) for ip in targets],"JUDGE-SRV TCP/23 negative tests",labels=["SVR2"]*len(targets))
            except Exception as exc:return self.skip(aid,f"SVR2 SSH console недоступна: {exc}")
        if aid=="G13":
            tests=[]; labels=[]; notes=[]; leases={}
            dhcp_expected={
                "PC1":("10.80.10.","10.80.10.1"),
                "PC2":("10.80.40.","10.80.40.1"),
                "PC3":("10.82.10.","10.82.10.1"),
                "PC4":("10.83.10.","10.83.10.1"),
            }
            # Four independent DHCP acceptance rows.
            for pc,(network,gateway) in dhcp_expected.items():
                try:
                    _,ip,prefix,gw,dns=self.vpcs_dhcp_lease(pc,60)
                    leases[pc]=ip
                    last=int(ip.rsplit(".",1)[1]) if ip.startswith(network) else -1
                    ok=100<=last<=199 and prefix==24 and gw==gateway and dns=="10.81.130.10"
                    notes.append(f"{pc} DHCP={'OK' if ok else 'FAIL'} ({ip}/{prefix}, gw {gw}, DNS {dns})")
                except Exception as exc:
                    ok=False;leases[pc]="";notes.append(f"{pc} DHCP=ERROR ({exc})")
                tests.append(ok);labels.append(pc)
            # DNS acceptance: every client must resolve all three required names.
            dns_rows=[("ops.c2.skill39.local","10.81.130.10"),
                      ("judge.c2.skill39.local","10.81.150.10"),
                      ("internet-test.c2.skill39.local","198.51.100.100")]
            dns_checks=[]
            try:
                for pc in dhcp_expected:
                    for name,expected in dns_rows:
                        _,out=self.vpcs_ping(pc,name,1)
                        dns_checks.append(expected in out)
                dns_ok=all(dns_checks)
            except Exception as exc:
                dns_ok=False;notes.append(f"DNS=ERROR ({exc})")
            tests.append(dns_ok);labels.append("PC1");notes.append(f"DNS matrix={'OK' if dns_ok else 'FAIL'}")
            # Positive user/inter-site/OPS/Internet matrix.
            allowed=[]
            allowed_matrix={
                "PC1":[leases.get("PC3"),leases.get("PC4"),"10.81.130.10","198.51.100.100"],
                "PC3":[leases.get("PC1"),"10.81.130.10","198.51.100.100"],
                "PC4":[leases.get("PC1"),"10.81.130.10","198.51.100.100"],
            }
            try:
                for pc,targets in allowed_matrix.items():
                    for target in targets:allowed.append(bool(target) and self.vpcs_ping(pc,target,2)[0])
                allowed_ok=all(allowed)
            except Exception as exc:
                allowed_ok=False;notes.append(f"allowed connectivity=ERROR ({exc})")
            tests.append(allowed_ok);labels.append("PC1");notes.append(f"allowed connectivity={'OK' if allowed_ok else 'FAIL'}")
            # Guest PC2 must not reach protected user/management/judge destinations.
            denied_targets=[leases.get("PC1"),leases.get("PC3"),leases.get("PC4"),"10.81.150.10","10.80.50.21"]
            try:
                denied=[bool(t) and not self.vpcs_ping("PC2",t,2)[0] for t in denied_targets]
                isolation_ok=all(denied)
            except Exception as exc:
                isolation_ok=False;notes.append(f"guest isolation=ERROR ({exc})")
            tests.append(isolation_ok);labels.append("PC2");notes.append(f"guest isolation={'OK' if isolation_ok else 'FAIL'}")
            # JUDGE-SRV: SSH is open and Telnet is closed on representative roles.
            policy_targets=[LOOPBACKS["IR1"],LOOPBACKS["DS1"],MGMT["AS1"][1],LOOPBACKS["IR3"],LOOPBACKS["BR1"]]
            try:
                policy_checks=[]
                for ip in policy_targets:
                    ssh_open=self.linux_tcp_probe("SVR2",ip,22)
                    telnet_closed=not self.linux_tcp_probe("SVR2",ip,23)
                    policy_checks.append(ssh_open and telnet_closed)
                ssh_policy=all(policy_checks)
            except Exception as exc:
                ssh_policy=False;notes.append(f"SSH/Telnet policy=ERROR ({exc})")
            tests.append(ssh_policy);labels.append("SVR2");notes.append(f"SSH/Telnet policy={'OK' if ssh_policy else 'FAIL'}")
            # Both permitted managers must complete an authPriv walk to each role.
            snmp_template="snmpwalk -v3 -l authPriv -u c2snmp -a SHA -A 'C2Auth@2026' -x AES -X 'C2Priv@2026' -t 3 -r 0 {ip} 1.3.6.1.2.1.1"
            snmp_checks=[]
            try:
                for host in ["SVR1","SVR2"]:
                    for ip in policy_targets:
                        out=self.host_cmd(host,snmp_template.format(ip=ip),timeout=10)
                        snmp_checks.append("1.3.6.1.2.1.1" in out or "SNMPv2-MIB::sys" in out)
                snmp_ok=all(snmp_checks)
            except Exception as exc:
                snmp_ok=False;notes.append(f"SNMPv3=ERROR ({exc})")
            tests.append(snmp_ok);labels.append("SVR1");notes.append(f"SNMPv3 managers={'OK' if snmp_ok else 'FAIL'}")
            return self.ratio(aid,tests,"; ".join(notes),labels=labels)
        if aid in {"G6","G11"}: return self.skip(aid,"VPCS не предоставляет безопасный SSH/SNMP client для negative test; используйте инструкцию ниже")
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
    p.add_argument("--skip-disruptive",action="store_true",help="не выполнять shutdown/no shutdown в failover-аспектах")
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
        scorer=Scorer(consoles,creds,disruptive=not a.skip_disruptive)
        try: scorer.connect(); scorer.run(start,pause=not a.no_pause); scorer.report()
        finally: scorer.close()
    finally:
        try: logout(url)
        except Exception: pass
if __name__=="__main__": main()
