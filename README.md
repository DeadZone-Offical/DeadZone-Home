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
| `DeadZone-GaimngPlus` | `.github/workflows/deadzone-gaimngplus.yml` | `DeadZone-Offical/DeadZone-xiaomi_GamingPlus` |
| `DeadZone-Legend` | `.github/workflows/deadzone-legend.yml` | `DeadZone-Offical/DeadZone-xiaomi_Legend` |
| `DeadZone-Ninja` | `.github/workflows/deadzone-ninja.yml` | `DeadZone-Offical/DeadZone-xiaomi_Ninja` |
| `DeadZoneJesi` | `.github/workflows/deadzone-jesi.yml` | `DeadZone-Offical/DeadZone_MysticGSI` |
| `DeadZone-Fastboot` | `.github/workflows/deadzone-fastboot.yml` | `DeadZone-Offical/DeadZone-Fastboot-Doctor` |
| `DeadZone-Xiaomi-Port` | `.github/workflows/deadzone-xiaomi-port.yml` | `DeadZone-Offical/DeadZone-xiaomi_Port` |
| `DeadZone-ColorOS-Port` | `.github/workflows/deadzone-coloros-port.yml` | `DeadZone-Offical/DeadZone-ColorOS_Port` |
| `DeadZone-Oxgen-Port` | `.github/workflows/deadzone-oxgen-port.yml` | `DeadZone-Offical/DeadZone-OxygenOS_Port` |

## Required secrets

| Secret | Used by | Purpose |
|---|---|---|
| `GITHUB_TOKEN` | All workflows | Default token; used for everything inside `DeadZone-Home`. |
| `DEADZONE_PRIVATE_READ_TOKEN` | All workflows | Fine-grained PAT scoped to `Contents: Read` on the private engine repos and to `DeadZone-Offical/DeadZone-File`. This is the canonical credential for cloning private sources. |
| `GH_TOKEN` | All workflows | Migration fallback for `DEADZONE_PRIVATE_READ_TOKEN`; kept active until the new secret is fully provisioned. |
| `GITHUB_BUILD_TOKEN` | `DeadZone-Bot` only | Used by the bot when it dispatches `workflow_dispatch` against this repo. |

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