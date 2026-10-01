# DeadZone Build System Architecture

> **Scope:** This document is the cross-repo map. For the contract that
> every DeadZone-Home master workflow honours, see
> [`REUSABLE_BUILD_CONTRACT.md`](./REUSABLE_BUILD_CONTRACT.md) and
> [`WORKFLOWS.md`](./WORKFLOWS.md).

## Overview

The DeadZone build system has three layers, each in its own repository:

1. **Telegram Bot** (`DeadZone-Offical/DeadZone-Bot`) — user-facing
   control plane (Cloudflare Worker).
2. **Build Orchestration** (`DeadZone-Offical/DeadZone-Home`) — the
   GitHub Actions workflows that actually build ROMs.
3. **Central Runtime** (`DeadZone-Offical/DeadZone-File`) — shared
   scripts and configuration consumed by every Home workflow.

The bot never executes a build itself; it always delegates to a
per-project workflow in DeadZone-Home. DeadZone-Home in turn sources
the engine repository and the central runtime scripts from
DeadZone-File.

## Request Flow

```text
Telegram user
  → Bot (validates, creates D1 record, resolves project)
  → GitHub Actions `workflow_dispatch` (direct per-builder workflow)
  → Home master workflow (builds ROM)
  → Central Runtime (upload to mirrors, notify)
  → Bot receives build event webhook (`/build/events`, HMAC-signed)
  → User gets Telegram result
```

There is **no generic dispatcher workflow** between the bot and the
selected builder. Every Telegram request becomes one independent
`workflow_dispatch` POST against the project-specific workflow file
in DeadZone-Home. Concurrent Telegram requests become independent
GitHub Actions runs.

## Supported Projects

| Project          | Mode      | Master Workflow         | Bot Registry Key |
| ---------------- | --------- | ----------------------- | ---------------- |
| Lite             | `rom_url` | `lite.yml`              | `lite`           |
| Jesse            | `rom_url` | `jesse.yml`             | `jesse`          |
| GamingPlus       | `rom_url` | `custom-gamingplus.yml` | `gamingplus`     |
| Legend           | `rom_url` | `custom-legend.yml`     | `legend`         |
| Ninja            | `rom_url` | `custom-ninja.yml`      | `ninja`          |
| Port (Xiaomi)    | `port_pair` | `port.yml`           | `port_xiaomi`    |
| Port (ColorOS)   | `port_pair` | `port-coloros.yml`   | `port_coloros`   |
| Port (OxygenOS)  | `port_pair` | `port-oxygenos.yml`  | `port_oxygenos`  |
| Port (RealmeUI)  | `port_pair` | `port-realmeui.yml`  | `port_realmeui`  |

The bot's `cloudflare/src/project-registry.ts` is the **single source
of truth** for which projects exist. Removing or renaming an entry
there removes it from the user-visible menu. Adding an entry requires
both that file *and* a matching standalone workflow on the Home side.

## Numbered Workers (Concurrency Pool)

ROM projects that ship with a dedicated engine (gamingplus, legend,
ninja) use a worker pool pattern:

- `custom-X.yml` — **master workflow** (full implementation; also
  reusable via `workflow_call`).
- `custom-X-1.yml` through `custom-X-5.yml` — thin `workflow_dispatch`
  workers that immediately call the master via
  `uses: ./.github/workflows/custom-X.yml` with `secrets: inherit`.
  Each worker has its own concurrency group
  (`deadzone-home-<project>-build-<N>`), so up to 5 concurrent builds
  of the same project type can run in parallel without queueing.

The user-facing project key (e.g. `gamingplus`) maps to the **master**
workflow only. The bot never picks a numbered worker; it always
dispatches the master. The numbered workers exist for self-hosted
runners and manual builds that want to pin a single builder slot.

## Adding a New ROM Project

1. Add an entry to `DeadZone-Offical/DeadZone-File/projects.env`
   (engine repository, project slug, codename).
2. Create the engine repository
   `DeadZone-Offical/DeadZone-xiaomi_{ProjectName}` (mirror the layout
   of `DeadZone-xiaomi_GamingPlus` / `DeadZone-xiaomi_Legend` /
   `DeadZone-xiaomi_Ninja`).
3. Add the master workflow
   `.github/workflows/custom-{projectname}.yml` — copy
   `custom-gamingplus.yml` as a template.
4. Add numbered workers `custom-{projectname}-1.yml` … `-5.yml` —
   copy `custom-gamingplus-1.yml` and update the concurrency group
   name.
