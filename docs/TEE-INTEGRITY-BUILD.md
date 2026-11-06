# DeadZone — the reproducible build of the TEE and Integrity integration

This document describes how to build, verify and roll back the DeadZone
identity, configuration and diagnostic system on the Android 17 target.

**Every command below was executed on the delivery workstation.** The
results are the ones that are printed in the output blocks. A command
that was not executed is marked as such and is not claimed to work.

Lead developer: MEZO.

---

## 1. The repositories and the branches

| Repository | Branch | Role |
|---|---|---|
| `DeadZone-Framework-Hooks` | `feature/tee-integrity-a17` | The hook layer that is injected into the boot class path |
| `DeadZone-Toolbox-App` | `feature/tee-integrity-a17` | The control and the diagnostic interface |
| `DeadZone-Native-Core` | `feature/tee-integrity-a17` | The native core and its view of the contract |
| `DeadZone-Home` | `feature/tee-integrity-a17` | This documentation |

The `main` branch of every repository is untouched. The separate Java
reconstruction branch `feature/java-framework-rebuild-a17` of the hook
layer is preserved at its own commit and was not replaced.

---

## 2. The layout of the workspace

```
mezo/
  _repos/
    DeadZone-Framework-Hooks/     the hook layer
    DeadZone-Toolbox-App/         the application
    DeadZone-Native-Core/         the native core
    DeadZone-Home/                this documentation
  references/
    TEESimulator/                 the upstream reference, read only
    Integrity-Box/                the upstream reference, read only
  mystock/                        the stock platform artifacts, never modified
  out/                            the generated output, never inside a repository
```

The `references` directory holds the two upstream projects. They were
read and never built, never modified and never copied from. Their
commits are recorded in the analysis document.

---

## 3. The prerequisites

| Tool | Version used | Note |
|---|---|---|
| Java | 17 | The hook layer and the application are compiled for 17 |
| Gradle | 8.9 (hook layer), 9.3.1 (application) | Through the wrapper of each repository |
| Python | 3.12 | Every verification script of the delivery |
| CMake | 3.22 or later | Only for the native core, and only for the host tests |
| A C++17 compiler | g++ | Only for the host tests of the native core |
| The Android SDK | `platforms/android-35/android.jar` | The compile target of the hook layer |

The Android SDK is found through `ANDROID_HOME` or `ANDROID_SDK_ROOT`.
The property `androidJar` in `gradle.properties` overrides it when the
platform of the target differs.

---

## 4. The contract comes first

The contract is the single definition of the settings keys, of the
configuration documents and of the capability ownership. It is mirrored,
byte for byte, into the three repositories, so every repository can
prove that the view it carries is the view of the definition.

```bash
cd _repos/DeadZone-Toolbox-App
python3 tools/contract.py --check --workspace ..
```

```
[+] the views of the contract are up to date (contract version 2)
```

The same check, restricted to one repository, needs nothing but that
repository:

```bash
cd _repos/DeadZone-Framework-Hooks
python3 tools/contract.py --repository DeadZone-Framework-Hooks --workspace .
```

```
[+] the views of the contract are up to date in DeadZone-Framework-Hooks (contract version 2)
```

The mirrors are compared with each other when the three repositories are
side by side:

```bash
cd _repos/DeadZone-Toolbox-App
python3 tools/test_contract_mirrors.py
```

```
[+] the mirror of DeadZone-Framework-Hooks is identical to the definition
[+] the mirror of DeadZone-Toolbox-App is identical to the definition
[+] the mirror of DeadZone-Native-Core is identical to the definition
[+] every mirror of the contract is identical to the definition
```

The native core carries the same check for its own header:

```bash
cd _repos/DeadZone-Native-Core
python3 scripts/check_contract.py
```

```
[+] the views of the contract are up to date in DeadZone-Native-Core (contract version 2)
```

---

## 5. The verification of the hook layer

```bash
cd _repos/DeadZone-Framework-Hooks
./gradlew --offline --no-daemon check
```

The run produces:

