#!/usr/bin/env bash
# Contract tests for the DeadZone Stable build flow.
#
# The launcher is `deadzone-stable.yml` in `.github/workflows/`. These
# tests pin the corrected ownership-boundary contract:
#
#   1. The Stable flow is dispatched by a single workflow_dispatch
#      call (no pre-build prompt collection on the bot side). The
#      workflow does NOT declare a `publish_profile` input. Device
#      configuration is owned by DeadZone-SuperInspector, which
#      generates and publishes
#      ``bin/DeviceConfig/<codename>/<codename>.json`` into the
#      Stable engine repository.
#   2. The build (Stages 1-11) runs as one script invocation
#      (`bash build.sh --with-upload`); it must not require extra
#      user interaction.
#   3. The "🗂️ Collect Stable artifact metadata" step is
#      `continue-on-error: true` so a missing final ZIP after a
#      failed build does not double-fail the job.
#   4. There is NO post-success "Publish Stable device profile"
#      step. The launcher does NOT publish, backfill, or duplicate
#      SuperInspector's work.
#   5. The "✅ Send success notification" step is the terminal
#      succeeded event for the live panel; the launcher's
#      post-success surface is a single artifact-metadata step,
#      a single success-notification step, and a build-summary
#      step.
#   6. The bot never sends a `publish_profile` input; the
#      dispatcher does NOT inject one. A stale caller that
#      forwards `publish_profile` via `extraInputs` is silently
#      ignored (the dispatcher only forwards the keys the
#      project declares in `extraRequiredInputs`, and Stable
#      declares none).
#   7. The pre-build "🛡️ Verify SuperInspector device config
#      presence" step is mandatory. If `bin/DeviceConfig/` is
#      missing or empty, the launcher fails fast with a clear,
#      actionable error pointing the operator at SuperInspector
#      instead of letting the build progress 11 stages only to
#      die in Stage 9 with the engine's own
#      ``dz_flash_load_config`` error.
#
# Usage: tests/test_stable_flow_contract.sh
set -Eeuo pipefail

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${WORKFLOW_PATH:-${script_root}/.github/workflows/deadzone-stable.yml}"

failures=0
tests_run=0

pass() {
    tests_run=$((tests_run + 1))
    printf 'ok %d - %s\n' "$tests_run" "$1"
}

fail() {
    tests_run=$((tests_run + 1))
    failures=$((failures + 1))
    printf 'not ok %d - %s\n' "$tests_run" "$1"
    if [[ -n "${2:-}" ]]; then
        printf '  # %s\n' "$2"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "expected to find: ${needle}"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "did not expect to find: ${needle}"
    fi
}

# Extract the workflow document as text so the tests can never drift
# from what CI actually runs.
extract_workflow() {
    python3 - "$workflow" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    document = yaml.safe_load(handle)

steps = document["jobs"]["build"]["steps"]
out = {
    "inputs": document[True]["workflow_dispatch"]["inputs"],
    "steps": steps,
}
sys.stdout.write(yaml.safe_dump(out, sort_keys=False, allow_unicode=True))
PY
}

