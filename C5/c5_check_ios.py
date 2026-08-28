#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only PNETLab scorer for WSC2026 Training C5.

The console and report framework is inherited from the proven C3/C4 checker.
Only operational show commands and the seven explicitly authorised targeted
configuration checks from the official C5 marking scheme are used.  Expert
Tests T1-T8 are never triggered by this program.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import ipaddress
import json
from pathlib import Path
import re
import shlex
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "C3"))
import c3_check_ios as c3

base = c3.base
C5_CHECKER_VERSION = "2026-08-28.16"
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

CISCO = ["ISP1", "IR1", "IR2", "CR1", "CR2", "DS1", "DS2", "AS1",
         "AS2", "IR3", "DS3", "DS4", "BR1", "AS3", "BR2", "AS4"]
ROUTERS = ["IR1", "IR2", "CR1", "CR2", "DS1", "DS2", "IR3", "DS3",
           "DS4", "BR1", "BR2"]
HQ = ["IR1", "IR2", "CR1", "CR2", "DS1", "DS2"]
DC = ["IR3", "DS3", "DS4"]
L3 = ["ISP1"] + ROUTERS
EDGES = ["IR1", "IR2", "IR3", "BR1", "BR2"]
SWITCHES = ["DS1", "DS2", "AS1", "AS2", "DS3", "DS4", "AS3", "AS4"]
ACCESS = ["AS1", "AS2", "AS3", "AS4"]

LOOP4 = {
    "IR1":"10.110.255.1", "IR2":"10.110.255.2", "CR1":"10.110.255.11",
    "CR2":"10.110.255.12", "DS1":"10.110.255.21", "DS2":"10.110.255.22",
    "IR3":"10.111.255.1", "DS3":"10.111.255.11", "DS4":"10.111.255.12",
    "BR1":"10.112.255.1", "BR2":"10.113.255.1"}
LOOP6 = {d: f"2001:db8:{'110' if d in HQ else '111' if d in DC else '112' if d=='BR1' else '113'}:ffff::{LOOP4[d].split('.')[-1]}"
         for d in ROUTERS}
WAN4 = {
    "IR1":("GigabitEthernet0/3", "203.0.113.102", "203.0.113.101"),
    "IR2":("GigabitEthernet0/3", "203.0.113.106", "203.0.113.105"),
    "IR3":("GigabitEthernet0/3", "203.0.113.110", "203.0.113.109"),
    "BR1":("GigabitEthernet0/0", "203.0.113.114", "203.0.113.113"),
    "BR2":("GigabitEthernet0/0", "203.0.113.118", "203.0.113.117")}
ISP_IF = {"IR1":"GigabitEthernet0/0", "IR2":"GigabitEthernet0/1",
          "IR3":"GigabitEthernet0/2", "BR1":"GigabitEthernet0/3",
          "BR2":"GigabitEthernet0/4"}
PEER6 = {d: f"2001:db8:ffff:{i}::1" for i,d in enumerate(EDGES,1)}
EDGE6 = {d: f"2001:db8:ffff:{i}::2" for i,d in enumerate(EDGES,1)}
ASNS = {"IR1":65450, "IR2":65450, "IR3":65460, "BR1":65471, "BR2":65472}
SUMMARY4 = {"IR1":"10.110.0.0/16", "IR2":"10.110.0.0/16",
            "IR3":"10.111.0.0/16", "BR1":"10.112.0.0/16", "BR2":"10.113.0.0/16"}
SUMMARY6 = {d: f"2001:db8:{SUMMARY4[d].split('.')[1]}::/48" for d in EDGES}
MGMT4 = {"ISP1":"198.51.100.200", **LOOP4,
         "AS1":"10.110.50.21", "AS2":"10.110.50.22",
         "AS3":"10.112.50.21", "AS4":"10.113.50.21"}
VLANS = {"DS1":{10,40,50,998,999}, "DS2":{10,40,50,998,999},
         "AS1":{10,40,50,998,999}, "AS2":{10,40,50,998,999},
         "DS3":{130,150,998,999}, "DS4":{130,150,998,999},
         "AS3":{110,150,998,999}, "AS4":{210,250,998,999}}
USED_SWITCH_PORTS = {
    "DS1":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2",
           "GigabitEthernet0/3","GigabitEthernet1/0","GigabitEthernet1/1"},
    "DS2":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2",
           "GigabitEthernet0/3","GigabitEthernet1/0","GigabitEthernet1/1"},
    "AS1":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2"},
    "AS2":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2"},
    "DS3":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2"},
    "DS4":{"GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2"},
    "AS3":{"GigabitEthernet0/0","GigabitEthernet0/1"},
    "AS4":{"GigabitEthernet0/0","GigabitEthernet0/1"},
}
PC_PORTS = {"AS1":"GigabitEthernet0/2", "AS2":"GigabitEthernet0/2",
            "AS3":"GigabitEthernet0/1", "AS4":"GigabitEthernet0/1"}

ROUTED4 = {
 "IR1":["10.110.0.1","10.110.0.5","10.110.0.17"],
 "IR2":["10.110.0.9","10.110.0.13","10.110.0.18"],
 "CR1":["10.110.0.2","10.110.0.10","10.110.0.21","10.110.0.25","10.110.0.29"],
 "CR2":["10.110.0.6","10.110.0.14","10.110.0.22","10.110.0.33","10.110.0.37"],
 "DS1":["10.110.0.26","10.110.0.34"], "DS2":["10.110.0.30","10.110.0.38"],
 "IR3":["10.111.0.1","10.111.0.5"], "DS3":["10.111.0.2"], "DS4":["10.111.0.6"]}
SVI4 = {"DS1":["10.110.10.11","10.110.40.11","10.110.50.11"],
        "DS2":["10.110.10.12","10.110.40.12","10.110.50.12"],
        "DS3":["10.111.130.11","10.111.150.11"],
        "DS4":["10.111.130.12","10.111.150.12"]}
BRANCH4 = {"BR1":["10.112.10.1","10.112.50.1"],
           "BR2":["10.113.10.1","10.113.50.1"]}

ASPECTS=[]; ROWS={}
with open(HERE/"c5_criteria.tsv", encoding="utf-8-sig") as criteria:
    next(criteria)
    for line in criteria:
        cols=line.rstrip("\n").split("\t")
        aspect=base.Aspect(int(cols[0]), cols[1], float(cols[5]), cols[3])
        ASPECTS.append(aspect); ROWS[aspect.id]=cols
BY_ID={a.id:a for a in ASPECTS}
base.ASPECTS,base.BY_ID=ASPECTS,BY_ID

