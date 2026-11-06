# DeadZone Home — Claude Code Context

## Repository Purpose

GitHub Actions build orchestration for DeadZone ROM projects. This
repo owns:

- **Master build workflows** — one per ROM project, each implementing
  the eleven-step shared lifecycle (validate → checkout runtime →
  load runtime → checkout engine → install deps → build → pack →
  upload → notify → cleanup).
- **Numbered worker workflows** — thin `workflow_call` wrappers
  (`custom-X-1.yml` … `custom-X-5.yml`) that give each project its
  own independent concurrency group.
- **Reusable validation** — `.github/workflows/validate.yml` for new
  projects.
- **Shared scripts** — `.github/scripts/` (notably
  `runner-cleanup.sh` and the `dz_*` helpers).
- **Build fixtures** — `tests_fixtures/` for integration tests.

## Key Files

| Path                                                                                          | Purpose                                                                                              |
| --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `.github/workflows/lite.yml`                                                                  | Master workflow for `lite` (`rom_url` mode).                                                          |
| `.github/workflows/jesse.yml`                                                                 | Master workflow for `jesse` (GSI engine, requires an extra `build_name` input).                      |
| `.github/workflows/custom-gamingplus.yml` / `custom-legend.yml` / `custom-ninja.yml`         | Master workflows for the gamingplus / legend / ninja ROM engines.                                     |
| `.github/workflows/custom-{gamingplus,legend,ninja}-{1..5}.yml`                              | Numbered worker wrappers — each declares the same `workflow_dispatch` inputs as its master, then `uses: ./.github/workflows/custom-X.yml` with `secrets: inherit`. |
| `.github/workflows/port.yml`, `port-coloros.yml`, `port-oxygenos.yml`, `port-realmeui.yml`   | Master workflows for `port_pair` projects (two ROM URLs in, single ZIP out).                         |
| `.github/workflows/framework.yml`                                                             | Special: Framework Patcher toolchain (not a ROM build). Has its own contract inline.                 |
| `.github/workflows/superinspector-{core,1..5}.yml`                                           | Diagnostic / CI helper runs.                                                                         |
| `.github/workflows/validate.yml`                                                              | **Reusable** validation step (new projects only). Validates `input_url`, `callback_url`, `request_id`, derives the expected engine slug. |
| `.github/workflows/bot-deploy.yml`, `configure-deadzone-bot-secrets.yml`, `deploy-bot.yml` | Bot release pipeline + secret configuration.                                                          |
| `.github/workflows/sync-file.yml`, `validate-website.yml`, `recover-lite-website.yml`        | Website / runtime sync helpers.                                                                       |
| `.github/scripts/runner-cleanup.sh`                                                          | Centralized cleanup helper. Modes: `bootstrap`, `pre-build`, `post-extract`, `pre-package`, `post-package`, `final`, `light`. |
| `.github/scripts/dz_emit_callback.py`, `dz_validate_rom.py`                                 | Build-event signing and ROM-URL validation helpers.                                                  |
| `.github/scripts/build_zircon_fixture.py`, `e2e_real_rom.py`, `extract_fastboot_tgz.sh`     | Build fixture + integration test scripts.                                                            |
| `.github/scripts/test_*.py`, `test_*.sh`                                                     | Vitest-style and shell-based tests for the helpers above.                                             |
| `tests_fixtures/rom_e2e_fixture.tgz` / `.tar`                                                | Test fixture for ROM integration tests (already committed).                                          |
| `docs/REUSABLE_BUILD_CONTRACT.md`                                                             | The contract every master workflow MUST honour.                                                      |
| `docs/WORKFLOWS.md`                                                                           | Tour of `.github/workflows/` and how to add a new master.                                            |
| `docs/BUILD_SYSTEM_ARCHITECTURE.md`                                                           | Cross-repo map of bot ↔ home ↔ runtime.                                                              |

## Adding a New ROM Project

