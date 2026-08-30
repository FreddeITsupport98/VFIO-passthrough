#!/usr/bin/env bash
# Regression for R43: ONE pristine VM-XML backup per stage (stealth / perf /
# live-attach), taken once and never re-backed-up, and a single --reset fresh-
# start wipe of EVERY stage backup. Locks in:
#   - the shared _save_pristine_vm_backup() once-only writer (write-if-absent,
#     dry-run safe, atomic via write_file_atomic);
#   - install_live_attach routing its legacy backup + with-GPU mode variant
#     through that helper (so live-attach stops overwriting on every run, and
#     now matches the stealth/perf once-only rule);
#   - _wipe_vm_stage_backups() replacing _remove_vm_tuning_backups, covering
#     stealth + perf + live-attach stage XMLs in one call while SPARING the
#     hugepages owned *.txt accounting files (freed separately); and that
#     --reset (reset_vfio_all) calls it.
# Functional tests source vfio.sh, override write_file_atomic for non-root
# temp-dir writes, and exercise both helpers end-to-end.
# shellcheck disable=SC2317,SC2329,SC2016
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

assert_contains_file() {
  local name="$1" pattern="$2" file="$3"
  if grep -Fq -- "$pattern" "$file"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (pattern not found: %s)\n' "$name" "$pattern" >&2
    record_failure "$name"
  fi
}

