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
    except json.JSONDecodeError as exc:
        # Genuine malformed-JSON case: the file exists and is
        # readable, but its content does not parse. Only in this
        # case is bin/metadata/detect_props.sh a likely culprit
        # -- the engine wrote a syntactically broken file. A
        # separate permission/disk-space failure below (e.g. on
        # run 38115295186, where the runner ran out of disk
        # while writing the compressed super.img.zst and the
        # subsequent engine cleanup could not flush the
        # metadata file either) surfaces as an OSError, NOT
        # this branch.
        print(
            "::error::Stable engine persisted a malformed "
            f"build/.deadzone/rom_metadata.json: "
            f"{type(exc).__name__}: {exc}. The reload-validator "
            "will reject any JSON that does not parse; fix "
            "bin/metadata/detect_props.sh so it writes valid JSON."
        )
        return 0
    except OSError as exc:
        # The file (or its parent directory) could not be
        # opened, read, or written. This is NOT a JSON
        # parse failure and is almost never caused by
        # bin/metadata/detect_props.sh. The two failure
        # modes we have actually observed are
        # PermissionError (errno 13, e.g. a parent directory
        # with read-only permissions) and OSError errno 28
        # ("No space left on device", e.g. when the runner
        # disk filled up during the zstd round-trip
        # verification of a multi-GB super.img.zst). Naming
        # detect_props.sh in either case is misleading and
        # would send the operator chasing a JSON-validity
        # fix for what is actually a runner / storage
        # problem; we therefore surface the OSError as its
        # own diagnostic and explicitly steer the operator
        # away from the wrong file.
        errno_attr = getattr(exc, "errno", None)
        if errno_attr == 28:
            # errno 28 -> ENOSPC. The most common cause on
            # the Stable builder is the post-upload
            # verify_zst_roundtrip step, which decompresses
            # super.img.zst (multi-GB) into the runner's
            # tmpfs after the 7 GB upload has already
            # consumed most of the available space.
            print(
                "::error::Stable engine could not persist "
                                f"build/.deadzone/rom_metadata.json: "
                                f"{type(exc).__name__}: {exc} "
                                "(errno 28, ENOSPC). The runner "
                                "ran out of disk space while the "
                                "engine was writing its metadata; "
                                "this is almost always a symptom "
                                "of an earlier stage (typically "
                                "the post-upload "
                                "verify_zst_roundtrip on a "
                                "multi-GB super.img.zst) "
                                "filling the runner's tmpfs. The "
                                "fix belongs in the Stable "
                                "engine (DeadZone-Xiaomi-Stable), "
                                "NOT in bin/metadata/detect_props.sh: "
                                "detect_props.sh is not running on "
                                "an empty disk and the JSON it would "
                                "have written is irrelevant until "
                                "the round-trip / disk issue is "
                                "resolved. Inspect build_action.log "
                                "for the first ENOSPC line and "
                                "shorten or skip the round-trip "
                                "verification (or stream the "
                                "decompression to a path that does "
                                "not share the runner's tmpfs)."
            )
        else:
            # Generic read/write failure: surface the errno
            # and a precise pointer to the *most likely*
            # upstream cause so the operator does not waste
            # time grepping detect_props.sh. We deliberately
            # do NOT recommend the JSON-validity fix here;
            # a PermissionError is not a JSON-validity
            # problem and the engine-internal
            # detect_props.sh review has to happen against
            # the right file.
            errno_label = (
                f"errno {errno_attr}" if errno_attr is not None
                else "no errno"
            )
            print(
                "::error::Stable engine could not open "
                                f"build/.deadzone/rom_metadata.json for "
                                "inspection: "
                                f"{type(exc).__name__}: {exc} "
                                f"({errno_label}). This is an "
                                "operating-system-level failure "
                                "(read, write, or permission "
                                "denied), NOT a JSON parse "
                                "failure -- bin/metadata/detect_props.sh "
                                "is almost certainly not the "
                                "cause. Inspect build_action.log "
                                "for the corresponding "
                                "PermissionError / OSError line "
                                "to identify the upstream engine "
                                "step that ran out of disk, lost "
                                "a file handle, or hit a "
                                "permissions boundary, and fix "
                                "that step in the Stable engine. "
                                "If the file is missing entirely, "
                                "the metadata persistence step "
                                "never reached write -- look at "
                                "the most recent [ERROR] / "
                                "Failed line in build_action.log "
                                "to see which earlier stage "
                                "actually failed."
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
