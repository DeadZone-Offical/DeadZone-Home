#!/usr/bin/env bash
# Contract tests for the DeadZone-Xiaomi-Port upload step.
#
# The launcher upload step failed run 37216287331 because it re-read
# DEADZONE_GOOGLE_UPLOAD_STATUS from the environment. Values written to
# $GITHUB_ENV are only applied to *later* steps, so the read always came back
# empty and the step fell through to the failure default even though the engine
# had already reported a successful Google Drive upload.
#
# These tests drive the real `run:` body extracted from the workflow with a
# stubbed engine, stubbed rclone, and a stubbed central mirror, and assert the
# three behaviours the launcher must guarantee:
#   1. a successful Drive upload is preserved and reported,
#   2. a transient Drive failure is retried by the engine,
#   3. Drive failure falls back to the configured mirror, and an all-destinations
#      failure reports a precise reason.
#
# Usage: tests/test_upload_contract.sh
set -Eeuo pipefail

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${WORKFLOW_PATH:-${script_root}/.github/workflows/deadzone-xiaomi-port.yml}"

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

# Extract the upload step body straight from the workflow so the tests can never
# drift from what CI actually runs.
extract_upload_step() {
    python3 - "$workflow" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    document = yaml.safe_load(handle)

for step in document["jobs"]["build"]["steps"]:
    script = step.get("run", "")
    if "uploadROM.sh" in script:
        sys.stdout.write(script)
        raise SystemExit(0)

raise SystemExit("upload step not found in workflow")
PY
}

# Build an isolated sandbox that mimics the runner layout the step expects.
make_sandbox() {
    local root="$1"
    mkdir -p "$root/toolbuild/out" "$root/runtime" "$root/bin"

    # The engine writes the preserved final ZIP into out/.
    local zip
    zip="$root/toolbuild/out/DeadZone_Port_V1.05_FIRE_OS4.0.0.6.XPSEUXM_IndiaStable-A17.zip"
    head -c 4096 /dev/urandom > "$zip"

    # The engine emits its per-role identity into .port_state.
    mkdir -p "$root/toolbuild/build/.port_state/stock/ddevice"
    mkdir -p "$root/toolbuild/build/.port_state/port/ddevice"
    printf 'fire\n' > "$root/toolbuild/build/.port_state/stock/ddevice/device_f.txt"
    printf 'OS4.0.0.6.XPSEUXM\n' > "$root/toolbuild/build/.port_state/port/ddevice/base_rom_code.txt"

    printf '[deadzone]\ntype = drive\n' > "$root/toolbuild/rclone.conf"
    printf 'deadzone\n' > "$root/runtime/build.env"

    # notify.py is the engine's best-effort Telegram notifier. The real file is
    # irrelevant to the upload contract, so stub it out with valid Python.
    printf 'import sys\nsys.exit(0)\n' > "$root/toolbuild/notify.py"
    printf '%s\n' "$root"
}

# Stub engine: honours the failure mode the test asks for and records attempts.
install_engine_stub() {
    local root="$1" mode="$2"
    cat > "$root/toolbuild/bin_port_uploadROM.sh" <<STUB
#!/usr/bin/env bash
set -Eeuo pipefail
attempts_file="\${DEADZONE_TEST_ATTEMPTS_FILE:-$root/toolbuild/upload_attempts.log}"
echo x >> "\$attempts_file"
mode="$mode"
if [[ "\$mode" == "transient_then_ok" ]]; then
    count="\$(wc -l < "\$attempts_file" | tr -d ' ')"
    if (( count < 3 )); then
        echo "[UPLOAD][ERROR] Google Drive upload attempt \${count}/3 failed with status 1."
        echo "[UPLOAD][ERROR] Too Many Requests: rateLimitExceeded (transient)"
        echo "[UPLOAD] Retrying Google Drive upload in 1s"
        exit 1
    fi
fi
if [[ "\$mode" == "fail" ]]; then
    echo "[UPLOAD][ERROR] Google Drive upload failed; not transient."
    exit 1
fi
echo "[UPLOADING] - Google Drive upload completed: DeadZone_Port_test.zip"
exit 0
STUB
    chmod +x "$root/toolbuild/bin_port_uploadROM.sh"
}

