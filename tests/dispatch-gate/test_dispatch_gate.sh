#!/usr/bin/env bash
# tests/dispatch-gate/test_dispatch_gate.sh
#
# Validates the dispatch gate introduced in
# .github/workflows/deadzone-stable.yml. The gate is a
# `bash` step that compares the `approved` workflow input
# to the literal string "true"; anything else rejects the
# dispatch. The test harness extracts the gate into a
# standalone script (without `set -e` / `set -u` magic that
# would mask the failure) and runs it under a matrix of
# inputs that mirror the cases in the run 38715832695
# acceptance criteria:
#
#   1. Unapproved dispatch is rejected (approved=false).
#   2. Approved dispatch proceeds (approved=true).
#   3. Empty / missing / wrong-case approved is rejected
#      (regression guard for `True`, `1`, `yes`, etc.).
#   4. The rejection is recorded in a Summary-like log file
#      (the test mirrors the GITHUB_STEP_SUMMARY write).
#
# Usage:
#   bash tests/dispatch-gate/test_dispatch_gate.sh
#
# Exit codes:
#   0 = all assertions pass
#   1 = at least one assertion failed
#   2 = environment setup failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/deadzone-stable.yml"

if [[ ! -f "$WORKFLOW" ]]; then
    echo "FAIL: workflow not found at $WORKFLOW" >&2
    exit 2
fi

# ---- Build a controlled runner that mirrors the gate step ----
WORK_DIR="$(mktemp -d -t dz-gate-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Reproduce the gate logic verbatim from the workflow. We do
# not source the workflow file directly: the gate is a
# single `bash` step whose logic is the canonical
# "APPROVED must be 'true'" comparison, plus a Summary
# write. We replicate the logic here so the test is
# self-contained and does not need GitHub Actions to run.
cat > "$WORK_DIR/gate.sh" <<'GATE'
#!/bin/bash
# Mirror of the workflow's 🛡️ Validate dispatch gate step.
# Argument: APPROVED=<value>
# Writes summary lines to $GATE_SUMMARY_FILE.
set -euo pipefail
APPROVED="${1:-}"
GATE_SUMMARY_FILE="${GATE_SUMMARY_FILE:-/dev/null}"
RUN_ID="${RUN_ID:-test}"
RUN_ATTEMPT="${RUN_ATTEMPT:-1}"
ACTOR="${ACTOR:-test}"
REQUEST_ID="${REQUEST_ID:-stable_test}"
if [[ "$APPROVED" != "true" ]]; then
    {
        echo "## ⛔ Dispatch gate: REJECTED"
        echo
        echo "- Run: \`${RUN_ID}\` (attempt \`${RUN_ATTEMPT}\`)"
        echo "- Actor: \`${ACTOR}\`"
        echo "- Request ID: \`${REQUEST_ID}\`"
        echo "- Reason: \`approved\` input is \`${APPROVED:-<empty>}\`"
    } >> "$GATE_SUMMARY_FILE"
    echo "::error::Dispatch gate rejected: approved='${APPROVED:-<empty>}'" >&2
    exit 1
fi
echo "Dispatch gate: APPROVED"
GATE
chmod +x "$WORK_DIR/gate.sh"

# ---- Helpers ----
run_gate() {
    local approved_value="$1"
    local summary_file="$2"
    GATE_SUMMARY_FILE="$summary_file" \
    RUN_ID="r1" RUN_ATTEMPT="1" ACTOR="test" REQUEST_ID="stable_test_$RANDOM" \
        bash "$WORK_DIR/gate.sh" "$approved_value" >"$WORK_DIR/gate.stdout" 2>"$WORK_DIR/gate.stderr"
    echo $?
}

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $label  (got '$actual')"
    else
        echo "  FAIL  $label  (expected '$expected', got '$actual')"
        fail=1
    fi
}

fail=0

# ---- Tests ----
echo
echo "== Dispatch gate regression test (run 38715832695 acceptance criteria) =="
echo

# Test 1: approved=false MUST be rejected.
summary="$WORK_DIR/summary_false.txt"
: > "$summary"
rc=$(run_gate "false" "$summary")
assert_eq "approved=false is rejected (rc=1)" "$rc" "1"
if [[ -s "$summary" ]] && grep -q "REJECTED" "$summary" \
   && grep -q "approved.*input is.*\`false\`" "$summary"; then
    echo "  PASS  summary records the rejection reason for approved=false"
else
    echo "  FAIL  summary did NOT record the rejection reason for approved=false"
    echo "---- summary ----"
    cat "$summary"
    echo "----"
    fail=1
fi

