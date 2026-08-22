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
# CRITICAL anti-deadlock: the hook MUST launch the helper FULLY DETACHED
# (setsid + </dev/null + >>log 2>&1) so the helper does NOT hold the hook's
# stdout/stderr pipe open. libvirt waits for that pipe to reach EOF before
# starting qemu; a plain `&` child inherits the fds, keeping the pipe open, so
# libvirt blocks until the helper exits — and the helper's attach-device --live
# blocks waiting for the VM to be running. DEADLOCK (observed: VM started 92s
# late, the instant the helper timed out). setsid + fd redirects close the pipe
# immediately so qemu starts at once.
assert_contains_text \
  "R23 hook detaches helper with setsid (anti-deadlock)" \
  'setsid /usr/local/sbin/vfio-live-attach.sh' \
  "$hook_block"
assert_contains_text \
  "R23 hook redirects helper stdin off the libvirt pipe" \
  '</dev/null >>/var/log/vfio-live-attach.log 2>&1 &' \
  "$hook_block"
if grep -Fq 'vfio-live-attach.sh "$DOMAIN" "$_la_delay" &' <<<"$hook_block"; then
  printf 'FAIL: R23 hook still launches helper with a bare & (deadlock: holds libvirt pipe open)\n' >&2
  record_failure "R23 hook does not launch helper with a bare &"
else
  printf 'PASS: R23 hook does not launch helper with a bare &\n'
fi
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
  "R23 helper polls guest-ping for Windows readiness (smart detection)" \
  'qemu-agent-command "$DOMAIN"' \
  "$helper_block"
assert_contains_text \
  "R23 helper uses guest-ping as the readiness probe" \
  '{"execute":"guest-ping"}' \
  "$helper_block"
assert_contains_text \
  "R23 helper binds immediately when the guest agent responds" \
  'guest agent responded after ${_elapsed}s' \
  "$helper_block"
assert_contains_text \
  "R23 helper falls back to fixed delay when agent is absent" \
  'guest agent did not respond within' \
  "$helper_block"
# The guest-ping loop MUST use WALL-CLOCK elapsed time (date +%s), not a counter
# that increments by 3 — each iteration takes up to 8s (5s virsh timeout + 3s
# sleep), so a counter made a 30s ceiling take ~80s real time (observed in the
# journal: 22:02:34 -> 22:03:54). Wall-clock makes DELAY mean what it says.
assert_contains_text \
  "R23 helper guest-ping loop uses wall-clock time (date +%s)" \
  '_start="$(date +%s)"' \
  "$helper_block"
assert_contains_text \
  "R23 helper guest-ping loop computes elapsed from wall clock" \
  '_elapsed=$((_now - _start))' \
  "$helper_block"
# Anti-hang: the helper MUST wrap virsh attach-device in `timeout` (tunable via
# VFIO_DYNAMIC_LIVE_ATTACH_TIMEOUT, default 60) so a hung attach (guest PCI
# address conflict, vfio reset hang) can NEVER block libvirt's VM lock
# indefinitely (observed: a stuck attach-device held the lock for minutes so
# every other virsh call, including VM start, queued behind it). 60s not 30s
# because the RX 9070 attach reset + Gen5 retrain can take >30s.
assert_contains_text \
  "R23 helper uses tunable attach timeout (VFIO_DYNAMIC_LIVE_ATTACH_TIMEOUT)" \
  '_la_timeout="${VFIO_DYNAMIC_LIVE_ATTACH_TIMEOUT:-60}"' \
  "$helper_block"
assert_contains_text \
  "R23 helper times out the GPU attach-device (anti-hang)" \
  'timeout "$_la_timeout" virsh -c qemu:///system attach-device "$DOMAIN" "$GPU_XML" --live' \
  "$helper_block"
assert_contains_text \
  "R23 helper times out the audio attach-device (anti-hang)" \
  'timeout "$_la_timeout" virsh -c qemu:///system attach-device "$DOMAIN" "$AUDIO_XML" --live' \
  "$helper_block"
# The helper MUST use [[ -s ]] (non-empty), not [[ -f ]] (exists), for the GPU
# and audio XML — an empty/stale file makes virsh attach-device hang on empty
# input and block libvirt.
assert_contains_text \
  "R23 helper guards GPU attach with -s (non-empty) not -f" \
  'if [[ -s "$GPU_XML" ]]; then' \
  "$helper_block"
assert_contains_text \
  "R23 helper guards audio attach with -s (non-empty) not -f" \
  'if [[ -s "$AUDIO_XML" ]]; then' \
  "$helper_block"
