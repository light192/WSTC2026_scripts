#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PNETLab scorer for WSC2026 Training C3 (100 aspects, 25 points).

Evidence is collected with operational and dedicated ``show`` commands.
``show running-config`` is deliberately never used.  The only configuration
fallback is the marking-scheme-authorized ``show startup-config | include
^ip route`` in A7 for inactive static routes which cannot exist in the RIB.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path
import json
import re
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "C2"))
import c2_check_ios as base  # reuse the proven PNETLab/console/host framework
from pnetlab_lib import filter_session, filter_user, get_sessions_count

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

DEVICES = ["IR1","IR2","CR1","CR2","DS1","DS2","AS1","AS2","IR3","DS3","DS4","BR1","BR2","AS3","AS4"]
INFRA = ["IR1","IR2","CR1","CR2","DS1","DS2","IR3","DS3","DS4"]
OSPF = ["IR1","IR2","CR1","CR2","DS1","DS2","IR3"]
OSPF_AREA0_INTERFACES = {
 "IR1":["GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2"],
 "IR2":["GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2","GigabitEthernet0/4"],
 "CR1":["GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2","GigabitEthernet0/3","GigabitEthernet0/4"],
 "CR2":["GigabitEthernet0/0","GigabitEthernet0/1","GigabitEthernet0/2","GigabitEthernet0/3","GigabitEthernet0/4"],
 "DS1":["GigabitEthernet0/0","GigabitEthernet0/3"],
 "DS2":["GigabitEthernet0/0","GigabitEthernet0/3"],
 "IR3":["GigabitEthernet0/2"],
}
EIGRP = ["IR2","IR3","DS3","DS4"]
EDGES = ["IR1","IR2","IR3","BR1","BR2"]
SWITCHES = ["DS1","DS2","AS1","AS2","DS3","DS4","AS3","AS4"]

LOOPBACKS = {
 "IR1":"10.255.90.1","IR2":"10.255.90.2","CR1":"10.255.90.11","CR2":"10.255.90.12",
 "DS1":"10.255.90.21","DS2":"10.255.90.22","IR3":"10.255.91.1","DS3":"10.255.91.11",
 "DS4":"10.255.91.12","BR1":"10.255.92.1","BR2":"10.255.93.1"}
V6_LOOPBACKS = {
 "IR1":"2001:db8:90:ff::1","IR2":"2001:db8:90:ff::2","CR1":"2001:db8:90:ff::11",
 "CR2":"2001:db8:90:ff::12","DS1":"2001:db8:90:ff::21","DS2":"2001:db8:90:ff::22",
 "IR3":"2001:db8:91:ff::1","DS3":"2001:db8:91:ff::11","DS4":"2001:db8:91:ff::12"}
WAN = {"IR1":("GigabitEthernet0/3","203.0.113.34"),"IR2":("GigabitEthernet0/3","203.0.113.38"),
       "IR3":("GigabitEthernet0/3","203.0.113.42"),"BR1":("GigabitEthernet0/0","203.0.113.46"),
       "BR2":("GigabitEthernet0/0","203.0.113.50")}
ROUTED = {
 "IR1":{"GigabitEthernet0/0":"10.90.0.1","GigabitEthernet0/1":"10.90.0.5","GigabitEthernet0/2":"10.90.0.17"},
 "IR2":{"GigabitEthernet0/1":"10.90.0.9","GigabitEthernet0/0":"10.90.0.13","GigabitEthernet0/2":"10.90.0.18","GigabitEthernet0/4":"10.90.0.41"},
 "CR1":{"GigabitEthernet0/0":"10.90.0.2","GigabitEthernet0/3":"10.90.0.10","GigabitEthernet0/2":"10.90.0.21","GigabitEthernet0/1":"10.90.0.25","GigabitEthernet0/4":"10.90.0.29"},
 "CR2":{"GigabitEthernet0/3":"10.90.0.6","GigabitEthernet0/0":"10.90.0.14","GigabitEthernet0/2":"10.90.0.22","GigabitEthernet0/4":"10.90.0.33","GigabitEthernet0/1":"10.90.0.37"},
 "DS1":{"GigabitEthernet0/0":"10.90.0.26","GigabitEthernet0/3":"10.90.0.34"},
 "DS2":{"GigabitEthernet0/3":"10.90.0.30","GigabitEthernet0/0":"10.90.0.38"},
 "IR3":{"GigabitEthernet0/2":"10.90.0.42","GigabitEthernet0/0":"10.91.0.1","GigabitEthernet0/1":"10.91.0.5"},
 "DS3":{"GigabitEthernet0/0":"10.91.0.2"},"DS4":{"GigabitEthernet0/0":"10.91.0.6"}}
V6_ROUTED = {
 "IR1":{"GigabitEthernet0/0":"2001:db8:90:1::1","GigabitEthernet0/1":"2001:db8:90:2::1","GigabitEthernet0/2":"2001:db8:90:5::1"},
 "IR2":{"GigabitEthernet0/1":"2001:db8:90:3::1","GigabitEthernet0/0":"2001:db8:90:4::1","GigabitEthernet0/2":"2001:db8:90:5::2","GigabitEthernet0/4":"2001:db8:9030:1::1"},
 "CR1":{"GigabitEthernet0/0":"2001:db8:90:1::2","GigabitEthernet0/3":"2001:db8:90:3::2","GigabitEthernet0/2":"2001:db8:90:6::1","GigabitEthernet0/1":"2001:db8:90:7::1","GigabitEthernet0/4":"2001:db8:90:8::1"},
 "CR2":{"GigabitEthernet0/3":"2001:db8:90:2::2","GigabitEthernet0/0":"2001:db8:90:4::2","GigabitEthernet0/2":"2001:db8:90:6::2","GigabitEthernet0/4":"2001:db8:90:9::1","GigabitEthernet0/1":"2001:db8:90:a::1"},
 "DS1":{"GigabitEthernet0/0":"2001:db8:90:7::2","GigabitEthernet0/3":"2001:db8:90:9::2"},
 "DS2":{"GigabitEthernet0/3":"2001:db8:90:8::2","GigabitEthernet0/0":"2001:db8:90:a::2"},
 "IR3":{"GigabitEthernet0/2":"2001:db8:9030:1::2","GigabitEthernet0/0":"2001:db8:91:1::1","GigabitEthernet0/1":"2001:db8:91:2::1"},
 "DS3":{"GigabitEthernet0/0":"2001:db8:91:1::2"},"DS4":{"GigabitEthernet0/0":"2001:db8:91:2::2"}}
