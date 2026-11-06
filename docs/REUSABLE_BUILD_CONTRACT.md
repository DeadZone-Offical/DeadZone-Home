# DeadZone-Home — Reusable Build Contract

> **Status:** Stable for existing projects. New projects SHOULD adopt
> the reusable validation helper (`.github/workflows/validate.yml`)
> described below; existing master workflows continue to use their
> inline Python validation until they are next revised.

This document defines the **shared build lifecycle** that every
DeadZone-Home ROM build workflow honours, and the contract that a new
project must satisfy to plug into the network.

The contract is intentionally narrow:

- The build pipeline is owned by the **central runtime**
  (`DeadZone-Offical/DeadZone-File`) — every master workflow checks it out
  the same way and refuses to start if any required artifact is empty.
- The **engine repository** — which actually compiles the project — is
  project-specific and lives outside this repo. Each project registers
  the engine it expects, and the workflow fails closed if the loaded
  runtime does not return exactly that engine.
- The **dispatch surface** — what Telegram / the bot / a human is
  allowed to ask for — is identical for every project, except that
  `port_pair` projects take two ROM URLs instead of one.

Everything else — output ZIP naming, OS folder derivation, the exact
zip pattern the workflow looks for in `out/`, the engine's
`build.sh` / `packROM.sh` / `uploadROM.sh` contract — is a property
of the **engine repository**, and is documented there, not here.

---

## 1. Shared build lifecycle

Every master workflow (`lite.yml`, `jesse.yml`, `custom-gamingplus.yml`,
`custom-legend.yml`, `custom-ninja.yml`, `port.yml`,
`port-coloros.yml`, `port-oxygenos.yml`, `port-realmeui.yml`) follows
the same eleven-step lifecycle. Differences are explicitly called out
below; everything else is identical.

| # | Phase                           | Mechanism                                                                       |
| -:| ------------------------------ | ------------------------------------------------------------------------------ |
| 1 | **Validate controlled request** | Inline Python (existing masters) **or** `.github/workflows/validate.yml` via `workflow_call` (new masters). |
| 2 | **Validate launcher credentials** | Bash: confirm `GH_TOKEN` (and, for `port_*`, the `DEADZONE_RUNTIME_TOKEN` alias) is set. |
| 3 | **Checkout DeadZone launcher** | `actions/checkout@v4` of this repository. `persist-credentials: false`, `fetch-depth: 1`. |
| 4 | **Checkout private runtime**   | `actions/checkout@v4` of `DeadZone-Offical/DeadZone-File` into `runtime/`, `sparse-checkout` limited to the files actually used: `projects.env`, `build.env`, `rclone.conf`, `load-build.sh`, `report_build_event.py`, `upload.env`, `upload-mirrors.sh`, `publish-website-release.py`. |
| 5 | **Load central runtime** | `runtime/load-build.sh <project_slug>` — sources `projects.env` and `build.env`, validates `rclone.conf` exists, and prints the resolved `engine_repository` on `stdout`. |
| 6 | **Validate loaded runtime** | Bash: confirm `DEADZONE_ENGINE_REPOSITORY`, `BUILD_PROGRESS_SECRET`, `RCLONE_REMOTE_NAME`, `RCLONE_UPLOAD_DIR` are non-empty, that `engine_repository` matches the expected engine for this project, and that `BUILD_PROGRESS_SECRET` equals `DEADZONE_EVENT_SECRET`. |
| 7 | **Maximize build space** | `easimon/maximize-build-space@fc881a613ad2a34aca9c9624518214ebc21dfc0c` (legacy) or `@c28619d8999a147d5e09c1199f84ff6af6ad5794` (port-family) with `build-mount-path: ${{ github.workspace }}/toolbuild`. |
| 8 | **Clean unused runner packages** | `docker image prune`, `sudo rm -rf /usr/share/dotnet /usr/local/lib/android`, `apt-get purge` for Azure CLI / Haskell / Java / .NET / Firefox / PHP / MySQL / PowerShell. |
| 9 | **Checkout private engine** | `actions/checkout@v4` of `${{ steps.runtime.outputs.engine_repository }}` into `toolbuild/`, with `lfs: true`, `persist-credentials: false`, `fetch-depth: 1`. |
| 10 | **Build / Pack / Upload** | Engine-driven `build.sh` → `packROM.sh` → `uploadROM.sh`. The master workflow logs `notify.py start/pack/upload/success/failed/cancelled` around each engine step, measures `df/free/nproc` before packaging, requires exactly one ZIP matching the project's pattern in `out/`, computes the human-readable file size, and exports `DEADZONE_FILE_SIZE`, `DEADZONE_INTEGRITY_VERIFIED=1`, and `DEADZONE_RESULT_NAME` to `$GITHUB_ENV`. |
| 11 | **Notify / Publish / Cleanup** | `notify.py success` → `publish-website-release.py local` (best-effort, `continue-on-error: true`) → failure / cancellation handlers signed with `BUILD_PROGRESS_SECRET` → runner-cleanup helper. |

