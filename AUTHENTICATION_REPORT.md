# DeadZone Private Repository Authentication

This document records the exact list of private repositories that the
DeadZone build pipelines need read-only access to, the secret name the
workflows expect, and the validation results from the post-fix run.

## Required GitHub Actions secret

| Repository | Secret name |
|---|---|
| `DeadZone-Offical/DeadZone-Home` | `DEADZONE_PRIVATE_READ_TOKEN` |
| `DeadZone-Offical/DeadZone-Bot` | `DEADZONE_PRIVATE_READ_TOKEN` |

## Fine-grained PAT specification

| Field | Value |
|---|---|
| Resource owner | `DeadZone-Offical` |
| Repository access | **Only the repositories listed below** |
| Permissions | **Contents: Read-only** |
| Expiration | 90 days (rotate before expiry) |
| Token storage | GitHub Actions secret on `DeadZone-Home` and `DeadZone-Bot` |

> Do **NOT** add Workflow, Administration, Issues, Pull Requests, or any
> write capability. The token is consumed by `actions/checkout@v4` and a
> few `git fetch` invocations. Nothing in the launcher pipelines mutates
> the engine repos.

## Private repositories that must be in the PAT scope

The exact list was extracted from
[`DeadZone-Offical/DeadZone-File/projects.env`](https://github.com/DeadZone-Offical/DeadZone-File/blob/main/projects.env)
plus the per-engine references in
`DeadZone-Home/.github/workflows/deadzone-*.yml`.

| # | Repository | Used by |
|---|---|---|
| 1 | `DeadZone-Offical/DeadZone-File` | All launchers (central runtime) |
| 2 | `DeadZone-Offical/DeadZone-xiaomi_Lite` | `deadzone-lite.yml` |
| 3 | `DeadZone-Offical/DeadZone-xiaomi_GamingPlus` | `deadzone-gaimngplus.yml` |
| 4 | `DeadZone-Offical/DeadZone_MysticGSI` | `deadzone-jesi.yml` |
| 5 | `DeadZone-Offical/DeadZone-xiaomi_Port` | `deadzone-xiaomi-port.yml` |
| 6 | `DeadZone-Offical/DeadZone-ColorOS_Port` | `deadzone-coloros-port.yml` |
| 7 | `DeadZone-Offical/DeadZone-OxygenOS_Port` | `deadzone-oxgen-port.yml` |
| 8 | `DeadZone-Offical/DeadZone-RealmeUI_Port` | `projects.env` map (reserved) |
| 9 | `DeadZone-Offical/DeadZone-xiaomi_Legend` | `deadzone-legend.yml` |
| 10 | `DeadZone-Offical/DeadZone-xiaomi_Ninja` | `deadzone-ninja.yml` |
| 11 | `DeadZone-Offical/DeadZone-xiaomi_FrameworkPatcher` | `projects.env` map |
| 12 | `DeadZone-Offical/FrameworkPatcherModule` | `projects.env` map |
| 13 | `DeadZone-Offical/DeadZone_EXE` | `projects.env` map |
| 14 | `DeadZone-Offical/DeadZone-Fastboot-Doctor` | `deadzone-fastboot.yml` |

Add every repository above to the fine-grained PAT, including the
`# # 8`–`# 13` entries that are reserved by the runtime project map even
though no current standalone workflow dispatches them yet.

## Rotation policy

- Rotate every **90 days** (or sooner if a workflow run ever reports a
  401/403 from any of the repos listed above).
- After rotating, update the `DEADZONE_PRIVATE_READ_TOKEN` value on both
  `DeadZone-Home` and `DeadZone-Bot` so the bot E2E probe and every
  engine launcher pick it up on the next dispatch.
- Never store the token in `DeadZone-File/bot.env` or in any commit.
  Treat any commit-time disclosure as a compromise and rotate immediately.

## Workflow changes (this fix)

Commit `b595748` on `DeadZone-Offical/DeadZone-Home` and `6402a1b` on
`DeadZone-Offical/DeadZone-Bot` make `DEADZONE_PRIVATE_READ_TOKEN` the
single credential for every private-source checkout in both repos.

- Removed `secrets.GH_TOKEN` and `secrets.GH_TOKEN || …` fallbacks
  from the validation, runtime-loading, and checkout steps of every
  engine launcher (`deadzone-lite`, `deadzone-legend`, `deadzone-ninja`,
  `deadzone-jesi`, `deadzone-fastboot`, `deadzone-gaimngplus`,
  `deadzone-xiaomi-port`, `deadzone-coloros-port`, `deadzone-oxgen-port`).
- Updated `bot-deploy.yml` to read `bot.env` from `DeadZone-File` via
  `DEADZONE_PRIVATE_READ_TOKEN`.
- Updated the bot E2E probe (`deadzone-bot-e2e.yml`) plus the supporting
  diagnostic workflows (`cloudflare-runtime-trace.yml`,
  `telegram-diagnostics.yml`, `workflow5-production-e2e.yml`,
  `workflow5-privmode-probe.yml`) to require the dedicated secret.
- The dispatcher contact token (`GITHUB_BUILD_TOKEN`) remains the only
  credential used by the Cloudflare Worker for `workflow_dispatch`. The
  launcher does not use it for source checkouts.

## Validation run (without the secret)

Manual dispatch of `deadzone-lite.yml` on `main` (commit `b595748`)
executed the new fail-fast credential check before reaching any checkout
step:

- **Run**: <https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37037090804>
- **Failed step**: `🔐 Validate launcher credentials`
- **Error message**:
  `::error::Missing required launcher secret: DEADZONE_PRIVATE_READ_TOKEN. Provision a fine-grained PAT with Contents: Read-only on the private engine repos and add it as the DEADZONE_PRIVATE_READ_TOKEN Actions secret on DeadZone-Offical/DeadZone-Home.`

The credential validation is now the first thing the launcher does
after the controlled-request shape check, so a missing or invalid token
surfaces immediately instead of producing a 403 during the engine
checkout (which was the original failure mode).

## Next steps

1. Provision the fine-grained PAT in the
   [`DeadZone-Offical` developer settings](https://github.com/organizations/DeadZone-Offical/settings/personal-access-tokens)
   with **Contents: Read-only** on the 14 repositories listed above.
2. Add the PAT as the `DEADZONE_PRIVATE_READ_TOKEN` Actions secret on
   both `DeadZone-Home` and `DeadZone-Bot`.
3. Re-run the Lite workflow from `main`; the credential check should
   pass and the run should reach the `📦 Checkout private Lite engine`
   step and beyond.
4. Re-run `deadzone-bot-e2e.yml` end-to-end through the deployed
   Cloudflare Worker. The probe should observe a bot-dispatched run
   appear in `DeadZone-Offical/DeadZone-Home` within the 60-second poll
   window, and the dispatched run should reach the engine checkout
   step and beyond.
5. Once both succeed, mark the system production-ready.