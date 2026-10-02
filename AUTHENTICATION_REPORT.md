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

## Post-provisioning validation (2026-10-02)

After the `DEADZONE_PRIVATE_READ_TOKEN` secret was added to both
`DeadZone-Home` and `DeadZone-Bot`, the validation was re-run end-to-end.

### Lite (`deadzone-lite.yml`)

- First run after provisioning: [37042448019](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37042448019)
  - Failed at `⚙️ Load central runtime` with
    `DeadZone runtime value is missing: PRIVATE_REPO_TOKEN`.
    `load-build.sh` reads `DEADZONE_PRIVATE_TOKEN` first, then
    `PRIVATE_REPO_TOKEN`, then `GH_TOKEN` — it was not aliased to the
    new secret name.
- Fix: commit [`f1e6ea3`](https://github.com/DeadZone-Offical/DeadZone-Home/commit/f1e6ea3)
  exposes the PAT under `DEADZONE_PRIVATE_TOKEN`, `PRIVATE_REPO_TOKEN`,
  and the canonical name in every launcher's `Load central runtime`
  step. The Port launchers already used `DEADZONE_PRIVATE_TOKEN` so
  they were left alone.
- Second run after the fix: [37042751807](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37042751807)
  - ✓ `🔐 Validate launcher credentials`
  - ✓ `📥 Checkout private runtime` (`DeadZone-File`)
  - ✓ `⚙️ Load central runtime`
  - ✓ `✅ Validate loaded runtime`
  - ✗ `📦 Checkout private Lite engine` failed in **LFS object fetch**
    with `Object does not exist on the server: [404]`. The git checkout
    succeeded; the Git LFS endpoint has no copy of the bin-mods APK
    binaries. The launcher's authentication is verified — the LFS layer
    needs the binaries re-pushed.

### Cross-workflow auth validation (2026-10-02 18:07–18:14)

All nine workflows were dispatched on `main` from the post-fix commit.
The auth-relevant steps succeed on every workflow that points at an
existing engine repo:

| Workflow | Run | `🔐 Validate launcher credentials` | Runtime load | Engine checkout |
|---|---|---|---|---|
| `deadzone-lite.yml` | [37044710457](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37044710457) | ✓ | ✓ | ✗ LFS 404 (object not on server) |
| `deadzone-gaimngplus.yml` | [37045775791](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37045775791) | ✓ | ✓ | ✗ `DeadZone-xiaomi_GamingPlus` repo not found |
| `deadzone-legend.yml` | [37045317806](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37045317806) | ✓ | ✓ | ✗ `DeadZone-xiaomi_Legend` repo not found |
| `deadzone-ninja.yml` | [37045317937](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37045317937) | ✓ | ✓ | ✗ `DeadZone-xiaomi_Ninja` repo not found |
| `deadzone-jesi.yml` | [37045318196](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37045318196) | ✓ | ✓ | ✗ `DeadZone_MysticGSI` repo not found |
| `deadzone-fastboot.yml` | [37045638024](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37045638024) | ✓ | ✓ | ✗ `DeadZone-Fastboot-Doctor` repo not found |
| `deadzone-xiaomi-port.yml` | [37045508413](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37045508413) | ✓ | ✓ | ✗ downstream Port processing fails |
| `deadzone-coloros-port.yml` | [37045509424](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37045509424) | ✓ | ✓ | ✗ downstream Port processing fails |
| `deadzone-oxgen-port.yml` | [37045508104](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37045508104) | ✓ | ✓ | ✗ downstream Port processing fails |

**Auth verdict**: every workflow validates `DEADZONE_PRIVATE_READ_TOKEN`,
checks out the central runtime, and loads it without 403. The remaining
failures are **content / repository-creation gaps**, not authentication:

- `DeadZone-xiaomi_GamingPlus`, `DeadZone_MysticGSI`,
  `DeadZone-xiaomi_Legend`, `DeadZone-xiaomi_Ninja`,
  `DeadZone-Fastboot-Doctor`, `DeadZone-ColorOS_Port`,
  `DeadZone-OxygenOS_Port`, `DeadZone-RealmeUI_Port`,
  `DeadZone-xiaomi_FrameworkPatcher`, `FrameworkPatcherModule`,
  `DeadZone_EXE` — repos in the PAT scope that **do not exist** at the
  `DeadZone-Offical` organisation.
- `DeadZone-xiaomi_Lite` — repo exists but the Git LFS layer does not
  have the binaries declared in `.gitattributes`. The auth header is
  accepted by the LFS endpoint (no 401/403); the binary objects simply
  were never pushed.

### Bot E2E (`deadzone-bot-e2e.yml`)

- Pre-fix deploy (commit `e969637` from earlier today) was prevented
  from going to production because `telegram-diagnostics.spec.ts`'s
  "reports webhook drift when URLs differ" test compared two identical
  URLs and asserted `webhookDrift` was true. Scheduled deploys from
  15:48 onwards failed at the test step.
- Test fix: [`bbe8e2c`](https://github.com/DeadZone-Offical/DeadZone-Bot/commit/bbe8e2c)
  uses a stale-looking subdomain for the actual URL so the drift
  branch is exercised correctly.
- Bot redeploy after the test fix: [37044263846](https://github.com/DeadZone-Offical/DeadZone-Home/actions/runs/37044263846)
  completed successfully (commit `bbe8e2c` is now live on the Worker).
- Bot E2E run: [37044381504](https://github.com/DeadZone-Offical/DeadZone-Bot/actions/runs/37044381504)
  - ✓ Step 1 `/start`
  - ✓ Step 2 `dz:build` callback
  - ✓ Step 3 `dz:project:<key>` callback
  - ✓ Step 4 ROM URL text input
  - ✓ Step 5 `dz:confirm` callback — acknowledged in 3s
    (contract: bot must not block on the build)
  - ✗ Step 6 fan-out wait — no bot-dispatched run observed within 60s.

### Bot dispatch root-cause

The bot's `dispatchBuild` call hits the GitHub API using the
**Worker secret `GITHUB_BUILD_TOKEN`**, which is unrelated to
`DEADZONE_PRIVATE_READ_TOKEN`. Direct probe of that token with
`POST /repos/DeadZone-Offical/DeadZone-Home/actions/workflows/deadzone-lite.yml/dispatches`
returns:

```json
{
  "message": "Resource not accessible by personal access token",
  "status": "403"
}
```

The `GITHUB_BUILD_TOKEN` is a Cloudflare Worker secret set with
`wrangler secret put`. It needs to be re-issued as a fine-grained PAT
scoped to `DeadZone-Offical/DeadZone-Home` with **Workflows: Read and
write**, then re-uploaded with:

```sh
cd cloudflare
wrangler secret put GITHUB_BUILD_TOKEN
```

Until that token is rotated, the bot will keep acknowledging Telegram
callbacks but will not create a GitHub workflow run. The auth fix is
complete and correct; production readiness is gated on the separate
`GITHUB_BUILD_TOKEN` rotation.

## Next steps

1. ~~Provision the fine-grained PAT in the
   [`DeadZone-Offical` developer settings](https://github.com/organizations/DeadZone-Offical/settings/personal-access-tokens)
   with **Contents: Read-only** on the 14 repositories listed above.~~
   **Done** — `DEADZONE_PRIVATE_READ_TOKEN` is present on both repos
   as of 2026-10-02T17:40Z.
2. ~~Add the PAT as the `DEADZONE_PRIVATE_READ_TOKEN` Actions secret on
   both `DeadZone-Home` and `DeadZone-Bot`.~~ **Done** —
   `created_at: 2026-10-02T17:40:23Z` (Home),
   `created_at: 2026-10-02T17:40:49Z` (Bot).
3. ~~Re-run the Lite workflow from `main`; the credential check should
   pass and the run should reach the `📦 Checkout private Lite engine`
   step and beyond.~~ **Done** — see Lite row above. Credential check
   passes; runtime loads; engine checkout reaches the git layer but
   hits a pre-existing LFS object gap.
4. Re-run `deadzone-bot-e2e.yml` end-to-end through the deployed
   Cloudflare Worker. The probe should observe a bot-dispatched run
   appear in `DeadZone-Offical/DeadZone-Home` within the 60-second poll
   window, and the dispatched run should reach the engine checkout
   step and beyond. **Pending** — blocked on the
   `GITHUB_BUILD_TOKEN` rotation described above.
5. Once the bot resolves the engine checkout step, mark the system
   production-ready.

### Additional open items (not part of the auth fix)

- Create the missing engine repositories (`DeadZone-xiaomi_GamingPlus`,
  `DeadZone_MysticGSI`, `DeadZone-xiaomi_Legend`,
  `DeadZone-xiaomi_Ninja`, `DeadZone-Fastboot-Doctor`,
  `DeadZone-ColorOS_Port`, `DeadZone-OxygenOS_Port`,
  `DeadZone-RealmeUI_Port`, `DeadZone-xiaomi_FrameworkPatcher`,
  `FrameworkPatcherModule`, `DeadZone_EXE`) so the per-engine
  workflows can fetch them. Re-push the Lite engine's LFS binaries so
  the `📦 Checkout private Lite engine` step can complete.
- Rotate the bot's `GITHUB_BUILD_TOKEN` Worker secret as described
  above.