### Project-specific invariants preserved by each master

These are the *only* places a master workflow may legitimately diverge
from another master:

| Invariant                  | How it is preserved                                                                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Project name / slug**    | `DEADZONE_PROJECT` job env, `engine_repository` assertion`, `notify.py` argument, `--project` flag on terminal-event scripts, `DEADZONE_*_URL` env var prefixes, `runtime/load-build.sh <slug>`. |
| **Engine repository**      | Hard-coded expected engine (e.g. `DeadZone-Offical/DeadZone-xiaomi_GamingPlus`) compared against `steps.runtime.outputs.engine_repository`. |
| **Final ZIP pattern**      | `find "$PWD/out" -maxdepth 1 -type f -name '<ProjectSlug>_*.zip'`. For example: GamingPlus looks for `DeadZone_Lite_*.zip` (legacy engine name); Port ColorOS looks for `DeadZone_ColorOSPort_*.zip`; Port OxygenOS looks for `DeadZone_OxygenOSPort_*.zip`. |
| **State dir path**         | `toolbuild/bin/ddevice/` for the lite-family (Lite, GamingPlus, Legend, Ninja); `toolbuild/bin/device/` for `lite.yml` itself; `toolbuild/build/.port_state/{stock,port}/ddevice/` for the port family. The `codename` is read from the **stock** state directory and the `rom_version` from the **port** state directory. |
| **OS folder derivation**   | Read `base_rom_code.txt`: if it matches `^OS[0-9]+`, take `OS<digits>`; else if it matches `^[Vv]([0-9]+)`, take `MIUI<digits>`. Port variants hard-code `os_folder="ColorOS"`, `os_folder="OxygenOS"`, `os_folder="RealmeUI"`. |
| **Mirror project name**    | The first positional argument passed to `runtime/upload-mirrors.sh`: e.g. `"GamingPlus"`, `"Legend"`, `"Ninja"`, `"Lite"`, `"Port"`, `"Jesse"`. |
| **Drive remote path**      | `${RCLONE_REMOTE_NAME}:${RCLONE_UPLOAD_DIR%/}/<ProjectSlug>/${codename}/${os_folder}/`. |
| **Notify / engine layout** | Engine-specific required files: `build.sh`, `functions.sh`, `notify.py`, `packROM.sh`, `uploadROM.sh` for the lite-family; `bin/port/{...}` for the port family; `cli.py`, `tools/notify.py`, `tools/upload.py` for `jesse`. |

---

## 2. `workflow_call` contract

The thin wrappers (`custom-X-N.yml`, `N = 1..5`) and any future
machine caller invoke a master workflow through `workflow_call`. The
contract is:

### Inputs

| Input          | Type   | Required | Description                                                       |
| -------------- | ------ | -------- | ------------------------------------------------------------------ |
| `input_url`    | string | yes      | ROM download URL (single-URL projects). Ignored by `port_pair` projects. |
| `builder_name` | string | no       | Human-readable builder name (Telegram display name).               |
| `builder_id`   | string | no       | Telegram user ID (decimal).                                         |
| `request_id`   | string | yes      | DeadZone controlled-build request ID. Pattern: `^[a-z][a-z0-9_]*_[A-Za-z0-9]{8,80}$` where the prefix is the project slug. |
| `callback_url` | string | yes      | Signed HTTPS callback endpoint for build events.                  |

`port_pair` projects (`port.yml`, `port-coloros.yml`, `port-oxygenos.yml`,
`port-realmeui.yml`) do **not** expose `workflow_call`. They are
dispatched directly via `workflow_dispatch` because they take two ROM
URLs (`stock_rom_url` + `port_rom_url`) instead of one and have a
different `DEADZONE_STOCK_ROM_URL` / `DEADZONE_PORT_ROM_URL` env
contract. They are still governed by the same lifecycle.

### Secrets

| Secret     | Required | Description                                                  |
| ---------- | -------- | ------------------------------------------------------------- |
| `GH_TOKEN` | yes      | Fine-grained PAT used for both `DeadZone-File` and engine checkouts and for `publish-website-release.py`. |

SourceForge SSH keys and PixelDrain API keys are **no longer required**
as of the 2026-09-30 single-destination change. The central
`upload-mirrors.sh` no-ops when `DEADZONE_ENABLE_SECONDARY_MIRRORS != "1"`,
which is the default while Google Drive is the only active destination.
Flip the env var back to `"1"` to re-enable SourceForge / PixelDrain.

### Outputs (from `workflow_call`)

The thin wrappers do not currently consume any outputs from the master
workflow — they `secrets: inherit` and let the master run to completion.
If a wrapper needs the final ZIP URL it can read
`DEADZONE_RESULT_URL` / `DEADZONE_GOOGLE_DRIVE_URL` from a future
master's `outputs:` block, but this is not yet implemented.

---

## 3. Central runtime — `DeadZone-Offical/DeadZone-File`

Every master workflow sparse-checkouts the same eight files from
`DeadZone-Offical/DeadZone-File@main`:

| File                          | Role                                                           |
| ----------------------------- | -------------------------------------------------------------- |
| `projects.env`                | Project → engine mapping, sourced by `load-build.sh`.          |
| `build.env`                   | Shared build-time secrets (`BUILD_PROGRESS_SECRET`, …).        |
| `rclone.conf`                 | Centralised rclone configuration for the upload remote.        |
| `load-build.sh`               | Sources both env files, validates `rclone.conf`, prints `engine_repository`. |
| `report_build_event.py`       | Signs and posts terminal events (`failed`, `cancelled`) to the callback URL. |
| `upload.env`                  | SourceForge / PixelDrain configuration (used by `upload-mirrors.sh`). |
| `upload-mirrors.sh`           | Drives secondary mirror uploads. No-ops when mirrors are disabled. |
| `publish-website-release.py`  | Publishes a successful build to the DeadZone website.          |

The master workflow then runs:

```bash
for runtime_file in projects.env build.env rclone.conf \
                    load-build.sh report_build_event.py \
                    upload.env upload-mirrors.sh \
                    publish-website-release.py; do
  if [[ ! -s "runtime/${runtime_file}" ]]; then
    echo "::error::Central runtime file is missing or empty: ${runtime_file}"
    exit 1
  fi