assert_contains_text \
  "R23 helper logs a timeout-specific failure message (rc 124)" \
  'virsh attach-device timed out after ${_la_timeout}s' \
  "$helper_block"
if grep -Fq 'if [[ -f "$GPU_XML" ]]; then' <<<"$helper_block"; then
  printf 'FAIL: R23 helper still uses -f for GPU_XML (empty file would hang libvirt)\n' >&2
  record_failure "R23 helper does not use -f for GPU_XML"
else
  printf 'PASS: R23 helper does not use -f for GPU_XML\n'
fi
# write_conf must persist the tunable timeout default.
assert_contains_file \
  "R23 write_conf emits VFIO_DYNAMIC_LIVE_ATTACH_TIMEOUT default (60)" \
  'VFIO_DYNAMIC_LIVE_ATTACH_TIMEOUT="60"' \
  "$VFIO_SCRIPT"
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
# The helper MUST capture and log the bind script's full output on failure so a
# bind-script bug surfaces in the journal instead of being swallowed (a swallowed
# stderr left us blind to the say() semicolon bug for an entire session — the
# helper reported "FAILED to bind GPU" with no cause).
assert_contains_text \
  "R23 helper captures bind output in _bind_out" \
  '_bind_out="$' \
  "$helper_block"
assert_contains_text \
  "R23 helper logs each bind output line on failure" \
  'jlog "live-attach: bind: $_line"' \
  "$helper_block"
# The generated bind script's say() must use a SPACE (printf '%s\n' "$*"), not
# a semicolon (printf '%s\n'; "$*"). The semicolon form executes the message as
# a command (exit 127) and set -e kills the script before the bind — which made
# --bind-now abort every live-attach attempt with a swallowed error.
bind_block="$(sed -n '/write_file_atomic "$BIND_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R23 bind script say() uses space (correct form)" \
  "printf '%s\\n' \"\$*\"" \
  "$bind_block"
if grep -Fq "printf '%s\\n'; \"\$*\"" <<<"$bind_block"; then
  printf 'FAIL: R23 bind script say() uses semicolon (executes messages as commands)\n' >&2
  record_failure "R23 bind script say() does not use semicolon form"
else
  printf 'PASS: R23 bind script say() does not use semicolon form\n'
fi

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
# The python3 hostdev extractor must use _strip0x (strips only the '0x' prefix),
# NOT lstrip('0x') (strips ALL leading 0/x chars — function='0x0' becomes '',
# the BDF becomes '0000:0e:00.' and the GPU never matches, so it is never
# extracted from the VM XML and qemu attaches it at boot anyway, defeating
# live-attach entirely).
assert_contains_file \
  "R23 python extractor uses _strip0x helper" \
  'def _strip0x(v):' \
  "$VFIO_SCRIPT"
if grep -Fq "lstrip('0x')" "$VFIO_SCRIPT"; then
  printf 'FAIL: R23 python extractor still uses lstrip(0x0) (strips all 0/x chars, breaks function=0x0 match)\n' >&2
  record_failure "R23 python extractor does not use lstrip(0x0)"
else
  printf 'PASS: R23 python extractor does not use lstrip(0x0)\n'
fi
# The python extractor MUST strip the fixed GUEST PCI address (<address type='pci'>
# directly under the hostdev) so libvirt auto-assigns a free guest address on
# hot-attach — a fixed guest address can collide with an existing device in the
# running VM and make virsh attach-device hang (the libvirt-lock-hang root cause).
assert_contains_file \
  "R23 python extractor strips fixed guest PCI address" \
  'def _strip_guest_addr(hd):' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 python extractor calls _strip_guest_addr on the GPU hostdev" \
  '_strip_guest_addr(gpu_hostdev)' \
  "$VFIO_SCRIPT"
# virsh attach-device wants a BARE <hostdev> element as the XML root, NOT
# wrapped in <devices>. A <devices> root makes attach-device reject it with
# "unsupported configuration: unknown device type 'devices'" (observed: instant
# rc=1 failure). The python extractor MUST write the hostdev directly.
assert_contains_file \
  "R23 python writes bare GPU hostdev (no <devices> wrapper)" \
  'ET.ElementTree(gpu_hostdev).write(gpu_path)' \
  "$VFIO_SCRIPT"
if grep -Fq "gpu_el = ET.Element('devices')" "$VFIO_SCRIPT"; then
  printf 'FAIL: R23 python still wraps GPU XML in <devices> (virsh attach-device rejects it)\n' >&2
  record_failure "R23 python does not wrap GPU XML in <devices>"
else
  printf 'PASS: R23 python does not wrap GPU XML in <devices>\n'