EXPERT = {
 "C12":"T6A: отключить только WAN IR2; default LSA IR2 v4 должен исчезнуть.",
 "C13":"T6B: отключить WAN IR3; default LSA IR3 v4 должен исчезнуть.",
 "C15":"T6A: default LSA IR2 v6 должен исчезнуть при потере local eBGP.",
 "C16":"T6B: default LSA IR3 v6 должен исчезнуть при потере local eBGP.",
 "D7":"T4: выполнить GM1-GM12 из Acceptance Matrix на PC2.",
 "D9":"T3: дополнить normal-state проверку spoofed-source тестом на BR1.",
 "D14":"T1: rogue DHCP OFFER с PC3, проверить рост drop counter.",
 "D16":"T2: forged ARP с PC3, проверить рост DAI drop counter.",
 "F7":"T7: создать один безопасный event и подтвердить новую запись SVR1.",
 "G4":"T5: shutdown одного member Po12, probes, затем восстановление.",
 "G5":"T6: shutdown WAN IR1; оба conditional default должны исчезнуть.",
 "G6":"T6: подтвердить dual-stack failover через IR2 не более 30 секунд.",
 "G7":"T6: восстановить IR1 и primary path не более 30 секунд.",
 "G8":"T8: полный final restore, convergence, save и отсутствие err-disable."}