done
chmod 700 runtime/load-build.sh runtime/upload-mirrors.sh
python3 -m py_compile runtime/report_build_event.py \
                       runtime/publish-website-release.py
runtime/load-build.sh <project_slug>
```

The engine slug returned by `load-build.sh` is captured in
`steps.runtime.outputs.engine_repository` and asserted against the
project's expected engine in the next step.

---

## 4. Adding a new ROM project in 3 steps

Adding a project means adding exactly three things:

1. **An entry in `DeadZone-Offical/DeadZone-File/projects.env`.**
   This maps the project slug (e.g. `aurora`) to its engine
   repository slug (e.g. `DeadZone-Offical/DeadZone-xiaomi_Aurora`).
   `load-build.sh` will then emit that slug into
   `engine_repository` for the master workflow to assert.

2. **An engine repository** — for example
   `DeadZone-Offical/DeadZone-xiaomi_Aurora`. The engine must contain
   at minimum: `build.sh`, `functions.sh`, `notify.py`, `packROM.sh`,
   `uploadROM.sh`. The engine's `uploadROM.sh` must produce exactly
   one ZIP in `out/` matching the project's declared pattern, e.g.
   `DeadZone_Aurora_*.zip`.

3. **A master workflow file** (`.github/workflows/custom-aurora.yml`).
   This file:
   - Declares `workflow_dispatch` and `workflow_call` triggers with the
     inputs in §2.
   - For new projects: replaces the inline Python validation step with
     a `workflow_call` to `.github/workflows/validate.yml` (see §5).
   - Sets `DEADZONE_PROJECT=aurora` and runs the eleven-step
     lifecycle from §1.
   - Asserts that `steps.runtime.outputs.engine_repository` equals
     `DeadZone-Offical/DeadZone-xiaomi_Aurora`.
   - Asserts the final ZIP pattern `DeadZone_Aurora_*.zip`.
   - Emits the same `DEADZONE_FILE_SIZE`, `DEADZONE_INTEGRITY_VERIFIED=1`,
     `DEADZONE_RESULT_NAME`, and `DEADZONE_*_URL` env vars as every
     other master.

Optionally, add one or more thin wrappers
(`custom-aurora-1.yml` .. `custom-aurora-5.yml`) so that the project
gets its own queue slots. Each wrapper is ~40 lines: declare the same
`workflow_dispatch` inputs, then `uses: ./.github/workflows/custom-aurora.yml`
with `secrets: inherit`. No further code.

---

## 5. Reusable validation: `.github/workflows/validate.yml`

`.github/workflows/validate.yml` is a **new** reusable workflow that
performs steps 1 and 2 of the lifecycle in §1 (controlled-request
validation + launcher-credential check). It is intended for **new**
master workflows only.

**Existing master workflows MUST NOT be retrofitted to call it.**
Their inline Python validation is part of their public contract — the
bot depends on its exact error messages and the inline step is what
lets existing projects ship before the reusable helper is fully
exercised in production.

### What it does

1. Validates `project_name` against `^[a-z][a-z0-9_]*$`.
2. Validates `request_id` against `^<project_name>_[A-Za-z0-9]{8,80}$`.
3. Validates `input_url` and `callback_url`:
   - scheme = `https`,
   - non-empty hostname,
   - no embedded username / password,
   - length ≤ 2048 chars,
   - the hostname resolves only to public IPs (rejects loopback,
     link-local, RFC1918 private, multicast, unspecified, reserved).
4. Confirms the `GH_TOKEN` secret is present.
5. Emits the expected engine repository slug
   (`DeadZone-Offical/DeadZone-xiaomi_<Project>`) into:
   - `$GITHUB_ENV` as `ENGINE_REPOSITORY`, for shell steps, and
   - `$GITHUB_OUTPUT` as the step output `engine_repository`, so the
     calling workflow can wire it into `jobs.<id>.outputs`.

It deliberately **does not** use the deprecated `::set-output` workflow
command — see the in-file comment.

### Required inputs and secrets

| Input          | Required | Notes                                                       |
| -------------- | -------- | ------------------------------------------------------------ |
| `input_url`    | yes      |                                                              |
| `builder_name` | no       | Default `""`.                                                |
| `builder_id`   | no       | Default `""`.                                                |
| `request_id`   | yes      |                                                              |
| `callback_url` | yes      |                                                              |
| `project_name` | yes      | Lowercase slug, e.g. `aurora`, `port_coloros`.              |

| Secret     | Required |
| ---------- | -------- |
| `GH_TOKEN` | yes      |

### Caller shape (new master workflow)

```yaml
jobs:
  validate:
    uses: ./.github/workflows/validate.yml
    with:
      input_url:    ${{ inputs.input_url }}
      builder_name: ${{ inputs.builder_name }}
      builder_id:   ${{ inputs.builder_id }}
      request_id:   ${{ inputs.request_id }}
      callback_url: ${{ inputs.callback_url }}
      project_name: aurora
    secrets:
      GH_TOKEN: ${{ secrets.GH_TOKEN }}

  build:
    needs: validate
    runs-on: ubuntu-latest
    env:
      DEADZONE_PROJECT: aurora
      # ...
    steps:
      - name: ⚙️ Load central runtime
        id: runtime
        env:
          ENGINE_REPOSITORY: ${{ needs.validate.outputs.engine_repository }}
        run: |
          set -euo pipefail
          # ... (same lifecycle as every master, but skip the
          # inline validation step and the credentials step —
          # validate.yml covered both.)