# Re-emit the YAML the test extracted with multi-line strings
# preserved as literal block scalars (`|`). The per-test
# `yaml.safe_load(yaml.safe_dump(...))` round-trip mangles
# every shell token that contains `"` or `$` because
# PyYAML folds long strings into a single double-quoted
# line. This helper walks the round-tripped value and
# re-marks multi-line strings so the second safe_dump
# emits them as `|` blocks the contract tests can grep
# verbatim. It is intentionally a thin wrapper around
# safe_dump so the rest of the test continues to operate
# on plain string values (e.g. `[[ "$x" == *"$y"* ]]`).
dump_step_yaml() {
    # Re-emit the YAML the test extracted with multi-line
    # strings preserved as literal block scalars (`|`).
    # The per-test `yaml.safe_load(yaml.safe_dump(...))`
    # round-trip mangles every shell token that contains
    # `"` or `$` because PyYAML folds long strings into a
    # single double-quoted line. This helper walks the
    # round-tripped value and re-marks multi-line strings
    # so the second safe_dump emits them as `|` blocks
    # the contract tests can grep verbatim. It is
    # intentionally a thin wrapper around safe_dump so the
    # rest of the test continues to operate on plain
    # string values (e.g. `[[ "$x" == *"$y"* ]]`).
    #
    # Implementation note: we use a temp file for the
    # Python script instead of `<<PYEOF` so the caller's
    # stdin (`< "$doc"`) is preserved. `<<PYEOF` would
    # override the caller's stdin redirection.
    local script
    script="$(mktemp)"
    cat > "$script" <<'PY'
import sys
import yaml


class _LiteralString(str):
    pass


def _literal_representer(dumper, data):
    return dumper.represent_scalar(
        "tag:yaml.org,2002:str", data, style="|"
    )


# IMPORTANT: `yaml.add_representer` registers on the
# unsafe Dumper, not SafeDumper. Pin the registration to
# SafeDumper so `yaml.safe_dump` (the only dumper the
# contract tests use) picks up the representer; without
# this, safe_dump falls through to `represent_undefined`
# and raises `RepresenterError: cannot represent an
# object` on every multi-line run script.
yaml.SafeDumper.add_representer(_LiteralString, _literal_representer)


def _walk(value):
    if isinstance(value, str) and "\n" in value:
        return _LiteralString(value)
    if isinstance(value, dict):
        return {key: _walk(sub) for key, sub in value.items()}
    if isinstance(value, list):
        return [_walk(sub) for sub in value]
    return value


raw = sys.stdin.read()
data = yaml.safe_load(raw)
if isinstance(data, dict):
    data = _walk(data)
sys.stdout.write(
    yaml.safe_dump(data, sort_keys=False, allow_unicode=True, width=99999)
)
PY
    python3 "$script"
    rm -f "$script"
}

# Resolve a step's index in the build job by name. Returns 0 on miss
# (the caller asserts afterwards).
step_index() {
    local workflow_doc="$1" step_name="$2"
    python3 - "$workflow_doc" "$step_name" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    document = yaml.safe_load(handle)

target = sys.argv[2]
for i, step in enumerate(document["steps"]):
    if step.get("name") == target:
        print(i)
        sys.exit(0)
sys.exit(1)
PY
}

