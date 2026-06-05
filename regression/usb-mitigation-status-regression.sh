#!/usr/bin/env bash
# Regression for USB mitigation reset-counter and --usb-mitigation-status mode.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VFIO_SCRIPT="${PROJECT_ROOT}/vfio.sh"

if [[ ! -f "$VFIO_SCRIPT" ]]; then
  printf 'FAIL: missing vfio.sh at %s\n' "$VFIO_SCRIPT" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$VFIO_SCRIPT"

fail=0
FAILED_ASSERTIONS=()

record_failure() {
  local name="$1"
  FAILED_ASSERTIONS+=("$name")
  fail=1
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (expected="%s", got="%s")\n' "$name" "$expected" "$actual" >&2
    record_failure "$name"
  fi
}

assert_contains_text() {
  local name="$1" pattern="$2" haystack="$3"
  if grep -Fq -- "$pattern" <<<"$haystack"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (pattern not found: %s)\n' "$name" "$pattern" >&2
    record_failure "$name"
  fi
}

assert_not_contains_text() {
  local name="$1" pattern="$2" haystack="$3"
  if grep -Fq -- "$pattern" <<<"$haystack"; then
    printf 'FAIL: %s (unexpected pattern found: %s)\n' "$name" "$pattern" >&2
    record_failure "$name"
  else
    printf 'PASS: %s\n' "$name"
  fi
}

assert_file_exists() {
  local name="$1" file="$2"
  if [[ -f "$file" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (missing file: %s)\n' "$name" "$file" >&2
    record_failure "$name"
  fi
}

assert_file_missing() {
  local name="$1" file="$2"
  if [[ ! -f "$file" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (file unexpectedly present: %s)\n' "$name" "$file" >&2
    record_failure "$name"
  fi
}

# Override helpers that may read system state or require root.
need_cmd() { return 0; }
require_root() { return 0; }
require_systemd() { return 0; }
require_writable_root_or_die() { return 0; }
have_cmd() {
  case "$1" in
    journalctl) return 1 ;;  # force dmesg fallback path for determinism
    dmesg) return 1 ;;      # force "no kernel log data" path for determinism
  esac
  command -v "$1" >/dev/null 2>&1
}

# Ensure color is off for stable text assertions.
ENABLE_COLOR=0

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# --- Case 1: state file parsing and per-device counts ---
USB_BT_STATE_FILE="$tmp_dir/case1.state"
{
  printf 'timestamp=2026-06-05T12:00:00+00:00 mode=disable targets=1-2:0a1b:2c3d\n'
  printf 'timestamp=2026-06-05T12:05:00+00:00 mode=enable targets=1-2:0a1b:2c3d\n'
  printf 'timestamp=2026-06-05T12:10:00+00:00 mode=disable targets=1-2:0a1b:2c3d,3-4:5e6f:7a8b\n'
} >>"$USB_BT_STATE_FILE"

case1_out="$(usb_bt_mitigation_status 2>&1)"

assert_contains_text "case1 reports total recorded runs" "Total recorded runs: 3" "$case1_out"
assert_contains_text "case1 reports per-device count for 1-2" "1-2:0a1b:2c3d: 3 run(s)" "$case1_out"
assert_contains_text "case1 reports per-device count for 3-4" "3-4:5e6f:7a8b: 1 run(s)" "$case1_out"
assert_contains_text "case1 reports last run timestamp" "Last run: 2026-06-05T12:10:00+00:00" "$case1_out"
assert_contains_text "case1 reports journalctl not available" "journalctl not available; skipping kernel log scan." "$case1_out"
assert_not_contains_text "case1 no unexpected WARN/OK from log scan" "Unstable USB devices detected" "$case1_out"
assert_not_contains_text "case1 no unexpected OK from log scan" "No obvious USB instability markers" "$case1_out"

# --- Case 2: missing state file ---
USB_BT_STATE_FILE="$tmp_dir/case2.state"
assert_file_missing "case2 state file absent before run" "$USB_BT_STATE_FILE"

case2_out="$(usb_bt_mitigation_status 2>&1)"

assert_contains_text "case2 reports missing state file" "No mitigation state file found" "$case2_out"
assert_contains_text "case2 missing-state note includes path" "$USB_BT_STATE_FILE" "$case2_out"

# --- Case 3: top-level CLI dispatch --usb-mitigation-status via main() ---
USB_BT_STATE_FILE="$tmp_dir/case3.state"
{
  printf 'timestamp=2026-06-05T12:00:00+00:00 mode=disable targets=1-2:0a1b:2c3d\n'
} >>"$USB_BT_STATE_FILE"

case3_rc=0
case3_out="$(main --usb-mitigation-status 2>&1)" || case3_rc=$?

assert_eq "case3 main --usb-mitigation-status exits 0" "0" "$case3_rc"
assert_contains_text "case3 emits USB Mitigation Status header" "USB Mitigation Status" "$case3_out"
assert_contains_text "case3 reports total recorded runs" "Total recorded runs: 1" "$case3_out"
assert_contains_text "case3 reports per-device count" "1-2:0a1b:2c3d: 1 run(s)" "$case3_out"

# --- Case 4: generated helper writes state file with correct format ---
# Validate that the state-line format produced by the generated helper is
# parseable by usb_bt_mitigation_status().  The helper uses:
#   printf "timestamp=%s mode=%s targets=%s\n" ...
USB_BT_STATE_FILE="$tmp_dir/case4.state"
{
  printf 'timestamp=2026-06-05T12:00:00+00:00 mode=disable targets=1-2:0a1b:2c3d\n'
  printf 'timestamp=2026-06-05T12:01:00+00:00 mode=enable targets=1-2:0a1b:2c3d\n'
} >>"$USB_BT_STATE_FILE"

case4_out="$(usb_bt_mitigation_status 2>&1)"

assert_eq "case4 total runs from generated helper format" "1" "$(printf '%s' "$case4_out" | grep -c 'Total recorded runs:')"
assert_contains_text "case4 per-device count parsed" "1-2:0a1b:2c3d: 2 run(s)" "$case4_out"

# --- Case 5: reset_usb_mitigation_only removes state file ---
USB_BT_STATE_FILE="$tmp_dir/case5.state"
: >"$USB_BT_STATE_FILE"
CONFIRM_FORCE_RC=0

confirm_phrase() {
  return 0
}
run() {
  if [[ "$1" == "rm" ]]; then
    "$@" 2>/dev/null || true
  fi
  return 0
}

reset_usb_mitigation_only >/dev/null 2>&1

assert_file_missing "case5 reset removes USB_BT_STATE_FILE" "$USB_BT_STATE_FILE"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'USB mitigation status regression checks passed.\n'