```

---

## 6. `rom_url` vs `port_pair` projects

Both classes honour the eleven-step lifecycle in §1. The only
differences are dispatch inputs and which files the engine reads.

| Aspect             | `rom_url` (lite, jesse, gamingplus, legend, ninja) | `port_pair` (port, port-coloros, port-oxygenos, port-realmeui) |
| ------------------ | -------------------------------------------------- | -------------------------------------------------------------- |
| Trigger inputs     | `input_url`                                       | `stock_rom_url` + `port_rom_url`                                |
| ROM URL env        | `DEADZONE_INPUT_URL`                              | `DEADZONE_STOCK_ROM_URL` + `DEADZONE_PORT_ROM_URL`               |
| Engine entry point | `bash build.sh "$DEADZONE_INPUT_URL" …`            | `bash build.sh "$DEADZONE_STOCK_ROM_URL" "$DEADZONE_PORT_ROM_URL" …` |
| ZIP pattern        | `DeadZone_<EngineSlug>_*.zip`                     | `DeadZone_<VariantSlug>Port_*.zip` (e.g. `DeadZone_ColorOSPort_*.zip`) |
| State dir          | `toolbuild/bin/ddevice/` (or `bin/device/` for lite) | `toolbuild/build/.port_state/{stock,port}/ddevice/`           |
| `codename` source  | engine state dir                                  | **stock** state dir                                              |
| `rom_version` source | engine state dir                                | **port** state dir                                               |
| `os_folder` derivation | regex over `base_rom_code.txt`               | hard-coded `ColorOS` / `OxygenOS` / `RealmeUI`, or regex for the stock-port pair |
| `workflow_call`?   | yes (`custom-X.yml`)                              | no — dispatched directly via `workflow_dispatch`                |

Both classes:

- share the same `workflow_call`-equivalent validation contract
  (`validate.yml`),
- share the same central runtime (`DeadZone-Offical/DeadZone-File`),
- share the same notify / publish / cleanup tail,
- and are routed through the same `DEADZONE_PROJECT` env var to the
  callback signing script.

---

## 7. Compatibility matrix

| Workflow                       | Mode         | Engine expected                                  | Slug     |
| ------------------------------ | ------------ | ------------------------------------------------- | -------- |
| `lite.yml`                     | rom_url      | `DeadZone-Offical/DeadZone-xiaomi_Lite`           | `lite`   |
| `jesse.yml`                    | rom_url      | `DeadZone-Offical/DeadZone_MysticGSI`             | `jesse`  |
| `custom-gamingplus.yml`        | rom_url      | `DeadZone-Offical/DeadZone-xiaomi_GamingPlus`     | `gamingplus` |
| `custom-legend.yml`            | rom_url      | `DeadZone-Offical/DeadZone-xiaomi_Legend`         | `legend` |
| `custom-ninja.yml`             | rom_url      | `DeadZone-Offical/DeadZone-xiaomi_Ninja`          | `ninja`  |
| `port.yml`                     | port_pair    | `DeadZone-Offical/DeadZone-xiaomi_Port`           | `port`   |
| `port-coloros.yml`             | port_pair    | `DeadZone-Offical/DeadZone-ColorOS_Port`          | `port_coloros` |
| `port-oxygenos.yml`            | port_pair    | `DeadZone-Offical/DeadZone-OxygenOS_Port`         | `port_oxygenos` |
| `port-realmeui.yml`            | port_pair    | `DeadZone-Offical/DeadZone-RealmeUI_Port`         | `port_realmeui` |
| `framework.yml`                | **special**  | not a ROM build — Framework Patcher toolchain. See `framework.yml` for its own contract. | n/a |

The numbered wrappers (`custom-X-1.yml` .. `custom-X-5.yml`) are queue
slots; they declare the same `workflow_dispatch` inputs as their
master and `uses: ./.github/workflows/<master>.yml` with
`secrets: inherit`.

---

## 8. See also

- [`WORKFLOWS.md`](./WORKFLOWS.md) — workflow directory tour.
- [`README.md`](../README.md) — top-level project overview.
- [`.github/workflows/validate.yml`](../.github/workflows/validate.yml)
  — the reusable validation helper described in §5.
- `DeadZone-Offical/DeadZone-File` — central runtime source of truth.