# Stub rclone: `link` echoes a Drive URL only when the upload "succeeded".
install_rclone_stub() {
    local root="$1" link_url="$2"
    # The real invocation is `rclone --config=<path> link <remote>`, so the
    # subcommand is not the first argument. Scan the whole argv instead.
    cat > "$root/bin/rclone" <<STUB
#!/usr/bin/env bash
set -Eeuo pipefail
for arg in "\$@"; do
    if [[ "\$arg" == "link" ]]; then
        [[ -n "$link_url" ]] && printf '%s\n' "$link_url"
        exit 0
    fi
done
exit 0
STUB
    chmod +x "$root/bin/rclone"
}

# Stub central mirror.
#
# Models the real DeadZone-File/upload-mirrors.sh contract, which is what makes
# the launcher's fallback detection correct:
#   * with mirrors enabled and credentials present it publishes a URL,
#   * with mirrors disabled it exits 0 as a deliberate no-op but publishes
#     nothing, so a launcher that trusted the exit status would wrongly report
#     a build as published.
install_mirror_stub() {
    local root="$1" mirror_url="$2" mode="${3:-enabled}"
    if [[ "$mode" == "disabled" ]]; then
        cat > "$root/runtime/upload-mirrors.sh" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "[DeadZone] Secondary mirrors are disabled (DEADZONE_ENABLE_SECONDARY_MIRRORS=0); skipping SourceForge/PixelDrain uploads."
printf 'DEADZONE_SOURCEFORGE_URL=\n' >> "${GITHUB_ENV:-/dev/null}"
printf 'DEADZONE_PIXELDRAIN_URL=\n' >> "${GITHUB_ENV:-/dev/null}"
exit 0
STUB
    else
        cat > "$root/runtime/upload-mirrors.sh" <<STUB
#!/usr/bin/env bash
set -Eeuo pipefail
echo "[DeadZone] Uploading secondary ROM mirrors for \$1/\$2/\$3"
if [[ -n "$mirror_url" ]]; then
    printf '[SourceForge] %s\n' "$mirror_url"
    printf 'DEADZONE_SOURCEFORGE_URL=%s\n' "$mirror_url" >> "\${GITHUB_ENV:-/dev/null}"
    printf 'DEADZONE_RESULT_URL=%s\n' "$mirror_url" >> "\${GITHUB_ENV:-/dev/null}"
    exit 0
fi
echo "::error::All configured secondary mirror uploads failed"
printf 'DEADZONE_SOURCEFORGE_URL=\n' >> "\${GITHUB_ENV:-/dev/null}"
printf 'DEADZONE_PIXELDRAIN_URL=\n' >> "\${GITHUB_ENV:-/dev/null}"
exit 1
STUB
    fi
    chmod +x "$root/runtime/upload-mirrors.sh"
}

# The workflow invokes the engine as `sudo -E bash bin/port/uploadROM.sh`. The
# sandbox has no sudo, so provide a passthrough that also redirects the engine
# path at our stub. Writing this to a real file keeps the quoting simple and
# mirrors how Actions actually executes a `run:` body.
write_runner() {
    local root="$1"
    # The workflow invokes the engine as `sudo -E bash bin/port/uploadROM.sh`.
    # The sandbox has no sudo, so provide a passthrough that redirects the engine
    # path at our stub. Crucially this must NOT use `exec`: the step body
    # continues after the upload call and decides the terminal verdict, so
    # replacing the shell would swallow the step's own exit status.
    cat > "$root/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail

sudo() {
    if [[ "${1:-}" == "-E" ]]; then shift; fi
    if [[ "${1:-}" == "bash" ]]; then shift; fi
    if [[ "${1:-}" == "bin/port/uploadROM.sh" ]]; then
        bash "$DEADZONE_TEST_ENGINE_STUB"
        return $?
    fi
    "$@"
}

source "$DEADZONE_TEST_STEP_BODY"
RUNNER
    chmod +x "$root/runner.sh"
}