fi
# The install MUST fail loudly when the GPU device XML extraction produces an
# empty file instead of silently shipping a broken live-attach with nothing to
# hot-attach (the helper would then hang or abort at VM start time).
assert_contains_file \
  "R23 install_live_attach fails loudly on empty GPU extraction" \
  'GPU device XML extraction failed' \
  "$VFIO_SCRIPT"
# install_live_attach must auto-inject the qemu guest-agent channel (virtio-serial
# + unix channel) into the VM XML so the live-attach helper has a transport for
# guest-ping (smart Windows-readiness detection). Without it the helper can
# only fall back to the blind fixed delay. Idempotent: skipped if already present.
assert_contains_file \
  "R23 python injector adds guest-agent channel target" \
  "'org.qemu.guest_agent.0'" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 python injector adds virtio-serial controller" \
  "'virtio-serial'" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 python injector is idempotent (checks existing channel first)" \
  '_has_ga = any' \
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
  '--install-early-binding --install-live-attach --install-virtio-win-guest-agent --install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
# R27 inserted --install-virtio-win-guest-agent between --install-live-attach and
# --install-stealth-vm-tuning in the bash opts string, so the ordered pattern above
# now includes that token (additive update; the R27 assertion below also covers it).
assert_contains_file \
  "R23 zsh completion includes --install-live-attach" \
  "'--install-live-attach[" \
  "$VFIO_SCRIPT"

# --- R26: install_live_attach is idempotent on an already-active setup ---
# A re-run of --install-live-attach (or accepting the R25 dynamic-install prompt)
# when live-attach is ALREADY active finds no shut-off VM with the GPU hostdev
# because a prior install already stripped it from the VM XML(s) and saved the
# device XML. Without idempotency that prints a confusing "No shut-off VMs found"
# error and returns 1 even though live-attach is healthy. R26 detects the
# already-active state (conf=1 + helper installed + non-empty VM list + GPU
# device XML -- all four = a prior successful install) and prints the same green
# "Live-attach is already active" banner the first install prints, returning 0 so
# callers see success. A partial/half-installed state still falls through to the
# original actionable error.
assert_contains_text \
  "R26 install_live_attach prints already-active confirmation banner" \
  'Live-attach is already active' \
  "$_la_fn"
assert_contains_text \
  "R26 idempotency gates on the helper being installed" \
  '-f "$LIVE_ATTACH_HELPER"' \
  "$_la_fn"
assert_contains_text \
  "R26 idempotency gates on a non-empty live-attach VM list" \
  '-s "$LIVE_ATTACH_VM_LIST"' \
  "$_la_fn"
assert_contains_text \
  "R26 idempotency gates on the GPU device XML existing" \
  '-s "$LIVE_ATTACH_GPU_XML"' \
  "$_la_fn"
assert_contains_text \
  "R26 idempotency gates on VFIO_DYNAMIC_LIVE_ATTACH=1 in conf" \
  'VFIO_DYNAMIC_LIVE_ATTACH="1"' \
  "$_la_fn"
assert_contains_text \
  "R26 idempotency returns 0 so callers see success" \
  'return 0' \
  "$_la_fn"
assert_contains_text \
  "R26 keeps the actionable fallback for a partial/half-installed state" \
  'No shut-off VMs with the guest GPU found' \
  "$_la_fn"

# --- R27: virtio-win guest-agent installer + hotplug-ready desktop notification ---
# --install-virtio-win-guest-agent resolves the virtio-win driver ISO (distro package
# or stable download) and attaches it as a SATA CD-ROM to each guest-GPU VM (idempotent)
# so the operator can run virtio-win-guest-tools.exe inside Windows to install the QEMU
# guest agent. With the agent installed, the live-attach helper's guest-ping poll hot-
# attaches the GPU the MOMENT Windows is up instead of after the blind fixed delay; the
# fixed-delay FALLBACK still works until the agent is installed. The live-attach helper
# also fires a desktop notification (notify-send via runuser to each /run/user/<uid>)
# when the GPU hot-plug is ready to use, and on bind/attach/missing-XML failures.

# Constants for the virtio-win ISO resolution.
assert_contains_file \
  "R27 VIRTIO_WIN_ISO_PATH constant defined" \
  'VIRTIO_WIN_ISO_PATH="/usr/share/virtio-win/virtio-win.iso"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 VIRTIO_WIN_FALLBACK_ISO constant defined" \
  'VIRTIO_WIN_FALLBACK_ISO="/var/lib/vfio-dynamic/virtio-win.iso"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 VIRTIO_WIN_STABLE_URL constant defined" \
  'VIRTIO_WIN_STABLE_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"' \
  "$VFIO_SCRIPT"

