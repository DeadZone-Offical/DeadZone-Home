# Dispatch-gate tests

These tests cover the Stable workflow's
[🛡️ Validate dispatch gate](../../.github/workflows/deadzone-stable.yml)
step, which is the launcher's only defence against
bot-originated storms, retry loops, callback errors, and
stale scheduled ticks.

The gate is the launcher's first step. It compares the
`approved` workflow input to the literal string `true`
and:

  * accepts the dispatch on a match (build proceeds);
  * rejects the dispatch on a mismatch (writes the
    rejection to `$GITHUB_STEP_SUMMARY`, posts a
    signed `dispatch_rejected` callback to the bot,
    and exits 1 BEFORE checkout / private repo
    download / build start).

The default value of `approved` is the literal string
`"false"`, so a JSON dispatch without the field (a
stale bot retry, a webhook storm) is rejected.

## Files

| File | What it tests |
| --- | --- |
| `test_dispatch_gate.sh` | The gate's accept/reject contract. A standalone mirror of the gate step is run with `approved=false`, `approved=true`, `approved=""`, `approved=True` (capital T), `approved=1`, `approved=yes`. Every value except the literal `true` must be rejected. |
| `test_no_automatic_redispatch.py` | Static contract guard on the DeadZone-Bot side: the bot must NEVER set `approved=true` from a retry / callback / failure path. Only the canonical user-initiated dispatch is allowed to set it. |

## Running locally

```bash
bash tests/dispatch-gate/test_dispatch_gate.sh
python3 -m unittest tests.dispatch-gate.test_no_automatic_redispatch -v
```

The python test auto-skips when the DeadZone-Bot source is
not on disk (the typical case for the public CI; the bot
is a private repo).

## CI

The `.github/workflows/tests.yml` workflow runs all of the
above on every push, pull request, and `workflow_dispatch`.
The CI also runs four static guards:

1. The workflow MUST declare the `approved` input.
2. The workflow MUST NOT add a `push`, `pull_request`, or
   `schedule` trigger.
3. The dispatch gate MUST be the first step in the build
   job (so checkout / private-repo download / build never
   happens before the rejection).
4. The concurrency block MUST have `cancel-in-progress: true`.

A future refactor that drops any of those guards will fail
CI with a precise annotation rather than silently
re-introduce the dispatch storm.