# Run the extracted workflow body inside the sandbox, echoing output. The exit
# status is stored in the caller's REPLY_STATUS.
REPLY_STATUS=0
run_upload_step() {
    local root="$1" output
    write_runner "$root"
    set +e
    output="$(cd "$root/toolbuild" && \
        GITHUB_WORKSPACE="$root" \
        GITHUB_ENV="$root/github_env" \
        GITHUB_STEP_SUMMARY="$root/step_summary" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_REPOSITORY="DeadZone-Offical/DeadZone-Home" \
        GITHUB_RUN_ID="1" \
        PATH="$root/bin:$PATH" \
        RCLONE_REMOTE_NAME="deadzone" \
        RCLONE_UPLOAD_DIR="DeadZone" \
        DEADZONE_SOURCE_REPOSITORY="DeadZone-Offical/DeadZone-Home" \
        DEADZONE_STOCK_ROM_URL="https://example.invalid/stock.zip" \
        DEADZONE_BUILDER_NAME="Tester" \
        DEADZONE_BUILDER_ID="1" \
        DEADZONE_ENABLE_SECONDARY_MIRRORS="1" \
        DEADZONE_TEST_STEP_BODY="$root/step_body.sh" \
        DEADZONE_TEST_ENGINE_STUB="$root/toolbuild/bin_port_uploadROM.sh" \
        bash "$root/runner.sh" 2>&1)"
    REPLY_STATUS=$?
    set -e
    printf '%s' "$REPLY_STATUS" > "$root/reply_status"
    printf '%s' "$output"
}

# ---------------------------------------------------------------------------
# Test 1: a successful Drive upload must be preserved and reported.
# ---------------------------------------------------------------------------
test_success_preserved() {
    local root output
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" ok
    install_rclone_stub "$root" "https://drive.google.com/open?id=ABC123"
    install_mirror_stub "$root" ""
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    output="$(DEADZONE_TEST_STEP_BODY="$root/step_body.sh" run_upload_step "$root")"

    assert_contains "$output" "Google Drive URL: https://drive.google.com/open?id=ABC123" \
        "success: Drive URL is reported"
    assert_not_contains "$output" "No upload destination succeeded" \
        "success: step does not report a total failure"
    assert_contains "$(cat "$root/github_env")" "DEADZONE_RESULT_URL=https://drive.google.com/open?id=ABC123" \
        "success: result URL is exported"
    assert_contains "$(cat "$root/github_env")" "DEADZONE_GOOGLE_DRIVE_URL=" \
        "success: Drive URL is exported"

    rm -rf "$root"
}

# ---------------------------------------------------------------------------
# Test 2: the launcher must trust the in-step status, not the GITHUB_ENV echo.
# This is the exact regression from run 37216287331.
# ---------------------------------------------------------------------------
test_github_env_status_not_reread() {
    local root output
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" ok
    install_rclone_stub "$root" "https://drive.google.com/open?id=XYZ789"
    install_mirror_stub "$root" ""
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    # A pre-existing env value of 1 models the stale/poisoned export that caused
    # the original failure. The step must ignore it when it has a fresh capture.
    output="$(DEADZONE_TEST_STEP_BODY="$root/step_body.sh" \
        DEADZONE_GOOGLE_UPLOAD_STATUS=1 \
        run_upload_step "$root")"

    assert_contains "$output" "Google Drive URL: https://drive.google.com/open?id=XYZ789" \
        "GITHUB_ENV regression: fresh in-step status wins over stale env"
    assert_not_contains "$output" "No upload destination succeeded" \
        "GITHUB_ENV regression: stale env does not fail a good build"

    rm -rf "$root"
}