```
> Task :verifyBootSafety
DeadZone boot safety regression suite
837 checks, 0 failures

> Task :verifyAssets
DeadZone - asset compatibility check
31 checks, 0 failures

> Task :verifyP0Integration
[*] DeadZoneProfilesTest
DeadZone profile engine tests
53 checks, 0 failures
[*] DeadZoneKeyMintBackendTest
DeadZone KeyMint test backend tests
44 checks, 0 failures
[*] DeadZoneCapabilityRegistryTest
DeadZone capability registry tests
64 checks, 0 failures
[*] DeadZoneKeyboxManagerTest
DeadZone keybox manager tests
45 checks, 0 failures
[*] DeadZoneRuntimeRepairTest
DeadZone P0 repair tests
53 checks, 0 failures
[+] the P0 integration passes its host tests

> Task :verifyPureJava
[+] the DEX is pure Java, no library is loaded

> Task :verifyRemainingJava
PASS 11 lifecycle assertions
PASS 12 admin safety assertions

BUILD SUCCESSFUL
```

The suite is a static analysis of the sources that end up in the boot
class path. It never touches a ROM, never flashes anything and never
modifies the stock platform artifacts.

**What this does not prove.** It does not prove that the device boots.
A device boot is a separate, still pending, step, and it is described in
`DeadZone-Framework-Hooks/docs/HARDWARE-VALIDATION.md`.

---

## 6. The verification of the application

```bash
cd _repos/DeadZone-Toolbox-App
./gradlew --no-daemon check
```

```
BUILD SUCCESSFUL
```

159 tests, 0 failures. The check also runs the static analysis of the
build, which reports two exceptions that are declared in `app/lint.xml`:
the permissions that only a system application may hold and the
enumeration of every installed application. Both are the reason the
toolbox exists, and the reason is written down in that file.

| Suite | Tests |
|---|---|
| `ProfileEngineTest` | 36 |
| `ConfigurationHealthTest` | 24 |
| `KeyboxLifecycleTest` | 22 |
| `DeadZoneContractTest` | 17 |
| `KeymintTestBackendTest` | 15 |
| `FrameworkLinkProbeTest` | 6 |
| `DeadZoneRomPublisherTest` | 5 |
| `PerAppSettingsDraftPolicyTest` | 4 |
| `DeviceDisplayNameTest` | 4 |
| `RuntimeHookProbeTest` | 4 |
| `StyleOptionsTest` | 4 |
| `SystemInfoRepositoryTest` | 4 |
| `DeadZoneEngineProbeTest` | 3 |
| `DeadZoneIntegrityLabTest` | 3 |
| `DeadZoneRuntimeProbeTest` | 3 |
| `DeadZoneRomPolicyTest` | 2 |
| `VerifiedDatabasePolicyTest` | 3 |
| **Total** | **159** |

---

## 7. The verification of the native core

```bash
cd _repos/DeadZone-Native-Core
bash scripts/run_host_tests.sh
```

```
== DeadZone Native Core host tests ==
89 checks, 0 failures

== DeadZone spoof engine tests ==
27 checks, 0 failures
```

The cross build for the device is described in §8.1.

---

## 8. The injection into the platform

The injection is a build step, so a failure is a build failure and
never a runtime bootloop.

```bash
cd _repos/DeadZone-Framework-Hooks
./gradlew --offline --no-daemon injectAndroid17 \
    -PstockPlatformDir=/path/to/mystock \
    -PpatchedPlatformDir=/path/to/out/patched
```

The stock jars are read and never written. The output goes to a separate
directory. The verification of the result is a hard gate:

```bash
./gradlew --offline --no-daemon verifyAndroid17 \
    -PstockPlatformDir=/path/to/mystock \
    -PpatchedPlatformDir=/path/to/out/patched
```

**This step was executed on the delivery workstation**, against the
stock artifacts of the target build.

```
> Task :injectAndroid17
[+] framework.jar: 16 hook point(s) applied, 0 legacy call(s) removed, appended ['classes8.dex']
[+] services.jar: 2 hook point(s) applied, 1 legacy call(s) removed, appended ['classes5.dex']
[+] the verification passed

> Task :verifyAndroid17
[+] framework.jar: 38291 classes, 0 lost, 0 duplicated
[+] services.jar: 23855 classes, 0 lost, 0 duplicated
[+] every check passed

> Task :verifyInjectionIdempotency
[+] framework.jar: already present (4 call sites), 0 legacy call(s) removed, appended nothing
[+] services.jar: already present (3 call sites), 0 legacy call(s) removed, appended nothing
[+] the injector is idempotent
```

