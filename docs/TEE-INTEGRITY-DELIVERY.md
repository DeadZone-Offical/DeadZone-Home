# DeadZone — the delivery report of the TEE and Integrity integration

**Target:** DeadZone OS — Android 17 (MIUI / HyperOS), device Zircon / MyA17
**Mission:** the integration of the capabilities of TEESimulator and of
Integrity-Box into DeadZone
**Branch:** `feature/tee-integrity-a17`
**Lead developer:** MEZO

---

## 1. What was asked and what was delivered

The mission asked for a coherent DeadZone system with a unified device
identity, per application profiles, KeyStore and KeyMint diagnostics, a
separated and testable KeyMint simulation, secure keybox management, a
single configuration contract, conflict detection, a safe startup and a
controlled recovery.

The delivery is an independent implementation. **No upstream file was
copied.** TEESimulator and Integrity-Box were read at the source level
and their concepts were implemented in the DeadZone components that own
them.

| Deliverable | Where | State |
|---|---|---|
| The upstream reverse engineering report | `DeadZone-Framework-Hooks/docs/UPSTREAM-ARCHITECTURE-ANALYSIS.md` | Delivered |
| The integration architecture | The same document, §4 and §5 | Delivered |
| The unified configuration schema | `tools/contract.py` in the three repositories | Delivered, 30 keys, 9 documents, 13 capabilities |
| The profile management | `ProfileEngine.kt`, `DeadZoneProfiles.java` | Delivered |
| The KeyMint test backend | `DeadZoneKeyMintBackend.java` (dev), `KeymintTestBackend.kt` | Delivered, development only |
| The keybox management | `DeadZoneKeyboxManager.java` (dev), `KeyboxLifecycle.kt` | Delivered |
| The toolbox controls and the diagnostics | `ui/identity/IdentityScreens.kt`, `module/diagnostics/` | Delivered |
| The native and Java compatibility work | `DeadZone-Native-Core`, `DeadZone-Framework-Hooks` | Delivered |
| The conflict and the boot safety checks | `DeadZoneCapabilityRegistry.java`, `scripts/boot_safety_check.py` | Delivered |
| The automated regression tests | 159 + 206 + 116 + 800 | Delivered |
| The Android 17 integration artifacts | `mezo/out/patched/` | Produced and statically verified |
| The reproducible build documentation | `DeadZone-Home/docs/TEE-INTEGRITY-BUILD.md` | Delivered |
| The feature parity matrix | `DeadZone-Framework-Hooks/docs/TEE-INTEGRITY-FEATURE-MATRIX.md` | Delivered |
| The recovery and the rollback | The same document, §9 | Delivered |
| The commit hashes and the pull requests | §8 of this document | Delivered |

---

## 2. The commits

### DeadZone-Framework-Hooks

| Commit | Subject |
|---|---|
| `4c45a68` | feat: add the unified DeadZone configuration contract |
| `218c334` | feat: add the profile engine and the capability registry to the hook layer |
| `b4676e9` | feat: add the isolated KeyMint test backend and the keybox manager |
| `f141b25` | test: add the boot safety regression suite and the host tests of the P0 work |
| `75a0426` | build: add the platform stubs of the KeyMint interfaces to the host check |
| `04d94b1` | build: verify the contract and correct the check of the pure Java DEX |
| `c425b7c` | refactor: make the hook facade stateless and the engines lazily built |
| `02dc8fd` | feat: add the Android 17 injection points of the reference implementation |
| `42afec1` | docs: publish the upstream analysis and the feature parity matrix |

### DeadZone-Toolbox-App

| Commit | Subject |
|---|---|
| `ddca769` | feat: add the unified DeadZone configuration contract to the toolbox |
| `3c9c536` | feat: add the profile engine and the pure Kotlin JSON model |
| `4b1af3b` | feat: add the keybox lifecycle to the toolbox |
| `767e8f0` | feat: add the KeyMint test backend and the configuration health report |
| `2f5546e` | feat: add the identity surfaces to the toolbox |
| `017be33` | feat: route the new identity surfaces from the navigation |
| `df7d255` | test: verify the views of the contract and the agreement of the components |

