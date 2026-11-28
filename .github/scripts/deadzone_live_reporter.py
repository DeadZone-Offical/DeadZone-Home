#!/usr/bin/env python3
"""Best-effort signed live events; never change the ROM engine's exit status."""
import os
import re
import sys
import threading
import time
from pathlib import Path

SIZE = r"(\d+(?:\.\d+)?)\s*([KMGT]?i?B)"
def size_bytes(value, unit):
    base = 1024 if "i" in unit else 1000
    power = "BKMGT".index(unit[0]) if unit != "B" else 0
    return int(float(value)*base**power)

def eta_seconds(value):
    parts = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", value)
    if not parts or not any(parts.groups()):
        return None
    return sum(int(n or 0)*scale for n,scale in zip(parts.groups(),(3600,60,1)))

class LiveReporter:
    def __init__(self, phase):
        self.env = dict(os.environ)
        self.project = self.env.get("DEADZONE_PROJECT","")
        self.request = self.env.get("DEADZONE_REQUEST_ID","")
        self.condition = threading.Condition()
        self.closed = False
        self.snapshot = None
        self.meta = {}
        self.pending_meta = {}
        self.artifact = 0
        self.worker = None
        root = self.env.get("GITHUB_WORKSPACE")
        if not root or not self.project or not self.request or not self.env.get("DEADZONE_CALLBACK_URL"):
            return
        if not (self.env.get("DEADZONE_EVENT_SECRET") or self.env.get("BUILD_PROGRESS_SECRET")):
            return
        sys.path.insert(0,str(Path(root)/"runtime"))
        try:
            from build_stage import build_stage_payload, post_stage_event
            self.make = build_stage_payload
            self.post = post_stage_event
        except Exception:
            return
        self.worker = threading.Thread(target=self.send_loop,daemon=True)
        self.worker.start()
        stage, kind, title = {
            "ROM preparation":("starting","preparing","Preparing ROM"),
            "Partition & super rebuild":("building","repacking","Rebuilding partitions"),
            "ROM packaging":("packaging","packaging","Packaging ROM"),
            "Cloud upload":("uploading","uploading","Uploading to Google Drive"),
            "Cloud verification":("uploading","verifying","Verifying ROM integrity"),
        }.get(phase,("starting","preparing","Preparing build"))
        self.update(stage,kind,title)

    def update(self, stage, kind, title, **metrics):
        if not self.worker:
            return
        with self.condition:
            if self.artifact:
                metrics.setdefault("artifactSize",self.artifact)
            self.snapshot = (stage,kind,title,dict(metrics),dict(self.meta),self.artifact)
            self.condition.notify_all()

    def send_loop(self):
        last_sent = 0.0
        previous = None
        while True:
            with self.condition:
                while not self.closed and self.snapshot is None:
                    self.condition.wait(1)
                snap = self.snapshot
                if snap is None:
                    return
                now = time.monotonic()
                # Stage transitions are immediate. Numeric progress is rate-limited.
                if not self.closed and previous and snap[:3]==previous[:3] and now-last_sent<15:
                    self.condition.wait(max(0.1,15-(now-last_sent)))
                    continue
                if self.closed and snap == previous:
                    return
            stage,kind,title,metrics,meta,artifact = snap
            try:
                payload = self.make(stage,project=self.project,request_id=self.request,
                                    run_id=self.env.get("GITHUB_RUN_ID",""),env=self.env)
                run = self.env.get("GITHUB_RUN_ID","")
                repo = self.env.get("GITHUB_REPOSITORY","")
                if run.isdigit() and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",repo):
                    payload["run_url"] = f"https://github.com/{repo}/actions/runs/{run}"
                rn = self.env.get("GITHUB_RUN_NUMBER","")
                if rn.isdigit() and int(rn)>0:
                    payload["run_number"]=int(rn)
                payload.update(meta)
                if artifact:
                    payload["output_size"]=artifact
                payload["telemetry"]={"stage":kind,"operation":"dz-live:"+title,**metrics}
                self.post(payload,env=self.env,attempts=1)
            except Exception:
                # A failed callback must not block the engine or disclose credentials.
                pass
            previous = snap
            last_sent = time.monotonic()
            if self.closed:
                return

    def close(self):
        if self.worker:
            with self.condition:
                self.closed=True
                self.condition.notify_all()
            self.worker.join(timeout=2)

    def line(self, line):
        # Only parse known fields and numerical progress, never forward raw log lines.
        try:
            self._line(line)
        except (ValueError, OverflowError):
            pass

    def _line(self,line):
        if not self.worker:
            return
        # BuildInfo is a contiguous, engine-authored metadata block.
        if self.project != "port_xiaomi":
            m = re.match(r"^- (Device Name|Codename|BuildRegion|Android|Xiaomi Version|BuildTool Version|OS Type):\s*(.+)$",line)
            if m:
                label,value=m.groups()
                if label=="Xiaomi Version" and not re.fullmatch(r"(?:OS|V)[A-Za-z0-9.]{4,80}",value):
                    return
                field={"Device Name":"stock_device_name","Codename":"stock_codename","BuildRegion":"stock_region","Android":"stock_android_version","Xiaomi Version":"stock_rom_version","BuildTool Version":"deadzoneVersion","OS Type":"filesystem"}[label]
                limit=16 if field=="stock_android_version" else 80
                if len(value)<=limit and re.fullmatch(r"[A-Za-z0-9 ._()+-]+",value):
                    self.pending_meta[field]=value
                return
            if self.pending_meta and (re.fullmatch(r"-{10,}",line) or "Debloat" in line or "Starting Apply Universal" in line):
                # Send known metadata together, rather than creating half-populated panels.
                info=dict(self.pending_meta)
                self.pending_meta.clear()
                self.meta.update({k:v for k,v in info.items() if k.startswith("stock_")})
                version=info.get("deadzoneVersion")
                filesystem=info.get("filesystem")
                self.update("reading_rom","inspecting","Device information detected",**({"deadzoneVersion":version} if version else {}),**({"filesystem":filesystem} if filesystem else {}))
        if "starting a download" in line or re.search(r"Downloading \d+ item",line):
            self.update("downloading","downloading","Downloading ROM")
        m=re.search(r"\[#\w+\s+"+SIZE+r"/"+SIZE+r"\(\d+%\).*?\bDL:"+SIZE+r"(?:\s+ETA:([0-9hms]+))?",line)
        if m:
            d,du,t,tu,s,su,eta=m.groups()
            total=size_bytes(t,tu)
            if total>0:
                metrics={"processedBytes":min(size_bytes(d,du),total),"totalBytes":total,"bytesPerSecond":size_bytes(s,su)}
                if eta and (seconds:=eta_seconds(eta)) is not None:
                    metrics["etaSeconds"]=seconds
                self.update("downloading","downloading","Downloading ROM",**metrics)
            return
        if "Extracting files payload.bin" in line or "Unpacking payload.bin" in line or "[Payload] Extracting partitions" in line:
            self.update("reading_rom","extracting","Extracting ROM partitions")
        elif "Gathering Devices Infomations" in line or "Gathering Device Information" in line:
            self.update("reading_rom","inspecting","Reading device information")
        elif "Starting Apply Universal File" in line or "Starting Update File" in line or "Removing directory:" in line:
            self.update("building","modifying","Applying DeadZone modifications")
        elif re.search(r"Super partitions: \d+",line):
            self.update("building","repacking","Creating Super image")
        elif "ZIP package built successfully" in line or "Archive written:" in line:
            self.update("packaging","packaging","Packaging ROM")
        elif (m:=re.search(r"Package size:\s*"+SIZE,line)):
            self.artifact=size_bytes(*m.groups())
            self.update("packaging","packaging","ROM package ready")
        elif (m:=re.search(r"Transferred:\s*"+SIZE+r"\s*/\s*"+SIZE+r",\s*\d+%",line)):
            d,du,t,tu=m.groups()
            total=size_bytes(t,tu)
            if total:
                self.update("uploading","uploading","Uploading to Google Drive",processedBytes=min(size_bytes(d,du),total),totalBytes=total)