The idempotency gate runs the pipeline a second time over its own output
and compares the digests of the two jars. They are equal, byte for byte,
so a build that runs twice produces the same artifact and reports the
truth about the second run.

The verification proves that the injection is lossless: no class of the
platform was lost and no class was duplicated, and the method id tables
of every DEX file stay under the limit of 65536.

**What this still does not prove.** It does not prove that the device
boots. A static verification cannot prove that. A device boot is a
separate, still pending, step, and it is described in
`DeadZone-Framework-Hooks/docs/HARDWARE-VALIDATION.md`.

---

## 8.1 The native core for the device

```bash
cd _repos/DeadZone-Native-Core
bash scripts/build_ndk.sh
```

**This step was executed on the delivery workstation**, with the NDK
27.0.12077973 that was on the machine.

```
[*] Building arm64-v8a (Release)
[*] Building armeabi-v7a (Release)
[*] Building x86 (Release)
[*] Building x86_64 (Release)
[*] Verifying symbol hygiene
[+] arm64-v8a: no Java_ symbol exported
[+] armeabi-v7a: no Java_ symbol exported
[+] x86: no Java_ symbol exported
[+] x86_64: no Java_ symbol exported
[PASS] Native ELF ABI, dependency, export and hardening checks
```

The library is built for every supported ABI and the export surface is
verified: only `JNI_OnLoad` is exported, so no `Java_` prefixed entry
point exists in the dynamic symbol table.

---

## 9. The rollback

There are three levels of rollback, from the cheapest to the most
complete.

### 9.1 The configuration of the toolbox

The application clears every document of the contract in one action
(the recovery action of the identity surfaces). With the documents gone
the platform answers with its own behaviour again, and nothing of the
platform was weakened to make that possible.

### 9.2 The injected DEX

The injection is reversible by construction. The stock jars are the
input of the injection and they are never modified, so restoring them is
a copy:

```bash
cp -f mystock/framework.jar out/patched/framework.jar
cp -f mystock/services.jar out/patched/services.jar
```

### 9.3 The platform partition

The procedure of a full restore, including the checksums of the original
files and the recovery path without a computer, is in
`DeadZone-Framework-Hooks/docs/HARDWARE-VALIDATION.md`. The checksum
list of the original artifacts is written before the flash and is the
authority on whether the partition was restored.

---

## 10. The resource protection of an unattended workstation

The delivery ran with a single Gradle daemon at a time and with the
offline flag, so no dependency was fetched in the middle of a build.

| Rule | How it was honoured |
|---|---|
| One heavy build at a time | The three repositories were built one after the other, never in parallel |
| No Gradle daemon left behind | Every build used `--no-daemon` |
| A bounded heap | The daemon of the hook layer is a single use daemon, forked by Gradle for the build and stopped with it |
| No destructive flashing | Nothing was flashed. The hardware step was never started |
| No unrelated process was killed | No process was terminated |
| The intermediate reports were kept | The boot safety report is written to `DeadZone-Framework-Hooks/build/boot-safety.json` |

---

## 11. What a reader can conclude, and what they cannot

**Concluded, with evidence in this delivery:**

- The hook layer stays pure Java. The DEX declares no native method and
  loads no shared library. The gate is part of the build.
- The boot class path carries no development component. The KeyMint test
  backend and the keybox manager live in the `dev` source set, which the
  build never compiles into the injected DEX.
- The components agree on the configuration. The four views of the
  contract are rendered from one definition and compared with the
  committed files, in every repository.
- The injection into the stock Android 17 artifacts is lossless. No class
  of the platform was lost, no class was duplicated and every method id
  table stays under its limit.
- The native core builds for every supported ABI and exports nothing but
  `JNI_OnLoad`.
- The simulated results cannot be read as real ones. The marker
  `deadzone-simulated-keymint` is on every document of the backend and
  the reported security level is always `Software`.
- No key material was downloaded, committed or logged.

**Not concluded, because no evidence exists:**

- That the device boots on the target ROM. The injection is verified
  statically; a boot needs a device.
- That any application passes Play Integrity or any other external
  attestation. A structurally valid keybox does not guarantee it, and
  the delivery makes no such claim.
- That the identity surfaces look correct on a device. They are compiled
  and their state logic is covered, but no screenshot test was run.