1. Add an entry to `DeadZone-Offical/DeadZone-File/projects.env`
   (engine repository, project slug, codename). `load-build.sh` reads
   from here.
2. Create the engine repository
   `DeadZone-Offical/DeadZone-xiaomi_{ProjectName}`. The engine must
   contain at minimum: `build.sh`, `functions.sh`, `notify.py`,
   `packROM.sh`, `uploadROM.sh`. `uploadROM.sh` must produce exactly
   one ZIP in `out/` matching the project's declared pattern.
3. Create the **master** workflow
   `.github/workflows/custom-{projectname}.yml`. The closest template
   is `custom-gamingplus.yml` (rom_url) or `port.yml` (port_pair).
   Replace inline names: `DEADZONE_PROJECT`, expected
   `engine_repository`, final ZIP pattern, notify / failure /
   cancellation messages.
4. (Recommended for new projects) Replace the inline Python validation
   step with a `workflow_call` to `.github/workflows/validate.yml` —
   see [`docs/REUSABLE_BUILD_CONTRACT.md` §5](./docs/REUSABLE_BUILD_CONTRACT.md#5-reusable-validation-githubworkflowsvalidateyml).
   **Existing masters MUST NOT be retrofitted.**
5. Create the five **worker wrappers**
   `custom-{projectname}-{1..5}.yml`. Each is ~40 lines:
   `workflow_dispatch` with the same inputs as the master, then
   `uses: ./.github/workflows/custom-{projectname}.yml` with
   `secrets: inherit`. Each wrapper needs its own concurrency group
   (`deadzone-home-{projectname}-build-{N}`).
6. Update the compatibility matrix in
   [`docs/REUSABLE_BUILD_CONTRACT.md` §7](./docs/REUSABLE_BUILD_CONTRACT.md#7-compatibility-matrix)
   and the bot registry in
   `DeadZone-Bot/cloudflare/src/project-registry.ts`.

## Workflow Contract

Every master ROM workflow MUST honour the eleven-step lifecycle:

```
1. Validate controlled request
2. Validate launcher credentials (GH_TOKEN present)
3. Checkout DeadZone launcher (this repo)
4. Checkout private runtime (DeadZone-Offical/DeadZone-File)
5. Load central runtime (runtime/load-build.sh <project_slug>)
6. Validate loaded runtime (engine_repository matches expected slug)
7. Maximize build space
8. Clean unused runner packages
9. Checkout private engine (DeadZone-Offical/DeadZone-xiaomi_<Project>)
10. Build / Pack / Upload (engine-driven)
11. Notify / Publish / Cleanup
```

`rom_url` projects expose both `workflow_dispatch` (for the bot) and
`workflow_call` (for the wrappers). `port_pair` projects expose only
`workflow_dispatch` because they take two ROM URLs.

See [`docs/REUSABLE_BUILD_CONTRACT.md`](./docs/REUSABLE_BUILD_CONTRACT.md)
for the full contract.

## Testing

- `tests_fixtures/rom_e2e_fixture.tgz` is a committed test ROM used by
  the integration scripts in `.github/scripts/`.
- The `dz_*` Python helpers have unit tests under
  `.github/scripts/test_dz_*.py`.
- The shared cleanup helper is exercised via the integration tests
  in `.github/scripts/test_superinspector_e2e.py` and
  `test_deadzone_mezo.py`.
- Real builds are triggered manually via `workflow_dispatch` in the
  GitHub Actions UI — there is no separate CI workflow for
  DeadZone-Home.

## Cross-Repo References

- Bot project registry: `DeadZone-Bot/cloudflare/src/project-registry.ts`.
- Build system map: `docs/BUILD_SYSTEM_ARCHITECTURE.md`.
- Master workflow contract: `docs/REUSABLE_BUILD_CONTRACT.md`.
- Workflow directory tour: `docs/WORKFLOWS.md`.