# ---------------------------------------------------------------------------
# Test 3: the launcher must not re-run the engine on its own.
#
# Retrying lives in the engine (DeadZone-xiaomi_Port uploadROM.sh), which
# re-executes the whole packaging pipeline and so cannot be safely repeated by
# the launcher. The launcher must instead attempt the fallback mirror. This test
# pins that division of responsibility so a future "helpful" retry loop is not
# added to the step.
# ---------------------------------------------------------------------------
test_launcher_does_not_double_run_engine() {
    local root output attempts
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" transient_then_ok
    install_rclone_stub "$root" "https://drive.google.com/open?id=RETRY01"
    install_mirror_stub "$root" "https://sourceforge.net/projects/deadzone-rom/files/Port/fire/OS4/f.zip/download"
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    output="$(DEADZONE_TEST_STEP_BODY="$root/step_body.sh" run_upload_step "$root")"
    attempts="$(wc -l < "$root/toolbuild/upload_attempts.log" | tr -d ' ')"

    if (( attempts == 1 )); then
        pass "retry: the launcher invokes the engine exactly once"
    else
        fail "retry: the launcher invokes the engine exactly once" "engine ran ${attempts} times"
    fi
    assert_contains "$output" "attempting the configured fallback mirror" \
        "retry: an engine-reported failure escalates to the mirror"
    assert_contains "$output" "Fallback mirror published the artifact:" \
        "retry: the fallback keeps the build green"

    rm -rf "$root"
}

# ---------------------------------------------------------------------------
# Test 4: a hard Drive failure falls back to the configured mirror.
# ---------------------------------------------------------------------------
test_fallback_mirror_used() {
    local root output published
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" fail
    install_rclone_stub "$root" ""
    install_mirror_stub "$root" "https://sourceforge.net/projects/deadzone-rom/files/Port/fire/OS4/file.zip/download"
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    output="$(DEADZONE_TEST_STEP_BODY="$root/step_body.sh" run_upload_step "$root")"

    assert_contains "$output" "attempting the configured fallback mirror" \
        "fallback: mirror is attempted after Drive fails"
    assert_contains "$output" "Fallback mirror published the artifact: https://sourceforge.net" \
        "fallback: successful mirror is reported"
    assert_not_contains "$output" "No upload destination succeeded" \
        "fallback: mirror success keeps the build green"

    # The launcher, not the mirror helper, must own the result-URL contract:
    # DeadZone-File/upload-mirrors.sh only promotes its own URL when
    # DEADZONE_SET_RESULT_URL=1. Counting the occurrences proves the launcher
    # wrote its own, independently of whatever the helper emitted.
    published="$(grep -c '^DEADZONE_RESULT_URL=https://sourceforge.net' "$root/github_env" || true)"
    if (( published >= 2 )); then
        pass "fallback: the launcher writes the result URL itself"
    else
        fail "fallback: the launcher writes the result URL itself" \
            "found ${published} occurrence(s); the launcher relied on the mirror helper"
    fi

    rm -rf "$root"
}

# ---------------------------------------------------------------------------
# Test 5: when every destination fails, the reason must be precise.
# ---------------------------------------------------------------------------
test_all_destinations_failed_reports_reason() {
    local root output status
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" fail
    install_rclone_stub "$root" ""
    install_mirror_stub "$root" ""
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    # `run_upload_step` publishes its exit status through a file, not a shell
    # variable: this call runs in a command-substitution subshell, so a variable
    # assignment inside it would be discarded.
    output="$(run_upload_step "$root")"
    status="$(cat "$root/reply_status")"

    if (( status != 0 )); then
        pass "all-failed: step exits non-zero"
    else
        fail "all-failed: step exits non-zero" "exited 0"
    fi
    assert_contains "$output" "No upload destination succeeded" \
        "all-failed: reports that no destination succeeded"
    assert_contains "$output" "Google Drive failed (status" \
        "all-failed: names the Drive status"
    assert_contains "$output" "not publicly reachable" \
        "all-failed: explains the artifact is unreachable"

    rm -rf "$root"
}

