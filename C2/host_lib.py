"""Console adapters for C2 Linux SSH nodes and PNETLab VPCS nodes."""
from __future__ import annotations
import re
import socket
import time

class VPCSSession:
    def __init__(self,host,port,label,timeout=8):
        self.host=host;self.port=port;self.label=label;self.timeout=timeout;self.sock=None
    def connect(self):
        self.sock=socket.create_connection((self.host,self.port),self.timeout)
        self.sock.settimeout(.3);self.sock.sendall(b"\r\n");self._read(2)
    def _read(self,max_wait,wait_pattern=None):
        if not self.sock:return ""
        chunks=[];end=time.monotonic()+max_wait;last=time.monotonic()
        while time.monotonic()<end:
            try:
                data=self.sock.recv(65535)
                if not data:break
                chunks.append(data);last=time.monotonic()
                text=b"".join(chunks).decode(errors="replace")
                if wait_pattern and re.search(wait_pattern,text,re.I|re.M):break
                if not wait_pattern and re.search(r"(?m)(?:VPCS|PC\d+)[^\r\n]*>\s*$",text):break
            except socket.timeout:
                if not wait_pattern and chunks and time.monotonic()-last>.4:break
        return b"".join(chunks).decode(errors="replace").replace("\r","")
    def exec(self,command,timeout=None):
        if not self.sock:self.connect()
        self._read(.3);self.sock.sendall((command+"\r\n").encode())
        wait_pattern=(r"\bDORA\b|(?:VPCS|PC\d+)[^\r\n]*>\s*$"
                      if re.fullmatch(r"\s*ip\s+dhcp\s*",command,re.I) else None)
        raw=self._read(timeout or self.timeout,wait_pattern=wait_pattern)
        lines=[]
        for line in raw.splitlines():
            s=line.strip()
            if not s or s==command or re.fullmatch(r"(?:VPCS|PC\d+)[^>]*>",s):continue
            lines.append(line)
        return "\n".join(lines)
    def close(self):
        if self.sock:
            try:self.sock.close()
            except OSError:pass
        self.sock=None

class LinuxSSHSession:
    def __init__(self,host,port,label,username,password,timeout=10):
        self.host=host;self.port=port;self.label=label;self.username=username;self.password=password;self.timeout=timeout;self.client=None
    def connect(self):
        try:import paramiko
        except ImportError as exc:raise RuntimeError("установите dependency: python -m pip install -r requirements.txt") from exc
        client=paramiko.SSHClient();client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(self.host,port=self.port,username=self.username,password=self.password,
                       timeout=self.timeout,banner_timeout=self.timeout,auth_timeout=self.timeout,
                       look_for_keys=False,allow_agent=False)
        self.client=client
    def exec(self,command,timeout=15):
        if not self.client:self.connect()
        _,stdout,stderr=self.client.exec_command(command,timeout=timeout)
        return (stdout.read()+stderr.read()).decode(errors="replace").strip()
    def close(self):
        if self.client:self.client.close()
        self.client=None
