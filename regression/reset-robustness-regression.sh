#!/usr/bin/env bash
# R45 regression: --reset --full robustness.
# 1. confirm_phrase re-prompts on a TYPED mismatch (up to CONFIRM_PHRASE_MAX_TRIES)
#    instead of one-shot dying -- the original "--reset --full didnt clear
#    trayicon" bug was a typo'd RESET VFIO -> die -> exit BEFORE any rm, so nothing
#    was removed. An explicit decline (EOF) still returns 1 immediately.
# 2. _reset_preview_paths / _reset_verify_paths enumerate managed files before
#    the confirm gate and verify removal after (so a partial failure is visible).
# 3. reset_vfio_all builds ONE _rm_paths list, previews it before confirm, removes
#    via the array, and verifies after. A rejected confirm dies with NOTHING
#    removed (the bug shape), and an accepted confirm removes every fixture.
# Functional tests source vfio.sh and drive the real confirm_phrase loop via the
# VFIO_CONFIRM_IN/OUT testability hooks (no tty needed).
# shellcheck disable=SC2034,SC2317,SC2329,SC2016
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

# Deterministic plain-text output from note()/_link() (no ANSI / hyperlinks).
ENABLE_COLOR=0

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

assert_contains_file() {
  local name="$1" pattern="$2" file="$3"
  if grep -Fq -- "$pattern" "$file"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (pattern not found: %s)\n' "$name" "$pattern" >&2
    record_failure "$name"
  fi
}

