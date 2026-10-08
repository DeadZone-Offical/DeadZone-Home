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
sys.stdout.write(yaml.safe_dump(out, sort_keys=False))
PY
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
    step_yaml="$(python3 -c "import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin.read()), sort_keys=False))" < "$doc")"
    assert_not_contains "$step_yaml" "publish_profile" \
        "input: publish_profile is NOT a workflow_dispatch input (device configuration is owned by SuperInspector)"

    rm -f "$doc"
}

# ---------------------------------------------------------------------------
# Test 2: "🗂️ Collect Stable artifact metadata" is continue-on-error.
# ---------------------------------------------------------------------------
test_collect_metadata_is_continue_on_error() {
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
    step_yaml="$(python3 -c "import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin.read())['steps'][$idx], sort_keys=False))" < "$doc")"
    assert_contains "$step_yaml" "continue-on-error: true" \
        "collect-metadata: step has continue-on-error: true (no double-failure on missing ZIP)"

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
    step_yaml="$(python3 -c "import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin.read()), sort_keys=False))" < "$doc")"
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
    step_yaml="$(python3 -c "import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin.read())['steps'][$idx], sort_keys=False))" < "$doc")"
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
    build_idx="$(step_index "$doc" "🛠️ Build, release, and upload Stable ROM" || true)"
    if [[ -z "$build_idx" ]]; then
        fail "build: step exists" "missing step"
        rm -f "$doc"
        return
    fi
    pass "build: step exists"
    step_yaml="$(python3 -c "import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin.read())['steps'][$build_idx], sort_keys=False))" < "$doc")"
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
    step_yaml="$(python3 -c "import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin.read()), sort_keys=False))" < "$doc")"
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
    step_yaml="$(python3 -c "import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin.read())['steps'][$idx], sort_keys=False))" < "$doc")"
    assert_contains "$step_yaml" "DEADZONE_PRIVATE_READ_TOKEN" \
        "403-diagnostic: step names the secret that must be re-provisioned"
    assert_contains "$step_yaml" "Contents: Read-only" \
        "403-diagnostic: step names the required Contents scope"
    assert_contains "$step_yaml" "DeadZone-Offical/DeadZone-Xiaomi-Stable" \
        "403-diagnostic: step names the engine repository that needs the scope"

    rm -f "$doc"
}

echo "1..7"
test_publish_profile_input_is_removed
test_collect_metadata_is_continue_on_error
test_no_post_success_publish_steps
test_pre_build_superinspector_validation
test_build_step_uses_build_sh
test_progress_events_present
test_engine_checkout_403_diagnostic

echo
if (( failures == 0 )); then
    echo "All ${tests_run} Stable flow contract assertions passed."
else
    echo "${failures} of ${tests_run} Stable flow contract assertions FAILED."
fi
exit "$failures"
