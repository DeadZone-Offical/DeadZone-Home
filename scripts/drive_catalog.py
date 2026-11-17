#!/usr/bin/env python3
"""Build the public /dz ROM catalog from a private, read-only rclone listing.

Credentials never leave the GitHub runner. Publish only metadata and public
Drive links for complete ROM ZIPs under DeadZone/<project>/<device>/<OS>/.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

FOLDER_ID = "10JPnmpweh7qDNMYRbijnG-uENb3EhQ4r"
REMOTE = "DeadZoneDrive:DeadZone"
PROJECTS = {"stable": "Stable", "lite": "Lite", "port": "Port", "ninja": "Ninja"}
DEVICE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
OS_FOLDER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
MAX_ARTIFACTS = 2000


def safe_link(url: str) -> bool:
    try:
        parsed = urlsplit(url)
        return (
            parsed.scheme == "https"
            and parsed.hostname == "drive.google.com"
            and not parsed.username
            and not parsed.password
            and parsed.port is None
            and parsed.path.startswith(("/file/d/", "/open", "/uc"))
        )
    except ValueError:
        return False


def published_at(value: str) -> str:
    if not value:
        return ""
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError):
        return ""


def read_old(path: Path) -> dict:
    try:
        old = json.loads(path.read_text("utf-8"))
        if old.get("version") == 1 and old.get("sourceFolderId") == FOLDER_ID:
            return old
    except (OSError, ValueError, AttributeError):
        pass
    return {}


def produce(input_path: Path, output_path: Path, config_path: Path) -> int:
    raw = json.loads(input_path.read_text("utf-8"))
    if not isinstance(raw, list):
        raise ValueError("rclone listing must be an array")
    old = read_old(output_path)
    old_links = {
        (entry.get("id"), entry.get("path")): entry.get("url")
        for entry in old.get("artifacts", [])
        if isinstance(entry, dict)
    }
    candidates = []
    ids = set()
    for record in raw:
        if not isinstance(record, dict) or record.get("IsDir") is not False:
            continue
        rel_path = record.get("Path")
        if not isinstance(rel_path, str) or "\\" in rel_path or rel_path.startswith("/"):
            continue
        segments = rel_path.split("/")
        if len(segments) != 4:
            continue
        project, codename, os_folder, filename = segments
        project = PROJECTS.get(project.lower())
        if not project or not DEVICE.fullmatch(codename) or not OS_FOLDER.fullmatch(os_folder):
            continue
        if not filename.lower().endswith(".zip") or not filename or any(ord(ch) < 32 for ch in filename):
            continue
        size = record.get("Size")
        identity = record.get("ID")
        if type(size) is not int or size <= 0 or not isinstance(identity, str) or not re.fullmatch(r"[A-Za-z0-9_-]{8,256}", identity):
            continue
        if identity in ids:
            continue
        ids.add(identity)
        candidates.append({
            "id": identity,
            "path": rel_path,
            "project": project,
            "codename": codename.lower(),
            "os": os_folder,
            "name": filename,
            "size": size,
            "modifiedAt": published_at(record.get("ModTime", "")),
        })
    if len(candidates) > MAX_ARTIFACTS:
        raise ValueError("Drive contains more ROMs than the configured safe catalog limit")
    artifacts = []
    for candidate in candidates:
        cache_key = (candidate["id"], candidate["path"])
        link = old_links.get(cache_key)
        if not isinstance(link, str) or not safe_link(link):
            destination = f"{REMOTE}/{candidate['path']}"
            result = subprocess.run(
                ["rclone", "--config", str(config_path), "link", destination],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, timeout=45,
            )
            link = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
        if not safe_link(link):
            raise ValueError("Drive returned a URL that is not a supported public download link")
        artifacts.append({**candidate, "url": link})
    artifacts.sort(key=lambda a: (a["modifiedAt"], a["name"]), reverse=True)
    now = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    timestamp = old.get("generatedAt") if old.get("artifacts") == artifacts else now
    output = {
        "version": 1,
        "source": "DeadZoneDrive",
        "sourceFolderId": FOLDER_ID,
        "generatedAt": timestamp or now,
        "artifacts": artifacts,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Drive ROM catalog ready: {len(artifacts)} releases (content changed: {old.get('artifacts') != artifacts})")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: drive_catalog.py <rclone-inventory.json> <catalog.json> <rclone.conf>", file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(produce(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])))
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"::error::Failed to build Drive catalog ({type(exc).__name__})", file=sys.stderr)
        sys.exit(1)