### DeadZone-Native-Core

| Commit | Subject |
|---|---|
| `8eb4f57` | feat: add the configuration contract to the native core |

### DeadZone-Home

| Commit | Subject |
|---|---|
| see §8 | docs: publish the delivery report and the reproducible build |

The `main` branch of every repository is untouched. The separate Java
reconstruction branch `feature/java-framework-rebuild-a17` of the hook
layer is preserved at `0c98673` and was not replaced.

---

## 3. The test evidence

Every number below is the number that the build reported. Nothing is
estimated.

| Suite | Command | Result |
|---|---|---|
| Toolbox unit tests | `./gradlew test` | 159 tests, 0 failures |
| Framework host tests | `./gradlew check` | 206 checks, 0 failures |
| Native core host tests | `bash scripts/run_host_tests.sh` | 116 checks, 0 failures |
| Boot safety | `python3 scripts/boot_safety_check.py` | 800 checks, 0 failures |
| Contract views | `python3 tools/contract.py --repository ...` | 4 views, up to date |
| Contract mirrors | `python3 tools/test_contract_mirrors.py` | 3 mirrors, identical |
| Native build | `bash scripts/build_ndk.sh` | 4 ABIs, export surface verified |
| Platform injection | `./gradlew injectAndroid17` | 16 + 2 hook points, verification passed |
| Platform verification | `./gradlew verifyAndroid17` | 0 classes lost, 0 duplicated |

The boot safety suite covers twelve invariants over the sources that end
up in the boot class path: no development component, no dangling
reference, no duplicate class, no native method and no load of a shared
library, no support library, no legacy namespace, a deterministic
initialization order, a hook point that names a method the hook layer
really defines, a configuration reader that fails open, an agreement
between the two contracts, and untouched stock artifacts.

The suite is a static analysis. **It does not prove that the device
boots.** The boot of the device on the real ROM is the one step of this
delivery that is still pending, and it is described as a procedure, not
as a result, in `DeadZone-Framework-Hooks/docs/HARDWARE-VALIDATION.md`.

---

## 4. What was deliberately not implemented, and why

| Upstream capability | Why it is excluded |
|---|---|
| The injection of a library into a running process | Replaced by a build time injection into the platform jars. The injection is deterministic and needs no privilege. |
| The PLT hook of `libbinder` | It would intercept the same native transaction twice. |
| The replacement of the real KeyMint | It would put a simulation in the path of a genuine attestation. |
| The Rust reference trusted application | It is not buildable in this environment and it is not the right design. The semantics are implemented against the crypto stack of the platform. |
| The vendored BoringSSL | Its build is Soong only and needs a whole AOSP tree. The crypto of the platform is already established and maintained. |
| The temporary relaxation of SELinux | The mission forbids solving a compatibility problem by disabling the platform security. |
| The edits of the root manager internals | Out of the scope of DeadZone and a stability risk. |
| The download of a keybox | A keybox carries the private key of the device. The upstream fetch is additionally unauthenticated by construction: it uses `wget --no-check-certificate` and `curl --insecure`. |
| The download and the execution of code at runtime | Never. |
| The web server of the module | The native interface of the toolbox is the better surface on Android, and a listening web server is a needless exposure. |
| The legacy KeyStore 1 interface | Android 17 has no KeyStore 1 path. |

Thirteen capabilities are excluded, every one of them with a reason.
None was excluded silently. The full list is in the parity matrix.

---

## 5. The licensing position

TEESimulator and Integrity-Box are GPLv3. **No upstream file was copied
into DeadZone.** The delivery is an independent implementation of the
concepts of the two projects, so the GPLv3 obligations of the two
upstream projects are not incurred by it.

