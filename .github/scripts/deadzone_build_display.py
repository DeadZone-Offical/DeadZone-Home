#!/usr/bin/env python3
"""Presentation only: never decide build, upload or release success."""
import datetime as dt
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from deadzone_live_reporter import LiveReporter

ENV = os.environ
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
SAFE_ID = r"[A-Za-z0-9_.+-]+"

def clean(value):
    return html.escape(str(value or "").replace("\n", " ").replace("\r", " ")[:240]).replace("|", "&#124;").replace(chr(96), "&#96;").replace("[", "&#91;").replace("]", "&#93;")

def drive_link(value):
    try:
        u = urllib.parse.urlsplit(value)
        if u.scheme != "https" or u.netloc != "drive.google.com" or u.fragment:
            return ""
        if u.path in ("/open", "/uc"):
            ids = urllib.parse.parse_qs(u.query).get("id", [])
            if len(ids) == 1 and re.fullmatch(r"[A-Za-z0-9_-]{10,}", ids[0]):
                return "https://drive.google.com/open?id=" + ids[0]
        m = re.fullmatch(r"/file/d/([A-Za-z0-9_-]{10,})(?:/view)?/?", u.path)
        if m:
            return "https://drive.google.com/file/d/" + m[1] + "/view"
    except (ValueError, TypeError):
        pass
    return ""

def duration(a, b):
    try:
        sec = max(0, int((dt.datetime.fromisoformat(b.replace("Z","+00:00")) -
                         dt.datetime.fromisoformat(a.replace("Z","+00:00"))).total_seconds()))
        h, rem = divmod(sec, 3600)
        m, s = divmod(rem, 60)
        return (f"{h}h " if h else "") + f"{m:02d}m {s:02d}s"
    except (ValueError, TypeError, AttributeError):
        return "—"