PEERS = {"IR1":"203.0.113.33","IR2":"203.0.113.37","IR3":"203.0.113.41","BR1":"203.0.113.45","BR2":"203.0.113.49"}
ASNS = {"IR1":"65320","IR2":"65320","IR3":"65330","BR1":"65341","BR2":"65342"}

# Criteria are kept in a separate UTF-8 TSV generated from the official XLSX.
ASPECTS = []
with open(HERE / "c3_criteria.tsv", encoding="utf-8-sig") as criteria:
    next(criteria)
    for number, line in enumerate(criteria, 1):
        cols = line.rstrip("\n").split("\t")
        ASPECTS.append(base.Aspect(number, cols[1], float(cols[5]), cols[3]))
BY_ID = {a.id:a for a in ASPECTS}
base.ASPECTS, base.BY_ID = ASPECTS, BY_ID

HOST_CHECK_INSTRUCTIONS = {
 "A6":"Проверить выдачу DHCP и baseline ACL/NAT/telemetry с PC/SVR; IOS evidence выводится автоматически.",
 "H1":"PC1: DNS, OPS-SRV, PC3/PC4 и ping 198.51.100.200 должны работать.",
 "H2":"PC3: HQ, OPS-SRV, BR2 и 198.51.100.200 должны быть доступны.",
 "H3":"PC4: HQ, OPS-SRV, BR1 и 198.51.100.200 должны быть доступны.",
 "H4":"PC2: разрешенные GUEST paths работают, private/management/SSH paths блокируются.",
 "H6":"С JUDGE-SRV выполнить SNMPv3 authPriv polling всех 15 Cisco с Expert Data credentials.",
 "H7":"С PC3 и PC4 выполнить HTTP GET http://198.51.100.105/healthz.",
}