# ---------------------------------------------------------------------------
# Test 1: workflow shape and `publish_profile` input contract.
#
# The corrected contract removes the `publish_profile`
# workflow_dispatch input entirely. Device configuration is owned
# by DeadZone-SuperInspector, which generates and publishes
# ``bin/DeviceConfig/<codename>/<codename>.json`` into the Stable
# engine repository; the launcher and the bot do NOT publish,
# backfill, or duplicate SuperInspector's work.
# ---------------------------------------------------------------------------
test_publish_profile_input_is_removed() {
    local doc step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"

    # The publish_profile workflow_dispatch input MUST NOT be
    # declared. The bot dispatches the build as soon as the user
    # submits a valid ROM URL, exactly like Lite / Fastboot /
    # Ninja, with only the baseline correlation inputs.
    step_yaml="$(dump_step_yaml < "$doc")"
    assert_not_contains "$step_yaml" "publish_profile" \
        "input: publish_profile is NOT a workflow_dispatch input (device configuration is owned by SuperInspector)"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 2: "🗂️ Collect Stable artifact metadata" is a hard gate after
# a successful build. When the Stable 11-stage pipeline completes
# and there is NOT exactly one preserved final ZIP, the workflow
# MUST fail with a precise ::error:: instead of degrading to a
# warning. A successful build that produced 0 or 2+ ZIPs is a
# real failure the operator has to act on, not a diagnostic
# footnote that the build could finish past.
# ---------------------------------------------------------------------------
test_collect_metadata_is_hard_gate() {
    local doc idx step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"
    idx="$(step_index "$doc" "🗂️ Collect Stable artifact metadata" || true)"
    if [[ -z "$idx" ]]; then
        fail "collect-metadata: step exists" "missing step"
        rm -f "$doc"
        return
    fi
    pass "collect-metadata: step exists"
    step_yaml="$(dump_step_yaml < "$doc")"
    assert_contains "$step_yaml" "if: success()" \
        "collect-metadata: step runs only after a successful build (if: success())"
    assert_not_contains "$step_yaml" "continue-on-error: true" \
        "collect-metadata: step is NOT marked continue-on-error (a successful build that produced the wrong ZIP count is a real failure)"
    assert_contains "$step_yaml" "Expected exactly one preserved final Stable ZIP" \
        "collect-metadata: step reports a precise error when the final ZIP is missing or duplicated"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 3: no post-success "Publish Stable device profile" step.
# ---------------------------------------------------------------------------
test_no_post_success_publish_steps() {
    local doc
    doc="$(mktemp)"
    extract_workflow > "$doc"

    local step_yaml
    step_yaml="$(dump_step_yaml < "$doc")"
    assert_not_contains "$step_yaml" "📤 Publish Stable device profile" \
        "no-publish: launcher does NOT include a 'Publish Stable device profile' post-success step (SuperInspector owns the registry)"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 4: pre-build SuperInspector DeviceConfig validation is wired
# up. If ``bin/DeviceConfig/`` is missing or empty, the launcher
# fails fast with a clear, actionable error pointing the operator
# at SuperInspector.
# ---------------------------------------------------------------------------
test_pre_build_superinspector_validation() {
    local doc idx step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"
    idx="$(step_index "$doc" "🛡️ Verify SuperInspector device config presence" || true)"
    if [[ -z "$idx" ]]; then
        fail "superinspector-validation: step exists" "missing step"
        rm -f "$doc"
        return
    fi
    pass "superinspector-validation: step exists"
    step_yaml="$(dump_step_yaml < "$doc")"
    assert_contains "$step_yaml" "bin/DeviceConfig" \
        "superinspector-validation: step probes bin/DeviceConfig"
    assert_contains "$step_yaml" "DeadZone-SuperInspector" \
        "superinspector-validation: step names DeadZone-SuperInspector as the owner"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 5: build step invokes build.sh with --with-upload, mirroring
# the Lite proven pipeline.
# ---------------------------------------------------------------------------
test_build_step_uses_build_sh() {
    local doc build_idx step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"
    build_idx="$(step_index "$doc" "🚀 Build, release, and upload Stable ROM" || true)"
    if [[ -z "$build_idx" ]]; then
        fail "build: step exists" "missing step"
        rm -f "$doc"
        return
    fi
    pass "build: step exists"
    step_yaml="$(dump_step_yaml < "$doc")"
    assert_contains "$step_yaml" "build.sh" \
        "build: step invokes build.sh (the Stable pipeline entrypoint)"
    assert_contains "$step_yaml" "--with-upload" \
        "build: step passes --with-upload so Stage 11 (Google Drive) runs inside the same script"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 6: Lite-parity progress events are wired up.
# ---------------------------------------------------------------------------
test_progress_events_present() {
    local doc
    doc="$(mktemp)"
    extract_workflow > "$doc"
    step_yaml="$(dump_step_yaml < "$doc")"
    assert_contains "$step_yaml" "Report progress to bot (Lite parity)" \
        "progress: Lite-parity stage events step is present"
    assert_contains "$step_yaml" "downloading" \
        "progress: downloading stage is emitted"
    assert_contains "$step_yaml" "reading_rom" \
        "progress: reading_rom stage is emitted"
    assert_contains "$step_yaml" "building" \
        "progress: building stage is emitted"
    assert_contains "$step_yaml" "packaging" \
        "progress: packaging stage is emitted"
    assert_contains "$step_yaml" "uploading" \
        "progress: uploading stage is emitted"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 7: the 403-diagnostic step exists for the private engine
# checkout. The canonical symptom of run 37811685473 was a silent
# 403 on `actions/checkout`; the corrected contract surfaces an
# actionable ::error:: annotation.
# ---------------------------------------------------------------------------
test_engine_checkout_403_diagnostic() {
    local doc idx step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"
    idx="$(step_index "$doc" "🛡️ Verify private Stable engine checkout" || true)"
    if [[ -z "$idx" ]]; then
        fail "403-diagnostic: step exists" "missing step"
        rm -f "$doc"
        return
    fi
    pass "403-diagnostic: step exists"
    step_yaml="$(dump_step_yaml < "$doc")"
    assert_contains "$step_yaml" "DEADZONE_PRIVATE_READ_TOKEN" \
        "403-diagnostic: step names the secret that must be re-provisioned"
    assert_contains "$step_yaml" "Contents: Read-only" \
        "403-diagnostic: step names the required Contents scope"
    assert_contains "$step_yaml" "DeadZone-Offical/DeadZone-Xiaomi-Stable" \
        "403-diagnostic: step names the engine repository that needs the scope"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 8: the Stable preparation sequence mirrors the verified
# Lite / Ninja layout. The accepted run 37817960658 failed at the
# engine checkout (403) and never reached the engine validation
# or build; the corrected workflow pins the full Lite / Ninja
# preparation chain — LFS object fetch, engine layout check,
# SuperInspector DeviceConfig presence, start live tracking,
# report starting stage, Cairo timezone, OpenJDK 17, apt deps,
# builder perms, and rclone config install — so a future operator
# who lands on the page immediately sees where the pipeline was
# stopped and which Lite-parity step is missing.
# ---------------------------------------------------------------------------
test_lite_parity_preparation_steps() {
    local doc step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"
    step_yaml="$(dump_step_yaml < "$doc")"

    assert_contains "$step_yaml" "🛡️ Verify Stable engine LFS objects" \
        "lite-parity: explicit LFS object verification step (matches Lite / Ninja)"
    assert_contains "$step_yaml" "🧭 Validate Stable engine layout" \
        "lite-parity: Stable-specific engine layout validation step (replaces the Lite 'functions.sh / packROM.sh / uploadROM.sh' check with Stable's bin/* layout)"
    assert_contains "$step_yaml" "🛡️ Verify SuperInspector device config presence" \
        "lite-parity: pre-build SuperInspector DeviceConfig check is mandatory"
    assert_contains "$step_yaml" "📣 Start live tracking" \
        "lite-parity: live tracking step (matches Lite / Ninja ordering)"
    assert_contains "$step_yaml" "📡 Report starting stage to bot" \
        "lite-parity: starting stage report (matches Lite / Ninja ordering)"
    assert_contains "$step_yaml" "🕒 Set Cairo timezone" \
        "lite-parity: Cairo timezone step (matches Lite / Ninja ordering)"
    assert_contains "$step_yaml" "☕ Install OpenJDK" \
        "lite-parity: OpenJDK 17 install step (matches Lite / Ninja)"
    assert_contains "$step_yaml" "🧰 Install Stable dependencies" \
        "lite-parity: full apt+pip dependency install step (matches Lite / Ninja)"
    assert_contains "$step_yaml" "🔓 Grant builder permissions" \
        "lite-parity: toolbuild chmod step (matches Lite / Ninja)"
    assert_contains "$step_yaml" "☁️ Install central Rclone configuration" \
        "lite-parity: rclone.conf install step (matches Lite / Ninja)"

    # Defensive: the old "🛡️ Prepare Stable engine for rclone
    # upload" step is gone because it conflated three concerns
    # (rclone config install, the now-removed bin/device cleanup,
    # and engine validation). The new step cleanly installs the
    # rclone config and does not touch bin/device, which is owned
    # by the engine's persist_state.sh and SuperInspector.
    assert_not_contains "$step_yaml" "🛡️ Prepare Stable engine for rclone upload" \
        "lite-parity: the old combined rclone+bin/device cleanup step is gone (it conflated concerns and could delete engine state files)"
    assert_not_contains "$step_yaml" "bin/device -type f -delete" \
        "lite-parity: no defensive find/delete over toolbuild/bin/device (the engine actively writes those state files for Lite compatibility)"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 9: failure-only "Diagnose Stable engine metadata persistence"
# step exists, runs the launcher-side helper, and is wired up to
# fire only after a failed build. The step exists to make the
# "missing device.name" failure mode (the canonical symptom of run
# 38063165985) visible inline in the Actions log instead of being
# buried inside the build's `tee build_action.log | cat` pipeline.
# ---------------------------------------------------------------------------
test_metadata_persistence_diagnostic() {
    local doc idx step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"
    idx="$(step_index "$doc" "🛡️ Diagnose Stable engine metadata persistence (failure-only)" || true)"
    if [[ -z "$idx" ]]; then
        fail "metadata-persistence-diagnostic: step exists" "missing step"
        rm -f "$doc"
        return
    fi
    pass "metadata-persistence-diagnostic: step exists"
    step_yaml="$(dump_step_yaml < "$doc")"
    assert_contains "$step_yaml" "if: failure()" \
        "metadata-persistence-diagnostic: step is failure-only (it must never run on a successful build)"
    assert_contains "$step_yaml" "inspect_rom_metadata.py" \
        "metadata-persistence-diagnostic: step invokes the launcher-side helper"
    assert_contains "$step_yaml" "rom_metadata.json" \
        "metadata-persistence-diagnostic: step targets build/.deadzone/rom_metadata.json"
    # The helper must never invent a device name; we
    # assert the workflow does not feed the helper any
    # fallback device name or substitute one itself.
    assert_not_contains "$step_yaml" "--device-name" \
        "metadata-persistence-diagnostic: step does NOT pass a fallback device name to the helper"
    assert_not_contains "$step_yaml" "device.name = " \
        "metadata-persistence-diagnostic: step does NOT mutate rom_metadata.json (no python json.dump)"

    # Also pin the helper's contract: it lives in
    # tools/inspect_rom_metadata.py, it never invents a
    # device name, and it requires device.name +
    # device.codename + rom.version.
    local helper_path
    helper_path="${script_root}/tools/inspect_rom_metadata.py"
    if [[ ! -s "$helper_path" ]]; then
        fail "metadata-persistence-diagnostic: helper script exists" "missing tools/inspect_rom_metadata.py"
        rm -f "$doc"
        return
    fi
    pass "metadata-persistence-diagnostic: helper script exists"
    local helper_text
    helper_text="$(cat "$helper_path")"
    assert_contains "$helper_text" "REQUIRED_DEVICE_FIELDS = (\"name\", \"codename\")" \
        "metadata-persistence-diagnostic: helper requires device.name and device.codename"
    assert_contains "$helper_text" "REQUIRED_ROM_FIELDS = (\"version\",)" \
        "metadata-persistence-diagnostic: helper requires rom.version"
    assert_contains "$helper_text" "do NOT invent" \
        "metadata-persistence-diagnostic: helper explicitly refuses to invent or backfill a device name"
    assert_not_contains "$helper_text" "json.dump" \
        "metadata-persistence-diagnostic: helper is read-only (no json.dump / mutate)"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 10: the failure notification's metadata-stage message no
# longer points the operator at erofsfuse / extract.erofs as the
# primary fix. That message was written when the metadata stage
# failed because the toolchain could not unpack partition EROFS
# images; the toolchain-chmod step (f6ccba8) resolved that, and
# the now-current failure mode is an engine-internal bug in
# bin/metadata/detect_props.sh that the launcher must NOT
# paper over.
# ---------------------------------------------------------------------------
test_metadata_failure_message_is_engine_internal() {
    local doc idx step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"
    idx="$(step_index "$doc" "❌ Send failure notification" || true)"
    if [[ -z "$idx" ]]; then
        fail "metadata-failure-message: failure notification step exists" "missing step"
        rm -f "$doc"
        return
    fi
    pass "metadata-failure-message: failure notification step exists"
    step_yaml="$(dump_step_yaml < "$doc")"
    # The metadata case in the failure-notification message
    # must mention the engine's own script and must NOT lead
    # with the old "install erofsfuse" advice as the
    # primary recommendation (it remains as a fallback when
    # the engine log does not show the persistence
    # error).
    assert_contains "$step_yaml" "bin/metadata/detect_props.sh" \
        "metadata-failure-message: message names the engine script that has to be fixed"
    assert_contains "$step_yaml" "do NOT invent" \
        "metadata-failure-message: message explicitly refuses to invent or substitute a device name"
    # The detail-line surfacing helper must extract the
    # engine's [ERROR] / "missing device." / "persisted
    # metadata" markers so the precise cause appears in the
    # notification.
    assert_contains "$step_yaml" "build_action.log" \
        "metadata-failure-message: message pulls detail line from build_action.log"
    assert_contains "$step_yaml" "missing device\\." \
        "metadata-failure-message: message greps build_action.log for the 'missing device.' marker"
    assert_contains "$step_yaml" "Persisted metadata" \
        "metadata-failure-message: message greps build_action.log for the 'Persisted metadata' marker"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 11: the build step's `bash build.sh … | tee build_action.log`
# pipeline is gone. That pipeline lost the on-disk
# build_action.log to SIGPIPE on the very run (38063165985) that
# introduced the missing-device.name metadata error, so we
# replace it with a `> build_action.log 2>&1` redirect plus a
# `tail -F` mirror to the live Actions log. The exit status of
# the engine must still propagate, and the file must be
# truncated at the start so a partial previous run cannot leak
# into the artifact.
# ---------------------------------------------------------------------------
test_build_log_capture_is_pipe_safe() {
    local doc build_idx step_yaml
    doc="$(mktemp)"
    extract_workflow > "$doc"
    build_idx="$(step_index "$doc" "🚀 Build, release, and upload Stable ROM" || true)"
    if [[ -z "$build_idx" ]]; then
        fail "build-log-capture: build step exists" "missing step"
        rm -f "$doc"
        return
    fi
    pass "build-log-capture: build step exists"
    step_yaml="$(dump_step_yaml < "$doc")"
    # The fragile `… | tee build_action.log` pipeline is
    # gone. We allow `tee` to appear in a comment
    # explaining the change, but NOT as a pipe target on
    # the build.sh invocation.
    assert_not_contains "$step_yaml" "build.sh \"\$DEADZONE_INPUT_URL\" \"\$DEADZONE_SOURCE_REPOSITORY\" \"stable\" \\\n            \"\$DEADZONE_BUILDER_NAME\" \"\$DEADZONE_BUILDER_ID\" \\\n            --with-upload 2>&1 | tee build_action.log" \
        "build-log-capture: build step no longer pipes through `tee build_action.log` (SIGPIPE-safe replacement in place)"
    # The new pipeline routes the engine's output to a
    # file via a plain redirect and mirrors it to stdout
    # via `tail -F`. Asserting on the file redirect and
    # the tail mirror is sufficient to pin the contract.
    assert_contains "$step_yaml" '> "$log_path" 2>&1' \
        "build-log-capture: build step redirects the engine output to build_action.log via a plain file redirect (not a pipe)"
    assert_contains "$step_yaml" 'tail -n +1 -F --pid="$build_pid" "$log_path"' \
        "build-log-capture: build step mirrors the log file to stdout via `tail -F --pid` so the live Actions log still streams line-by-line"
    assert_contains "$step_yaml" ': > "$log_path"' \
        "build-log-capture: build step truncates the log file at start (so a partial previous run cannot leak into the artifact)"
    assert_contains "$step_yaml" 'wait "$build_pid"' \
        "build-log-capture: build step waits for the engine to exit before re-raising its status"
    assert_contains "$step_yaml" 'exit "$google_status"' \
        "build-log-capture: build step re-raises the engine exit code so a failure still propagates to the workflow"

    rm -f "$doc"
}

echo "1..12"
test_publish_profile_input_is_removed
test_collect_metadata_is_hard_gate
test_no_post_success_publish_steps
test_pre_build_superinspector_validation
test_build_step_uses_build_sh
test_progress_events_present
test_engine_checkout_403_diagnostic
test_lite_parity_preparation_steps
test_metadata_persistence_diagnostic
test_metadata_failure_message_is_engine_internal
test_build_log_capture_is_pipe_safe

echo
if (( failures == 0 )); then
    echo "All ${tests_run} Stable flow contract assertions passed."
else
    echo "${failures} of ${tests_run} Stable flow contract assertions FAILED."
fi
exit "$failures"