def timings():
    try:
        repo = ENV["GITHUB_REPOSITORY"]
        run = int(ENV["GITHUB_RUN_ID"])
        attempt = int(ENV.get("GITHUB_RUN_ATTEMPT", "1"))
        token = ENV["DZ_TIMING_TOKEN"]
        req = urllib.request.Request(
            f"{ENV.get('GITHUB_API_URL','https://api.github.com')}/repos/{repo}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100",
            headers={"Authorization": "Bearer "+token, "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=8) as response:
            jobs = json.load(response).get("jobs", [])
        if len(jobs) != 1:
            return {}
        return {s["name"]: duration(s.get("started_at"), s.get("completed_at")) for s in jobs[0].get("steps", [])}
    except Exception:
        return {}

def summary():
    project = ENV.get("DZ_SUMMARY_PROJECT", "ROM")
    status = ENV.get("DZ_JOB_STATUS", "unknown")
    verdict = {"success":"✅ Build completed", "failure":"❌ Build did not complete", "cancelled":"⏹️ Build cancelled"}.get(status,"ℹ️ Build status unavailable")
    rows = []
    for line in ENV.get("DZ_SUMMARY_STAGES","").splitlines():
        bits = line.split("|",2)
        if len(bits) == 3:
            rows.append(bits)
    times = timings()
    out = ["# DeadZone Build System", f"**{clean(project)} Edition** · Developed by MEZO", "", f"## {verdict}", ""]
    name = ENV.get("DEADZONE_RESULT_NAME") or ENV.get("ROM_FILENAME") or ""
    codename = ENV.get("DEADZONE_RELEASE_CODENAME") or ENV.get("PUBLISH_CODENAME") or ""
    version = ENV.get("DEADZONE_RELEASE_ROM_VERSION") or ""
    android = ""
    m = re.search(r"_(?:Stable|Lite|Ninja|Port)_V[0-9.]+_([A-Za-z0-9-]+)_((?:OS|V)[A-Za-z0-9.]+)_.*-A([0-9]+)\.zip$", name, re.I)
    if m:
        codename = codename or m[1].upper()
        version = version or m[2]
        android = m[3]
    out += ["### Release details", "", "| Field | Value |", "| :-- | :-- |"]
    fields = [("Device", ENV.get("DEADZONE_RELEASE_DEVICE_NAME")), ("Codename", codename),
              ("ROM version", version), ("HyperOS / MIUI", ENV.get("DEADZONE_RELEASE_OS")),
              ("Android", android), ("Artifact", name)]
    for key, value in fields:
        if value:
            out.append(f"| {key} | {clean(value)} |")
    size = ENV.get("DEADZONE_FILE_SIZE") or ENV.get("DEADZONE_RESULT_SIZE") or ""
    if size.isdigit() and int(size)>0:
        out.append(f"| Size | {int(size)/1073741824:.2f} GiB |")
    if not any(v for _,v in fields) and not size:
        out.append("| Metadata | Not available |")
    out += ["", "### Build stages", "", "| Stage | Result | Duration |", "| :-- | :-- | --: |"]
    labels = {"success":"✅ Completed","failure":"❌ Failed","cancelled":"⏹️ Cancelled","skipped":"— Skipped"}
    for label, actual, state in rows:
        if state == "skipped" and ("integrated" in label or (project=="Stable" and "integrated" not in label and any("integrated" in x[0] and x[2]=="success" for x in rows))):
            continue
        out.append(f"| {clean(label)} | {labels.get(state,'— Not run')} | {times.get(actual,'—')} |")
    out += ["", "### Delivery & integrity", ""]
    if project.startswith("Fastboot"):
        out.append(f"- Publisher dispatch: **{clean(ENV.get('STABLE_PUBLISH_STATUS') or 'Not queued')}**")
        out.append(f"- Device publication: **{clean(ENV.get('CONFIRMED_PUBLISH_STATUS') or 'Not confirmed')}**")
        out.append("- A queued publisher is not proof of publication.")
    else:
        upload = ENV.get("DEADZONE_GOOGLE_UPLOAD_STATUS","")
        verified = ENV.get("DEADZONE_UPLOAD_VERIFIED","") == "1"
        local_hash = ENV.get("DEADZONE_INTEGRITY_SHA256","")
        out.append("- ROM package: **" + ("Ready" if size.isdigit() and int(size)>0 and name else "Not confirmed") + "**")
        upload_step_failed = any(state == "failure" and ("Google Drive upload" in label or "cloud upload" in label) for label, _, state in rows)
        transfer = "Completed" if upload=="0" else ("Upload or verification failed" if upload_step_failed else ("Failed" if upload and upload!="0" else "Not confirmed"))
        out.append("- Google Drive transfer: **" + transfer + "**")
        if verified and project=="Stable" and ENV.get("DEADZONE_ENGINE_LAYOUT")=="pre_refactor":
            out.append("- Remote verification: **Filename, size and MD5 matched**")
        elif verified:
            out.append("- Remote verification: **Confirmed by workflow**")
        else:
            out.append("- Remote verification: **Not confirmed by workflow**")
        link = drive_link(ENV.get("DEADZONE_GOOGLE_DRIVE_URL","") or ENV.get("DEADZONE_RESULT_URL",""))
        if upload=="0" and link and (project!="Stable" or verified):
            out += ["", f"**[⬇ Download ROM from Google Drive]({link})**"]
        if re.fullmatch(r"[0-9a-fA-F]{64}",local_hash):
            out += ["", "<details><summary>SHA-256 checksum</summary>", "", chr(96)+local_hash+chr(96), "", "</details>"]
    out += ["", "_Durations are from GitHub Actions; a dash means unavailable. See individual steps for available diagnostics._", ""]
    with open(ENV["GITHUB_STEP_SUMMARY"],"a",encoding="utf-8") as output:
        output.write("\n".join(out)+"\n")
    print("[DeadZone] Build summary published")

# Preserve actionable diagnostics while keeping routine tool chatter compact.
ERROR_LINE = re.compile(
    r"\[(?:ERROR|FATAL|BLOCKER)\]|\b(?:ERROR|FATAL|FAILED|BLOCKER|[A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception))\s*:"
    r"|^fatal\s*:|^Traceback \(most recent call last\):|(?:^|\s)error(?:\s+[^:\s]+)?\s*:"
    r"|No space left on device|Permission denied|command not found|undefined reference"
    r"|(?:failed|failure)\s+(?:to|at|with)\b|^##\[error\]", re.I)

def error_detail(line):
    # Patch engines emit JSON failures, including class/method and DEX details.
    if line.startswith("{"):
        try:
            payload = json.loads(line)
            if isinstance(payload, dict) and str(payload.get("status", "")).upper() in ("FAILED", "ERROR", "FAILED_CRITICAL"):
                detail = payload.get("error") or payload.get("message") or payload.get("reason")
                if detail:
                    return str(detail)
        except (ValueError, TypeError):
            pass
    if ERROR_LINE.search(line):
        return line
    return ""

def safe_diagnostic(detail):
    # Keep log messages single-line and prevent accidental runner commands.
    detail = ANSI.sub("", str(detail))
    detail = re.sub(r"[\x00-\x1f\x7f]", " ", detail)
    detail = re.sub(r"(?i)\b(Bearer)\s+\S+", r"\1 [REDACTED]", detail)
    detail = re.sub(r"(?i)\b((?:access_token|refresh_token|client_secret|password|api_key|authorization|token)[\"']?\s*[:=]\s*[\"']?)[^\s,\"'&}]+", r"\1[REDACTED]", detail)
    return detail[:2400]

# Show useful engine information, not per-file or per-instruction noise.
BUILD_INFO = re.compile(r"^-\s*(Device Name|Codename|BuildRegion|Android|Xiaomi Version|BuildTool Version|OS Type):\s*(.+)$")
PROGRESS_SIZE = r"(\d+(?:\.\d+)?\s*[KMGT]?i?B)"

def patch_result(line):
    if line.startswith("{"):
        try:
            data = json.loads(line)
            if isinstance(data, dict):
                status = str(data.get("status", "")).upper()
                if status in ("APPLIED", "ALREADY_APPLIED", "PARTIAL", "SKIPPED", "NOT_APPLICABLE", "UNSUPPORTED", "ROLLED_BACK", "DRY_RUN"):
                    count = data.get("changed")
                    suffix = f" | {len(count)} changes" if isinstance(count, list) and count else ""
                    reason = data.get("reason") or data.get("message")
                    if reason:
                        suffix += " | " + safe_diagnostic(reason)[:240]
                    return status.replace("_", " ").title() + suffix
        except (ValueError, TypeError):
            pass
    m = re.match(r"^\[DeadZone[^\]]*\]\s*(SKIPPED|APPLIED|ALREADY_APPLIED|PARTIAL|NOT_APPLICABLE|UNSUPPORTED|ROLLED_BACK)\s*:?\s*(.*)$", line, re.I)
    if m:
        status, detail = m.groups()
        return status.replace("_", " ").title() + (" | " + safe_diagnostic(detail)[:240] if detail else "")
    return ""

def stream(stage):
    # Keep the display pipe alive even when a native tool emits invalid UTF-8.
    sys.stdin.reconfigure(errors="replace")
    print(f"[DeadZone] {stage} | started", flush=True)
    live = LiveReporter(stage)
    seen = set()
    active_patch = ""
    metadata = {}
    progress = {}
    last = time.monotonic()

    def emit(msg):
        nonlocal last
        if msg and msg not in seen:
            seen.add(msg)
            print("[DeadZone] " + msg, flush=True)
            last = time.monotonic()

    def show_metadata():
        if metadata:
            fields = [("Device Name", "Device"), ("Codename", "Codename"),
                      ("Xiaomi Version", "ROM"), ("BuildRegion", "Region"),
                      ("Android", "Android"), ("BuildTool Version", "DeadZone"),
                      ("OS Type", "Filesystem")]
            emit("ROM details | " + " | ".join(f"{label}: {metadata[key]}" for key, label in fields if key in metadata))
            metadata.clear()

    def show_progress(kind, percent, detail):
        bucket = min(100, percent) // 10
        if bucket > progress.get(kind, -1):
            progress[kind] = bucket
            emit(f"{kind} | {percent}% | {detail}")
    for raw in sys.stdin:
        line = ANSI.sub("",raw).strip()
        live.line(line)
        msg = ""
        if (m := BUILD_INFO.match(line)):
            key, value = m.groups()
            if re.fullmatch(r"[A-Za-z0-9 ._()+-]{1,120}", value):
                if key != "Xiaomi Version" or key not in metadata or len(value) >= len(metadata[key]):
                    metadata[key] = value
            continue
        if metadata:
            show_metadata()
        if (m := re.search(r"\[#\w+\s+" + PROGRESS_SIZE + r"/" + PROGRESS_SIZE + r"\((\d+)%\).*?\bDL:" + PROGRESS_SIZE, line)):
            done, total, percent, speed = m.groups()
            show_progress("Download", int(percent), f"{done} / {total} | {speed}/s")
        elif "starting a download" in line or re.search(r"Downloading \d+ item", line):
            msg = "Downloading source ROM"
        elif "Gathering Devices Infomations" in line or "Gathering Device Information" in line:
            msg = "Reading device information"
        elif (m:=re.search(r"\[Payload\] Complete \| (\d+) partitions extracted",line)):
            msg = f"Extraction | {m[1]} partitions extracted"
        elif re.search(r"\[Payload\] Extracting partitions|ROM: Unpacking payload",line):
            msg = "Extracting ROM partitions"
        elif "ROM validation passed" in line:
            msg = "Source ROM validated"
        elif "Debloat Done" in line:
            msg = "Application cleanup completed"
        elif "Starting Apply Universal File" in line:
            msg = "Applying universal modifications"
        elif "Starting Update File" in line:
            msg = "Applying partition modifications"
        elif re.search(r"MODS: .*Space: installing partition apps and permissions",line):
            msg = "Installing project apps and permissions"
        elif (m := re.search(r"(Device profile \| (?:Exact OS[1-4]|Fallback OS[1-4] -> OS[1-4])(?: \| OTA layout checked)?)$", line)):
            msg = m[1]
        elif (m := re.search(r"(Fallback Super \| rebuilt \d+ bytes / \d+ bytes)$", line)):
            msg = m[1]
        elif "Update File Done" in line:
            active_patch = ""
            msg = "Partition modifications completed"
        elif (m := re.search(r"MODS: (ThemeManager|MIUISystemUIPlugin|MIUIScreenshot|MIUISecurityCenter|MiuiHome|MIUIAod):\s*([A-Za-z0-9._+-]+)$", line)):
            active_patch = m[1]
            msg = f"Applying | {active_patch} | {m[2]}"
        elif (m := re.search(r"Packing \[(" + SAFE_ID + r"\.img)\] success", line)):
            msg = f"Packed | {m[1]}"
        elif "Successfully packed super.img" in line:
            msg = "Super image created"
        elif "ZIP package built successfully" in line:
            msg = "ROM archive created"
        elif (m:=re.search(r"Package size: (\d+(?:\.\d+)?) (GiB|MiB|GB|MB)",line)):
            msg = f"Package size | {m[1]} {m[2]}"
        elif (m:=re.search(r"Super partitions: (\d+)",line)):
            msg = f"Super image | {m[1]} partitions"
        elif (m:=re.search(r"ROM: File ("+SAFE_ID+r")\.img extracted\.",line)):
            msg = f"Extracted | {m[1]}"
        elif (m:=re.search(r"MODS: UpdateFile: ("+SAFE_ID+r")/("+SAFE_ID+r")$",line)):
            active_patch = f"{m[1]} / {m[2]}"
            msg = f"Applying | {active_patch}"
        elif (m:=re.search(r"\[PERF\] ZIP create: (\d+(?:\.\d+)?)s",line)):
            msg = f"Archive creation | {m[1]}s"
        elif re.search(r"storageQuotaExceeded|dailyLimitExceeded|uploadLimitExceeded",line,re.I):
            msg = "Google Drive | storage or upload quota reported"
        elif re.search(r"rateLimitExceeded|userRateLimitExceeded|too many requests",line,re.I):
            msg = "Google Drive | rate limit reported"
        elif (detail := error_detail(line)):
            context = stage + (f" | {active_patch}" if active_patch else "")
            msg = f"ERROR | {context} | {safe_diagnostic(detail)}"
        elif (result := patch_result(line)):
            msg = (active_patch or stage) + " | " + result
        elif re.match(r"^\[(?:WARN|WARNING)\]", line, re.I):
            msg = "WARNING | " + (active_patch + " | " if active_patch else "") + safe_diagnostic(line)[:400]
        elif (m:=re.search(r"Transferred:\s*([0-9.]+\s*[kMGT]?i?B)\s*/\s*([0-9.]+\s*[kMGT]?i?B),\s*(\d+)%",line)):
            show_progress("Transfer", int(m[3]), f"{m[1]} / {m[2]}")
        emit(msg)
        now = time.monotonic()
        if now-last>=60:
            context = active_patch or stage
            print(f"[DeadZone] {context} | working", flush=True)
            last = now
    show_metadata()
    live.close()
    print(f"[DeadZone] {stage} | output closed", flush=True)

if __name__ == "__main__":
    if len(sys.argv)>1 and sys.argv[1]=="summary":
        summary()
    elif len(sys.argv)>2 and sys.argv[1]=="stream":
        stream(sys.argv[2])
    else:
        sys.exit("Expected summary or stream STAGE")