class Scorer(base.Scorer):
    def record_command(self,dev,command,output):
        """Keep only the latest evidence for repeated convergence polling."""
        for index,(old_dev,old_command,_) in enumerate(self.command_records):
            if old_dev==dev and old_command==command:
                self.command_records[index]=(dev,command,output)
                return
        super().record_command(dev,command,output)

    def filtered_command(self, command):
        """Keep evidence focused without converting a dedicated show into config scraping."""
        filters = [
          (r"^show ip interface brief$", r"up|down|administratively"),
          (r"^show ipv6 interface brief$", r"GigabitEthernet|Loopback|2001:DB8|2001:db8|up|down"),
          (r"^show ip ospf neighbor$", r"FULL|Neighbor ID"),
          (r"^show ip eigrp neighbors$", r"Address|10\.90|10\.91"),
          (r"^show ipv6 ospf neighbor$", r"FULL|Neighbor ID"),
          (r"^show bgp ipv4 unicast summary$", r"BGP router identifier|Neighbor|203\.0\.113|10\.255"),
        ]
        for pattern, include in filters:
            if re.match(pattern, command, re.I): return f"{command} | include {include}"
        return command

    @staticmethod
    def contains(text, *patterns): return all(re.search(p,text,re.I|re.M) for p in patterns)
    @staticmethod
    def absent(text, *patterns): return all(not re.search(p,text,re.I|re.M) for p in patterns)
    def brief_ok(self, dev, iface, address):
        out=self.cmd(dev,"show ip interface brief")
        short=iface.replace("GigabitEthernet","Gi").replace("Loopback","Lo")
        return bool(re.search(rf"^(?:{re.escape(iface)}|{re.escape(short)})\s+{re.escape(address)}\s+\S+\s+\S+\s+up\s+up\s*$",out,re.I|re.M))
    @staticmethod
    def ospf_interface_in_area(text,iface,area):
        short=iface.replace("GigabitEthernet","Gi").replace("Loopback","Lo").replace("Vlan","Vl")
        return bool(re.search(
            rf"^(?:{re.escape(iface)}|{re.escape(short)})\s+30\s+{re.escape(str(area))}\s+",
            text,re.I|re.M))
    def route(self,dev,prefix): return self.cmd(dev,f"show ip route {prefix}")
    def floating_default_active(self,dev):
        """Recognize both compact and detailed IOS static-route formats."""
        out=self.route(dev,"0.0.0.0")
        expected_next_hop={"BR1":"203.0.113.45","BR2":"203.0.113.49"}[dev]
        static_ad250=bool(
            re.search(r"\[\s*250\s*/\s*0\s*\]",out) or
            re.search(r'Known via\s+"static",\s+distance\s+250\b',out,re.I))
        return static_ad250 and expected_next_hop in out
    @staticmethod
    def ospf_external_metrics(text):
        """Return exact Type-5 Metric field values, avoiding 10 vs 100 matches."""
        return [
            int(value) for value in
            re.findall(r"(?mi)^\s*Metric:\s*(\d+)\s*$",text)
        ]
    def bgp_prefix(self,dev,prefix): return self.cmd(dev,f"show bgp ipv4 unicast {prefix}")
    @staticmethod
    def bgp_table_prefixes(text):
        """Extract NLRI from an IOS BGP table and normalize default to /0."""
        prefixes=set()
        for line in text.splitlines():
            match=re.match(
                r"^\s*(?:[\*\>\<sdhrSmbfxacRi]+\s*)+"
                r"(\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?)\s+",
                line,re.I)
            if not match:continue
            prefix=match.group(1)
            if prefix=="0.0.0.0":prefix="0.0.0.0/0"
            prefixes.add(prefix)
        return prefixes
    def bgp_established(self,dev,peer):
        out=self.cmd(dev,"show bgp ipv4 unicast summary")
        return bool(re.search(rf"^{re.escape(peer)}\s+4\s+\d+.*\s+\d+\s*$",out,re.I|re.M))
    def ebgp_session_ok(self,dev):
        """Validate state, local AS and ISP remote AS in their actual IOS fields."""
        peer=PEERS[dev]
        summary=self.cmd(dev,"show bgp ipv4 unicast summary")
        detail=self.cmd(dev,f"show bgp ipv4 unicast neighbors {peer}")
        local_as_ok=bool(re.search(
            rf"BGP router identifier\s+\S+,\s+local AS number\s+{re.escape(ASNS[dev])}\b",
            summary,re.I))
        remote_as_ok=bool(re.search(
            rf"BGP neighbor is\s+{re.escape(peer)},\s+remote AS\s+65000,\s+external link",
            detail,re.I))
        summary_state_ok=bool(re.search(
            rf"^{re.escape(peer)}\s+4\s+65000(?:\s+\S+){{5,}}\s+\d+\s*$",
            summary,re.I|re.M))
        state_ok=summary_state_ok and bool(re.search(
            r"BGP state\s*=\s*Established\b",detail,re.I))
        return local_as_ok and remote_as_ok and state_ok
    def wait_for(self,fn,timeout=90,interval=5):
        end=time.time()+timeout
        while time.time()<end:
            self.cache.clear()
            if fn(): return True
            time.sleep(interval)
        return False
    def expected(self,aid):
        with open(HERE/"c3_criteria.tsv",encoding="utf-8-sig") as f:
            next(f)
            for line in f:
                c=line.rstrip("\n").split("\t")
                if c[1]==aid:return c[4]
        return ""
    @staticmethod
    def print_expected(aspect):
        print(f"{base.CYAN}Ожидаемый результат:{base.NC}\n  {aspect.title}.\n  Максимальный балл: {aspect.mark:.3f}")
        with open(HERE/"c3_criteria.tsv",encoding="utf-8-sig") as f:
            next(f)
            row=next((x.rstrip("\n").split("\t") for x in f if x.split("\t",2)[1]==aspect.id),None)
        if row: print(f"  Проверяемые свойства: {row[4]}")

    def check(self, aid):
        # A — baseline and addressing integrity
        if aid=="A1":
            tests=[];labels=[]
            for d in DEVICES:
                out=self.cmd(d,"show interfaces description")
                tests.append(bool(re.search(r"\bup\s+up\b",out,re.I)));labels.append(d)
                if d in SWITCHES:self.cmd(d,"show interfaces status")
            return self.ratio(aid,tests,"Рабочие links должны быть up/up/connected",labels)
        if aid=="A2": return self.ratio(aid,[self.brief_ok(d,*WAN[d]) for d in EDGES],labels=EDGES)
        if aid=="A3": return self.ratio(aid,[self.brief_ok(d,"Loopback0",ip) for d,ip in LOOPBACKS.items()],labels=list(LOOPBACKS))
        if aid=="A4":
            tests=[];labels=[]
            for d,ifs in ROUTED.items():
                for iface,ip in ifs.items():tests.append(self.brief_ok(d,iface,ip));labels.append(d)
            return self.ratio(aid,tests,"26 корректно адресованных сторон внутренних links",labels)
        if aid=="A5":
            tests=[all("active" in self.cmd(d,"show vlan brief").lower() for d in SWITCHES),
                   all(bool(self.cmd(d,"show interfaces trunk")) for d in SWITCHES),
                   all("mst" in self.cmd(d,"show spanning-tree mst").lower() for d in SWITCHES),
                   all("standby" in self.cmd(d,"show standby brief").lower() for d in ["DS1","DS2","DS3","DS4"])]
            return self.ratio(aid,tests,"VLAN / trunks / MST / HSRP baseline")
        if aid=="A6":
            groups=[all("helper" in self.cmd(d,"show ip interface | include Helper").lower() for d in ["DS1","DS2","BR1","BR2"]),
                    all(bool(self.cmd(d,"show access-lists")) and "inside" in self.cmd(d,"show ip nat statistics").lower() for d in EDGES),
                    all(bool(self.cmd(d,"show ntp associations")) and bool(self.cmd(d,"show logging")) for d in DEVICES)]
            return self.ratio(aid,groups,"DHCP relay / ACL+NAT / telemetry")
        if aid=="A7":
            policy="".join(self.cmd(d,"show ip policy") for d in DEVICES)
            tunnels="".join(self.cmd(d,"show interfaces tunnel") for d in DEVICES)
            static={d:self.cmd(d,"show ip route static") for d in EDGES}
            startup={d:self.cmd(d,"show startup-config | include ^ip route") for d in EDGES}
            allowed=re.compile(r"(?:198\.51\.100\.(?:96|104)|10\.(?:92|93)\.0\.0|0\.0\.0\.0)")
            lines=[x for out in startup.values() for x in out.splitlines() if x.strip().startswith("ip route")]
            return self.ratio(aid,[not re.search(r"route-map",policy,re.I),not re.search(r"Tunnel\d+",tunnels,re.I),all(allowed.search(x) for x in lines)],"Единственный разрешенный config fallback — startup static routes")
        if aid=="A8":
            tests=[];labels=[]
            for d in DEVICES:
                diff=self.cmd(d,"show archive config differences nvram:startup-config system:running-config")
                tests.append(not re.search(r"^[+-]",diff,re.M));labels.append(d)
            return self.ratio(aid,tests,"Startup соответствует рабочему состоянию",labels)

        # B — OSPFv2
        if aid=="B4":
            tests=[];labels=[]
            for d,interfaces in OSPF_AREA0_INTERFACES.items():
                out=self.cmd(d,"show ip ospf interface brief")
                for iface in interfaces:
                    tests.append(self.ospf_interface_in_area(out,iface,0))
                    labels.append(d)
            return self.ratio(
                aid,tests,
                "Каждый обязательный HQ/transit interface должен присутствовать в OSPF process 30 area 0",
                labels)
        if aid=="B5":
            tests=[];labels=[]
            for d,interfaces in OSPF_AREA0_INTERFACES.items():
                for iface in interfaces:
                    out=self.cmd(d,f"show ip ospf interface {iface}")
                    exists=bool(re.search(
                        rf"\b{re.escape(iface)}\s+is\s+(?:up|down)|"
                        rf"\b{re.escape(iface.replace('GigabitEthernet','Gi'))}\s+is\s+(?:up|down)",
                        out,re.I))
                    process_area=bool(re.search(
                        r"Process ID\s+30\b.*\bArea\s+0\b|"
                        r"Internet Address\s+\S+,\s+Area\s+0\b",
                        out,re.I))
                    point_to_point=bool(re.search(
                        r"Network Type\s+POINT_TO_POINT\b|"
                        r"State\s+POINT_TO_POINT\b",
                        out,re.I))
                    tests.append(exists and process_area and point_to_point)
                    labels.append(d)
            return self.ratio(
                aid,tests,
                "Для каждого /30 требуется OSPF process 30, area 0 и Network Type/State POINT_TO_POINT",
                labels)
        if aid in {"B1","B2","B3"}:
            tests=[];labels=[]
            for d in OSPF:
                ospf_detail=self.cmd(d,"show ip ospf")
                protocols=self.cmd(d,"show ip protocols")
                proto=ospf_detail+protocols
                ospf_protocol_section_match=re.search(
                    r'Routing Protocol is "ospf 30"(.*?)(?=\nRouting Protocol is "|\Z)',
                    protocols,re.I|re.S)
                ospf_protocol_section=(
                    ospf_protocol_section_match.group(1)
                    if ospf_protocol_section_match else "")
                ints=self.cmd(d,"show ip ospf interface brief")
                if aid=="B1":ok=bool(re.search(
                    r'Routing Process\s+"?ospf\s+30"?\s+with ID\b'
                    r"|OSPF Router with ID.*Process ID 30",
                    ospf_detail,re.I))
                elif aid=="B2":ok=bool(re.search(
                    rf'Routing Process\s+"?ospf\s+30"?\s+with ID\s+{re.escape(LOOPBACKS[d])}\b'
                    rf"|OSPF Router with ID\s*\({re.escape(LOOPBACKS[d])}\)\s*\(Process ID 30\)",
                    ospf_detail,re.I))
                elif aid=="B3":ok=(
                    bool(ospf_protocol_section)
                    and "passive" in ospf_protocol_section.lower()
                    and "Loopback0" not in ints)
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="B6": return self.ratio(aid,["FULL" in self.cmd(d,"show ip ospf neighbor") for d in ["IR1","IR2","CR1","CR2","DS1","DS2"]],labels=["IR1","IR2","CR1","CR2","DS1","DS2"])
        if aid=="B7": return self.ratio(aid,["FULL" in self.cmd(d,"show ip ospf neighbor") and "GigabitEthernet0/4" in self.cmd("IR2","show ip ospf interface brief") for d in ["IR2","IR3"]],labels=["IR2","IR3"])
        if aid=="B8": return self.ratio(aid,[self.contains(self.cmd(d,"show ip ospf interface brief"),r"Vl(?:an)?10.*\b10\b",r"Vl(?:an)?40.*\b10\b",r"Vl(?:an)?50.*\b10\b") for d in ["DS1","DS2"]],labels=["DS1","DS2"])
        if aid=="B9": return self.ratio(aid,[self.contains(self.cmd(d,"show ip ospf"),r"area border router") and "Summary Net Link States" in self.cmd(d,"show ip ospf database summary") for d in ["DS1","DS2"]],labels=["DS1","DS2"])
        if aid=="B10": return self.ratio(aid,["10.90.0.0/16" in self.cmd(d,"show ip route ospf") or "10.90.0.0" in self.cmd(d,"show ip ospf database summary") for d in ["IR1","IR2","CR1","CR2","IR3"]],labels=["IR1","IR2","CR1","CR2","IR3"])
        if aid=="B11":
            tests=[];labels=[];details=[]
            for d in ["IR1","IR2","IR3"]:
                for prefix in ["10.90.10.0","10.90.40.0","10.90.50.0"]:
                    out=self.cmd(d,f"show ip route {prefix} 255.255.255.0")
                    exact_ospf_ia=bool(re.search(
                        rf"Routing entry for\s+{re.escape(prefix)}/24\b"
                        r"[\s\S]*?Known via\s+\"ospf 30\""
                        r"[\s\S]*?type inter area",
                        out,re.I))
                    tests.append(not exact_ospf_ia);labels.append(d)
                    details.append(
                        f"{d} {prefix}/24={'LEAK' if exact_ospf_ia else 'ABSENT'}")
            return self.ratio(
                aid,tests,
                "; ".join(details)+"; summary 10.90.0.0/16 разрешен и ожидается",
                labels)
        if aid=="B12":
            out=self.cmd("CR1","show ip ospf database external 0.0.0.0")
            return self.ratio(aid,[self.contains(out,r"Metric\s*:\s*10",r"Metric\s*:\s*100") and self.bgp_prefix("IR1","0.0.0.0/0") and self.bgp_prefix("IR2","0.0.0.0/0")])

        # C — named EIGRP
        if aid in {"C1","C2","C3","C4","C5","C6","C7"}:
            tests=[];labels=[]
            expected_active={"IR2":["GigabitEthernet0/4"],"IR3":["GigabitEthernet0/2","GigabitEthernet0/0","GigabitEthernet0/1"],"DS3":["GigabitEthernet0/0"],"DS4":["GigabitEthernet0/0"]}
            for d in EIGRP:
                proto=self.cmd(d,"show ip protocols");ints=self.cmd(d,"show ip eigrp interfaces");neigh=self.cmd(d,"show ip eigrp neighbors")
                if aid=="C1":ok=self.contains(proto,r"CAMP-C3",r"eigrp")
                elif aid=="C2":ok=self.contains(proto,r"3030",re.escape(LOOPBACKS[d]))
                elif aid=="C3":ok=all(i in ints or i.replace("GigabitEthernet","Gi") in ints for i in expected_active[d])
                elif aid=="C4":ok="Loopback0" not in ints and not re.search(r"Vlan(?:130|150)",ints,re.I)
                elif aid=="C5":ok=all((i in " ".join(expected_active[d]) or i not in ints) for i in ROUTED.get(d,{}))
                elif aid=="C6":ok=bool(re.search(
                    r"automatic\s+(?:network\s+)?summari[sz]ation\s*(?:is\s+not\s+in\s+effect|:\s*disabled)"
                    r"|auto-summary\s*(?::\s*)?disabled",
                    proto,re.I))
                else:ok="10.90.0." in neigh or "10.91.0." in neigh
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="C8":
            out=self.cmd("IR2","show ip route eigrp")+self.cmd("IR2","show ip eigrp topology 10.91.0.0/16")
            return self.ratio(aid,["10.91.0.0/16" in out and not re.search(r"10\.91\.(?:130|150)\.0/24",self.cmd("IR2","show ip route eigrp"))],labels=["IR2"])
        if aid=="C9": return self.ratio(aid,[self.contains(self.route(d,"0.0.0.0"),r"Known via.*eigrp",r"10\.91\.0\.(?:1|5)") and "333" in self.cmd(d,"show ip eigrp topology 0.0.0.0/0") for d in ["DS3","DS4"]],labels=["DS3","DS4"])
        if aid=="C10": return self.ratio(aid,["10.90.0." in self.cmd(d,"show ip eigrp neighbors") or "10.91.0." in self.cmd(d,"show ip eigrp neighbors") for d in EIGRP],"Converged operational state after any expert clear",EIGRP)

        # D — controlled redistribution. Dedicated policy/database commands only.
        if aid=="D2":
            tests=[];labels=[];details=[]
            for d in ["IR2","IR3"]:
                protocols=self.cmd(d,"show ip protocols")
                route_maps=self.cmd(d,"show route-map")
                ospf_from_eigrp=bool(re.search(
                    r'Routing Protocol is "ospf 30"'
                    r'[\s\S]*?Redistributing External Routes from,?'
                    r'[\s\S]*?\beigrp\b',
                    protocols,re.I))
                eigrp_from_ospf=bool(re.search(
                    r'Routing Protocol is "eigrp 3030"'
                    r'[\s\S]*?Redistributing:\s*[^\n]*\bospf 30\b',
                    protocols,re.I))
                ospf_to_eigrp_policy=bool(re.search(
                    r'(?mi)^route-map\s+\S*OSPF\S*(?:TO|2)\S*EIGRP\S*,',
                    route_maps))
                eigrp_to_ospf_policy=bool(re.search(
                    r'(?mi)^route-map\s+\S*EIGRP\S*(?:TO|2)\S*OSPF\S*,',
                    route_maps))
                # D1 evaluates whether both mandatory directions exist.
                # D2 must not penalize that same absence again: it fails only
                # when an active redistribution direction has no controlling
                # directional route-map.
                ospf_to_eigrp_safe=not eigrp_from_ospf or ospf_to_eigrp_policy
                eigrp_to_ospf_safe=not ospf_from_eigrp or eigrp_to_ospf_policy
                ok=ospf_to_eigrp_safe and eigrp_to_ospf_safe
                def policy_state(active,policy):
                    if not active:return "NOT_CONFIGURED (см. D1)"
                    return "CONTROLLED" if policy else "UNCONDITIONAL"
                tests.append(ok);labels.append(d)
                details.append(
                    f"{d}: OSPF->EIGRP="
                    f"{policy_state(eigrp_from_ospf,ospf_to_eigrp_policy)}, "
                    f"EIGRP->OSPF="
                    f"{policy_state(ospf_from_eigrp,eigrp_to_ospf_policy)}")
            return self.ratio(aid,tests,"; ".join(details),labels)
        if aid in {"D1","D3","D4","D5","D7","D8","D9","D10","D11","D14","D15","D16","D17","D18","D19"}:
            tests=[];labels=[]
            for d in ["IR2","IR3"]:
                proto=self.cmd(d,"show ip protocols");rm=self.cmd(d,"show route-map");pl=self.cmd(d,"show ip prefix-list")
                if aid=="D1":ok=self.contains(proto,r"ospf 30",r"eigrp 3030")
                elif aid=="D3":ok="10.90.0.0/16" in pl and not re.search(r"10\.90\.0\.0/16\s+(?:le|ge)",pl,re.I)
                elif aid=="D4":ok="0.0.0.0/0" not in self.cmd(d,"show ip route eigrp") or "333" in self.cmd(d,"show ip eigrp topology 0.0.0.0/0") or "334" in self.cmd(d,"show ip eigrp topology 0.0.0.0/0")
                elif aid=="D5":ok=self.contains(rm,r"deny",r"tag 330")
                elif aid=="D7":ok=self.contains(rm,r"10000 100 255 1 1500")
                elif aid in {"D8","D9"}:ok="10.90.0.0/16" in pl and "tag 30" in rm.lower()
                elif aid=="D10":ok="10.91.0.0/16" in pl and not re.search(r"10\.91\.0\.0/16\s+(?:le|ge)",pl,re.I)
                elif aid=="D11":ok=self.contains(rm,r"deny",r"tag 30")
                elif aid=="D14":ok=bool(re.search(r"route-map\s+\S*(?:OSPF|EIGRP|BGP)\S*",rm,re.I))
                elif aid=="D15":ok=self.contains(rm,r"0\.0\.0\.0/0|prefix-list",r"tag 333") if d=="IR3" else True
                elif aid=="D16":ok=self.contains(rm,r"1000 10 255 1 1500") if d=="IR3" else True
                elif aid=="D17":ok=self.contains(rm,r"0\.0\.0\.0/0|prefix-list",r"tag 334") if d=="IR2" else True
                elif aid=="D18":ok=self.contains(rm,r"10000 100 255 1 1500") if d=="IR2" else True
                else:ok=self.absent(rm,r"redistribute connected",r"redistribute static")
                tests.append(ok);labels.append(d)
            return self.ratio(aid,tests,labels=labels)
        if aid=="D6": return self.ratio(aid,["30" in self.cmd(d,"show ip eigrp topology 10.90.0.0/16") for d in ["DS3","DS4"]],labels=["DS3","DS4"])
        if aid=="D12": return self.ratio(aid,["330" in self.route(d,"10.91.0.0") for d in ["CR1","CR2","DS1","DS2"]],labels=["CR1","CR2","DS1","DS2"])
        if aid=="D13":
            out=self.cmd("CR1","show ip ospf database external 10.91.0.0")
            return self.ratio(aid,[self.contains(out,r"Metric Type\s*:\s*1",r"Metric\s*:\s*50",r"Route Tag\s*:\s*330")],labels=["CR1"])
        if aid=="D20":
            tests=[];labels=[];details=[]
            for d in ["CR1","CR2","DS1","DS2"]:
                out=self.route(d,"10.91.0.0")
                prefix_ok=bool(re.search(r"Routing entry for\s+10\.91\.0\.0/16\b",out,re.I))
                ospf_ok=bool(re.search(r'Known via\s+"ospf 30"',out,re.I))
                type_ok=bool(re.search(
                    r"\btype\s+extern(?:al)?\s+1\b|"
                    r"\bexternal\s+type\s+1\b|"
                    r"\bO E1\b",
                    out,re.I))
                tag_ok=bool(re.search(
                    r"\b(?:Tag|Route tag|External Route Tag)\s*:?\s*330\b",
                    out,re.I))
                next_hop_ok=bool(re.search(
                    r"(?:Last update from|^\s*\*?)\s*10\.90\.0\.\d+\b",
                    out,re.I|re.M))
                tests.append(prefix_ok and ospf_ok and type_ok and tag_ok and next_hop_ok)
                labels.append(d)
                metric_match=re.search(r'Known via\s+"ospf 30".*?\bmetric\s+(\d+)',out,re.I)
                details.append(
                    f"{d}: prefix={'OK' if prefix_ok else 'FAIL'}, "
                    f"protocol={'O E1' if ospf_ok and type_ok else 'FAIL'}, "
                    f"tag330={'OK' if tag_ok else 'FAIL'}, "
                    f"next-hop={'OK' if next_hop_ok else 'FAIL'}, "
                    f"RIB-metric={metric_match.group(1) if metric_match else 'UNKNOWN'} "
                    f"(может быть больше 50)")
            return self.ratio(aid,tests,"; ".join(details),labels)
        if aid=="D21": return self.ratio(aid,[self.contains(self.route(d,"10.90.0.0"),r"Known via.*eigrp",r"external|D EX",r"30") for d in ["DS3","DS4"]],labels=["DS3","DS4"])
        if aid=="D22":
            ospf="".join(self.cmd(d,"show ip route ospf") for d in OSPF);eig="".join(self.cmd(d,"show ip route eigrp") for d in EIGRP)
            return self.ratio(aid,[not re.search(r"O E1\s+10\.90\.0\.0/16",ospf),not re.search(r"D EX\s+10\.91\.0\.0/16",eig),not re.search(r"(?:O E1|D EX).*10\.(?:90|91)\.(?:10|40|50|130|150)\.0/24",ospf+eig)])

        # E — BGP policy
        if aid in {"E1","E2","E3","E4","E5"}:
            d={"E1":"IR1","E2":"IR2","E3":"IR3","E4":"BR1","E5":"BR2"}[aid]
            return self.ratio(aid,[self.ebgp_session_ok(d)],labels=[d])
        if aid=="E6": return self.ratio(aid,[self.contains(self.cmd(d,f"show bgp ipv4 unicast neighbors {PEERS[d]}"),r"hold time is 30",r"keepalive interval is 10") for d in EDGES],labels=EDGES)
        if aid=="E7": return self.ratio(aid,[self.bgp_established("IR1",LOOPBACKS["IR2"]),self.bgp_established("IR2",LOOPBACKS["IR1"])],labels=["IR1","IR2"])
        if aid=="E8":
            tests=[]
            for d,p in [("IR1",LOOPBACKS["IR2"]),("IR2",LOOPBACKS["IR1"])]:
                adv=self.cmd(d,f"show bgp ipv4 unicast neighbors {p} advertised-routes")
                tests.append("0.0.0.0/0" not in adv and "10.92.0.0/16" in adv and "10.93.0.0/16" in adv)
            return self.ratio(aid,tests,labels=["IR1","IR2"])
        accepted={"E9":("IR1",["0.0.0.0/0","10.92.0.0/16","10.93.0.0/16"]),"E10":("IR2",["0.0.0.0/0","10.92.0.0/16","10.93.0.0/16"]),"E11":("IR3",["0.0.0.0/0","10.92.0.0/16","10.93.0.0/16"]),"E12":("BR1",["0.0.0.0/0","10.90.0.0/16","10.91.0.0/16","10.93.0.0/16"]),"E13":("BR2",["0.0.0.0/0","10.90.0.0/16","10.91.0.0/16","10.92.0.0/16"])}
        if aid in accepted:
            d,prefixes=accepted[aid];out=self.cmd(d,f"show bgp ipv4 unicast neighbors {PEERS[d]} routes")
            actual=self.bgp_table_prefixes(out)
            expected=set(prefixes)
            if actual or "Total number of prefixes" in out:
                tests=[p in actual for p in prefixes]
                tests.append(actual==expected)
                details=f"expected={sorted(expected)}; actual={sorted(actual)}; последняя проверка — отсутствие лишних prefixes"
                return self.ratio(aid,tests,details,[d]*len(tests))
            # Some IOS images require inbound soft-reconfiguration for
            # `neighbor routes`; use individual operational BGP lookups then.
            lookups={p:self.bgp_prefix(d,p) for p in prefixes}
            tests=[bool(self.bgp_table_prefixes(text)) or
                   bool(re.search(rf"\b{re.escape(p.removesuffix('/0'))}\b",text))
                   for p,text in lookups.items()]
            return self.ratio(aid,tests,"Neighbor routes недоступны; проверены individual BGP lookups",[d]*len(tests))
        if aid in {"E14","E15"}:
            d,lp=("IR1","250") if aid=="E14" else ("IR2","150")
            return self.ratio(aid,[lp in self.bgp_prefix(d,p) for p in ["0.0.0.0/0","10.92.0.0/16","10.93.0.0/16"]],labels=[d]*3)
        if aid in {"E16","E17","E18","E19"}:
            if aid=="E16":checks=[("IR1",["10.90.0.0/16","198.51.100.96/29"]),("IR2",["10.90.0.0/16","198.51.100.96/29"])]
            elif aid=="E17":checks=[("IR1",["10.90.0.0/16"]),("IR2",["10.90.0.0/16"])]
            elif aid=="E18":checks=[("IR3",["10.91.0.0/16","198.51.100.104/29"])]
            else:checks=[("BR1",["10.92.0.0/16"]),("BR2",["10.93.0.0/16"])]
            tests=[];labels=[]
            for d,prefixes in checks:
                adv=self.cmd(d,f"show bgp ipv4 unicast neighbors {PEERS[d]} advertised-routes")
                tests.append(all(p in adv for p in prefixes));labels.append(d)
                for p in prefixes:self.route(d,p.split('/')[0])
            return self.ratio(aid,tests,"Advertised routes и operational RIB source",labels)
        if aid=="E20":
            tests=[];labels=[]
            for d in EDGES:
                adv=self.cmd(d,f"show bgp ipv4 unicast neighbors {PEERS[d]} advertised-routes")
                tests.append(not re.search(r"(?:0\.0\.0\.0/0|10\.(?:90|91|92|93)\.0\.0/16).*(?:65000)",adv));labels.append(d)
            return self.ratio(aid,tests,"Нет повторной рекламы provider/чужого customer route",labels)

        # F — normal defaults and controlled failover
        if aid in {"F1","F3"}:
            d="BR1" if aid=="F1" else "BR2";out=self.route(d,"0.0.0.0")
            return self.ratio(aid,[self.contains(out,r"Known via.*bgp|B\*",r"203\.0\.113") and "250/0" not in out],labels=[d])
        if aid in {"F2","F4","F7","F8","F9"}:
            if not self.disruptive:return self.skip(aid,"Отказной тест отключен параметром --skip-disruptive")
            if aid in {"F2","F4"}:
                d="BR1" if aid=="F2" else "BR2";peer=PEERS[d];restored=False
                try:
                    self.privileged_exec(d,"configure terminal")
                    self.privileged_exec(d,f"router bgp {ASNS[d]}")
                    self.privileged_exec(d,f"neighbor {peer} shutdown")
                    self.privileged_exec(d,"end")
                    failed=self.wait_for(lambda:self.floating_default_active(d),60)
                finally:
                    self.privileged_exec(d,"configure terminal");self.privileged_exec(d,f"router bgp {ASNS[d]}");self.privileged_exec(d,f"no neighbor {peer} shutdown");self.privileged_exec(d,"end")
                    restored=self.wait_for(lambda:self.bgp_established(d,peer),90)
                details=(
                    f"FAILOVER floating-static AD250={'PASS' if failed else 'FAIL'}; "
                    f"RESTORE BGP Established={'PASS' if restored else 'FAIL'}"
                )
                return self.ratio(aid,[failed,restored],details,[d,d])
            d={"F7":"IR1","F8":"IR2","F9":"IR3"}[aid];iface=WAN[d][0];restored=False
            try:
                self.configure_interface_state(d,iface,True)
                if aid=="F7":failed=self.wait_for(
                    lambda:(lambda metrics:10 not in metrics and 100 in metrics)(
                        self.ospf_external_metrics(
                            self.cmd("CR1","show ip ospf database external 0.0.0.0"))),90)
                elif aid=="F8":failed=self.wait_for(
                    lambda:(lambda metrics:100 not in metrics and 10 in metrics)(
                        self.ospf_external_metrics(
                            self.cmd("CR1","show ip ospf database external 0.0.0.0"))),90)
                else:failed=self.wait_for(lambda:"334" in self.cmd("DS3","show ip eigrp topology 0.0.0.0/0"),90)
            finally:
                self.configure_interface_state(d,iface,False);restored=self.wait_for(lambda:self.bgp_established(d,PEERS[d]),120)
            expected=(
                "OSPF metric 10 withdrawn, metric 100 remains" if aid=="F7" else
                "OSPF metric 100 withdrawn, metric 10 remains" if aid=="F8" else
                "EIGRP default tag 334 selected"
            )
            details=(
                f"FAILOVER {expected}={'PASS' if failed else 'FAIL'}; "
                f"RESTORE {d}-ISP1 BGP Established={'PASS' if restored else 'FAIL'}"
            )
            return self.ratio(aid,[failed,restored],details,[d,d])
        if aid=="F5":
            out=self.route("CR1","0.0.0.0")+self.cmd("CR1","show ip ospf database external 0.0.0.0")
            return self.ratio(aid,[self.contains(out,r"Metric\s*:\s*10")],labels=["CR1"])
        if aid=="F6": return self.ratio(aid,["333" in self.cmd(d,"show ip eigrp topology 0.0.0.0/0") for d in ["DS3","DS4"]],labels=["DS3","DS4"])
        if aid=="F10": return self.ratio(aid,[self.bgp_established(d,PEERS[d]) for d in EDGES]+["333" in self.cmd("DS3","show ip eigrp topology 0.0.0.0/0")],labels=EDGES+["DS3"])

        # G — OSPFv3
        if aid=="G1": return self.ratio(aid,[bool(self.cmd(d,"show ipv6 protocols")) and bool(self.cmd(d,"show ipv6 route")) for d in INFRA],labels=INFRA)
        if aid=="G2":
            tests=[];labels=[]
            for d in INFRA:
                out=self.cmd(d,"show ipv6 interface brief")
                tests.append(V6_LOOPBACKS[d].lower() in out.lower());labels.append(d)
                for ip in V6_ROUTED[d].values():tests.append(ip.lower() in out.lower());labels.append(d)
            return self.ratio(aid,tests,"9 Loopback /128 и 26 routed-link addresses",labels)
        if aid=="G3": return self.ratio(aid,[self.contains(self.cmd(d,"show ipv6 ospf"),r"Routing Process.*30",re.escape(LOOPBACKS[d])) for d in INFRA],labels=INFRA)
        if aid=="G4": return self.ratio(aid,["Loopback0" not in self.cmd(d,"show ipv6 ospf interface brief") and bool(self.cmd(d,"show ipv6 route ospf")) for d in INFRA],labels=INFRA)
        if aid=="G5": return self.ratio(aid,["FULL" in self.cmd(d,"show ipv6 ospf neighbor") for d in ["IR1","IR2","CR1","CR2","DS1","DS2"]],labels=["IR1","IR2","CR1","CR2","DS1","DS2"])
        if aid=="G6": return self.ratio(aid,["FULL" in self.cmd(d,"show ipv6 ospf neighbor") for d in ["IR2","IR3"]],labels=["IR2","IR3"])
        if aid=="G7": return self.ratio(aid,["FULL" in self.cmd(d,"show ipv6 ospf neighbor") for d in ["DS3","DS4"]],labels=["DS3","DS4"])
        if aid=="G8":
            tests=[];labels=[]
            for d in INFRA:
                for target in V6_LOOPBACKS.values():tests.append("Success rate is 100 percent" in self.cmd(d,f"ping ipv6 {target} source Loopback0 repeat 2"));labels.append(d)
            scope="".join(self.cmd(d,"show ipv6 ospf interface brief") for d in INFRA)
            tests.append(not re.search(r"GigabitEthernet0/3|Vlan(?:10|40|50|130|150)",scope,re.I));labels.append("scope")
            return self.ratio(aid,tests,"IPv6 Loopback matrix и отсутствие unintended scope",labels)

        # H — functional integrity
        if aid in {"H1","H2","H3"}:
            pc={"H1":"PC1","H2":"PC3","H3":"PC4"}[aid]
            targets={"PC1":["10.91.130.10","198.51.100.200"],"PC3":["10.90.10.1","10.91.130.10","198.51.100.200"],"PC4":["10.90.10.1","10.91.130.10","198.51.100.200"]}[pc]
            try:return self.ratio(aid,[self.vpcs_ping(pc,t,2)[0] for t in targets],labels=[pc]*len(targets))
            except Exception as exc:return self.skip(aid,f"Нет VPCS console: {exc}")
        if aid=="H4":
            try:return self.ratio(aid,[self.vpcs_ping("PC2","198.51.100.200",2)[0],not self.vpcs_ping("PC2","10.91.150.10",2)[0]],labels=["PC2","PC2"])
            except Exception as exc:return self.skip(aid,f"Нет PC2 console: {exc}")
        if aid=="H5":
            addresses={**LOOPBACKS,"AS1":"10.90.50.21","AS2":"10.90.50.22","AS3":"10.92.50.21","AS4":"10.93.50.21"}
            try:return self.ratio(aid,[self.linux_tcp_probe("SVR2",ip,22,record_label=d) for d,ip in addresses.items()],labels=list(addresses))
            except Exception as exc:return self.skip(aid,f"Нет JUDGE-SRV SSH console: {exc}")
        if aid=="H6": return self.skip(aid,"SNMPv3 secrets находятся в защищенных Expert Data и намеренно не вшиваются в checker")
        if aid=="H7":
            out=self.cmd("IR3","show ip nat translations")+self.cmd("IR3","show ip nat statistics")
            return self.ratio(aid,["198.51.100.105" in out],"Дополнительно выполнить HTTP с PC3/PC4",["IR3"])
        if aid=="H8":
            tests=[];labels=[]
            for d in DEVICES:
                tests.append(bool(self.cmd(d,"show ntp associations")));labels.append(d)
                tests.append(bool(self.cmd(d,"show logging")));labels.append(d)
            for d in EDGES:tests.append(bool(self.cmd(d,"show ip flow export")+self.cmd(d,"show flow exporter")));labels.append(d)
            return self.ratio(aid,tests,"NTP / Syslog / NetFlow operational evidence; SNMP manager test см. H6",labels)
        if aid=="H9": return self.ratio(aid,[bool(self.cmd(d,"show access-lists")) and bool(self.cmd(d,"show ip nat statistics")) for d in EDGES],labels=EDGES)
        if aid=="H10": return self.ratio(aid,[self.bgp_established(d,PEERS[d]) for d in EDGES]+["FULL" in self.cmd(d,"show ip ospf neighbor") for d in OSPF]+[bool(self.cmd(d,"show ip eigrp neighbors")) for d in EIGRP],labels=EDGES+OSPF+EIGRP)
        raise KeyError(aid)

    def print_result(self,result):
        color={"PASS":base.GREEN,"PART":base.PURPLE,"FAIL":base.RED,"SKIP":base.YELLOW}[result.status]
        fraction=f" ({result.passed}/{result.total})" if result.total else ""
        print(f"\n{base.CYAN}Результат аспекта:{base.NC}")
        print(f"{color}[{result.status}] {result.aspect.id} {result.score:.3f}/{result.aspect.mark:.3f}{fraction} — {result.aspect.title}{base.NC}")
        if result.details:print(f"  {result.details}")
        instruction=HOST_CHECK_INSTRUCTIONS.get(result.aspect.id)
        if instruction:print(f"{base.YELLOW}Дополнительная функциональная проверка:{base.NC}\n  {instruction}")
    def report(self):
        totals=defaultdict(float);maximums=defaultdict(float)
        print(f"\n{base.PURPLE}{'#'*90}\nC3 Marking Scheme Report\n{'#'*90}{base.NC}")
        for r in self.results:
            totals[r.aspect.id[0]]+=r.score;maximums[r.aspect.id[0]]+=r.aspect.mark
            color={"PASS":base.GREEN,"PART":base.PURPLE,"FAIL":base.RED,"SKIP":base.YELLOW}[r.status]
            frac=f" ({r.passed}/{r.total})" if r.total else ""
            print(f"{color}[{r.status:4}] {r.aspect.number:03d} {r.aspect.id:3} {r.score:.3f}/{r.aspect.mark:.3f}{frac} — {r.aspect.title}{base.NC}")
            if r.details:print("       "+r.details)
        for c in "ABCDEFGH":print(f"  {c}: {totals[c]:.3f}/{maximums[c]:.3f}")
        print(f"{base.CYAN}TOTAL: {sum(totals.values()):.3f}/{sum(maximums.values()):.3f}{base.NC}")

