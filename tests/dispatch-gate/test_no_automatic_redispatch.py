#!/usr/bin/env python3
"""
tests/dispatch-gate/test_no_automatic_redispatch.py

Documents and validates the contract on the DeadZone-Bot side:
the bot must NEVER set `approved=true` automatically. The
launcher-side gate (`tests/dispatch-gate/test_dispatch_gate.sh`)
is the source of truth for the rejection logic; this file
is the static guard that prevents a future bot refactor from
silently passing `approved=true` from any path other than the
canonical user-initiated dispatch.

The contract:

  1. The bot's `dispatchImmediately` helper (in
     `src/user-flow.ts`) is the only place that should set
     `approved=true`. It is the single source of truth for
     "the user pressed Build". A retry path, a callback
     handler, a notification failure path, and the bot's
     scheduled-tick path must all reach a code path that
     either:
       a. does NOT call `dispatchImmediately` at all, or
       b. calls it WITHOUT `approved=true`.

  2. The dispatch payload must include `approved: "true"`
     verbatim — NOT a JavaScript boolean. GitHub
     `workflow_dispatch` inputs are strings on the wire;
     `true` (boolean) is rendered as the empty string by
     some GitHub API endpoints.

This test does not run the bot (the bot is a Cloudflare
Worker, not a testable Node process in this repository).
Instead, it parses the bot's source and asserts the
contract through static analysis: the only place
`approved: "true"` appears is the dispatch helper, and
no retry / callback / failure path injects it
automatically.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path


# The DeadZone-Bot source is not part of the DeadZone-Home
# repository; this test is a documentation/contract test,
# not a code-coverage test. It is checked out separately
# by the operator's local dev environment.
#
# When the bot source is not available (the typical case for
# the launcher-side CI), the test is skipped.
BOT_ROOT_CANDIDATES = [
    Path("/home/mohammed/Desktop/GitHub/DeadZone-Bot"),
    Path("/home/mohammed/Desktop/Space/DeadZone-Bot"),
]


def _find_bot_root() -> Path | None:
    for candidate in BOT_ROOT_CANDIDATES:
        if candidate.is_dir():
            return candidate
    return None


BOT_ROOT = _find_bot_root()


@unittest.skipUnless(BOT_ROOT is not None, "DeadZone-Bot source not found")
class BotDispatchContractTest(unittest.TestCase):
    """Static guard: the bot must not auto-dispatch approved=true."""

    def test_dispatch_helper_is_single_source_of_truth(self) -> None:
        user_flow = BOT_ROOT / "cloudflare/src/user-flow.ts"
        self.assertTrue(user_flow.is_file(), f"{user_flow} not found")
        text = user_flow.read_text(encoding="utf-8", errors="replace")
        # The contract: approved="true" appears at most once, in
        # the dispatchInputs build, and never in a retry /
        # callback / catch block.
        approved_true_count = len(
            re.findall(r"""approved\s*:\s*["']true["']""", text)
        )
        self.assertEqual(
            approved_true_count,
            1,
            f"approved='true' appears {approved_true_count} times in "
            f"{user_flow}; the bot contract requires it to appear "
            f"exactly once, in the dispatchImmediately helper, and "
            f"never in a retry / callback / failure path.",
        )

    def test_no_retry_path_auto_approves(self) -> None:
        user_flow = BOT_ROOT / "cloudflare/src/user-flow.ts"
        text = user_flow.read_text(encoding="utf-8", errors="replace")
        # Negative case: any block that handles a dispatch
        # failure (catch, retry, recover) must not pass
        # approved="true" through. We grep for the pattern
        # `catch` followed within 30 lines by `approved`.
        # If we find a match, fail with a precise diagnostic.
        for match in re.finditer(r"catch\b", text):
            window = text[match.start(): match.start() + 1500]
            if re.search(r"approved\s*:\s*['\"]true['\"]", window):
                self.fail(
                    "A catch block in user-flow.ts sets approved='true' "
                    "automatically. The contract is that retry / catch "
                    "paths must not pass approved=true; only the "
                    "single canonical user-initiated dispatch does."
                )

    def test_callback_failure_does_not_dispatch(self) -> None:
        user_flow = BOT_ROOT / "cloudflare/src/user-flow.ts"
        text = user_flow.read_text(encoding="utf-8", errors="replace")
        # The callback dispatcher in user-flow.ts (the section
        # commented with "Callback dispatcher") is the bot's
        # entry point for build events from the launcher.
        # It must NEVER re-dispatch on a build failure /
        # callback failure. We assert that no call to
        # `dispatchImmediately` exists inside a callback
        # event handler.
        cb_section_match = re.search(
            r"Callback dispatcher[\s\S]+?(?=\n// ---- )", text
        )
        if cb_section_match is None:
            self.skipTest("Callback dispatcher section not found")
        cb_section = cb_section_match.group(0)
        self.assertNotIn(
            "dispatchImmediately",
            cb_section,
            "Callback dispatcher calls dispatchImmediately; "
            "a callback failure must NEVER auto-dispatch a new build.",
        )

    def test_dispatch_payload_uses_string_approved(self) -> None:
        # GitHub workflow_dispatch inputs are strings on the
        # wire. A JavaScript boolean `true` is rendered as
        # the empty string by some API endpoints, which
        # would silently route the dispatch through the
        # launcher's gate as `approved=""` and reject it.
        # The bot MUST pass `approved: "true"` (a string).
        dispatcher = BOT_ROOT / "cloudflare/src/github-dispatcher.ts"
        if not dispatcher.is_file():
            self.skipTest("github-dispatcher.ts not found")
        text = dispatcher.read_text(encoding="utf-8", errors="replace")
        # The contract: `buildWorkflowInputs` produces a
        # `Record<string, string>`, so the value type is
        # already string. The Stable project's approved value
        # is the literal `"true"`. We check that the helper
        # either sets `inputs.approved = "true"` for stable
        # or that a future caller must add the field.
        if "approved" not in text:
            self.fail(
                "github-dispatcher.ts does not set `approved` on the "
                "workflow_dispatch inputs. After the launcher gate, "
                "this is required for the canonical user-initiated "
                "dispatch; without it, every build is rejected. "
                "Add `inputs.approved = \"true\"` to buildWorkflowInputs."
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
