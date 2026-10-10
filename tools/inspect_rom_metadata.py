#!/usr/bin/env python3
"""Inspect the engine-persisted ``build/.deadzone/rom_metadata.json``.

The DeadZone Stable build engine persists its ROM metadata to
``build/.deadzone/rom_metadata.json`` at Stage 4 (metadata) and then a
reload-validator re-reads the file to confirm it carries the fields the
downstream stages (super, partitions, flash, release) consume. Run
38063165985 exposed a regression where the engine wrote a JSON that the
reload-validator rejected with::

    [ERROR] Persisted metadata failed reload validation
    missing device.name

The previous launcher's failure notification asked the operator to
install ``erofsfuse`` / vendor ``bin/Linux/x86_64/extract.erofs``,
which was the symptom of the *prior* (now-fixed) toolchain-permission
bug, not this one. This helper produces a precise ``::error::``
annotation whenever the reload-validator would reject the persisted
JSON, so the failure notification can name the actual root cause
without inventing or backfilling a device name.

We do NOT modify, fix-up, or backfill the JSON. Silently substituting
a ``device.name`` would let the build proceed against a wrong device
profile and produce a brick-prone ROM, which is the exact failure mode
the reload-validator exists to prevent. The launcher reports; the
engine fixes.

Usage::

    python3 inspect_rom_metadata.py <path-to-rom_metadata.json>

Exits 0 on success (whether or not a diagnostic is emitted). Emits
zero or more ``::error::`` annotations on stdout, GitHub-Actions
style, so the message is rendered inline in the Actions log.
"""

from __future__ import annotations

import json
import sys
from typing import Any


REQUIRED_DEVICE_FIELDS = ("name", "codename")
REQUIRED_ROM_FIELDS = ("version",)


def _missing_fields(block: dict[str, Any], required: tuple[str, ...]) -> list[str]:
    """Return the required fields that are missing or blank in ``block``."""
    return [
        field
        for field in required
        if not (block.get(field) or "").strip()
    ]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(
            "::error::inspect_rom_metadata.py expects exactly one "
            "argument: the path to build/.deadzone/rom_metadata.json.",
            file=sys.stderr,
        )
        return 0

    path = argv[1]
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except FileNotFoundError as exc:
        print(
            "::error::Stable engine did not persist "
            f"build/.deadzone/rom_metadata.json ({exc}). The "
            "metadata stage never reached the persistence "
            "step; inspect bin/metadata/detect_props.sh and "
            "the engine's build_action.log to see which "
            "earlier check failed before the JSON was written."
        )
        return 0
    except (OSError, json.JSONDecodeError) as exc:
        print(
            "::error::Stable engine persisted a malformed "
            f"build/.deadzone/rom_metadata.json: "
            f"{type(exc).__name__}: {exc}. The reload-validator "
            "will reject any JSON that does not parse; fix "
            "bin/metadata/detect_props.sh so it writes valid JSON."
        )
        return 0

    device_block = document.get("device") or {}
    rom_block = document.get("rom") or {}

    missing_device = _missing_fields(device_block, REQUIRED_DEVICE_FIELDS)
    missing_rom = _missing_fields(rom_block, REQUIRED_ROM_FIELDS)

    if not missing_device and not missing_rom:
        return 0

    parts: list[str] = []
    if missing_device:
        parts.append("device." + ", device.".join(missing_device))
    if missing_rom:
        parts.append("rom." + ", rom.".join(missing_rom))
    missing = " and ".join(parts)
    print(
        "::error::Stable engine reload-validator will reject "
        f"build/.deadzone/rom_metadata.json: missing {missing}. "
        "The engine wrote a rom_metadata.json that does not "
        "carry the fields the reload-validator requires "
        "(device.name and device.codename come from the "
        "per-codename DeviceConfig, rom.version from "
        "build.prop). This is a bug in "
        "bin/metadata/detect_props.sh \u2014 do NOT invent or "
        "backfill a device name from the launcher; the build "
        "must be rejected so a wrong device profile cannot "
        "leak into a Stable ROM. Fix detect_props.sh so the "
        "persisted JSON satisfies the reload-validator."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