The analysis document quotes the upstream identifiers and names the
upstream functions. That is attribution of a prior work, and it is not a
distribution of its code.

If a future change decides to reuse an upstream file, the obligations
that come with it have to be settled first: a copyleft file in the hook
layer would put the whole ROM under the terms of the GPLv3, and the
strategy for that is a decision of the project, not of a commit.

---

## 6. The security position

| Rule | How it is held |
|---|---|
| No embedded private key | The keybox is only imported from material the owner supplies. The tests generate their own key pairs at run time. |
| No secret in a repository | The three repositories were scanned for key material before the delivery. The only occurrences of a PEM header are the synthetic test vectors of the native core, and they were already on `main`. |
| No untrusted automatic code execution | Nothing is downloaded and executed at run time. The update path of the upstream was not ported. |
| No silent system security downgrade | The SELinux relaxation of the upstream was not ported. DeadZone reaches the same result through the framework hook points, where no policy has to be relaxed. |
| No fake attestation report | The simulation marker `deadzone-simulated-keymint` is on every document of the backend and the reported security level is always `Software`. The contract test proves the marker is the same on both sides of the boundary. |
| No uncontrolled change to an unrelated application | Every hook point answers only for the packages that a profile claims. The platform answers for everything else. |
| No private information in a log | The keybox manifest is a description and never carries key material. The redaction of the upstream was not needed because nothing sensitive is produced. |
| No deployment to a third party device | Nothing was flashed. The hardware step was never started. |

---

## 7. The remaining limitations

1. **The device boot is unverified.** No authorised Android 17 device or
   emulator was attached to the workstation. The injection is verified
   statically against the real stock artifacts, but that is not a boot.
2. **The identity surfaces have no screenshot test.** They compile and
   their state logic is covered by 159 tests, but their layout on a
   device was not confirmed.
3. **The KeyMint test backend is not a trusted application.** It is a
   host test harness for the shape of the interface. It is not ABI
   compatible with the platform KeyMint AIDL and it does not produce a
   platform attestation. Its stated purpose is to be a test harness, and
   it is marked as such everywhere.
4. **A faithful port of the Rust reference trusted application was not
   attempted.** There is no Rust toolchain on the machine, its BoringSSL
   dependency does not build outside an AOSP tree, and it targets
   `android-15` rather than Android 17.
5. **The chain of the keybox is not validated against a trust anchor.**
   The private key is checked against its certificate with a sign and
   verify round trip, which is the correct check for a device keybox,
   because such a chain is self signed by design.
6. **One backup level of the keybox.** The upstream keeps a timestamped
   directory of them. DeadZone keeps one document, which is enough to
   recover from a bad import.

---

## 8. The pull requests

| Repository | Pull request |
|---|---|
| DeadZone-Framework-Hooks | `https://github.com/DeadZone-Offical/DeadZone-Framework-Hooks/pull/1` |
| DeadZone-Toolbox-App | `https://github.com/DeadZone-Offical/DeadZone-Toolbox-App/pull/1` |
| DeadZone-Native-Core | `https://github.com/DeadZone-Offical/DeadZone-Native-Core/pull/1` |
| DeadZone-Home | `https://github.com/DeadZone-Offical/DeadZone-Home/pull/1` |

**None of them is merged.** A runtime critical modification must not be
merged before its applicable validation has passed, and the device boot
has not happened yet.

---

## 9. The next step

The next step is a controlled hardware run, and it is described in
`DeadZone-Framework-Hooks/docs/HARDWARE-VALIDATION.md`:

1. Record the checksums of the stock artifacts.
2. Flash the patched jars to an authorised device.
3. Boot it and watch the log of the hook layer.
4. Roll the partition back if the boot fails.

Nothing in this delivery claims that the boot succeeds. The procedure
exists so that the claim can be made with evidence, or refuted.