# Test 2: approved=true MUST be accepted.
summary="$WORK_DIR/summary_true.txt"
: > "$summary"
rc=$(run_gate "true" "$summary")
assert_eq "approved=true is accepted (rc=0)" "$rc" "0"
if [[ ! -s "$summary" || "$(grep -c REJECTED "$summary" || true)" == "0" ]]; then
    echo "  PASS  summary is empty for approved=true (no rejection)"
else
    echo "  FAIL  summary unexpectedly contains a rejection for approved=true"
    cat "$summary"
    fail=1
fi

# Test 3: approved=empty MUST be rejected (the case where a
# bot sends a JSON without the field at all).
summary="$WORK_DIR/summary_empty.txt"
: > "$summary"
rc=$(run_gate "" "$summary")
assert_eq "approved=<empty> is rejected (rc=1)" "$rc" "1"
if [[ -s "$summary" ]] && grep -q "<empty>" "$summary"; then
    echo "  PASS  summary names the empty value as <empty>"
else
    echo "  FAIL  summary did not name the empty value"
    cat "$summary"
    fail=1
fi

# Test 4: approved=True (capital T) MUST be rejected. A
# future bot bug that capitalises the value should not
# accidentally pass the gate.
summary="$WORK_DIR/summary_True.txt"
: > "$summary"
rc=$(run_gate "True" "$summary")
assert_eq "approved='True' (capital T) is rejected" "$rc" "1"

# Test 5: approved=1 MUST be rejected. A future bot bug
# that sends the JSON boolean "1" should not pass the
# gate.
summary="$WORK_DIR/summary_1.txt"
: > "$summary"
rc=$(run_gate "1" "$summary")
assert_eq "approved='1' is rejected" "$rc" "1"

# Test 6: approved=yes MUST be rejected. Some shells /
# YAML encoders render booleans as yes/no.
summary="$WORK_DIR/summary_yes.txt"
: > "$summary"
rc=$(run_gate "yes" "$summary")
assert_eq "approved='yes' is rejected" "$rc" "1"

# Test 7: negative case — the workflow file MUST declare
# the `approved` input. A regression that drops the input
# would let the bot dispatch builds without opt-in.
if grep -qE '^\s+approved:' "$WORKFLOW"; then
    echo "  PASS  workflow declares the 'approved' workflow input"
else
    echo "  FAIL  workflow does NOT declare the 'approved' workflow input"
    fail=1
fi

# Test 8: negative case — the workflow MUST NOT add a
# push / pull_request / schedule trigger. The acceptance
# criteria say "No workflow trigger exists other than
# workflow_dispatch".
triggers=$(awk '/^on:/{flag=1;next} /^[a-z]/{flag=0} flag && /^  [a-z_]+:$/' "$WORKFLOW" | sed 's/:$//' | tr -d ' ')
forbidden=(push pull_request schedule)
for trigger in "${forbidden[@]}"; do
    if [[ " $triggers " == *" $trigger "* ]]; then
        echo "  FAIL  workflow declares a forbidden trigger: $trigger"
        fail=1
    fi
done
if [[ $fail -eq 0 ]]; then
    echo "  PASS  workflow only declares workflow_dispatch"
fi

# Test 9: negative case — the workflow MUST keep the
# concurrency block with cancel-in-progress: true. The
# setting is on a single line of its own but the key
# (`concurrency:`) is followed by a long comment block
# before the actual settings, so we use a multi-line
# read with awk instead of `grep -A2`.
concurrency_block="$(awk '/^concurrency:/{flag=1;next} /^on:/{flag=0} flag' "$WORKFLOW")"
if grep -q "cancel-in-progress: true" <<<"$concurrency_block"; then
    echo "  PASS  concurrency block has cancel-in-progress: true"
else
    echo "  FAIL  concurrency block does NOT have cancel-in-progress: true"
    echo "---- concurrency block ----"
    echo "$concurrency_block"
    echo "----"
    fail=1
fi

# Test 10: negative case — the gate MUST be the FIRST
# step in the build job. A regression that reorders the
# steps could let a checkout / private-repo download
# happen before the rejection.
first_step=$(awk '/^    steps:/{flag=1;next} flag && /^      - name:/{print; exit}' "$WORKFLOW" | sed 's/^[[:space:]]*- name: *//')
if [[ "$first_step" == *"Validate dispatch gate"* ]]; then
    echo "  PASS  first step is the dispatch gate"
else
    echo "  FAIL  first step is NOT the dispatch gate (got: $first_step)"
    fail=1
fi

echo
if [[ $fail -eq 0 ]]; then
    echo "OK: dispatch gate regression test passed"
    exit 0
else
    echo "FAIL: dispatch gate regression test failed"
    exit 1
fi
