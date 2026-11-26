#!/usr/bin/env python3
"""Expose only numeric rclone transfer stats; stop stalled transfers."""
import json
import math
import os
import subprocess
import sys
import time

STALL_SECONDS = 300
METADATA_SECONDS = 120
HEARTBEAT_SECONDS = 30


def number(value, default=0):
    if isinstance(value, (int, float)) and math.isfinite(value) and value >= 0:
        return value
    return default


def display(stats):
    done = number(stats.get("bytes"))
    total = number(stats.get("totalBytes"))
    speed = number(stats.get("speed"))
    eta = number(stats.get("eta"), None)
    percent = f"{min(100, 100 * done / total):.1f}%" if total else "--"
    eta_text = f"{int(eta)}s" if eta is not None else "--"
    print(f"Upload: {percent} | {done / 1048576:.1f}/{total / 1048576:.1f} MiB"
          f" | {speed / 1048576:.2f} MiB/s | ETA {eta_text}", flush=True)
    return done


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def run(mode, output, errors, command):
    start = last_progress = last_report = time.monotonic()
    last_bytes = 0
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
                                transferred = display(stats)
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
                    expired = (now - start >= METADATA_SECONDS if mode == "metadata"
                               else now - last_progress >= STALL_SECONDS)
                    if expired:
                        print("::warning::Google Drive request timed out"
                              if mode == "metadata" else
                              "::warning::No upload progress for 5 minutes; stopping attempt.",
                              flush=True)
                        return 124
                    if now - last_report >= HEARTBEAT_SECONDS:
                        elapsed = int(now - (start if mode == "metadata" else last_progress))
                        print(f"Google Drive {mode}: waiting for response/progress ({elapsed}s)", flush=True)
                        last_report = now
                    time.sleep(1)
        finally:
            stop(process)


if __name__ == "__main__":
    if len(sys.argv) < 6 or sys.argv[1] not in ("upload", "metadata") or sys.argv[4] != "--":
        sys.exit("Invalid upload watchdog arguments")
    os.umask(0o077)
    sys.exit(run(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[5:]))
