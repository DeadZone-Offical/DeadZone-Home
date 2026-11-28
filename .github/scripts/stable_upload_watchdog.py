#!/usr/bin/env python3
"""Expose safe numeric rclone stats without interrupting upload retries."""
import json
import math
import os
import re
import subprocess
import sys
import time
from deadzone_live_reporter import LiveReporter

METADATA_SECONDS = 180
HEARTBEAT_SECONDS = 30


def number(value, default=0):
    if isinstance(value, (int, float)) and math.isfinite(value) and value >= 0:
        return value
    return default


def display(stats, live=None):
    aggregate = number(stats.get("bytes"))
    active = stats.get("transferring")
    transfer = active[0] if isinstance(active, list) and len(active) == 1 and isinstance(active[0], dict) else None
    expected = int(os.environ.get("DEADZONE_UPLOAD_BYTES", "0") or 0)
    if transfer and number(transfer.get("size")) and (not expected or transfer["size"] == expected):
        done = number(transfer.get("bytes"))
        total = number(transfer.get("size"))
        speed = number(transfer.get("speedAvg"), number(transfer.get("speed")))
        eta = number(transfer.get("eta"), None)
        label = "Upload"
    else:
        # Aggregate totals can reset after an error or span several retries.
        # Never turn these into a misleading percentage for the ROM.
        print("[Drive] Waiting for transfer or server confirmation", flush=True)
        return aggregate
    ratio = min(1, done / total) if total else 0
    filled = int(ratio * 20)
    bar = "=" * filled + "-" * (20 - filled)
    percent = f"{100 * ratio:5.1f}%" if total else "   -- "
    eta_text = f"{int(eta)}s" if eta is not None else "--"
    done = min(done, total)
    if live is not None:
        metrics = {"processedBytes": int(done), "totalBytes": int(total), "bytesPerSecond": int(speed), "artifactSize": int(total)}
        if eta is not None:
            metrics["etaSeconds"] = int(eta)
        live.update("uploading", "uploading", "Uploading to Google Drive", **metrics)
    status = " | awaiting server response" if total and done >= total else f" | ETA {eta_text}"
    print(f"[Drive] {label} [{bar}] {percent} | {done / 1073741824:.2f}/{total / 1073741824:.2f} GiB"
          f" | {speed / 1048576:.1f} MiB/s{status}", flush=True)
    return aggregate



def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def verify(path, size, md5, filename=None):
    """Accept a single remote object only when its size and MD5 match."""
    try:
        with open(path, encoding="utf-8") as stream:
            item = json.load(stream)
        if isinstance(item, list):
            if len(item) != 1:
                return 1
            item = item[0]
        if not isinstance(item, dict) or item.get("IsDir"):
            return 1
        if filename is not None and item.get("Name") != filename:
            return 1
        hashes = item.get("Hashes") or {}
        remote_md5 = hashes.get("MD5") or hashes.get("md5") or ""
        return 0 if (int(size) > 0 and item.get("Size") == int(size)
                     and re.fullmatch(r"[0-9a-fA-F]{32}", md5)
                     and isinstance(remote_md5, str)
                     and remote_md5.lower() == md5.lower()) else 1
    except (OSError, ValueError, TypeError, AttributeError):
        return 1


def report_failure(errors, rc):
    # Fixed diagnostic labels only: raw rclone messages may contain private paths.
    categories = (
        ("storage or upload quota", r"storageQuotaExceeded|dailyLimitExceeded|uploadLimitExceeded|quota exceeded|upload limit"),
        ("user rate limit", r"userRateLimitExceeded"),
        ("API rate limit", r"rateLimitExceeded|too many requests|(?:HTTP|Error) (?:response code )?429"),
        ("authentication or permission", r"invalid_grant|unauthorized|insufficientPermissions|permission denied|(?:HTTP|Error) (?:response code )?40[13]"),
        ("Google backend error", r"backendError|(?:HTTP|Error) (?:response code )?50[0234]"),
        ("network timeout or disconnect", r"timeout|deadline exceeded|connection reset|connection timed out|unexpected EOF"),
        ("object not found", r"not found|(?:HTTP|Error) (?:response code )?404"),
    )
    try:
        with open(errors, encoding="utf-8", errors="replace") as stream:
            content = stream.read()
    except OSError:
        content = ""
    label = next((name for name, pattern in categories
                  if re.search(pattern, content, re.I)), "unclassified error")
    if rc == 124:
        label = "watchdog timeout" if label == "unclassified error" else label
    print(f"::warning::Google Drive {label} (exit {rc})", flush=True)


def run(mode, output, errors, command):
    start = last_progress = last_report = time.monotonic()
    last_bytes = 0
    live = LiveReporter('Cloud upload' if mode == 'upload' else 'Cloud verification')
    # Logs contain potentially private error details; do not stream them.
    with open(output, "wb") as out, open(errors, "wb") as err:
        process = subprocess.Popen(command, stdout=out, stderr=err)
        try:
            with open(errors, "rb") as reader:
                while True:
                    position = reader.tell()
                    line = reader.readline()
                    if line and line.endswith(b"\n"):
                        if mode == "upload":
                            try:
                                record = json.loads(line)
                            except (ValueError, UnicodeError):
                                continue
                            stats = record.get("stats") if isinstance(record, dict) else None
                            if isinstance(stats, dict):
                                transferred = display(stats, live)
                                now = time.monotonic()
                                if transferred > last_bytes:
                                    last_progress = now
                                    last_bytes = transferred
                                last_report = now
                        continue
                    if line:
                        reader.seek(position)
                    rc = process.poll()
                    if rc is not None:
                        return rc if rc >= 0 else 128 - rc
                    now = time.monotonic()
                    # Only metadata requests have a local deadline. Uploads use
                    # rclone's own timeout/backoff and the workflow time limit.
                    if mode == "metadata" and now - start >= METADATA_SECONDS:
                        print("::warning::Google Drive metadata request timed out", flush=True)
                        return 124
                    if now - last_report >= HEARTBEAT_SECONDS:
                        elapsed = int(now - (start if mode == "metadata" else last_progress))
                        print(f"[Drive] {'Waiting for file confirmation' if mode == 'metadata' else 'Waiting for transfer progress'} | {elapsed}s", flush=True)
                        last_report = now
                    time.sleep(1)
        finally:
            stop(process)
            live.close()


if __name__ == "__main__":
    if len(sys.argv) in (5, 6) and sys.argv[1] == "verify":
        sys.exit(verify(sys.argv[2], sys.argv[3], sys.argv[4],
                        sys.argv[5] if len(sys.argv) == 6 else None))
    if len(sys.argv) < 6 or sys.argv[1] not in ("upload", "metadata") or sys.argv[4] != "--":
        sys.exit("Invalid upload watchdog arguments")
    os.umask(0o077)
    rc = run(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[5:])
    if rc:
        report_failure(sys.argv[3], rc)
    sys.exit(rc)