def start_number(value):
    value=value.upper()
    if value.isdigit() and 1<=int(value)<=100:return int(value)
    if value in BY_ID:return BY_ID[value].number
    found=next((a.number for a in ASPECTS if a.id.startswith(value)),None)
    if found:return found
    raise ValueError("Используйте A-H, A1-H10 или порядковый номер 1-100")

def choose_running_session(pnet_url, cookie, requested_id=None):
    """Show every active PNETLab session and let the expert select its ID."""
    try:
        users=filter_user(pnet_url,cookie).json().get("data",{}).get("data_table",[])
    except Exception:
        users=[]
    pod_users={str(u.get("pod")):u.get("username","?") for u in users if u.get("pod") is not None}

    count_data=get_sessions_count(pnet_url,cookie).json().get("data",0)
    try:count=max(1,int(count_data))
    except (TypeError,ValueError):count=25
    sessions=filter_session(pnet_url,cookie,1,count).json().get("data",{}).get("data_table",[])
    available={}
    print(f"\n{base.PURPLE}===== Активные сессии лабораторий ====={base.NC}")
    for session in sessions:
        raw_id=session.get("lab_session_id")
        try:sid=int(raw_id)
        except (TypeError,ValueError):continue
        path=session.get("lab_session_path") or "?"
        status=session.get("status") or session.get("lab_session_status") or "?"
        user=pod_users.get(str(session.get("lab_session_pod")),"?")
        available[sid]=session
        print(f"  [{sid}] user: {user} | status: {status} | path: {path}")
    print(f"{base.PURPLE}========================================{base.NC}")
    if not available:raise RuntimeError("Нет активных сессий лабораторий")

    if requested_id is not None:
        if requested_id not in available:
            raise RuntimeError(f"Сессия ID {requested_id} отсутствует в списке активных")
        print(f"{base.YELLOW}[i] Выбрана сессия ID {requested_id}{base.NC}")
        return requested_id

    while True:
        try:answer=input("Введите ID лаборатории из списка: ").strip()
        except EOFError as exc:raise RuntimeError("Невозможно выбрать сессию без интерактивного ввода; используйте --session-id") from exc
        try:sid=int(answer)
        except ValueError:
            print(f"{base.RED}[!] Введите числовой ID из списка.{base.NC}")
            continue
        if sid in available:
            print(f"{base.YELLOW}[i] Выбрана сессия ID {sid}{base.NC}")
            return sid
        print(f"{base.RED}[!] ID {sid} отсутствует в списке активных сессий.{base.NC}")

def arguments():
    p=argparse.ArgumentParser(description="WSC2026 C3 PNETLab IOS scorer")
    p.add_argument("--start",default="A",help="A-H, aspect ID или 1-100")
    p.add_argument("--session-id",type=int,help="выбрать активную сессию по ID без интерактивного запроса")
    p.add_argument("--no-pause",action="store_true")
    p.add_argument("--skip-disruptive",action="store_true",help="не выполнять контролируемые failover tests")
    return p.parse_args()

def main():
    args=arguments();start=start_number(args.start)
    with open(HERE/"creds.json",encoding="utf-8") as f:creds=json.load(f)
    cookie=base.login(creds["pnet_url"],creds["username"],creds["password"])
    try:
        sid=choose_running_session(creds["pnet_url"],cookie,args.session_id)
        base.join_session(creds["pnet_url"],sid,cookie)
        consoles=base.build_node_console_map(base.get_nodes(creds["pnet_url"],cookie).json())
        scorer=Scorer(consoles,creds,disruptive=not args.skip_disruptive)
        try:scorer.connect();scorer.run(start,pause=not args.no_pause);scorer.report()
        finally:scorer.close()
    finally:
        try:base.logout(creds["pnet_url"])
        except Exception:pass

if __name__=="__main__":main()