assert_file_exists() {
  local name="$1" file="$2"
  if [[ -e "$file" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (missing: %s)\n' "$name" "$file" >&2
    record_failure "$name"
  fi
}

assert_file_missing() {
  local name="$1" file="$2"
  if [[ ! -e "$file" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (unexpectedly present: %s)\n' "$name" "$file" >&2
    record_failure "$name"
  fi
}

assert_non_empty() {
  local name="$1" value="$2"
  if [[ -n "$value" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (output was empty)\n' "$name" >&2
    record_failure "$name"
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# =====================================================================
# Part 1: confirm_phrase re-prompt loop (REAL function, no mock)
# =====================================================================
# HAS_TUI=0 forces the plain /dev/stdin path; VFIO_CONFIRM_IN/OUT redirect the
# I/O so the loop is deterministic without a tty. Each case captures rc via the
# `cmd || rc=$?` idiom (exempt from set -e). The return code is the deterministic
# proof of the re-prompt count: a wrong-then-correct rc=0 needs 2 reads, a
# 3rd-try-correct rc=0 needs 3 reads, and a max-exhausted run rc=1. (The OUT file
# is written with `>` which truncates per write, so the per-attempt marker text
# does not accumulate there -- the marker text itself is verified statically in
# Part 3 against the vfio.sh source.)
cout="$tmp_dir/cp_out"

rcA=0; : >"$cout"
printf 'WRONG\nRESET VFIO\n' | HAS_TUI=0 ENABLE_COLOR=0 RECOMMENDED_MODE=0 \
  VFIO_CONFIRM_IN=/dev/stdin VFIO_CONFIRM_OUT="$cout" \
  confirm_phrase "To continue, confirm reset." "RESET VFIO" || rcA=$?
assert_eq "P1 wrong-then-correct returns 0 (re-prompted, matched on 2nd)" "0" "$rcA"

rcB=0; : >"$cout"
printf 'NOPE\nNOPE2\n' | CONFIRM_PHRASE_MAX_TRIES=2 HAS_TUI=0 ENABLE_COLOR=0 RECOMMENDED_MODE=0 \
  VFIO_CONFIRM_IN=/dev/stdin VFIO_CONFIRM_OUT="$cout" \
  confirm_phrase "c" "X" || rcB=$?
assert_eq "P1 two-wrong with max=2 returns 1 (loop exhausted)" "1" "$rcB"

# 3rd-try-correct with default max=3 -> rc=0 proves the loop read 3 lines
# (re-prompted twice). VFIO_CONFIRM_OUT is a file written with `>` (truncate per
# write), so the per-attempt marker text does not accumulate there; the return
# code is the deterministic proof of the re-prompt count.
rcF=0; : >"$cout"
printf 'A\nB\nRESET VFIO\n' | HAS_TUI=0 ENABLE_COLOR=0 RECOMMENDED_MODE=0 \
  VFIO_CONFIRM_IN=/dev/stdin VFIO_CONFIRM_OUT="$cout" \
  confirm_phrase "c" "RESET VFIO" || rcF=$?
assert_eq "P1 third-try-correct returns 0 (re-prompted twice, matched on 3rd)" "0" "$rcF"

# 3 wrong with default max=3 -> rc=1 (loop exhausted at 3 attempts).
rcG=0; : >"$cout"
printf 'A\nB\nC\n' | HAS_TUI=0 ENABLE_COLOR=0 RECOMMENDED_MODE=0 \
  VFIO_CONFIRM_IN=/dev/stdin VFIO_CONFIRM_OUT="$cout" \
  confirm_phrase "c" "RESET VFIO" || rcG=$?
assert_eq "P1 three-wrong default-max returns 1 (loop exhausted at 3)" "1" "$rcG"

rcC=0; : >"$cout"
printf '' | HAS_TUI=0 ENABLE_COLOR=0 RECOMMENDED_MODE=0 \
  VFIO_CONFIRM_IN=/dev/stdin VFIO_CONFIRM_OUT="$cout" \
  confirm_phrase "c" "X" || rcC=$?
assert_eq "P1 immediate EOF returns 1 (explicit decline, no loop)" "1" "$rcC"
assert_not_contains_text "P1 EOF did NOT re-prompt (no attempt-2 marker)" "attempt 2 of" "$(cat "$cout")"

rcD=0; : >"$cout"
printf 'I UNDERSTAND\n' | HAS_TUI=0 ENABLE_COLOR=0 RECOMMENDED_MODE=0 \
  VFIO_CONFIRM_IN=/dev/stdin VFIO_CONFIRM_OUT="$cout" \
  confirm_phrase "c" "I UNDERSTAND" || rcD=$?
assert_eq "P1 correct-first returns 0" "0" "$rcD"
assert_not_contains_text "P1 correct-first did NOT re-prompt" "attempt 2 of" "$(cat "$cout")"

rcE=0; : >"$cout"
printf '' | HAS_TUI=0 ENABLE_COLOR=0 RECOMMENDED_MODE=1 \
  VFIO_CONFIRM_IN=/dev/stdin VFIO_CONFIRM_OUT="$cout" \
  confirm_phrase "c" "I UNDERSTAND" || rcE=$?
assert_eq "P1 recommended auto-accepts 'I UNDERSTAND' returns 0" "0" "$rcE"
_nE="$(wc -l <"$cout" | tr -d '[:space:]')"
assert_eq "P1 recommended auto-accept wrote NO prompt lines to OUT" "0" "$_nE"

# =====================================================================
# Part 2: _reset_preview_paths / _reset_verify_paths (direct, fixtures)
# =====================================================================
pvroot="$tmp_dir/pv"; mkdir -p "$pvroot"
: >"$pvroot/exist1"; : >"$pvroot/exist2"
ln -s "$pvroot/nonexistent_target" "$pvroot/dangle"   # dangling symlink
missing="$pvroot/missing"

prev_out="$(_reset_preview_paths "LBL" "$pvroot/exist1" "$missing" "$pvroot/exist2" "$pvroot/dangle")"
assert_contains_text "P2 preview lists exist1" "$pvroot/exist1" "$prev_out"
assert_contains_text "P2 preview lists exist2" "$pvroot/exist2" "$prev_out"
assert_contains_text "P2 preview lists the dangling symlink" "$pvroot/dangle" "$prev_out"
assert_not_contains_text "P2 preview omits the missing path" "$missing" "$prev_out"
assert_contains_text "P2 preview reports the count (3)" "3 managed file(s) currently present" "$prev_out"

# verify: exist1 left, exist2 removed -> reports 1 leftover (exist1), not exist2.
rm -f "$pvroot/exist2"
ver_out="$(_reset_verify_paths "LBL" "$pvroot/exist1" "$pvroot/exist2" "$missing")"
assert_contains_text "P2 verify reports exist1 as still present" "$pvroot/exist1" "$ver_out"
assert_contains_text "P2 verify says 'still present'" "still present" "$ver_out"
assert_not_contains_text "P2 verify does not list the removed exist2" "$pvroot/exist2" "$ver_out"
assert_contains_text "P2 verify reports 1 leftover" "1 managed file(s) still present" "$ver_out"

# verify: all gone -> "verified removed".
rm -f "$pvroot/exist1" "$pvroot/dangle"
ver_ok="$(_reset_verify_paths "LBL" "$pvroot/exist1" "$pvroot/exist2" "$missing")"
assert_contains_text "P2 verify all-gone says verified removed" "all managed files verified removed." "$ver_ok"

# =====================================================================
# Part 3: static wiring of R45 reset robustness in vfio.sh
# =====================================================================
assert_contains_file "P3 confirm_phrase honors CONFIRM_PHRASE_MAX_TRIES" 'CONFIRM_PHRASE_MAX_TRIES' "$VFIO_SCRIPT"
assert_contains_file "P3 confirm_phrase re-prompt marker exists" 'attempt $i of $max' "$VFIO_SCRIPT"
assert_contains_file "P3 _reset_preview_paths defined" '_reset_preview_paths()' "$VFIO_SCRIPT"
assert_contains_file "P3 _reset_verify_paths defined" '_reset_verify_paths()' "$VFIO_SCRIPT"

_reset_fn="$(sed -n '/^reset_vfio_all()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text "P3 reset builds the _rm_paths array" 'local -a _rm_paths=(' "$_reset_fn"
assert_contains_text "P3 reset previews managed files before confirm" '_reset_preview_paths "Managed files"' "$_reset_fn"
assert_contains_text "P3 reset keeps the RESET VFIO confirm gate" 'confirm_phrase "To continue, confirm reset." "RESET VFIO"' "$_reset_fn"
assert_contains_text "P3 reset rm uses the _rm_paths array" 'rm -f "${_rm_paths[@]}"' "$_reset_fn"
assert_contains_text "P3 reset verifies before complete" '_reset_verify_paths "Managed files"' "$_reset_fn"
# R46: reset must sweep the previously-left-behind artifacts too.
assert_contains_text "P3 reset _rm_paths includes USB_BT_STATE_FILE" '$USB_BT_STATE_FILE' "$_reset_fn"
assert_contains_text "P3 reset _rm_paths includes GRAPHICS_DAEMON_WANTS_LINK" '$GRAPHICS_DAEMON_WANTS_LINK' "$_reset_fn"
assert_contains_text "P3 reset _rm_paths includes SDDM_PLASMA_WAYLAND_CONF" '$SDDM_PLASMA_WAYLAND_CONF' "$_reset_fn"
assert_contains_text "P3 reset rmdir's the now-empty VFIO_DYNAMIC_DIR" 'rmdir "$VFIO_DYNAMIC_DIR"' "$_reset_fn"
_vwga_fn="$(sed -n '/^remove_virtio_win_guest_agent()/,/^}/p' "$VFIO_SCRIPT")"
assert_non_empty "P3 remove_virtio_win_guest_agent body extracted" "$_vwga_fn"
assert_contains_text "P3 remove_virtio_win_guest_agent sweeps the repo file" '$VIRTIO_WIN_REPO_FILE' "$_vwga_fn"
assert_contains_text "P3 remove_virtio_win_guest_agent guards on the fedorapeople URL" 'fedorapeople' "$_vwga_fn"
# R47: reset must sweep the bind-script runtime state + the hook/live-attach logs.
assert_contains_text "P3 reset _rm_paths includes VFIO_COOLDOWN_TS_FILE" '$VFIO_COOLDOWN_TS_FILE' "$_reset_fn"
assert_contains_text "P3 reset _rm_paths includes VFIO_DRIVER_STATUS_FILE" '$VFIO_DRIVER_STATUS_FILE' "$_reset_fn"
assert_contains_text "P3 reset _rm_paths includes VFIO_HOOK_LOG" '$VFIO_HOOK_LOG' "$_reset_fn"
assert_contains_text "P3 reset _rm_paths includes VFIO_LIVE_ATTACH_LOG" '$VFIO_LIVE_ATTACH_LOG' "$_reset_fn"
# R47: reset strips amdgpu.rebar=0 (added by the installer but never stripped before).
assert_contains_text "P3 reset strips amdgpu.rebar=0 from GRUB cmdline" 'remove_param_all "$new" "amdgpu.rebar=0"' "$_reset_fn"
assert_contains_text "P3 reset strips amdgpu.rebar=0 from /etc/kernel/cmdline" 'remove_param_all "$knew" "amdgpu.rebar=0"' "$_reset_fn"
# R47: reset removes the SELinux module + sweeps user-home runtime artifacts + /root rollback scripts.
assert_contains_file "P3 remove_selinux_virtqemud_policy defined" 'remove_selinux_virtqemud_policy()' "$VFIO_SCRIPT"
assert_contains_text "P3 reset calls remove_selinux_virtqemud_policy" 'remove_selinux_virtqemud_policy' "$_reset_fn"
assert_contains_file "P3 _wipe_user_runtime_artifacts defined" '_wipe_user_runtime_artifacts()' "$VFIO_SCRIPT"
assert_contains_text "P3 reset calls _wipe_user_runtime_artifacts" '_wipe_user_runtime_artifacts' "$_reset_fn"
assert_contains_text "P3 reset sweeps /root vfio-rollback scripts" '/root/vfio-rollback-*.sh' "$_reset_fn"
_early_fn="$(sed -n '/^install_early_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text "P3 install-early-binding removes the SELinux module" 'remove_selinux_virtqemud_policy' "$_early_fn"
# R48: standalone systemd-boot entry reset helper + reset_vfio_all auto-invocation.
assert_contains_file "P3 reset_systemd_boot_entries defined" 'reset_systemd_boot_entries()' "$VFIO_SCRIPT"
_rsbe_fn="$(sed -n '/^reset_systemd_boot_entries()/,/^}/p' "$VFIO_SCRIPT")"
assert_non_empty "P3 reset_systemd_boot_entries body extracted" "$_rsbe_fn"
assert_contains_text "P3 reset_systemd_boot_entries strips amdgpu.rebar=0" 'remove_param_all "$_new" "amdgpu.rebar=0"' "$_rsbe_fn"
assert_contains_text "P3 reset_systemd_boot_entries strips vfio-pci.ids prefix" 'remove_param_prefix "$_new" "vfio-pci.ids="' "$_rsbe_fn"
assert_contains_text "P3 reset_systemd_boot_entries skips snapper entries" '== snapper-*' "$_rsbe_fn"
assert_contains_text "P3 reset_systemd_boot_entries uses the shared writer" 'systemd_boot_write_options "$_entry" "$_new"' "$_rsbe_fn"
assert_contains_text "P3 reset_vfio_all auto-invokes it for standalone systemd-boot" 'reset_systemd_boot_entries no-confirm' "$_reset_fn"
assert_contains_text "P3 reset gates the systemd-boot call on detect_bootloader" '$reset_bl" == "systemd-boot"' "$_reset_fn"
# R48: standalone --reset-systemd-boot-entries CLI flag wiring.
assert_contains_file "P3 parse_args handles --reset-systemd-boot-entries" '--reset-systemd-boot-entries)' "$VFIO_SCRIPT"
assert_contains_file "P3 MODE comment lists reset-systemd-boot-entries" '| reset-systemd-boot-entries |' "$VFIO_SCRIPT"
assert_contains_file "P3 fish completion includes --reset-systemd-boot-entries" '-l reset-systemd-boot-entries' "$VFIO_SCRIPT"
assert_contains_file "P3 bash completion opts include --reset-systemd-boot-entries" ' --reset-systemd-boot-entries ' "$VFIO_SCRIPT"
assert_contains_file "P3 main dispatch wires reset-systemd-boot-entries" 'MODE" == "reset-systemd-boot-entries"' "$VFIO_SCRIPT"

_prev_line="$(printf '%s\n' "$_reset_fn" | grep -nF '_reset_preview_paths "Managed files"' | awk -F: 'NR==1{print $1}')"
_conf_line="$(printf '%s\n' "$_reset_fn" | grep -nF 'confirm_phrase "To continue, confirm reset." "RESET VFIO"' | awk -F: 'NR==1{print $1}')"
_ver_line="$(printf '%s\n' "$_reset_fn" | grep -nF '_reset_verify_paths "Managed files"' | awk -F: 'NR==1{print $1}')"
_done_line="$(printf '%s\n' "$_reset_fn" | grep -nF 'say "Reset complete. Reboot recommended."' | awk -F: 'NR==1{print $1}')"
if [[ -n "$_prev_line" && -n "$_conf_line" ]] && (( _prev_line < _conf_line )); then
  printf 'PASS: P3 preview runs before the confirm gate\n'
else
  printf 'FAIL: P3 preview must run before the confirm gate (prev=%s conf=%s)\n' "$_prev_line" "$_conf_line" >&2
  record_failure "P3 preview runs before the confirm gate"
fi
if [[ -n "$_ver_line" && -n "$_done_line" ]] && (( _ver_line < _done_line )); then
  printf 'PASS: P3 verify runs before Reset complete\n'
else
  printf 'FAIL: P3 verify must run before Reset complete (ver=%s done=%s)\n' "$_ver_line" "$_done_line" >&2
  record_failure "P3 verify runs before Reset complete"
fi

# =====================================================================
# Part 4: reset_vfio_all full end-to-end (mocked sub-removers + run)
# =====================================================================
# Mocks neutralize every real side effect: confirm_phrase returns a forced rc;
# run only rm's paths under the fixture root (real paths like /etc/... are never
# touched); every sub-remover + bootloader/initramfs helper is a no-op so the
# test exercises ONLY the preview -> rm -> verify -> complete wiring.
CONFIRM_FORCE_RC=0
EO_RUN_LOG="$tmp_dir/eo_run.log"

confirm_phrase() { return "${CONFIRM_FORCE_RC:-0}"; }
run() {
  printf '%s\n' "$*" >>"$EO_RUN_LOG"
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || return 0
  shift
  case "$cmd" in
    rm)
      local p
      for p in "$@"; do
        if [[ "$p" == "$EO_ROOT"* ]]; then rm -f "$p" 2>/dev/null || true; fi
      done
      ;;
    rmdir)
      local p
      for p in "$@"; do
        if [[ "$p" == "$EO_ROOT"* ]]; then rmdir "$p" 2>/dev/null || true; fi
      done
      ;;
    *) return 0 ;;
  esac
}
remove_vbios_romfile() { :; }
remove_live_attach() { :; }
_wipe_vm_stage_backups() { :; }
remove_looking_glass() { :; }
_reset_perf_hugepages_all() { :; }
remove_openbox_autostart_hook() { :; }
remove_user_audio_unit() { :; }
remove_selinux_virtqemud_policy() { :; }
_wipe_user_runtime_artifacts() { :; }
unmask_plymouth_services() { :; }
detect_bootloader() { echo "none"; }
maybe_update_initramfs() { :; }
maybe_check_grub_cfg() { return 0; }
backup_file() { :; }
is_opensuse_like() { return 1; }
bootlog_bin_path() { printf '%s\n' "$EO_ROOT/bootlog_bin"; }

# Override every global reset_vfio_all puts into _rm_paths -> fixture files under
# $EO_ROOT, so the rm block + verify operate ONLY on fixtures (bootlog_unit is a
# hardcoded local and is skipped by the mock run since it is not under $EO_ROOT).
prep_eo_fixtures() {
  local root="$1" _g _ic
  for _g in SYSTEMD_UNIT BIND_SCRIPT AUDIO_SCRIPT OPENBOX_MONITOR_SCRIPT \
            LIBVIRT_HOOK_SCRIPT CONF_FILE MODULES_LOAD BLACKLIST_FILE \
            SOFTDEP_FILE DRACUT_VFIO_CONF UDEV_ISOLATION_RULE \
            USB_BT_SCRIPT USB_BT_SYSTEMD_UNIT USB_BT_UDEV_RULE USB_BT_MATCH_CONF \
            USB_BT_STATE_FILE \
            GRAPHICS_DAEMON_SCRIPT GRAPHICS_DAEMON_UNIT GRAPHICS_DAEMON_WANTS_LINK \
            LIGHTDM_FALLBACK_CONF XORG_HOST_GPU_CONF LIGHTDM_HOST_GPU_CONF \
            SDDM_PLASMA_WAYLAND_CONF \
            KWIN_RENDER_PIN_FILE WLR_RENDER_PIN_FILE \
            REBOOT_FLR_SCRIPT REBOOT_FLR_UNIT \
            PARK_KEEPALIVE_SCRIPT PARK_KEEPALIVE_UNIT PARK_KEEPALIVE_CHECK_UNIT \
            PARK_KEEPALIVE_RESUME_HOOK PARK_KEEPALIVE_UDEV_RULE PARK_KEEPALIVE_STATE_FILE \
            LIVE_ATTACH_HELPER LIVE_ATTACH_GPU_XML LIVE_ATTACH_AUDIO_XML LIVE_ATTACH_VM_LIST \
            LIVE_ATTACH_MODE_FILE LIVE_ATTACH_TRAY LIVE_ATTACH_POLKIT \
            VFIO_HOOK_LOG VFIO_LIVE_ATTACH_LOG; do
    declare -g "$_g"="$root/$_g"
    : >"$root/$_g"
  done
  # R46: VFIO_DYNAMIC_DIR is a directory (rmdir'd at the end of reset), not a
  # file fixture — create it empty so the mock `run rmdir` can remove it.
  declare -g VFIO_DYNAMIC_DIR="$root/VFIO_DYNAMIC_DIR"
  mkdir -p "$VFIO_DYNAMIC_DIR"
  # R47: the two bind-script runtime state files live INSIDE VFIO_DYNAMIC_DIR
  # (matching the real ${VFIO_DYNAMIC_DIR}/... paths) so the rmdir assertion
  # also proves the rm block empties the dir before rmdir removes it.
  declare -g VFIO_COOLDOWN_TS_FILE="$VFIO_DYNAMIC_DIR/last-vm-stop.ts"
  declare -g VFIO_DRIVER_STATUS_FILE="$VFIO_DYNAMIC_DIR/amd-driver-status"
  : >"$VFIO_COOLDOWN_TS_FILE"
  : >"$VFIO_DRIVER_STATUS_FILE"
  printf 'GUEST_GPU_BDF="0000:01:00.0"\n' >"$CONF_FILE"
  declare -g LIBVIRT_HOOK_ENTRY="$root/no_such_hook_entry"
  declare -g SELF_INSTALL_BIN="$root/vfio"; : >"$SELF_INSTALL_BIN"
  _ic="$(basename "$SELF_INSTALL_BIN")"
  declare -g FISH_COMPLETION_DIR="$root/fishc"; mkdir -p "$FISH_COMPLETION_DIR"; : >"$FISH_COMPLETION_DIR/$_ic.fish"
  declare -g BASH_COMPLETION_DIR="$root/bashc"; mkdir -p "$BASH_COMPLETION_DIR"; : >"$BASH_COMPLETION_DIR/$_ic"
  declare -g ZSH_COMPLETION_DIR="$root/zshc"; mkdir -p "$ZSH_COMPLETION_DIR"; : >"$ZSH_COMPLETION_DIR/_$_ic"
}

# --- Case 4a: accepted confirm -> every fixture removed + verify ran. ---
EO_ROOT="$tmp_dir/eo"; mkdir -p "$EO_ROOT"; : >"$EO_RUN_LOG"
prep_eo_fixtures "$EO_ROOT"
_ic_main="$(basename "$SELF_INSTALL_BIN")"
CONFIRM_FORCE_RC=0
eo_out="$tmp_dir/eo_stdout.txt"; eo_err="$tmp_dir/eo_stderr.txt"
reset_vfio_all full >"$eo_out" 2>"$eo_err" || true
assert_file_missing "P4a removes SYSTEMD_UNIT fixture" "$EO_ROOT/SYSTEMD_UNIT"
assert_file_missing "P4a removes CONF_FILE fixture" "$EO_ROOT/CONF_FILE"
assert_file_missing "P4a removes LIVE_ATTACH_TRAY fixture (the original bug)" "$EO_ROOT/LIVE_ATTACH_TRAY"
assert_file_missing "P4a removes LIVE_ATTACH_POLKIT fixture" "$EO_ROOT/LIVE_ATTACH_POLKIT"
assert_file_missing "P4a removes USB_BT_SCRIPT fixture" "$EO_ROOT/USB_BT_SCRIPT"
assert_file_missing "P4a removes USB_BT_STATE_FILE fixture (R46)" "$EO_ROOT/USB_BT_STATE_FILE"
assert_file_missing "P4a removes GRAPHICS_DAEMON_WANTS_LINK fixture (R46)" "$EO_ROOT/GRAPHICS_DAEMON_WANTS_LINK"
assert_file_missing "P4a removes SDDM_PLASMA_WAYLAND_CONF fixture (R46)" "$EO_ROOT/SDDM_PLASMA_WAYLAND_CONF"
assert_file_missing "P4a removes VFIO_HOOK_LOG fixture (R47)" "$EO_ROOT/VFIO_HOOK_LOG"
assert_file_missing "P4a removes VFIO_LIVE_ATTACH_LOG fixture (R47)" "$EO_ROOT/VFIO_LIVE_ATTACH_LOG"
assert_file_missing "P4a removes VFIO_COOLDOWN_TS_FILE fixture (R47)" "$VFIO_COOLDOWN_TS_FILE"
assert_file_missing "P4a removes VFIO_DRIVER_STATUS_FILE fixture (R47)" "$VFIO_DRIVER_STATUS_FILE"
assert_file_missing "P4a rmdir's the VFIO_DYNAMIC_DIR fixture (R46)" "$EO_ROOT/VFIO_DYNAMIC_DIR"
assert_contains_text "P4a rm log includes the SDDM fixture path (R46)" "$EO_ROOT/SDDM_PLASMA_WAYLAND_CONF" "$(cat "$EO_RUN_LOG")"
assert_contains_text "P4a run log includes rmdir of the dynamic dir (R46)" "rmdir $EO_ROOT/VFIO_DYNAMIC_DIR" "$(cat "$EO_RUN_LOG")"
assert_file_missing "P4a removes the self-installed CLI fixture" "$SELF_INSTALL_BIN"
assert_file_missing "P4a removes the fish completion fixture" "$FISH_COMPLETION_DIR/$_ic_main.fish"
assert_file_missing "P4a removes the bash completion fixture" "$BASH_COMPLETION_DIR/$_ic_main"
assert_file_missing "P4a removes the zsh completion fixture" "$ZSH_COMPLETION_DIR/_$_ic_main"
assert_contains_text "P4a prints the preview header" "Preview of managed files this reset will remove:" "$(cat "$eo_out")"
assert_contains_text "P4a runs the verification header" "Reset verification" "$(cat "$eo_out")"
assert_contains_text "P4a prints Reset complete" "Reset complete." "$(cat "$eo_out")"
assert_contains_text "P4a rm log includes the tray fixture path (array rm)" "$EO_ROOT/LIVE_ATTACH_TRAY" "$(cat "$EO_RUN_LOG")"
assert_not_contains_text "P4a verify does NOT report the tray fixture as leftover" "$EO_ROOT/LIVE_ATTACH_TRAY (still present)" "$(cat "$eo_out")"

# --- Case 4b: rejected confirm -> die, NOTHING removed (the original bug shape). ---
EO_ROOT="$tmp_dir/eo2"; mkdir -p "$EO_ROOT"
prep_eo_fixtures "$EO_ROOT"
CONFIRM_FORCE_RC=1
eo2_rc=0
eo2_out="$tmp_dir/eo2_stdout.txt"; eo2_err="$tmp_dir/eo2_stderr.txt"
( reset_vfio_all full ) >"$eo2_out" 2>"$eo2_err" || eo2_rc=$?
assert_eq "P4b rejected confirm exits 1" "1" "$eo2_rc"
assert_contains_text "P4b rejected confirm reports Reset cancelled" "ERROR: Reset cancelled" "$(cat "$eo2_err")"
assert_contains_text "P4b ran the preview before the die" "Preview of managed files this reset will remove:" "$(cat "$eo2_out")"
assert_file_exists "P4b leaves LIVE_ATTACH_TRAY fixture intact (nothing removed)" "$EO_ROOT/LIVE_ATTACH_TRAY"
assert_file_exists "P4b leaves CONF_FILE fixture intact" "$EO_ROOT/CONF_FILE"
assert_file_exists "P4b leaves the self-installed CLI fixture intact" "$SELF_INSTALL_BIN"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'Reset robustness regression checks passed.\n'
