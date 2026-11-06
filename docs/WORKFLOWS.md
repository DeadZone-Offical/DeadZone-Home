# DeadZone-Home — Workflows tour

This page is the index to `.github/workflows/` for the DeadZone-Home
build network. For the deep contract every master workflow honours,
see [`REUSABLE_BUILD_CONTRACT.md`](./REUSABLE_BUILD_CONTRACT.md).

## Directory layout

```
.github/
├── scripts/
│   └── runner-cleanup.sh          # post-extract / post-package / final cleanup
└── workflows/
    ├── validate.yml               # reusable validation (new projects)
    ├── lite.yml                   # master — rom_url
    ├── jesse.yml                  # master — rom_url (GSI)
    ├── custom-gamingplus.yml      # master — rom_url
    ├── custom-legend.yml          # master — rom_url
    ├── custom-ninja.yml           # master — rom_url
    ├── custom-gamingplus-{1..5}.yml  # wrappers (queue slots)
    ├── custom-legend-{1..5}.yml       # wrappers (queue slots)
    ├── custom-ninja-{1..5}.yml        # wrappers (queue slots)
    ├── port.yml                   # master — port_pair
    ├── port-coloros.yml           # master — port_pair (variant)
    ├── port-oxygenos.yml          # master — port_pair (variant)
    ├── port-realmeui.yml          # master — port_pair (variant)
    ├── framework.yml              # SPECIAL — Framework Patcher toolchain (not a ROM build)
    ├── superinspector-*.yml       # diagnostic runs (CI helper)
    ├── bot-deploy.yml             # bot release pipeline
    ├── configure-deadzone-bot-secrets.yml
    ├── recover-lite-website.yml   # website recovery
    ├── sync-file.yml              # runtime sync helper
    └── validate-website.yml       # website CI
```

## Master vs wrapper

- **Master** workflows (`lite.yml`, `custom-X.yml`, `jesse.yml`,
  `port*.yml`) contain the full eleven-step lifecycle described in the
  [contract](./REUSABLE_BUILD_CONTRACT.md#1-shared-build-lifecycle).
  They expose both `workflow_dispatch` (for the bot) and
  `workflow_call` (for the wrappers).
- **Wrapper** workflows (`custom-X-N.yml`, `N = 1..5`) are ~40-line
  thin shells: they declare the same `workflow_dispatch` inputs as
  their master, then `uses: ./.github/workflows/<master>.yml` with
  `secrets: inherit`. Wrappers exist to give each project its own
  independent queue slot and concurrency group.

## Two dispatch shapes

| Shape       | Workflows                                                                   | Inputs                                                                                          |
| ----------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| `rom_url`   | `lite.yml`, `jesse.yml`, `custom-gamingplus.yml`, `custom-legend.yml`, `custom-ninja.yml` (and their `-N` wrappers) | `input_url`, `builder_name`, `builder_id`, `request_id`, `callback_url`                        |
| `port_pair` | `port.yml`, `port-coloros.yml`, `port-oxygenos.yml`, `port-realmeui.yml`        | `stock_rom_url`, `port_rom_url`, `builder_name`, `builder_id`, `request_id`, `callback_url`       |

`rom_url` projects expose `workflow_call`; `port_pair` projects are
dispatched directly because they take two ROM URLs and have a
different env contract.

## Reusable validation

`.github/workflows/validate.yml` is a single-job `workflow_call`-able
helper that performs controlled-request validation + launcher-credential
presence + engine slug derivation. **It is for new projects only** —
existing masters keep their inline Python validation. See the
[contract §5](./REUSABLE_BUILD_CONTRACT.md#5-reusable-validation-githubworkflowsvalidateyml)
for the full spec.

## Special cases

- `framework.yml` is **not** a ROM build — it is the Framework Patcher
  toolchain and follows its own lifecycle. It is documented inline in
  `framework.yml` and not covered by this contract.
- `superinspector-*.yml`, `bot-deploy.yml`,
  `configure-deadzone-bot-secrets.yml`, `recover-lite-website.yml`,
  `sync-file.yml`, `validate-website.yml` are auxiliary pipelines and
  are outside the build contract.

## Adding a new master workflow

1. Read [`REUSABLE_BUILD_CONTRACT.md`](./REUSABLE_BUILD_CONTRACT.md).
2. Decide whether your project is `rom_url` or `port_pair`.
3. Copy the closest existing master (`custom-ninja.yml` for `rom_url`,
   `port.yml` for `port_pair`) and adapt:
   - project name → everywhere it appears,
   - `engine_repository` slug → in the runtime assertion,
   - final ZIP pattern → in the `find … -name` call,
   - `DEADZONE_PROJECT` env var → for terminal-event signing,
   - notify / failure / cancellation messages.
4. (Optional, new projects) replace the inline Python validation step
   with a `workflow_call` to `.github/workflows/validate.yml` per
   [contract §5](./REUSABLE_BUILD_CONTRACT.md#5-reusable-validation-githubworkflowsvalidateyml).
5. Add a `workflows/<master>-N.yml` wrapper for each additional queue
   slot you need (or none, if a single slot is enough).
6. Update the compatibility matrix in
   [`REUSABLE_BUILD_CONTRACT.md` §7](./REUSABLE_BUILD_CONTRACT.md#7-compatibility-matrix).