assert_absent_file() {
  local name="$1" pattern="$2" file="$3"
  if grep -Fq -- "$pattern" "$file"; then
    printf 'FAIL: %s (unexpected pattern still present: %s)\n' "$name" "$pattern" >&2
    record_failure "$name"
  else
    printf 'PASS: %s\n' "$name"
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ===================== Static wiring (R43) =====================

assert_contains_file \
  "R43 _save_pristine_vm_backup helper defined" \
  '_save_pristine_vm_backup()' \
  "$VFIO_SCRIPT"

assert_contains_file \
  "R43 helper enforces once-only (keeps existing pristine)" \
  'Keeping existing pristine stage backup' \
  "$VFIO_SCRIPT"

assert_contains_file \
  "R43 helper is dry-run safe (skips write under DRY_RUN)" \
  '[DRY-RUN] would save pristine pre-stage VM XML backup' \
  "$VFIO_SCRIPT"

# R44: install_live_attach no longer writes the old full-domain live-attach
# backups (live-attach-backup-*.xml / with-gpu / without-gpu) via
# _save_pristine_vm_backup — it now extracts device FRAGMENTS
# (profiles/<dom>/devices/*.xml) + uses profile_apply_mode. The old full
# backups are at most a one-release read-only fallback; --reset's
# _wipe_vm_stage_backups still sweeps them (asserted below).
assert_absent_file \
  "R44 install_live_attach does not route the legacy backup through _save_pristine_vm_backup" \
  '| _save_pristine_vm_backup "$_backup_xml"' \
  "$VFIO_SCRIPT"
assert_absent_file \
  "R44 install_live_attach does not route a with-gpu variant through _save_pristine_vm_backup" \
  '| _save_pristine_vm_backup "$_with_gpu_xml"' \
  "$VFIO_SCRIPT"
# R44: install_live_attach extracts device fragments instead of full backups.
assert_contains_file \
  "R44 install_live_attach extracts the GPU fragment via _la_extract_hostdev_fragment" \
  '_la_extract_hostdev_fragment' \
  "$VFIO_SCRIPT"

# The old per-layer wipe is gone (definition + call); the unified one is defined
# + wired into reset. The new comment still NAMES the old function for history
# ("supersedes the R37 _remove_vm_tuning_backups"), so assert the DEFINITION
# (_remove_vm_tuning_backups() with parens) is absent, not the bare token.
assert_absent_file \
  "R43 _remove_vm_tuning_backups definition fully removed" \
  '_remove_vm_tuning_backups()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R43 _wipe_vm_stage_backups helper defined" \
  '_wipe_vm_stage_backups()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R43 reset_vfio_all calls _wipe_vm_stage_backups" \
  '_wipe_vm_stage_backups' \
  "$VFIO_SCRIPT"

# The unified wipe must cover all three stages' XMLs (live-attach dir is derived
# from $LIVE_ATTACH_GPU_XML so it is testable without root).
assert_contains_file \
  "R43 wipe covers live-attach without-gpu variant" \
  'live-attach-vm-without-gpu-*.xml' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R43 wipe covers live-attach with-gpu variant" \
  'live-attach-vm-with-gpu-*.xml' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R43 wipe derives live-attach dir from LIVE_ATTACH_GPU_XML" \
  'dirname "$LIVE_ATTACH_GPU_XML"' \
  "$VFIO_SCRIPT"

# Stealth/perf keep their richer _vm_is_*_tuned once-only guard (not regressed).
assert_contains_file \
  "R43 stealth still uses _vm_is_stealth_tuned guard" \
  '_vm_is_stealth_tuned "$_dom" "$_xml"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R43 perf still uses _vm_is_perf_tuned guard" \
  '_vm_is_perf_tuned "$_dom" "$_xml"' \
  "$VFIO_SCRIPT"

# ===================== Functional: _save_pristine_vm_backup =====================
# Override write_file_atomic for non-root temp-dir writes (drop the root
# ownership so install(1) succeeds as the test user); keep DRY_RUN semantics.
# shellcheck disable=SC2034
write_file_atomic() {
  local dst="$1" mode="$2" _owner="$3"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if (( DRY_RUN )); then
    rm -f "$tmp" || true
    return 0
  fi
  install -m "$mode" "$tmp" "$dst" 2>/dev/null || cp -f "$tmp" "$dst"
  rm -f "$tmp" || true
}

DRY_RUN=0
_bak="$tmp_dir/bak/win.xml"
printf 'PRISTINE_V1\n' | _save_pristine_vm_backup "$_bak"
assert_eq \
  "R43 first save writes the pristine snapshot" \
  "PRISTINE_V1" "$(cat "$_bak" 2>/dev/null || printf '')"

# Second save with DIFFERENT content must NOT overwrite (once-only).
printf 'SHOULD_NOT_OVERWRITE_V2\n' | _save_pristine_vm_backup "$_bak"
assert_eq \
  "R43 second save keeps the original pristine (once-only, no overwrite)" \
  "PRISTINE_V1" "$(cat "$_bak" 2>/dev/null || printf '')"

# Empty path is a safe no-op (returns 0, writes nothing).
if printf 'NOPE\n' | _save_pristine_vm_backup "" 2>/dev/null; then
  if [[ -e "$tmp_dir/bak/empty" ]]; then
    printf 'FAIL: R43 empty-path save created a file\n' >&2
    record_failure "R43 empty-path save is a no-op (no file created)"
  else
    printf 'PASS: R43 empty-path save is a no-op (no file created)\n'
  fi
else
  printf 'FAIL: R43 empty-path save returned non-zero\n' >&2
  record_failure "R43 empty-path save returns 0"
fi

# Dry-run: a brand-new path must NOT be written.
DRY_RUN=1
_bak_dry="$tmp_dir/bak/dryrun.xml"
printf 'DRY_ONLY\n' | _save_pristine_vm_backup "$_bak_dry"
DRY_RUN=0
if [[ -e "$_bak_dry" ]]; then
  printf 'FAIL: R43 dry-run save created a backup file\n' >&2
  record_failure "R43 dry-run save does not write a file"
else
  printf 'PASS: R43 dry-run save does not write a file\n'
fi

# After dry-run, a real save of the same path writes the content.
printf 'REAL_AFTER_DRY\n' | _save_pristine_vm_backup "$_bak_dry"
assert_eq \
  "R43 real save after a dry-run writes the snapshot" \
  "REAL_AFTER_DRY" "$(cat "$_bak_dry" 2>/dev/null || printf '')"

# ===================== Functional: _wipe_vm_stage_backups =====================
# Redirect every location the wipe reads to temp dirs (no root, no real files):
#   CONF_FILE (STEALTH_VM_BACKUP_DIR / ULTIMATE_PERF_VM_BACKUP_DIR keys),
#   BACKUP_DIR (the legacy ~/Desktop fallback), and LIVE_ATTACH_GPU_XML (the
#   live-attach backup dir is its dirname).
_wipe_root="$tmp_dir/wipe"
mkdir -p "$_wipe_root/stealth" "$_wipe_root/perf" "$_wipe_root/legacy" "$_wipe_root/la"

# export: these are read by the sourced vfio.sh helpers (_wipe_vm_stage_backups
# reads CONF_FILE / BACKUP_DIR / LIVE_ATTACH_GPU_XML), so export them to point
# those helpers at temp dirs (also silences SC2034 "appears unused" — they ARE
# used, just by the sourced script).
export CONF_FILE="$_wipe_root/conf"
{
  printf 'STEALTH_VM_BACKUP_DIR="%s/stealth"\n' "$_wipe_root"
  printf 'ULTIMATE_PERF_VM_BACKUP_DIR="%s/perf"\n' "$_wipe_root"
}>"$CONF_FILE"
export BACKUP_DIR="$_wipe_root/legacy"
export LIVE_ATTACH_GPU_XML="$_wipe_root/la/live-attach-gpu.xml"

dom="win11"
# Stealth stage (fixed-name + a timestamped one in the same dir).
printf '<domain>%s stealth</domain>\n' "$dom" >"$_wipe_root/stealth/${dom}_stealth.xml"
printf '<domain>%s stealth ts</domain>\n' "$dom" >"$_wipe_root/stealth/${dom}_stealth_20260101.xml"
# Perf stage (fixed-name) + the hugepages owned accounting file (must SURVIVE).
printf '<domain>%s perf</domain>\n' "$dom" >"$_wipe_root/perf/${dom}_perf.xml"
printf '16096\n' >"$_wipe_root/perf/${dom}_perf_hugepages_owned.txt"
# Legacy ~/Desktop timestamped litter.
printf '<domain>%s stealth legacy</domain>\n' "$dom" >"$_wipe_root/legacy/${dom}_stealth_20260101.xml"
printf '<domain>%s perf legacy</domain>\n' "$dom" >"$_wipe_root/legacy/${dom}_perf_20260101.xml"
# Live-attach stage (all three variants).
printf '<domain>%s la backup</domain>\n' "$dom" >"$_wipe_root/la/live-attach-backup-${dom}.xml"
printf '<domain>%s la with-gpu</domain>\n' "$dom" >"$_wipe_root/la/live-attach-vm-with-gpu-${dom}.xml"
printf '<domain>%s la without-gpu</domain>\n' "$dom" >"$_wipe_root/la/live-attach-vm-without-gpu-${dom}.xml"

# Sanity: the files exist before the wipe.
_pre_count="$(find "$_wipe_root" -type f | wc -l | tr -d ' ')"
assert_eq "R43 wipe pre-condition: sample files exist" "10" "$_pre_count"

_wipe_vm_stage_backups

# Every stage .xml must be gone ...
for _gone in \
  "$_wipe_root/stealth/${dom}_stealth.xml" \
  "$_wipe_root/stealth/${dom}_stealth_20260101.xml" \
  "$_wipe_root/perf/${dom}_perf.xml" \
  "$_wipe_root/legacy/${dom}_stealth_20260101.xml" \
  "$_wipe_root/legacy/${dom}_perf_20260101.xml" \
  "$_wipe_root/la/live-attach-backup-${dom}.xml" \
  "$_wipe_root/la/live-attach-vm-with-gpu-${dom}.xml" \
  "$_wipe_root/la/live-attach-vm-without-gpu-${dom}.xml"; do
  if [[ -e "$_gone" ]]; then
    printf 'FAIL: R43 wipe left a stage backup behind: %s\n' "$_gone" >&2
    record_failure "R43 wipe removes $(basename "$_gone")"
  else
    printf 'PASS: R43 wipe removed %s\n' "$(basename "$_gone")"
  fi
done

# ... but the hugepages owned .txt accounting file MUST survive (freed by
# _reset_perf_hugepages_all, not by the stage-backup wipe).
if [[ -f "$_wipe_root/perf/${dom}_perf_hugepages_owned.txt" ]]; then
  printf 'PASS: R43 wipe spares the hugepages owned .txt accounting file\n'
else
  printf 'FAIL: R43 wipe deleted the hugepages owned .txt accounting file\n' >&2
  record_failure "R43 wipe spares hugepages owned .txt"
fi

# A second wipe on the now-empty slate must be a safe no-op (return 0).
if _wipe_vm_stage_backups 2>/dev/null; then
  printf 'PASS: R43 wipe on an empty slate is a no-op (returns 0)\n'
else
  printf 'FAIL: R43 wipe on an empty slate returned non-zero\n' >&2
  record_failure "R43 wipe on empty slate returns 0"
fi

# ===================== FAIL SUMMARY =====================
if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'VM stage-backup regression checks passed.\n'