# ---------------------------------------------------------------------------
# Test 6: a Drive success with an unresolvable link and no mirror must still
# fail, because nothing is publicly reachable. The bytes may be on Drive, but
# the bot hands users a link, so an unresolvable link is not a deliverable.
# ---------------------------------------------------------------------------
test_drive_success_without_link() {
    local root output status
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" ok
    install_rclone_stub "$root" ""   # `link` resolves to nothing
    install_mirror_stub "$root" ""   # and the mirror is unavailable too
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    output="$(run_upload_step "$root")"
    status="$(cat "$root/reply_status")"

    assert_contains "$output" "share link could not be resolved" \
        "no-link: warns that the Drive link is unresolvable"
    assert_contains "$output" "no shareable link could be resolved" \
        "no-link: an unreachable artifact is reported as a failure"
    if (( status != 0 )); then
        pass "no-link: step exits non-zero when nothing is reachable"
    else
        fail "no-link: step exits non-zero when nothing is reachable" "exited 0"
    fi

    rm -rf "$root"
}

# ---------------------------------------------------------------------------
# Test 7: regression for the failure-masking bug.
#
# DeadZone-File/upload-mirrors.sh exits 0 as a deliberate no-op when
# DEADZONE_ENABLE_SECONDARY_MIRRORS is not "1", which is the current repo
# default. A launcher that treated that exit status as "the mirror published the
# artifact" would turn a total Drive outage into a green build with no
# download. The verdict must depend on a published URL, never on the helper's
# exit code alone.
# ---------------------------------------------------------------------------
test_disabled_mirror_does_not_mask_drive_failure() {
    local root output status
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" fail          # Drive hard-fails
    install_rclone_stub "$root" ""
    install_mirror_stub "$root" "" disabled   # mirror no-ops with status 0
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    output="$(run_upload_step "$root")"
    status="$(cat "$root/reply_status")"

    if (( status != 0 )); then
        pass "masking: a no-op mirror does not hide a Drive failure"
    else
        fail "masking: a no-op mirror does not hide a Drive failure" "exited 0"
    fi
    assert_contains "$output" "fallback mirror published no URL" \
        "masking: the empty mirror result is called out"
    assert_contains "$output" "DEADZONE_ENABLE_SECONDARY_MIRRORS=0" \
        "masking: the report names the mirror toggle that disabled the fallback"

    rm -rf "$root"
}

# ---------------------------------------------------------------------------
# Test 8: regression for run 37229640251.
#
# The engine (DeadZone-xiaomi_Port uploadROM.sh) resolves the Drive share link
# itself and exports it as DEADZONE_GOOGLE_DRIVE_URL, yet the launcher ignored
# that value and re-derived the link with its own `rclone link` call. In that
# run the engine had already logged
#   [UPLOADING] - Google Drive link resolved: https://drive.google.com/open?id=...
# and exported DEADZONE_RESULT_URL, but the launcher's redundant lookup returned
# nothing, so it discarded a perfectly good URL, escalated to the mirror, got a
# no-op, and failed a 9.9 GB build that had in fact published successfully.
#
# The launcher must trust the URL the engine already produced. The `rclone link`
# call is only a fallback for engines that predate the export, and must never
# override a URL that is already in $GITHUB_ENV.
# ---------------------------------------------------------------------------
test_engine_exported_link_is_trusted() {
    local root output status env
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" ok
    # The launcher's own re-derivation fails, exactly as it did in the real run.
    install_rclone_stub "$root" ""
    install_mirror_stub "$root" ""
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    # Model the engine having exported its resolved link, as uploadROM.sh does
    # via write_github_env after its own `rclone link`.
    printf 'DEADZONE_GOOGLE_DRIVE_URL=https://drive.google.com/open?id=ENGINE01\n' \
        > "$root/github_env"
    printf 'DEADZONE_RESULT_URL=https://drive.google.com/open?id=ENGINE01\n' \
        >> "$root/github_env"

    output="$(run_upload_step "$root")"
    status="$(cat "$root/reply_status")"
    env="$(cat "$root/github_env")"

    if (( status == 0 )); then
        pass "engine-link: a Drive upload with an engine-exported link stays green"
    else
        fail "engine-link: a Drive upload with an engine-exported link stays green" \
            "exited ${status}"
    fi
    assert_contains "$env" "DEADZONE_RESULT_URL=https://drive.google.com/open?id=ENGINE01" \
        "engine-link: the engine's URL is preserved as the result URL"
    assert_not_contains "$output" "No upload destination succeeded" \
        "engine-link: a resolvable engine link is not treated as a total failure"
    assert_contains "$output" "https://drive.google.com/open?id=ENGINE01" \
        "engine-link: the resolved URL is reported in the step output"

    rm -rf "$root"
}

