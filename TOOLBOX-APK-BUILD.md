# DeadZone Toolbox APK workflow

Workflow: [DeadZone Toolbox APK](.github/workflows/deadzone-toolbox-apk.yml)

This workflow is intentionally limited to **DeadZone-Toolbox-App**. It
checks out `DeadZone-Offical/DeadZone-Toolbox-App` at `main`, restores Git LFS
build prerequisites, builds `:app:assembleRelease`, validates the APK's
**V1, V2 and V3** signatures, and publishes the signed APK plus a SHA-256
checksum as a GitHub Actions artifact. It does not build a ROM, patch
framework jars, or flash a device.

## One-time setup

In **DeadZone-Home → Settings → Secrets and variables → Actions**, configure:

| Secret | Value |
|---|---|
| `DEADZONE_PRIVATE_READ_TOKEN` | Existing/restricted fine-grained GitHub PAT with **Contents: read** on the private `DeadZone-Toolbox-App` repository. If this secret already exists for other workflows, extend its repository access; do not replace it without checking other workflows. |
| `TOOLBOX_KEYSTORE_BASE64` | Base64 of the existing, stable Android release `.jks` file. |
| `TOOLBOX_STORE_PASSWORD` | Password for the release keystore. |
| `TOOLBOX_KEY_ALIAS` | Alias of the release signing key. |
| `TOOLBOX_KEY_PASSWORD` | Password for the release signing key. |

Base64-encode the keystore locally (do **not** commit it or paste it into a
workflow, issue, or chat):

```sh
base64 < deadzone-release.jks | tr -d '\n'
```

Store that output only as `TOOLBOX_KEYSTORE_BASE64` in GitHub Actions
Secrets. Reuse the same release keystore for all future updates of the app;
generating a different key on each run would break signature compatibility
for installed versions.

The app repository currently contains example release signing values in
`gradle.properties`. The workflow removes those example settings in the
**ephemeral checkout only** and supplies the real configuration using
Gradle environment-based project properties. No signing credential is
written back to either Git repository.

## Build

1. Open **DeadZone-Home → Actions → DeadZone Toolbox APK**.
2. Click **Run workflow**, select **main**, and run.
3. After the run succeeds, open its **Artifacts** and download
   `DeadZone-Toolbox-App-signed-V1-V2-V3`.
4. The artifact contains:
   - `DeadZone-Toolbox-App-V1-V2-V3.apk`
   - `signature-report.txt`
   - `SHA256SUMS.txt`

A missing secret, invalid checkout permissions, failed Gradle build,
or missing V1/V2/V3 signature causes the job to fail rather than
uploading an unverified APK.

The workflow is **manual-only** (`workflow_dispatch`) and always builds the
private app's **main** branch. The GitHub repository running the workflow
is public, so never print key material or add real keystores to its source.