class Scorer(c3.Scorer):
    """C5 evaluator. Every automatic action is read-only."""

    @staticmethod
    def has(text,*patterns):
        return all(re.search(p,text,re.I|re.M) for p in patterns)

    @staticmethod
    def ipv6_has(text,address):
        try: wanted=ipaddress.IPv6Address(address)
        except ValueError:return False
        for token in re.findall(r"[0-9a-fA-F:]{3,}",text):
            try:
                if ipaddress.IPv6Address(token.strip("/"))==wanted:return True
            except ValueError:pass
        return wanted.compressed.lower() in text.lower()

    @staticmethod
    def established(text,peer,asn):
        for line in text.replace("\r","").splitlines():
            fields=line.split()
            if len(fields)>=3 and fields[0].lower()==peer.lower() and fields[2]==str(asn):
                return fields[-1].isdigit()
        return False

    @staticmethod
    def rsa_2048(text):
        """Recognize a 2048-bit IOS RSA general-purpose public key.

        Some IOSv releases do not print ``Modulus Size: 2048``.  Their
        SubjectPublicKeyInfo DER starts with 30 82 01 22 (shown by IOS as
        30820122) for an RSA-2048 public key.  The temporary ``.server`` key
        has a different, shorter DER header and is deliberately ignored.
        """
        explicit=bool(re.search(
            r"(?:Modulus(?: Size)?|Key size|RSA key size)\s*[:=]?\s*2048\s*(?:bits)?",
            text,re.I))
        blocks=re.split(r"(?=^Key name:)",text,flags=re.I|re.M)
        der_2048=any(
            not re.search(r"(?mi)^Temporary key\s*$",block)
            and re.search(r"(?mi)^\s*30820122\b",block)
            for block in blocks)
        return explicit or der_2048

    def filtered_command(self,command):
        # Do not add a second pipe to the seven exact Restricted Checks.
        if "|" in command:return command
        filters=[
          (r"^show version$",r"uptime is|Cisco IOS Software"),
          (r"^show ip interface brief$",r"up|down|administratively"),
          (r"^show ipv6 interface brief$",r"up|down|2001:|Loopback|Vlan|Gigabit"),
          (r"^show ip ospf neighbor$",r"Neighbor ID|FULL"),
          (r"^show ipv6 ospf neighbor$",r"Neighbor ID|FULL"),
          (r"^show interfaces status$",r"connected|notconnect|disabled|Gi"),
          (r"^show bgp ipv4 unicast summary$",r"BGP router identifier|Neighbor|203\.0\.113"),
          (r"^show bgp ipv6 unicast summary$",r"BGP router identifier|Neighbor|2001:db8"),
        ]
        for pattern,include in filters:
            if re.match(pattern,command,re.I):return f"{command} | include {include}"
        return command

    def expected(self,aid):return ROWS[aid][4]

    @staticmethod
    def print_expected(aspect):
        row=ROWS[aspect.id]
        print(f"{base.CYAN}Ожидаемый результат:{base.NC}")
        # Requirement is the authoritative value-oriented statement from the
        # marking scheme.  Print it first and split compound requirements so
        # exact addresses, priorities, metrics and names are not hidden after
        # a vague title such as "uses the required parameters".
        requirement=str(row[4]).strip()
        parts=[part.strip() for part in re.split(r";\s*",requirement) if part.strip()]
        if len(parts)>1:
            for part in parts:print(f"  - {part}")
        else:
            print(f"  {requirement}")
        print(f"  Аспект: {aspect.title}")
        print(f"  Максимальный балл: {aspect.mark:.3f}")
        print(f"{base.GREEN}Методика / готовые команды:{base.NC}")
        print(f"  {row[7]}")
        if aspect.id in EXPERT:
            print(f"  {EXPERT[aspect.id]}")

    def ratio(self,aid,tests,details="",labels=None):
        values=[bool(x) for x in tests]; labels=list(labels or [])
        full=[labels[i] if i<len(labels) else f"Подпроверка {i+1}" for i in range(len(values))]
        passed=sum(values)
        if 0<passed<len(values):
            breakdown="\n".join(f"[{'PASS' if ok else 'FAIL'}] {label}" for ok,label in zip(values,full))
            details=(str(details).strip()+"\n" if str(details).strip() else "")+breakdown
        return super().ratio(aid,values,details=details,labels=full)

    def print_device_results(self,values,explicit_labels=None):
        """Print a verdict calculated only from checks belonging to a device.

        The inherited C2/C3 formatter falls back to the aspect-wide fraction
        when commands and subchecks have different cardinality.  Addressing
        aspects have many checks per one device command, so that fallback made
        every device display e.g. 41/43.  C5 labels every subcheck with its
        device and groups those labels explicitly here.
        """
        if not self.command_records:return
        values=[bool(v) for v in values]
        labels=list(explicit_labels or [])
        known=CISCO+["PC1","PC2","PC3","PC4","SVR1","SVR2"]
        grouped=defaultdict(list)
        unassigned=[]
        for index,value in enumerate(values):
            label=str(labels[index]) if index<len(labels) else ""
            owner=next((dev for dev in known if re.match(
                rf"^{re.escape(dev)}(?:\b|\s*[:#])",label,re.I)),None)
            if owner:grouped[owner].append(value)
            else:unassigned.append(value)

        records=defaultdict(list);order=[]
        for dev,command,output in self.command_records:
            records[dev].append((command,output))
            if dev not in order:order.append(dev)

        # A single-device aspect owns any generic labels (for example the
        # three ISP1 integrity checks in C24).  Never spread generic values
        # over several devices because that recreates the misleading total.
        if len(order)==1 and unassigned:grouped[order[0]].extend(unassigned)

        print(f"\n{base.CYAN}Информация и результаты по устройствам:{base.NC}",flush=True)
        for dev in order:
            print(f"\n{base.BLUE}--- {dev} ---{base.NC}",flush=True)
            for command,output in records[dev]:
                # Commands already prefixed with a Linux prompt describe a
                # probe source (for example SVR2), not an IOS command entered
                # on the target device represented by this evidence block.
                prompt=(command if re.match(r"^[A-Za-z0-9_-]+\$\s",command)
                        else f"{dev}# {command}")
                print(f"{base.BLUE}{prompt}{base.NC}",flush=True)
                print(output or "(пустой вывод)",flush=True)
            own=grouped.get(dev,[])
            if own:
                passed=sum(own);total=len(own)
                status="PASS" if passed==total else "PART" if passed else "FAIL"
                color={"PASS":base.GREEN,"PART":base.PURPLE,"FAIL":base.RED}[status]
                print(f"{color}>>> {dev}: {status} ({passed}/{total}){base.NC}",flush=True)
            else:
                print(f"{base.CYAN}>>> {dev}: EVIDENCE ONLY — отдельный результат к устройству не привязан{base.NC}",flush=True)

    def all_state(self,aid,devices,command,predicate):
        tests=[];labels=[]
        for dev in devices:
            out=self.cmd(dev,command)
            try:ok=predicate(dev,out)
            except Exception:ok=False
            tests.append(ok);labels.append(dev)
        return self.ratio(aid,tests,labels=labels)

    def restricted_output(self,dev,command,redact_patterns=()):
        """Run an authorised targeted check without recording secret material."""
        session=self.sessions.get(dev)
        if session is None:
            self.record_command(dev,command,"(device unavailable)")
            return ""
        raw=session.exec(command)
        output=base.format_ios_output(raw,command)
        safe=output
        for pattern,replacement in redact_patterns:
            safe=re.sub(pattern,replacement,safe,flags=re.I|re.M)
        self.record_command(dev,command,safe)
        return output

    def address_set(self,aid,expected,ipv6=False):
        tests=[];labels=[]
        command="show ipv6 interface brief" if ipv6 else "show ip interface brief"
        for dev,addresses in expected.items():
            out=self.cmd(dev,command)
            for address in addresses:
                ok=self.ipv6_has(out,address) if ipv6 else bool(re.search(rf"\b{re.escape(address)}\b",out))
                tests.append(ok);labels.append(f"{dev}: {address}")
        return self.ratio(aid,tests,labels=labels)

    @staticmethod
    def vlan_ids(text):
        return {int(x) for x in re.findall(r"(?m)^\s*(\d{1,4})\s+\S+\s+(?:active|act/unsup)",text,re.I)}

    @staticmethod
    def mst_is_root(text,instance):
        """Recognize root wording used by classic and IOSvL2 MST output."""
        return bool(re.search(
            rf"This bridge is (?:the )?root|Root\s+this switch for MST{instance}\b",
            text,re.I))

    @staticmethod
    def mst_base_priority(text):
        """Return the base bridge priority, excluding the MST sysid."""
        match=re.search(
            r"(?mi)^Bridge\s+(?:ID\s+)?address\s+\S+\s+priority\s+"
            r"\d+\s+\((\d+)\s+sysid\s+\d+\)",text)
        return int(match.group(1)) if match else None

    def check(self,aid):
        # A — blank-start baseline and addressing
        if aid=="A1":
            return self.all_state(aid,CISCO,"show version",lambda d,o:bool(re.search(rf"(?mi)^{re.escape(d)}\s+uptime is",o)))
        if aid=="A2":
            tests=[];labels=[]
            for d in CISCO:
                ssh=self.cmd(d,"show ip ssh")
                # Keep the DER header needed to infer key size but omit the
                # many lines of public-key material from the report.
                keys=self.cmd(
                    d,"show crypto key mypubkey rsa | include Key name:|Key type:|Temporary key|30820122")
                hosts=self.cmd(d,"show hosts")
                restricted=self.restricted_output(
                    d,"show running-config | include ip domain name|username netadmin",
                    [(r"(?m)^(username netadmin privilege 15)(?:\s+.*)?$",r"\1 <secret redacted>")])
                domain_ok=bool(
                    re.search(r"ip domain(?: name|-name)\s+c5\.skill39\.local",restricted,re.I)
                    or re.search(r"Default domain(?: is|:)?\s+c5\.skill39\.local",hosts,re.I))
                user_ok=bool(re.search(r"username netadmin privilege 15\b",restricted,re.I))
                ok=(self.has(ssh,r"SSH Enabled.*version 2") and
                    self.rsa_2048(keys) and domain_ok and user_ok)
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,"R6 применяется только к domain/user privilege.",labels)
        if aid=="A3":
            tests=[];labels=[]
            for d in CISCO:
                clock=self.cmd(d,"show clock detail")
                # IOS trains differ in whether they retain the optional zero
                # minutes field as `clock timezone ALMT 5 0`.
                cfg=self.cmd(d,"show running-config | include ^no ip domain-lookup$|^service timestamps log datetime msec$|^clock timezone ALMT 5")
                timezone_ok=bool(re.search(
                    r"(?m)^clock timezone ALMT 5(?: 0)?\s*$",cfg,re.I))
                tests.append("ALMT" in clock and timezone_ok and self.has(
                    cfg,r"(?m)^no ip domain-lookup\s*$",
                    r"(?m)^service timestamps log datetime msec\s*$"));labels.append(d)
            return self.ratio(aid,tests,"R1: exact targeted baseline lines.",labels)
        if aid=="A4":
            tests=[];labels=[]
            for d in L3:
                tests.append(bool(self.cmd(d,"show ipv6 route").strip()));labels.append(f"{d}: IPv6 routing")
            for d in ["DS1","DS2","DS3","DS4"]:
                tests.append(bool(self.cmd(d,"show ip route").strip()));labels.append(f"{d}: IPv4 routing")
            for d in ACCESS:
                out=self.cmd(d,"show ip route")
                tests.append(not re.search(r"Gateway of last resort|Codes:.*connected",out,re.I|re.S));labels.append(f"{d}: L2 role")
            return self.ratio(aid,tests,labels=labels)
        if aid=="A5":
            expected={"ISP1":["203.0.113.101","203.0.113.105","203.0.113.109","203.0.113.113","203.0.113.117"]}
            expected.update({d:[v[1]] for d,v in WAN4.items()})
            return self.address_set(aid,expected)
        if aid=="A6":
            expected={"ISP1":[f"2001:db8:ffff:{i}::1" for i in range(1,6)]}
            expected.update({d:[EDGE6[d]] for d in EDGES})
            return self.address_set(aid,expected,True)
        if aid=="A7":
            expected={d:[LOOP4[d]] for d in ROUTERS};expected["ISP1"]=["198.51.100.200"]
            tests=[];labels=[]
            for d,ips in expected.items():
                out4=self.cmd(d,"show ip interface brief | include Loopback")
                for ip in ips:tests.append(ip in out4);labels.append(f"{d}: {ip}")
            for d in ROUTERS:
                # IPv6 addresses are printed on indented lines below the
                # interface heading; `include Loopback` drops those lines.
                out6=self.cmd(d,"show ipv6 interface brief | section Loopback")
                tests.append(self.ipv6_has(out6,LOOP6[d]));labels.append(f"{d}: {LOOP6[d]}")
            out6=self.cmd("ISP1","show ipv6 interface brief | section Loopback")
            tests.append(self.ipv6_has(out6,"2001:db8:ffff::200"));labels.append("ISP1: Loopback200")
            tests.append(not re.search(r"(?mi)^Loopback0\s",self.cmd("ISP1","show ip interface brief")));labels.append("ISP1: Loopback0 absent")
            return self.ratio(aid,tests,labels=labels)
        if aid=="A8":return self.address_set(aid,{d:ROUTED4[d] for d in HQ})
        if aid=="A9":return self.address_set(aid,{d:ROUTED4.get(d,[])+SVI4.get(d,[]) for d in DC+["DS1","DS2"]})
        if aid=="A10":
            expected={d:[LOOP6[d]] for d in HQ+DC}
            for d in HQ:
                for ip in ROUTED4[d]:
                    octet=int(ip.split('.')[-1]); net=(octet-1)//4+1
                    # Address tables use stable ::1/::2 sides; verify every required prefix.
                    expected[d].append(f"2001:db8:110:{net:x}::{'1' if octet%4==1 else '2'}")
            expected["IR3"] += ["2001:db8:111:1::1","2001:db8:111:2::1"]
            expected["DS3"] += ["2001:db8:111:1::2","2001:db8:111:130::11","2001:db8:111:150::11"]
            expected["DS4"] += ["2001:db8:111:2::2","2001:db8:111:130::12","2001:db8:111:150::12"]
            expected["DS1"] += ["2001:db8:110:10::11","2001:db8:110:40::11","2001:db8:110:50::11"]
            expected["DS2"] += ["2001:db8:110:10::12","2001:db8:110:40::12","2001:db8:110:50::12"]
            return self.address_set(aid,expected,True)
        if aid=="A11":
            expected={"BR1":BRANCH4["BR1"],"BR2":BRANCH4["BR2"],
                      "AS1":["10.110.50.21"],"AS2":["10.110.50.22"],
                      "AS3":["10.112.50.21"],"AS4":["10.113.50.21"]}
            return self.address_set(aid,expected)
        if aid=="A12":
            tests=[];labels=[]
            for d,iface in (("IR2","GigabitEthernet0/4"),("IR3","GigabitEthernet0/2")):
                brief=self.cmd(d,"show ip interface brief")
                tests.append(bool(re.search(rf"(?:{iface}|Gi0/[24]).*unassigned.*administratively down",brief,re.I)));labels.append(f"{d} bypass down/unnumbered")
            for d in CISCO:
                policy=self.cmd(d,"show ip policy")
                tunnel=self.cmd(d,"show ip interface brief | include Tunnel")
                diff=self.cmd(d,"show archive config differences nvram:startup-config system:running-config")
                tests.append(not re.search(r"route-map\s+\S+",policy,re.I) and not tunnel.strip());labels.append(f"{d}: no PBR/tunnel")
                tests.append("No changes were found" in diff or not re.search(r"^[+-]",diff,re.M));labels.append(f"{d}: saved")
            for d in EDGES:
                cfg=self.cmd(d,"show startup-config | include ^ip route|^ipv6 route")
                allowed=SUMMARY4[d].split('/')[0] in cfg and SUMMARY6[d].split('/')[0].lower() in cfg.lower() and "254" in cfg
                tests.append(allowed);labels.append(f"{d}: R2 static whitelist")
            return self.ratio(aid,tests,labels=labels)

        # B — switching, MST, LACP and HSRP
        if aid=="B1":return self.all_state(aid,SWITCHES,"show vlan brief",lambda d,o:VLANS[d].issubset(self.vlan_ids(o)))
        if aid=="B2":return self.all_state(aid,SWITCHES,"show vtp status",lambda d,o:bool(re.search(r"Operating Mode\s*:?[ ]+Transparent",o,re.I)))
        if aid=="B3":
            tests=[];labels=[]
            for d in SWITCHES:
                out=self.cmd(d,"show interfaces status")
                spare=[];incorrect=[]
                for line in out.splitlines():
                    match=re.match(r"^\s*((?:Gi|GigabitEthernet)\S+)\s+(.+)$",line,re.I)
                    if not match:continue
                    raw=match.group(1)
                    port=("GigabitEthernet"+raw[2:]) if re.match(r"(?i)^Gi\d",raw) else raw
                    if port in USED_SWITCH_PORTS[d]:continue
                    remainder=match.group(2)
                    spare.append(port)
                    # IOSvL2 column order is Status then Vlan:
                    # `Gi0/3  disabled  998`, not `998 ... disabled`.
                    if not (re.search(r"\bdisabled\b",remainder,re.I)
                            and re.search(r"\b998\b",remainder)):
                        incorrect.append(f"{port} ({remainder.strip()})")
                ok=bool(spare) and not incorrect
                tests.append(ok)
                state=("all spare ports disabled/VLAN998" if ok else
                       "incorrect: "+", ".join(incorrect) if incorrect else
                       "spare ports not parsed")
                labels.append(f"{d}: {state}")
            return self.ratio(aid,tests,labels=labels)
        if aid in {"B4","B5"}:
            tests=[];labels=[]
            for d in SWITCHES:
                out=self.cmd(d,"show interfaces trunk")
                native=bool(re.search(r"trunking\s+999",out,re.I))
                needed={10,40,50,999} if d in {"DS1","DS2","AS1","AS2"} else {130,150,999} if d in {"DS3","DS4"} else {110,150,999} if d=="AS3" else {210,250,999}
                vlan_ok=all(str(v) in out for v in needed)
                tests.append(native if aid=="B4" else vlan_ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid in {"B6","B7"}:
            tests=[];labels=[]
            for d in ["DS1","DS2"]:
                ec=self.cmd(d,"show etherchannel summary");tr=self.cmd(d,"show interfaces trunk")
                ok=self.has(ec,r"Po12\(SU\)",r"LACP",r"\(P\).+\(P\)")
                if aid=="B7":ok=ok and self.has(tr,r"Po12",r"999",r"10,40,50,999")
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid in {"B8","B9","B10"}:
            targets={"B8":[("AS1",10),("AS2",40)],"B9":[("DS3",130),("DS4",150)],"B10":[("AS3",110),("AS4",210)]}[aid]
            return self.ratio(aid,[bool(re.search(rf"(?m)^\s*{v}\s+\S+\s+active.+Gi",self.cmd(d,"show vlan brief"),re.I)) for d,v in targets],labels=[d for d,_ in targets])
        if aid=="B11":
            return self.ratio(aid,[self.linux_ping("SVR2",MGMT4[d],count=2) for d in ACCESS],labels=ACCESS)
        if aid=="B12":
            return self.all_state(aid,["DS1","DS2","AS1","AS2"],"show spanning-tree mst configuration",lambda d,o:self.has(o,r"Name\s+\[?C5-MST",r"Revision\s+5",r"1\s+10,50",r"2\s+40"))
        if aid=="B13":
            tests=[];labels=[]
            design={"DS1":(1,2),"DS2":(2,1)}
            for d,(primary,secondary) in design.items():
                primary_out=self.cmd(d,f"show spanning-tree mst {primary}")
                secondary_out=self.cmd(d,f"show spanning-tree mst {secondary}")
                primary_ok=(self.mst_is_root(primary_out,primary)
                            and self.mst_base_priority(primary_out)==24576)
                secondary_ok=(not self.mst_is_root(secondary_out,secondary)
                              and self.mst_base_priority(secondary_out)==28672)
                tests.extend([primary_ok,secondary_ok])
                labels.extend([
                    f"{d}: MST{primary} primary/root, base priority 24576",
                    f"{d}: MST{secondary} secondary, base priority 28672"])
            return self.ratio(aid,tests,labels=labels)
        if aid=="B14":
            tests=[];labels=[]
            for d in ["DS3","DS4"]:
                cfg=self.cmd(d,"show spanning-tree mst configuration")
                state=self.cmd(d,"show spanning-tree mst 3")
                region_ok=self.has(
                    cfg,r"Name\s+\[?C5-DC\]?",r"Revision\s+5",
                    r"(?m)^\s*3\s+130,150\s*$")
                if d=="DS3":
                    role_ok=(self.mst_is_root(state,3)
                             and self.mst_base_priority(state)==24576)
                    role_label="MST3 primary/root, base priority 24576"
                else:
                    role_ok=(not self.mst_is_root(state,3)
                             and self.mst_base_priority(state)==28672)
                    role_label="MST3 secondary, base priority 28672"
                tests.extend([region_ok,role_ok])
                labels.extend([f"{d}: region C5-DC revision 5, MST3 VLAN130,150",
                               f"{d}: {role_label}"])
            return self.ratio(aid,tests,labels=labels)
        if aid in {"B15","B16"}:
            vlans=[10,40,50] if aid=="B15" else [130,150]; devices=["DS1","DS2"] if aid=="B15" else ["DS3","DS4"]
            active={10:"DS1",40:"DS2",50:"DS1",130:"DS3",150:"DS3"};tests=[];labels=[]
            for vlan in vlans:
                for d in devices:
                    out=self.cmd(d,f"show standby Vlan{vlan}")
                    role="Active" if d==active[vlan] else "Standby";prio=120 if role=="Active" else 100
                    tests.append(self.has(out,rf"State is {role}",rf"Priority {prio}",r"Preemption enabled",rf"Virtual IP address is .*\.{1}"));labels.append(f"{d} Vlan{vlan}")
            return self.ratio(aid,tests,labels=labels)

        # C — OSPFv2/OSPFv3 and dual-stack eBGP
        if aid in {"C1","C7"}:
            devices=HQ if aid=="C1" else HQ+DC; command="show ip ospf" if aid=="C1" else "show ipv6 ospf"
            return self.all_state(aid,devices,command,lambda d,o:"50" in o and LOOP4[d] in o)
        if aid in {"C2","C5","C8"}:
            devices=HQ if aid=="C2" else DC+["BR1","BR2"] if aid=="C5" else HQ+DC
            command="show ip ospf interface brief" if aid!="C8" else "show ipv6 ospf interface brief"
            tests=[];labels=[]
            for d in devices:
                out=self.cmd(d,command)
                if aid=="C5" and d in {"BR1","BR2"}:ok=not out.strip() or "not enabled" in out.lower()
                else:ok=bool(re.search(r"(?:Gi|GigabitEthernet).+\b0\b",out,re.I)) and "Loopback0" not in out
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="C3":
            return self.all_state(aid,HQ+DC,"show ip ospf interface brief",lambda d,o:not re.search(r"(?:BROADCAST|DR|BDR)",o,re.I) and bool(re.search(r"P2P|POINT_TO_POINT",o,re.I)))
        if aid in {"C4","C6","C9","C10"}:
            devices=HQ if aid in {"C4","C9"} else DC
            command="show ipv6 ospf neighbor" if aid in {"C9","C10"} else "show ip ospf neighbor"
            minimum={"IR1":3,"IR2":3,"CR1":5,"CR2":5,"DS1":2,"DS2":2,"IR3":2,"DS3":1,"DS4":1}
            return self.all_state(aid,devices,command,lambda d,o:len(re.findall(r"\bFULL(?:/\S+)?\b",o,re.I))>=minimum[d])
        if aid in {"C11","C12","C13"}:
            dev={"C11":"IR1","C12":"IR2","C13":"IR3"}[aid];metric={"C11":10,"C12":100,"C13":20}[aid]
            pl=self.cmd(dev,"show ip prefix-list");rm=self.cmd(dev,"show route-map");proto=self.cmd(dev,"show ip protocols")
            lsa=self.cmd(dev,"show ip ospf database external 0.0.0.0")
            normal=self.has(pl,r"0\.0\.0\.0/0") and self.has(rm,r"permit") and self.has(proto,r"bgp") and self.has(lsa,rf"Metric:\s+{metric}\b")
            if aid in EXPERT:return self.ratio(aid,[normal,False],"Normal-state evidence + обязательный Expert Test; checker не изменяет WAN.",[f"{dev}: normal state",EXPERT[aid]])
            return self.ratio(aid,[normal],labels=[dev])
        if aid in {"C14","C15","C16"}:
            dev={"C14":"IR1","C15":"IR2","C16":"IR3"}[aid];metric={"C14":10,"C15":100,"C16":20}[aid]
            # IOSv uses the OSPFv3 database type `external`; the
            # `external-prefix` spelling exists on other Cisco trains only.
            evidence=self.cmd(dev,"show ipv6 prefix-list")+self.cmd(dev,"show route-map")+self.cmd(dev,"show ipv6 protocols")+self.cmd(dev,"show ipv6 ospf database external")
            normal=self.has(evidence,r"::/0",rf"Metric:\s+{metric}\b|metric\s+{metric}\b",r"bgp")
            if aid in EXPERT:return self.ratio(aid,[normal,False],"Normal-state evidence + обязательный Expert Test.",[f"{dev}: normal state",EXPERT[aid]])
            return self.ratio(aid,[normal],labels=[dev])
        if aid in {"C17","C18"}:
            ipv6=aid=="C18";tests=[];labels=[]
            for d in EDGES:
                command="show bgp ipv6 unicast summary" if ipv6 else "show bgp ipv4 unicast summary"
                peer=PEER6[d] if ipv6 else WAN4[d][2]
                out=self.cmd(d,command);tests.append(self.established(out,peer,65000));labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="C19":
            tests=[];labels=[]
            for d in EDGES:
                peer=WAN4[d][2];detail=self.cmd(d,f"show bgp ipv4 unicast neighbors {peer}")
                password=self.restricted_output(
                    d,"show running-config | include neighbor .* password",
                    [(r"(?m)^(\s*neighbor\s+\S+\s+password\s+).*$",r"\1<redacted>")])
                ok=self.has(detail,r"BGP state = Established",r"hold time is 30, keepalive interval is 10") and re.search(rf"neighbor\s+{re.escape(peer)}\s+password\s+Skill39@C5BGP",password,re.I)
                tests.append(bool(ok));labels.append(d)
            return self.ratio(aid,tests,"R3 output must not be copied into comments.",labels)
        if aid=="C20":
            tests=[];labels=[]
            for d in EDGES:
                v4_table=self.cmd(d,"show ip route static")
                v4_network=SUMMARY4[d].split("/",1)[0]
                # The compact static table omits AD for a directly connected
                # Null0 route.  Detailed lookup exposes `distance 254`.
                v4_detail=self.cmd(d,f"show ip route {v4_network} 255.255.0.0")
                v6=self.cmd(d,"show ipv6 route static")
                v4_ok=(SUMMARY4[d] in v4_table
                       and self.has(v4_detail,
                                    rf"Routing entry for\s+{re.escape(SUMMARY4[d])}\b",
                                    r"Known via\s+\"static\",\s+distance\s+254\b",
                                    r"Null0"))
                v6_ok=(SUMMARY6[d].lower() in v6.lower()
                       and bool(re.search(r"\[\s*254\s*/\s*0\s*\]",v6))
                       and "Null0" in v6)
                ok=v4_ok and v6_ok
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid in {"C21","C22"}:
            tests=[];labels=[]
            for d in EDGES:
                peer=WAN4[d][1]
                v4=self.cmd("ISP1",f"show bgp ipv4 unicast neighbors {peer}")
                v6=self.cmd("ISP1",f"show bgp ipv6 unicast neighbors {EDGE6[d]}")
                direction="inbound" if aid=="C21" else "outbound"
                ok=bool(re.search(rf"(route-map|prefix-list).+{direction}",v4,re.I) and re.search(rf"(route-map|prefix-list).+{direction}",v6,re.I))
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="C23":
            tests=[];labels=[]
            for d in EDGES:
                v4=self.cmd(d,f"show bgp ipv4 unicast neighbors {WAN4[d][2]}")
                v6=self.cmd(d,f"show bgp ipv6 unicast neighbors {PEER6[d]}")
                ok=all(re.search(rf"(route-map|prefix-list).+{direction}",v4,re.I) and re.search(rf"(route-map|prefix-list).+{direction}",v6,re.I) for direction in ("inbound","outbound"))
                tests.append(bool(ok));labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="C24":
            v4=self.cmd("ISP1","show bgp ipv4 unicast");v6=self.cmd("ISP1","show bgp ipv6 unicast")
            tests=[all(p in v4 for p in {"10.110.0.0/16","10.111.0.0/16","10.112.0.0/16","10.113.0.0/16"}),
                   all(p.lower() in v6.lower() for p in {"2001:db8:110::/48","2001:db8:111::/48","2001:db8:112::/48","2001:db8:113::/48"}),
                   "250" in self.cmd("ISP1","show bgp ipv4 unicast 10.110.0.0/16") and "150" in self.cmd("ISP1","show bgp ipv4 unicast 10.110.0.0/16")]
            return self.ratio(aid,tests,labels=["four IPv4 NLRI","four IPv6 NLRI","HQ local-pref 250/150"])

        # D — ACL, uRPF and L2 security
        if aid in {"D1","D2","D3"}:
            tests=[];labels=[]
            for d in ["DS1","DS2"]:
                acl=self.cmd(d,"show access-lists GUEST-IN")
                iface=self.cmd(d,"show ip interface Vlan40")
                if aid=="D1":ok="GUEST-IN" in iface and "Inbound" in iface
                elif aid=="D2":ok=self.has(acl,r"permit udp.*boot",r"permit.*10\.111\.130\.10.*(?:domain|53)",r"permit icmp.*198\.51\.100\.200",r"permit tcp.*10\.111\.130\.10.*(?:www|80|443|https)")
                else:ok=all(prefix in acl for prefix in ["10.110.0.0","10.111.0.0","10.112.0.0","10.113.0.0"]) and bool(re.search(r"permit ip any any",acl,re.I))
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid in {"D4","D5","D6"}:
            tests=[];labels=[]
            for d in ["DS1","DS2"]:
                acl=self.cmd(d,"show ipv6 access-list GUEST-V6");iface=self.cmd(d,"show ipv6 interface Vlan40")
                if aid=="D4":ok="GUEST-V6" in iface
                elif aid=="D5":ok=self.has(acl,r"permit icmp",r"2001:DB8:111:130::10",r"2001:DB8:FFFF::200",r"(?:www|80|443|https)")
                else:ok=all(f"2001:DB8:{x}" in acl.upper() for x in ["110","111","112","113"]) and bool(re.search(r"permit ipv6 any any",acl,re.I))
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="D7":return self.skip(aid,EXPERT[aid])
        if aid in {"D8","D9","D11","D12"}:
            pairs={"D8":[("DS1","Vlan10"),("DS1","Vlan40"),("DS2","Vlan10"),("DS2","Vlan40")],
                   "D9":[("BR1","GigabitEthernet0/1.110"),("BR2","GigabitEthernet0/1.210")],
                   "D11":[(d,WAN4[d][0]) for d in EDGES],
                   "D12":[("ISP1",ISP_IF[d]) for d in EDGES]}[aid]
            tests=[];labels=[]
            for d,iface in pairs:
                out=self.cmd(d,f"show ip interface {iface}")
                strict=aid in {"D8","D9"};ok=bool(re.search(r"RPF.*(?:strict|rx)|verify unicast source reachable-via rx",out,re.I)) if strict else bool(re.search(r"RPF.*(?:loose|any)|verify unicast source reachable-via any",out,re.I))
                tests.append(ok);labels.append(f"{d} {iface}")
            if aid=="D9":
                # Operational state and T3 are each worth 0.125.  Two state
                # checks therefore require two equal expert placeholders.
                tests.extend([False,False])
                labels.extend([f"T3 half 1/2: {EXPERT[aid]}",
                               f"T3 half 2/2: {EXPERT[aid]}"])
            return self.ratio(aid,tests,"Expert half is deliberately not executed." if aid=="D9" else "",labels)
        if aid=="D10":
            tests=[];labels=[]
            for d in ["DS1","DS2","BR1","BR2"]:
                out=self.cmd(d,"show access-lists 199")
                tests.append(self.has(out,r"permit ip host 0\.0\.0\.0 any",r"deny ip any any"));labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="D18":
            tests=[];labels=[]
            for d,port in PC_PORTS.items():
                out=self.cmd(d,f"show port-security interface {port}")
                ok=self.has(
                    out,r"Port Security\s*:\s*Enabled",
                    r"Port Status\s*:\s*Secure-up",
                    r"Violation Mode\s*:\s*Restrict",
                    r"Maximum MAC Addresses\s*:\s*1\b",
                    r"Sticky MAC Addresses\s*:\s*1\b",
                    r"Security Violation Count\s*:\s*0\b")
                tests.append(ok);labels.append(f"{d}: {port} PC access port")
            return self.ratio(aid,tests,labels=labels)
        if aid in {"D13","D14","D15","D16","D17","D19","D20","D21"}:
            devices=ACCESS if aid not in {"D20"} else ["DS3","DS4"]
            command={"D13":"show ip dhcp snooping","D14":"show ip dhcp snooping","D15":"show ip arp inspection","D16":"show ip arp inspection interfaces","D17":"show ip verify source","D19":"show spanning-tree summary","D20":"show spanning-tree summary","D21":"show ip dhcp snooping binding"}[aid]
            tests=[];labels=[]
            for d in devices:
                out=self.cmd(d,command)
                if aid=="D13":ok="enabled" in out.lower() and bool(re.search(r"10|40|110|210",out)) and bool(re.search(r"Option 82.*disabled|information option.*disabled",out,re.I))
                elif aid=="D14":ok=bool(re.search(r"trusted",out,re.I) and re.search(r"15",out))
                elif aid=="D15":ok=bool(re.search(r"10|40|110|210",out) and re.search(r"enabled|active",out,re.I))
                elif aid=="D16":ok=bool(re.search(r"trusted",out,re.I) and re.search(r"15",out))
                elif aid=="D17":ok=bool(re.search(r"active|enabled|Gi",out,re.I))
                elif aid in {"D19","D20"}:ok=self.has(out,r"PortFast|Edge",r"BPDU Guard|Bpduguard")
                else:ok=bool(re.search(r"10\.(?:110\.(?:10|40)|112\.10|113\.10)\.",out))
                tests.append(ok);labels.append(d)
            if aid in {"D14","D16"}:
                # Four device-state checks together are 0.125; the Expert
                # Test is the other 0.125.  Repeat its placeholder four times
                # so ratio() preserves the official 50/50 weighting.
                tests.extend([False]*4)
                labels.extend([f"Expert half {i}/4: {EXPERT[aid]}" for i in range(1,5)])
            return self.ratio(aid,tests,"State evidence plus mandatory post-time expert test." if aid in {"D14","D16"} else "",labels)

        # E — DHCP and endpoints
        if aid=="E1":
            out=self.cmd("IR3","show ip dhcp pool")
            return self.ratio(aid,[name in out for name in ["HQ-STAFF","HQ-GUEST","BR1-USERS","BR2-USERS"]],labels=["HQ-STAFF","HQ-GUEST","BR1-USERS","BR2-USERS"])
        if aid=="E2":
            out=self.cmd("IR3","show running-config | include ^ip dhcp excluded-address")
            networks=["10.110.10","10.110.40","10.112.10","10.113.10"]
            return self.ratio(aid,[f"{n}.1 {n}.99" in out and f"{n}.200 {n}.254" in out for n in networks],"R4 exact exclusions.",networks)
        if aid=="E3":
            gateways={"PC1":"10.110.10.1","PC2":"10.110.40.1",
                      "PC3":"10.112.10.1","PC4":"10.113.10.1"}
            tests=[];labels=[]
            for d,gateway_expected in gateways.items():
                try:
                    out,_,_,gateway,dns=self.vpcs_ip(d)
                    gateway_ok=gateway==gateway_expected
                    dns_ok=dns=="10.111.130.10"
                    # VPCS normally prints the total DHCP lease in seconds,
                    # e.g. `DHCP LEASE : 14391, 14400/7200/12600`.
                    lease_ok=bool(re.search(
                        r"DHCP\s+LEASE[^\r\n]*(?:\b14400\b|"
                        r"\b4\s*hours?\b|\b0?4:00:00\b)",out,re.I))
                except Exception:
                    gateway_ok=dns_ok=lease_ok=False
                tests.append(gateway_ok and dns_ok and lease_ok)
                labels.append(
                    f"{d}: gateway={gateway_expected}, DNS=10.111.130.10, "
                    "DHCP lease=4h")
            return self.ratio(
                aid,tests,
                "Проверяются фактически полученные DHCP options на PC1-PC4; "
                "show ip dhcp pool эти поля не отображает.",labels)
        if aid=="E4":
            pairs=[("DS1","Vlan10"),("DS1","Vlan40"),("DS2","Vlan10"),("DS2","Vlan40"),("BR1","GigabitEthernet0/1.110"),("BR2","GigabitEthernet0/1.210")]
            return self.ratio(aid,["10.111.255.1" in self.cmd(d,f"show ip interface {i}") for d,i in pairs],labels=[f"{d} {i}" for d,i in pairs])
        if aid=="E5":
            expected={"PC1":"10.110.10.","PC2":"10.110.40.","PC3":"10.112.10.","PC4":"10.113.10."};tests=[];labels=[]
            for d,prefix in expected.items():
                try:_,ip,mask,_,_=self.vpcs_ip(d);ok=ip.startswith(prefix) and mask==24 and 100<=int(ip.split('.')[-1])<=199
                except Exception:ok=False
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="E6":
            pairs=[("DS1","Vlan10"),("DS1","Vlan40"),("DS1","Vlan50"),("DS2","Vlan10"),("DS2","Vlan40"),("DS2","Vlan50"),("DS3","Vlan130"),("DS3","Vlan150"),("DS4","Vlan130"),("DS4","Vlan150"),("BR1","GigabitEthernet0/1.110"),("BR2","GigabitEthernet0/1.210")]
            return self.ratio(aid,[bool(re.search(r"ND router advertisements are sent|Router advertisements are sent",self.cmd(d,f"show ipv6 interface {i}"),re.I)) for d,i in pairs],"Endpoint SLAAC/default-route half is confirmed by G2/T0.",[f"{d} {i}" for d,i in pairs])
        if aid in {"E7","E8"}:
            dev="SVR1" if aid=="E7" else "SVR2";vlan="130" if aid=="E7" else "150"
            out=self.host_cmd(dev,"ip -br address; ip route; ip -6 route")
            tests=[f"10.111.{vlan}.10/24" in out,f"default via 10.111.{vlan}.1" in out,f"2001:db8:111:{vlan}::10/64" in out.lower(),bool(re.search(r"(?m)^default via fe80:",out,re.I))]
            return self.ratio(aid,tests,labels=["IPv4 address","IPv4 gateway","IPv6 address","IPv6 RA default"])

        # F — management and telemetry
        if aid=="F1":
            tests=[];labels=[]
            for d in CISCO:
                v4=self.cmd(d,"show access-lists C5-VTY4");v6=self.cmd(d,"show ipv6 access-list C5-VTY6")
                tests.append("10.111.150.10" in v4 and "2001:DB8:111:150::10" in v6.upper());labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="F2":
            session=self.host_sessions.get("SVR2");tests=[];labels=[]
            if session is None:return self.ratio(aid,[False],"SVR2 session unavailable",["SVR2"])
            password=self.creds.get("device_password","Skill39@C5")
            for d,ip in MGMT4.items():
                script=("tmp=$(mktemp); printf '#!/bin/sh\\necho %s\\n' "+shlex.quote(password)+">\"$tmp\"; chmod 700 \"$tmp\"; "
                        "printf 'show privilege\\nexit\\n' | "
                        "DISPLAY=:1 SSH_ASKPASS=\"$tmp\" SSH_ASKPASS_REQUIRE=force "
                        "timeout 12 ssh -tt -o StrictHostKeyChecking=no "
                        "-o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 "
                        "netadmin@"+ip+"; rc=$?; rm -f \"$tmp\"; exit $rc")
                out=session.exec(script,timeout=16);ok="privilege level is 15" in out.lower()
                self.record_command(
                    d,f"SVR2$ ssh -tt netadmin@{ip} (show privilege)",
                    "SUCCESS privilege 15" if ok else "FAILED")
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="F3":return self.skip(aid,"Negative SSH/Telnet attempts from PC1-PC4 are intentionally manual; use the marking scheme procedure.")
        if aid=="F4":
            out=self.cmd("ISP1","show ip interface brief | include Loopback")+self.cmd("ISP1","show ipv6 interface brief | section Loopback")+self.cmd("ISP1","show ntp status")
            return self.ratio(aid,["198.51.100.200" in out,self.ipv6_has(out,"2001:db8:ffff::200"),bool(re.search(r"stratum\s+3|Clock is synchronized",out,re.I))],labels=["Loopback100","Loopback200","NTP master 3"])
        if aid=="F5":return self.all_state(aid,[d for d in CISCO if d!="ISP1"],"show ntp status",lambda d,o:bool(re.search(r"Clock is synchronized|stratum [4-9]",o,re.I)))
        if aid=="F6":
            tests=[];labels=[]
            for d in CISCO:
                state=self.cmd(d,"show logging")
                cfg=self.cmd(d,"show running-config | include logging host|logging trap|logging buffered|logging source-interface")
                ok="10.111.130.10" in state+cfg and self.has(state+cfg,r"informational|level 6",r"buffer") and "source-interface" in cfg
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,"R7 targeted fields only.",labels)
        if aid=="F7":return self.skip(aid,EXPERT[aid])
        if aid=="F8":
            tests=[];labels=[]
            for d in CISCO:
                out=self.cmd(d,"show snmp view")+self.cmd(d,"show snmp group")+self.cmd(d,"show snmp user")
                tests.append(self.has(out,r"C5VIEW",r"C5GROUP",r"c5mon",r"SHA",r"AES|Privacy Protocol"));labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="F9":return self.skip(aid,"Positive SVR2 and negative SVR1 SNMPv3/v1/v2c tests require protected functional procedure; R5 only if result is ambiguous.")
        if aid=="F10":
            session=self.host_sessions.get("SVR2");tests=[];labels=[]
            for d,ip in MGMT4.items():
                if session is None:ok=False;out="SVR2 unavailable"
                else:
                    cmd=f"timeout 12 snmpwalk -v3 -l authPriv -u c5mon -a SHA -A 'AuthC5!2026' -x AES -X 'PrivC5!2026' {ip} 1.3.6.1.2.1.1"
                    out=session.exec(cmd,timeout=15);ok="sysName" in out and "sysUpTime" in out
                self.record_command(d,f"SVR2$ SNMPv3 authPriv {ip} system OIDs","SUCCESS sysName/sysUpTime" if ok else "FAILED")
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="F11":
            tests=[];labels=[]
            for d in EDGES:
                out=self.cmd(d,"show flow record C5-REC")+self.cmd(d,"show flow exporter C5-EXP")+self.cmd(d,"show flow monitor C5-MON")+self.cmd(d,"show flow monitor C5-MON cache")
                config=self.has(out,r"IPV4 SOURCE ADDRESS",r"IPV4 DESTINATION ADDRESS",r"PROTOCOL",r"TRANSPORT SOURCE-PORT",r"10\.111\.130\.10",r"2055",r"VERSION 9",r"60")
                evidence=bool(re.search(r"Flows added|Current entries|IPV4 SOURCE ADDRESS",out,re.I)) if d!="IR2" else False
                tests.extend([config,evidence]);labels.extend([f"{d}: config/state",f"{d}: flow evidence"+(" during T6" if d=="IR2" else "")])
            return self.ratio(aid,tests,"IR2 evidence is intentionally completed during T6.",labels)

        # G — fixed acceptance matrix and destructive tests
        if aid=="G1":
            ips={}
            for d in ["PC1","PC3","PC4"]:
                try:ips[d]=self.vpcs_ip(d)[1]
                except Exception:ips[d]=""
            checks=[("PC1","10.111.130.10"),("PC3","10.111.130.10"),("PC4","10.111.130.10"),("PC3",ips.get("PC4","")),("PC4",ips.get("PC3",""))]
            tests=[bool(dst) and self.vpcs_ping(src,dst,2)[0] for src,dst in checks]
            tests.append(bool(ips.get("PC1")) and self.linux_ping("SVR1",ips["PC1"],2))
            return self.ratio(aid,tests,labels=["A1","A2","A3","A4","A5","A6"])
        if aid=="G2":return self.skip(aid,"Execute Acceptance Matrix A7-A12 with current SLAAC addresses captured at T0.")
        if aid=="G3":
            tests=[];labels=[]
            for d in ["PC1","PC3","PC4"]:
                tests.append(self.vpcs_ping(d,"198.51.100.200",2)[0]);labels.append(f"{d} IPv4")
            tests.append(self.linux_ping("SVR1","198.51.100.200",2));labels.append("SVR1 IPv4")
            # IPv6 endpoint commands differ by the organizer image; list those as manual outcomes.
            tests += [False]*4;labels += [f"{d} IPv6 A{17+i}" for i,d in enumerate(["PC1","PC3","PC4","SVR1"])]
            return self.ratio(aid,tests,"A17-A20 must be executed on the actual endpoint image with current IPv6 routes.",labels)
        if aid in {"G4","G5","G6","G7","G8"}:return self.skip(aid,EXPERT[aid])
        return self.skip(aid,"Для этого аспекта требуется указанная в схеме оценки ручная/экспертная проверка.")

    def report(self):
        totals=defaultdict(float);maximums=defaultdict(float)
        print(f"\n{base.PURPLE}{'#'*90}\nC5 Marking Scheme Report\n{'#'*90}{base.NC}")
        for r in self.results:
            section=r.aspect.id[0];totals[section]+=r.score;maximums[section]+=r.aspect.mark
            color={"PASS":base.GREEN,"PART":base.PURPLE,"FAIL":base.RED,"SKIP":base.YELLOW}[r.status]
            fraction=f" ({r.passed}/{r.total})" if r.total else ""
            print(f"{color}[{r.status:4}] {r.aspect.number:03d} {r.aspect.id:3} {r.score:.3f}/{r.aspect.mark:.3f}{fraction} — {r.aspect.title}{base.NC}")
        for section in "ABCDEFG":print(f"  {section}: {totals[section]:.3f}/{maximums[section]:.3f}")
        print(f"{base.CYAN}TOTAL: {sum(totals.values()):.3f}/{sum(maximums.values()):.3f}{base.NC}")