5. Register the project in
   `DeadZone-Bot/cloudflare/src/project-registry.ts` (add the key to
   `PROJECT_KEYS` and an entry to `PROJECT_REGISTRY`).
6. The bot's `github-dispatcher.ts` requires no new branch — it
   already reads `project.workflow` directly from the registry.
7. Add tests in `DeadZone-Bot/cloudflare/test/github-dispatcher.spec.ts`
   and `project-registry.spec.ts`.
8. Run `npm run workflows:fetch && npm test` in the bot repo.

See [`WORKFLOWS.md`](./WORKFLOWS.md#adding-a-new-master-workflow) for
the Home-side checklist and
[`REUSABLE_BUILD_CONTRACT.md`](./REUSABLE_BUILD_CONTRACT.md#4-adding-a-new-rom-project-in-3-steps)
for the lifecycle invariant every new master must preserve.

## Workflow Lifecycle (ROM Projects)

All ROM workflows implement the same eleven-step lifecycle:

```
validate → checkout runtime → load runtime → checkout engine
  → install deps → build → pack → upload → notify → cleanup
```

See [`REUSABLE_BUILD_CONTRACT.md`](./REUSABLE_BUILD_CONTRACT.md#1-shared-build-lifecycle)
for the full contract — every master ROM workflow MUST implement
these steps in this order to remain drop-in compatible with the bot's
correlation contract.

## Secrets Required

### DeadZone-Home (GitHub repository secrets)

| Secret     | Purpose                                                                 |
| ---------- | ----------------------------------------------------------------------- |
| `GH_TOKEN` | Fine-grained PAT with `repo` scope — fetches the private runtime & engine, and is forwarded to `publish-website-release.py`. |

SourceForge SSH keys and PixelDrain API keys are no longer required as
of the 2026-09-30 single-destination change. The central
`upload-mirrors.sh` no-ops when `DEADZONE_ENABLE_SECONDARY_MIRRORS != "1"`,
which is the default while Google Drive is the only active destination.

### DeadZone-Bot (Cloudflare Worker secrets)

| Secret                    | Purpose                                                                                  |
| ------------------------- | ---------------------------------------------------------------------------------------- |
| `TELEGRAM_BOT_TOKEN`      | Telegram Bot API token (issued by `@BotFather`).                                         |
| `TELEGRAM_WEBHOOK_SECRET` | HMAC secret matching Telegram's `X-Telegram-Bot-Api-Secret-Token`.                       |
| `BUILD_EVENT_SECRET`      | HMAC secret for `/build/events` webhooks from DeadZone-Home.                             |
| `GITHUB_BUILD_TOKEN`      | GitHub PAT with `workflow` scope on `DeadZone-Offical/DeadZone-Home` for dispatching.    |

The Cloudflare API token and account id used by `.github/workflows/cloudflare-deploy.yml`
are **not** Worker secrets — they are repository-level GitHub secrets
(`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`).

## CI / CD

| Workflow                                                | Purpose                                                                                       |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `DeadZone-Bot/.github/workflows/cloudflare-ci.yml`      | Runs typecheck, security audit, vitest, and a deploy dry-run on every PR/push that touches `cloudflare/`. |
| `DeadZone-Bot/.github/workflows/cloudflare-deploy.yml` | Deploys the Worker to Cloudflare on `main` (after CI passes).                                |
| `DeadZone-Bot/.github/workflows/registry-audit.yml`    | Validates that the bot's registry matches the workflows that exist in DeadZone-Home.          |
| `DeadZone-Home/.github/workflows/*`                    | Project-specific ROM workflows. CI is implicit (manual runs via `workflow_dispatch`).         |

## Telemetry & Correlation

Every `workflow_dispatch` carries the same correlation envelope:

```yaml
inputs:
  request_id:  <bot D1 row id>     # used as the unique build slug
  builder_id:  <telegram user id>
  builder_name: <telegram full name or @username>
  callback_url: <bot /build/events endpoint>
  input_url:   <user-supplied ROM URL>   # rom_url mode
  stock_rom_url / port_rom_url: <...>    # port_pair mode
  build_name:  <derived from request_id> # jesse only
```

The callback URL is called by the runtime after each lifecycle
transition (`start`, `pack`, `upload`, `success` / `failed` /
`cancelled`). The bot persists every event against the original D1
row keyed by `request_id`, and surfaces the latest terminal event to
the originating Telegram chat.