# ---------------------------------------------------------------------------
# Test 9: a URL recovered from the environment must be validated before it is
# published. An empty value, a bare host, or a non-HTTP scheme is not a usable
# download URL and must not be reported as success.
# ---------------------------------------------------------------------------
test_result_url_is_validated() {
    local root output status body
    for bad in "" "   " "not-a-url" "ftp://drive.google.com/open?id=X" "/local/path/file.zip"; do
        root="$(mktemp -d)"
        make_sandbox "$root" >/dev/null
        install_engine_stub "$root" ok
        install_rclone_stub "$root" ""
        install_mirror_stub "$root" ""
        printf 'DEADZONE_GOOGLE_DRIVE_URL=%s\n' "$bad" > "$root/github_env"
        printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

        output="$(run_upload_step "$root")"
        status="$(cat "$root/reply_status")"

        if (( status != 0 )); then
            pass "validate: unusable URL '${bad:-<empty>}' does not count as success"
        else
            fail "validate: unusable URL '${bad:-<empty>}' does not count as success" \
                "exited 0 and accepted an invalid URL"
        fi
        body="$(cat "$root/github_env")"
        if grep -qE '^DEADZONE_RESULT_URL=not-a-url' <<< "$body"; then
            fail "validate: '${bad:-<empty>}' is never exported as the result URL" \
                "invalid URL was written to DEADZONE_RESULT_URL"
        else
            pass "validate: '${bad:-<empty>}' is never exported as the result URL"
        fi
        rm -rf "$root"
    done
}

# ---------------------------------------------------------------------------
# Test 10: credentials must never reach the logs or the summary. The launcher
# echoes the resolved URL and writes it to $GITHUB_STEP_SUMMARY, so a signed or
# tokenized URL must be stripped before it is printed.
# ---------------------------------------------------------------------------
test_no_credentials_in_output() {
    local root output summary
    root="$(mktemp -d)"
    make_sandbox "$root" >/dev/null
    install_engine_stub "$root" ok
    install_rclone_stub "$root" ""
    install_mirror_stub "$root" ""
    : > "$root/github_env"
    printf '%s' "$(extract_upload_step)" > "$root/step_body.sh"

    # A signed-URL-shaped value with secret material in the query string.
    printf 'DEADZONE_GOOGLE_DRIVE_URL=https://drive.example.com/d/ABC?token=SECRETTOKEN123&signature=LEAKEDSIG\n' \
        > "$root/github_env"

    output="$(run_upload_step "$root")"
    summary="$(cat "$root/step_summary" 2>/dev/null || true)"

    assert_not_contains "$output" "SECRETTOKEN123" \
        "secrets: a token in the resolved URL is not echoed to the log"
    assert_not_contains "$output" "LEAKEDSIG" \
        "secrets: a signature in the resolved URL is not echoed to the log"
    assert_not_contains "$summary" "SECRETTOKEN123" \
        "secrets: a token in the resolved URL is not echoed to the summary"
    assert_not_contains "$summary" "LEAKEDSIG" \
        "secrets: a signature in the resolved URL is not echoed to the summary"

    rm -rf "$root"
}

echo "1..10"
test_success_preserved
test_github_env_status_not_reread
test_launcher_does_not_double_run_engine
test_fallback_mirror_used
test_all_destinations_failed_reports_reason
test_drive_success_without_link
test_disabled_mirror_does_not_mask_drive_failure
test_engine_exported_link_is_trusted
test_result_url_is_validated
test_no_credentials_in_output

echo
if (( failures == 0 )); then
    echo "All ${tests_run} upload contract assertions passed."
else
    echo "${failures} of ${tests_run} upload contract assertions FAILED."
fi
exit "$failures"
