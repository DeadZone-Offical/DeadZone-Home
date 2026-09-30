# Workflows

This directory contains the public-facing GitHub Actions workflows for
the DeadZone build network. Every workflow in here is a **dispatcher**:
it captures the public input contract, validates the request, and
delegates the actual work to a private engine repository under the
`DeadZone-Offical` organization.

## Conventions

* `permissions: contents: read` is the maximum scope declared on any
  workflow in this directory. The called engine workflow declares its
  own permissions and uses `secrets: inherit` to receive the secrets
  configured on this repository.
* Concurrency groups are namespaced as `deadzone-<project>-build-queue`
  with `queue: max` so that an outage in one track cannot starve other
  tracks.
* All input validation lives in this repository, so a malformed
  dispatch fails fast *before* any private engine is invoked.
* All repository references use the `DeadZone-Offical` account. No
  `mohammedmezo99` references remain.
* All branches are `main`. No tag-pinned branches.
* No credentials are hardcoded in workflow files. All credentials
  flow through GitHub repository Secrets.

## Dispatch contract

Each dispatcher accepts a `workflow_dispatch` event and exposes the
inputs required by its target engine. Inputs that are purely
DeadZone-MEZO control-plane fields (e.g. `request_id`,
`callback_url`) are accepted for backwards compatibility but are
forwarded only to engines that consume them.

### `lite.yml` — DeadZone Lite dispatcher

Forwards a Xiaomi Fastboot ROM URL to
[`DeadZone-Offical/DeadZone-xiaomi_Lite/.github/workflows/build.yml@main`](https://github.com/DeadZone-Offical/DeadZone-xiaomi_Lite/blob/main/.github/workflows/build.yml).

Inputs:

| Name | Required | Description |
|---|---|---|
| `input_url` | yes | HTTP(S) URL of the Xiaomi Fastboot ROM archive |
| `builder_name` | no | Display name of the requesting builder |
| `builder_id` | no | Telegram user ID of the requesting builder |
| `request_id` | no | Controlled-build request ID (forwarded only to engines that consume it) |
| `callback_url` | no | Signed DeadZone build-event endpoint (forwarded only to engines that consume it) |

Concurrency: `deadzone-lite-build-queue` (queued, never cancelled).

## Required Secrets

This repository must have the following Secrets configured under
**Settings → Secrets and variables → Actions** for the dispatcher to
forward them to the called engine:

| Secret | Purpose | Consumed by |
|---|---|---|
| `GH_TOKEN` | Cross-repo clone + commit to private runtime repos | Called engine |
| `GH_REPO` | Repository identifier the engine reports against | Called engine |
| `RCLONE_TOKEN_PATH` | Cloud-upload authentication | Called engine |
| `TELEGRAM_BOT_TOKEN` | Telegram progress notifications | Called engine |
| `TELEGRAM_CHANNEL_ID` | Telegram target channel for progress notifications | Called engine |

If a controlled build (`request_id` + `callback_url`) is desired, the
called engine additionally requires:

| Secret | Purpose | Consumed by |
|---|---|---|
| `BUILD_PROGRESS_SECRET` | HMAC key for signed callback events | Called engine |

> **Do not** create secrets that duplicate the
> `mohammedmezo99`-era configuration. Use secrets authorized for the
> new `DeadZone-Offical` account only.

## How to invoke a build

1. Open the **Actions** tab on this repository.
2. Select **DeadZone Lite** in the left sidebar.
3. Click **Run workflow**.
4. Fill in the inputs above (only `input_url` is required).
5. Click **Run workflow** to dispatch.

The dispatcher validates the inputs and then invokes the private
engine workflow on the `main` branch of
`DeadZone-Offical/DeadZone-xiaomi_Lite`. The engine reports its
progress via the `DeadZone-Offical/DeadZone-xiaomi_Lite` Actions tab.

## Validation

The dispatcher's `validate` job runs the regex/length checks up front,
so a malformed dispatch fails in this public repository without ever
invoking the private engine. This keeps the public repository's
Actions tab self-explanatory and prevents accidental queue pressure
on the private engines from invalid traffic.