# DeadZone-Home

Public launcher and dispatcher for the DeadZone build network.

This repository holds the public-facing GitHub Actions workflows that
delegate controlled build requests to the private DeadZone engines.
It does **not** contain ROM source, build tooling, or release assets
— those live in the private `DeadZone-Offical/*` repositories.

---

## Workflows

| Workflow | What it does | Target engine |
|---|---|---|
| [`lite.yml`](./.github/workflows/lite.yml) | Dispatches a DeadZone Lite build request | [`DeadZone-Offical/DeadZone-xiaomi_Lite`](https://github.com/DeadZone-Offical/DeadZone-xiaomi_Lite) |

See [`.github/workflows/README.md`](./.github/workflows/README.md) for
the dispatch contract, required secrets, and how to invoke a build.

---

## Repository policy

* This repo is **public** and only contains the dispatcher workflow
  files and minimal documentation. Build engine code, ROM assets, and
  release artifacts live in the private `DeadZone-Offical/*`
  repositories.
* No credentials, secrets, or tokens are committed to this repo. The
  dispatcher uses `${{ secrets.* }}` and forwards them to the called
  engine via `secrets: inherit`.
* No application source code, assets, or unrelated files from
  upstream DeadZone repositories are mirrored here.

---

<p align="center"><sub>DeadZone-Home — public dispatcher for the DeadZone build network.</sub></p>