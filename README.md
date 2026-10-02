# DeadZone-Home

`DeadZone-Home` is the lightweight dispatch surface for the DeadZone build
automation. It contains **only** the centralized GitHub Actions workflows
that the public Telegram bot (`DeadZone-Offical/DeadZone-Bot`) invokes
through `workflow_dispatch`, plus the supporting `.gitattributes` that
keeps shell scripts and Python source LF-clean on Windows checkouts.

It does **not** contain engine code, build assets, documentation, or
tests. Those live in the private engine repositories listed below.

## Project → workflow map

The bot dispatches one workflow per project. Each workflow is its own
self-contained build pipeline: it pulls the central runtime, clones the
private engine repository, runs the build, packages the ROM, and reports
back to the bot via signed callback events.

| Public name | Workflow file | Private engine repository |
|---|---|---|
| `Deadzone-Lite` | `.github/workflows/deadzone-lite.yml` | `DeadZone-Offical/DeadZone-xiaomi_Lite` |
| `DeadZone-Xiaomi-Port` | `.github/workflows/deadzone-xiaomi-port.yml` | `DeadZone-Offical/DeadZone-xiaomi_Port` |
| `DeadZone-Fastboot` | `.github/workflows/deadzone-fastboot.yml` | `DeadZone-Offical/DeadZone-SuperInspector` |

## Required secrets

| Secret | Used by | Purpose |
|---|---|---|
| `GITHUB_TOKEN` | All workflows | Default token; used for everything inside `DeadZone-Home`. |
| `DEADZONE_PRIVATE_READ_TOKEN` | All workflows | Fine-grained PAT scoped to `Contents: Read` on the private engine repos and to `DeadZone-Offical/DeadZone-File`. This is the canonical credential for cloning private sources. |
| `GH_TOKEN` | All workflows | Migration fallback for `DEADZONE_PRIVATE_READ_TOKEN`; kept active until the new secret is fully provisioned. |
| `GITHUB_BUILD_TOKEN` | `DeadZone-Bot` only | Used by the bot when it dispatches `workflow_dispatch` against this repo. |

## Deploying the Cloudflare Worker

The `DeadZone-Bot` Worker (`deadzone-bot` on Cloudflare Workers) is
deployed from this repository by the `bot-deploy.yml` workflow. The
Worker itself lives in the private `DeadZone-Offical/DeadZone-Bot`
repository and is cloned at deploy time — `DeadZone-Home` only owns
the deploy *contract*.

### How it works

1. `DeadZone-Home` clones `DeadZone-Offical/DeadZone-Bot` (`main`) using
   a fine-grained PAT (`DEADZONE_BOT_TOKEN`, `Contents: Read-only`).
2. It runs `npm ci`, the secret audit, typecheck, the test suite, and a
   `wrangler deploy --dry-run`.
3. It calls `npx wrangler deploy` using `CLOUDFLARE_API_TOKEN` and
   `CLOUDFLARE_ACCOUNT_ID` to push the Worker to Cloudflare.
4. It resolves the deployed Worker URL via the Cloudflare REST API
   (`GET /accounts/{id}/workers/subdomain`) — never from `wrangler`
   stdout, which is unreliable across versions.
5. It probes the Worker's `/health` endpoint for `2xx`.
6. It registers the Telegram webhook (`/telegram/webhook`) using the
   bot token from `DeadZone-Offical/DeadZone-File/bot.env`, read via
   `GH_TOKEN`.

### Triggers

| Trigger | Behaviour |
|---|---|
| `schedule` (`*/15 * * * *`) | Polls the upstream Bot `main` SHA and short-circuits when the SHA has not changed since the last successful deploy (no deploys, no Cloudflare API calls). |
| `workflow_dispatch` | Manual run. Supports `mode=deploy\|dry-run` and `ref=<Bot branch>` inputs. |

### Required secrets

| Secret | Purpose |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token with `Workers Scripts:Edit`, `Workers Routes:Edit`, `D1:Edit`, `Queues:Edit`, and `Account Settings:Read`. The bot does not need R2, KV, Pages, or zone/DNS scopes. |
| `CLOUDFLARE_ACCOUNT_ID` | 32-character hexadecimal Cloudflare account ID. The Worker URL is derived from `GET /accounts/{id}/workers/subdomain` so this secret does not have to match the workers.dev subdomain, but it MUST be the account that owns the `deadzone-bot` Worker. |
| `DEADZONE_BOT_TOKEN` | Fine-grained PAT authorised on `DeadZone-Offical/DeadZone-Bot` only with `Contents: Read-only`. Used only for the `actions/checkout` step. |
| `GH_TOKEN` | Migration fallback PAT used to read the Telegram bot token from `DeadZone-Offical/DeadZone-File/bot.env` when registering the Telegram webhook. |

### Secrets that DO NOT live here

The following runtime secrets are Cloudflare **Worker Secrets**
(`wrangler secret put` or the Cloudflare dashboard, never repository
secrets on this public-adjacent repository):

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_WEBHOOK_SECRET`
- `BUILD_EVENT_SECRET`
- `GITHUB_BUILD_TOKEN`

### Manually re-deploying the Worker

1. Open <https://github.com/DeadZone-Offical/DeadZone-Home/actions/workflows/bot-deploy.yml>.
2. Click **Run workflow** → set `ref` to the desired Bot branch
   (default `main`) and `mode` to `deploy` (or `dry-run` to validate
   only).
4. After the run completes, the step summary lists the resolved Worker
   URL and the upstream Bot commit SHA that was deployed.

## Layout rules

- One workflow per public project. No per-version, per-codename, or per-flavor
  workflow files.
- Each workflow sets its own `concurrency.group` to
  `deadzone-home-<project>-${{ inputs.request_id }}`. Two different
  Telegram users can dispatch the same project in parallel; the same
  user re-pressing Build for the same `request_id` cancels their
  previous run.
- The build environment, system packages, scripts, storage management,
  and curl/rclone pipeline are driven by the central runtime in
  `DeadZone-Offical/DeadZone-File`. Workflow files do not vendor any of
  this content.
- `.gitattributes` keeps shell scripts, Python, YAML, Markdown, and
  web sources LF, and marks ROM/build artifacts as `binary` so
  `git checkout` and `git diff` never re-encode them.

## Local validation (run before opening a PR)

1. `python -m py_compile $(find .github -name '*.py')` — sanity-check
   embedded Python.
2. YAML lint:

   ```bash
   python -c "import sys, glob, yaml
   for path in sorted(glob.glob('.github/workflows/*.yml')):
       with open(path, encoding='utf-8') as fh:
           yaml.safe_load(fh)
   print('OK')"
   ```

3. Confirm only the nine expected workflow files are tracked:

   ```bash
   git ls-files .github/workflows/ | sort
   ```

   The expected list is:

   - `deadzone-coloros-port.yml`
   - `deadzone-fastboot.yml`
   - `deadzone-gaimngplus.yml`
   - `deadzone-jesi.yml`
   - `deadzone-legend.yml`
   - `deadzone-lite.yml`
   - `deadzone-ninja.yml`
   - `deadzone-oxgen-port.yml`
   - `deadzone-xiaomi-port.yml`