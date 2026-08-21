#!/usr/bin/env bash
# Regression for R23: live-attach (hotplug GPU) workflow.
# The VM starts WITHOUT the GPU (Windows boots on a virtual display); after a
# configurable delay the GPU is bound to vfio-pci and hot-attached to the running
# VM via `virsh attach-device --live`, sidestepping the RX 9070 / RDNA4
# parked-restart card death. This file locks in the constants, conf keys, CLI
# mode + dispatch, install/remove/helper functions, the libvirt hook's
# live-attach branch, the helper's bind+hot-attach logic, the reset/early-binding
# cleanup, and fish/bash/zsh completion coverage.
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

assert_contains_file() {
  local name="$1" pattern="$2" file="$3"
  if grep -Fq -- "$pattern" "$file"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (pattern not found: %s)\n' "$name" "$pattern" >&2
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

# --- Static wiring: live-attach constants ---
assert_contains_file \
  "R23 LIVE_ATTACH_HELPER constant defined" \
  'LIVE_ATTACH_HELPER="/usr/local/sbin/vfio-live-attach.sh"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 LIVE_ATTACH_GPU_XML constant defined" \
  'LIVE_ATTACH_GPU_XML="/var/lib/vfio-dynamic/live-attach-gpu.xml"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 LIVE_ATTACH_AUDIO_XML constant defined" \
  'LIVE_ATTACH_AUDIO_XML="/var/lib/vfio-dynamic/live-attach-audio.xml"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 LIVE_ATTACH_VM_LIST constant defined" \
  'LIVE_ATTACH_VM_LIST="/var/lib/vfio-dynamic/live-attach-vms"' \
  "$VFIO_SCRIPT"

# --- Static wiring: write_conf persists live-attach conf keys ---
assert_contains_file \
  "R23 write_conf emits VFIO_DYNAMIC_LIVE_ATTACH default (0)" \
  'VFIO_DYNAMIC_LIVE_ATTACH="0"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 write_conf emits VFIO_DYNAMIC_LIVE_ATTACH_DELAY default (30)" \
  'VFIO_DYNAMIC_LIVE_ATTACH_DELAY="30"' \
  "$VFIO_SCRIPT"

# --- Static wiring: --install-live-attach CLI mode + dispatch ---
assert_contains_file \
  "R23 parse_args handles --install-live-attach" \
  '--install-live-attach)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 parse_args sets MODE=install-live-attach" \
  'MODE="install-live-attach"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 main dispatch wires install-live-attach" \
  '[[ "$MODE" == "install-live-attach" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 main dispatch calls install_live_attach" \
  'install_live_attach' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 usage help documents --install-live-attach" \
  'Set up the live-attach (hotplug GPU) workflow: the VM starts WITHOUT the' \
  "$VFIO_SCRIPT"

# --- Static wiring: install/remove/helper functions defined ---
assert_contains_file \
  "R23 install_live_attach_helper function defined" \
  'install_live_attach_helper()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 install_live_attach function defined" \
  'install_live_attach()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 remove_live_attach function defined" \
  'remove_live_attach()' \
  "$VFIO_SCRIPT"

# --- Static wiring: generated libvirt hook has the live-attach branch ---
# Reuse the same heredoc extraction the dynamic-binding regression uses (proven
# to capture the prepare/stopped phases), then assert the live-attach branch.
hook_block="$(sed -n '/write_file_atomic "$LIBVIRT_HOOK_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R23 hook gates live-attach on VFIO_DYNAMIC_LIVE_ATTACH=1" \
  '[[ "${VFIO_DYNAMIC_LIVE_ATTACH:-0}" == "1" ]]' \
  "$hook_block"
assert_contains_text \
  "R23 hook checks the live-attach VM list file" \
  'grep -Fixq "$DOMAIN" /var/lib/vfio-dynamic/live-attach-vms' \
  "$hook_block"
assert_contains_text \
  "R23 hook launches the live-attach helper in the background" \
  'vfio-live-attach.sh "$DOMAIN" "$_la_delay" &' \
  "$hook_block"
assert_contains_text \
  "R23 hook logs the live-attach launch" \
  'action=live-attach-launch domain=$DOMAIN delay=${_la_delay}s' \
  "$hook_block"

# --- Static wiring: generated live-attach helper script ---
helper_block="$(sed -n '/write_file_atomic "$LIVE_ATTACH_HELPER" 0755 "root:root" <<.HELPEREOF./,/^HELPEREOF$/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R23 helper is valid bash" \
  '#!/usr/bin/env bash' \
  "$helper_block"
assert_contains_text \
  "R23 helper sleeps the configured delay before binding" \
  'sleep "$DELAY"' \
  "$helper_block"
assert_contains_text \
  "R23 helper binds the GPU via the bind script --bind-now" \
  '"$BIND_SCRIPT" --bind-now' \
  "$helper_block"
assert_contains_text \
  "R23 helper hot-attaches the GPU via virsh attach-device --live" \
  'virsh -c qemu:///system attach-device "$DOMAIN" "$GPU_XML" --live' \
  "$helper_block"
assert_contains_text \
  "R23 helper hot-attaches the audio function via virsh attach-device --live" \
  'attach-device "$DOMAIN" "$AUDIO_XML" --live' \
  "$helper_block"

# --- Static wiring: install_live_attach extracts hostdevs + flips conf + regenerates ---
assert_contains_file \
  "R23 install_live_attach requires python3" \
  'have_cmd python3 || die "python3 not available (needed to extract hostdev XML)."' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 install_live_attach extracts hostdev XML via python3" \
  'python3 - "$_tmp_vm" "$_tmp_gpu" "$_tmp_audio" "$GUEST_GPU_BDF"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 install_live_attach validates VM XML before redefine" \
  'virt-xml-validate "$_tmp_vm"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 install_live_attach appends VM to live-attach list" \
  'printf '\''%s\n'\'' "$_dom" >>"$LIVE_ATTACH_VM_LIST"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 install_live_attach flips VFIO_DYNAMIC_LIVE_ATTACH=1" \
  'rewrite_conf_key "VFIO_DYNAMIC_LIVE_ATTACH" "1"' \
  "$VFIO_SCRIPT"
# install_live_attach must reinstall the libvirt hook (deploys the live-attach
# branch + recreates the /etc/libvirt/hooks/qemu entry point) AND regenerate the
# bind script (the helper calls --bind-now). Without the hook reinstall, a hook
# written by an older vfio.sh would lack the live-attach branch, and a missing
# qemu entry would mean libvirt never invokes the hook at all.
_la_fn="$(sed -n '/^install_live_attach()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R23 install_live_attach calls install_libvirt_hook (deploys live-attach hook)" \
  'install_libvirt_hook' \
  "$_la_fn"
assert_contains_text \
  "R23 install_live_attach calls install_bind_script (helper uses --bind-now)" \
  'install_bind_script' \
  "$_la_fn"
assert_contains_file \
  "R23 install_live_attach regenerates the bind script" \
  'Regenerated $BIND_SCRIPT (bind logic for the live-attach helper)' \
  "$VFIO_SCRIPT"

# --- Static wiring: remove_live_attach cleans up + flips conf back ---
assert_contains_file \
  "R23 remove_live_attach removes the helper script" \
  'run rm -f "$LIVE_ATTACH_HELPER"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 remove_live_attach flips VFIO_DYNAMIC_LIVE_ATTACH=0" \
  'rewrite_conf_key "VFIO_DYNAMIC_LIVE_ATTACH" "0"' \
  "$VFIO_SCRIPT"

# --- Static wiring: install saves a per-VM XML backup; remove restores it ---
# install_live_attach removes the GPU hostdev from each VM's persistent XML so
# the VM boots on a virtual display; it MUST save a full pre-live-attach backup
# (with the GPU) per VM so the revert path can re-attach the GPU automatically
# instead of leaving the VM permanently GPU-less.
assert_contains_text \
  "R23 install_live_attach saves per-VM pre-live-attach XML backup" \
  'live-attach-backup-$_dom.xml' \
  "$_la_fn"
assert_contains_text \
  "R23 install_live_attach writes backup atomically (write_file_atomic)" \
  'write_file_atomic "$_backup_xml"' \
  "$_la_fn"
# remove_live_attach must restore each VM's XML from the backup BEFORE deleting
# it (only shut-off VMs; virsh define requires it), then clean up the backups.
_rm_la_fn="$(sed -n '/^remove_live_attach()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R23 remove_live_attach restores VM XML from pre-live-attach backup" \
  'virsh -c qemu:///system define "$_backup_xml"' \
  "$_rm_la_fn"
assert_contains_text \
  "R23 remove_live_attach validates backup before restore" \
  'virt-xml-validate "$_backup_xml"' \
  "$_rm_la_fn"
assert_contains_text \
  "R23 remove_live_attach only restores shut-off VMs" \
  '[[ "$_state" != "shut off" ]]' \
  "$_rm_la_fn"
assert_contains_text \
  "R23 remove_live_attach removes per-VM backup files (glob)" \
  'live-attach-backup-*.xml' \
  "$_rm_la_fn"

# --- Static wiring: reset + early-binding call remove_live_attach ---
_reset_fn="$(sed -n '/^reset_vfio_all()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R23 reset calls remove_live_attach before deleting CONF_FILE" \
  'remove_live_attach' \
  "$_reset_fn"
assert_contains_file \
  "R23 reset rm -f includes all live-attach artifacts" \
  '"$LIVE_ATTACH_HELPER" "$LIVE_ATTACH_GPU_XML" "$LIVE_ATTACH_AUDIO_XML" "$LIVE_ATTACH_VM_LIST"' \
  "$VFIO_SCRIPT"
_early_fn="$(sed -n '/^install_early_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R23 install-early-binding calls remove_live_attach" \
  'remove_live_attach' \
  "$_early_fn"

# --- Static wiring: fish/bash/zsh completions cover --install-live-attach ---
assert_contains_file \
  "R23 fish completion includes --install-live-attach" \
  'complete -c $cmd -l install-live-attach' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 bash completion opts include --install-live-attach" \
  '--install-early-binding --install-live-attach --install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 zsh completion includes --install-live-attach" \
  "'--install-live-attach[" \
  "$VFIO_SCRIPT"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'R23 live-attach regression checks passed.\n'