# install_virtio_win_guest_agent function defined + body wiring.
assert_contains_file \
  "R27 install_virtio_win_guest_agent function defined" \
  'install_virtio_win_guest_agent()' \
  "$VFIO_SCRIPT"
_vw_fn="$(sed -n '/^install_virtio_win_guest_agent()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R27 install_virtio_win_guest_agent requires python3" \
  'have_cmd python3 || die "python3 not available (needed to attach the ISO to the VM XML)."' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent prefers the distro ISO path" \
  '-f "$VIRTIO_WIN_ISO_PATH"' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent dnf-installs virtio-win as fallback" \
  'dnf -y install virtio-win' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent zypper-installs virtio-win as fallback" \
  'zypper --non-interactive in virtio-win' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent wget-downloads the stable ISO" \
  'wget -qO "$VIRTIO_WIN_FALLBACK_ISO" "$VIRTIO_WIN_STABLE_URL"' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent curl-downloads the stable ISO" \
  'curl -fsSL -o "$VIRTIO_WIN_FALLBACK_ISO" "$VIRTIO_WIN_STABLE_URL"' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent attaches a cdrom disk" \
  "'device': 'cdrom'" \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent attaches via SATA bus" \
  "'bus': 'sata'" \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent idempotent (python exit 3 on already-attached ISO)" \
  'sys.exit(3)' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent exits 4 when no free vdX target" \
  'sys.exit(4)' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent finds a free vdX target" \
  'string.ascii_lowercase' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent validates VM XML before redefine" \
  'virt-xml-validate "$_tmp_vm"' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent only attaches shut-off VMs" \
  '[[ "$_state" != "shut off" ]]' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent qualifies VM by guest GPU BDF" \
  'grep -Fixq "$_gpu_bdf"' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent qualifies VM by live-attach VM list" \
  'grep -Fixq "$_dom" "$_la_list"' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent prints the Windows guest-tools instructions" \
  'virtio-win-guest-tools.exe' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent prints the silent-install MSI alternative" \
  'virtio-win-gt-x64.msi' \
  "$_vw_fn"
assert_contains_text \
  "R27 install_virtio_win_guest_agent notes the fixed-delay FALLBACK still works" \
  'FALLBACK still works' \
  "$_vw_fn"

# --install-virtio-win-guest-agent CLI mode + dispatch + completions + usage.
assert_contains_file \
  "R27 parse_args handles --install-virtio-win-guest-agent" \
  '--install-virtio-win-guest-agent)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 parse_args sets MODE=install-virtio-win-guest-agent" \
  'MODE="install-virtio-win-guest-agent"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 main dispatch wires install-virtio-win-guest-agent" \
  '[[ "$MODE" == "install-virtio-win-guest-agent" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 MODE comment lists install-virtio-win-guest-agent" \
  'install-virtio-win-guest-agent | completion printers' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 usage help documents --install-virtio-win-guest-agent" \
  'Attach the virtio-win driver ISO to each guest-GPU VM' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 usage one-liner includes --install-virtio-win-guest-agent" \
  '[--install-live-attach] [--install-virtio-win-guest-agent]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 fish completion includes --install-virtio-win-guest-agent" \
  'complete -c $cmd -l install-virtio-win-guest-agent' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 bash completion opts include --install-virtio-win-guest-agent" \
  '--install-live-attach --install-virtio-win-guest-agent --install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 zsh completion includes --install-virtio-win-guest-agent" \
  "'--install-virtio-win-guest-agent[" \
  "$VFIO_SCRIPT"

# Hotplug-ready desktop notification in the live-attach helper heredoc.
assert_contains_text \
  "R27 helper defines _notify_desktop" \
  '_notify_desktop()' \
  "$helper_block"
assert_contains_text \
  "R27 helper notify uses notify-send" \
  'notify-send' \
  "$helper_block"
assert_contains_text \
  "R27 helper notify reaches user sessions via runuser" \
  'runuser' \
  "$helper_block"
assert_contains_text \
  "R27 helper notifies GPU hot-plug ready on success" \
  'GPU hot-plug ready' \
  "$helper_block"
assert_contains_text \
  "R27 helper success notification body mentions hot-attach to VM" \
  'hot-attached to VM' \
  "$helper_block"
assert_contains_text \
  "R27 helper notifies GPU hot-plug failed on failure" \
  'GPU hot-plug failed' \
  "$helper_block"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'R23 live-attach regression checks passed.\n'