def start_number(value):
    value=value.upper()
    if value.isdigit() and 1<=int(value)<=100:return int(value)
    if value in BY_ID:return BY_ID[value].number
    found=next((a.number for a in ASPECTS if a.id.startswith(value)),None)
    if found:return found
    raise ValueError("Используйте A-G, ID аспекта или порядковый номер 1-100")

def arguments():
    parser=argparse.ArgumentParser(description="WSC2026 C5 PNETLab read-only scorer")
    parser.add_argument("--start",default="A",help="A-G, aspect ID или 1-100")
    parser.add_argument("--session-id",type=int,help="выбрать активную сессию по ID")
    parser.add_argument("--no-pause","--continuous","-c",dest="no_pause",action="store_true",help="не ожидать Enter между критериями")
    return parser.parse_args()

def main():
    args=arguments();start=start_number(args.start)
    print(f"{base.GREEN}C5 checker version: {C5_CHECKER_VERSION}{base.NC}")
    print(f"{base.CYAN}Режим: {'непрерывный' if args.no_pause else 'пауза после каждого аспекта'}.{base.NC}")
    print(f"Script: {Path(__file__).resolve()}")
    with open(HERE/"creds.json",encoding="utf-8") as file:creds=json.load(file)
    cookie=base.login(creds["pnet_url"],creds["username"],creds["password"])
    try:
        sid=c3.choose_running_session(creds["pnet_url"],cookie,args.session_id)
        base.join_session(creds["pnet_url"],sid,cookie)
        consoles=base.build_node_console_map(base.get_nodes(creds["pnet_url"],cookie).json())
        scorer=Scorer(consoles,creds,disruptive=False)
        try:
            scorer.connect();scorer.run(start,pause=not args.no_pause);scorer.report()
        finally:scorer.close()
    finally:
        try:base.logout(creds["pnet_url"])
        except Exception:pass

if __name__=="__main__":main()
