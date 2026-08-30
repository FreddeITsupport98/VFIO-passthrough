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
  '--install-early-binding --install-live-attach --live-attach-on --live-attach-off --live-attach-toggle --live-attach-status --install-virtio-win-guest-agent --install-looking-glass --remove-looking-glass --install-looking-glass-client --remove-looking-glass-client --menu --install-self --uninstall-self --install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
# R27 inserted --install-virtio-win-guest-agent between --install-live-attach and
# --install-stealth-vm-tuning in the bash opts string, so the ordered pattern above
# now includes that token (additive update; the R27 assertion below also covers it).
# R33 inserted --menu between --install-virtio-win-guest-agent and --install-stealth-
# vm-tuning, so both ordered bash-opts patterns above now include the --menu token too.
# R34 inserted --install-self --uninstall-self between --menu and --install-stealth-vm-
# tuning, so the ordered bash-opts patterns above now include those two tokens too.
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
# R30: on Fedora, virtio-win is NOT in the default repos — the script adds the
# fedorapeople repo first, then `dnf install virtio-win` (the proven fix).
assert_contains_text \
  "R30 adds the virtio-win repo on Fedora before dnf install" \
  'curl -fsSL -o /etc/yum.repos.d/virtio-win.repo "$VIRTIO_WIN_REPO_URL"' \
  "$_vw_fn"
assert_contains_text \
  "R30 picks up a user-provided ISO at the fallback path" \
  'Found virtio-win ISO (user-provided)' \
  "$_vw_fn"
assert_contains_text \
  "R30 points the operator to download the ISO themselves (no auto-download)" \
  'Download it yourself' \
  "$_vw_fn"
# R30: the 270MB ISO auto-download was REMOVED. Negative assertion: neither
# wget nor curl may download the ISO to VIRTIO_WIN_FALLBACK_ISO anymore.
if printf '%s\n' "$_vw_fn" | grep -Fq 'wget -qO "$VIRTIO_WIN_FALLBACK_ISO"'; then
  printf 'FAIL: R30 still auto-downloads the ISO via wget\n' >&2
  record_failure "R30 does not auto-download the ISO via wget"
else
  printf 'PASS: R30 does not auto-download the ISO via wget\n'
fi
if printf '%s\n' "$_vw_fn" | grep -Fq 'curl -fsSL -o "$VIRTIO_WIN_FALLBACK_ISO"'; then
  printf 'FAIL: R30 still auto-downloads the ISO via curl\n' >&2
  record_failure "R30 does not auto-download the ISO via curl"
else
  printf 'PASS: R30 does not auto-download the ISO via curl\n'
fi
# R30 new constants.
assert_contains_file \
  "R30 VIRTIO_WIN_REPO_URL constant defined" \
  'VIRTIO_WIN_REPO_URL="https://fedorapeople.org/groups/virt/virtio-win/virtio-win.repo"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R30 VIRTIO_WIN_RPM_URL constant defined" \
  'VIRTIO_WIN_RPM_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.noarch.rpm"' \
  "$VFIO_SCRIPT"
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
  'install-virtio-win-guest-agent | install-ultimate-perf-vm-tuning | reset-ultimate-perf-vm-tuning | install-looking-glass | remove-looking-glass | install-looking-glass-client | remove-looking-glass-client | menu | install-self | uninstall-self | completion printers' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 usage help documents --install-virtio-win-guest-agent" \
  'Attach the virtio-win driver ISO to each guest-GPU VM' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 usage one-liner includes --install-virtio-win-guest-agent" \
  '[--install-live-attach] [--live-attach-on] [--live-attach-off] [--live-attach-toggle] [--live-attach-status] [--install-virtio-win-guest-agent]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 fish completion includes --install-virtio-win-guest-agent" \
  'complete -c $cmd -l install-virtio-win-guest-agent' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 bash completion opts include --install-virtio-win-guest-agent" \
  '--install-live-attach --live-attach-on --live-attach-off --live-attach-toggle --live-attach-status --install-virtio-win-guest-agent --install-looking-glass --remove-looking-glass --install-looking-glass-client --remove-looking-glass-client --menu --install-self --uninstall-self --install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R27 zsh completion includes --install-virtio-win-guest-agent" \
  "'--install-virtio-win-guest-agent[" \
  "$VFIO_SCRIPT"

# --- R33: interactive --menu installer mode (pick an action from a TUI menu) ---
# --menu launches vfio_menu(): a whiptail TUI (select_from_list) + plain-text
# fallback that loops back after each action, so the operator can configure /
# switch binding / live-attach / virtio-win / stealth / verify / detect / reset
# without running the whole wizard or remembering individual flags. The dispatch
# requires root + writable-root in main() (preserves --menu across the sudo
# re-exec that require_root performs); read-only actions run inside the menu.
assert_contains_file \
  "R33 vfio_menu function defined" \
  'vfio_menu()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 parse_args handles --menu" \
  '--menu)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 parse_args sets MODE=menu" \
  'MODE="menu"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 MODE comment lists menu" \
  'menu | install-self | uninstall-self | completion printers' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 main dispatch wires menu" \
  '[[ "$MODE" == "menu" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 usage help documents --menu" \
  'Interactive menu' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 usage one-liner includes --menu" \
  '[--install-virtio-win-guest-agent] [--install-looking-glass] [--remove-looking-glass] [--install-looking-glass-client] [--remove-looking-glass-client] [--menu]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 fish completion includes --menu" \
  'complete -c $cmd -l menu' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 bash completion opts include --menu" \
  '--install-virtio-win-guest-agent --install-looking-glass --remove-looking-glass --install-looking-glass-client --remove-looking-glass-client --menu --install-self --uninstall-self --install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R33 zsh completion includes --menu" \
  "'--menu[" \
  "$VFIO_SCRIPT"
_menu_fn="$(sed -n '/^vfio_menu()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R33 vfio_menu loops back after each action" \
  'Returning to menu' \
  "$_menu_fn"
assert_contains_text \
  "R33 vfio_menu offers a full-configure (wizard) option" \
  'apply_configuration' \
  "$_menu_fn"
assert_contains_text \
  "R33 vfio_menu dispatches dynamic binding" \
  'install_dynamic_binding_from_existing_config' \
  "$_menu_fn"
assert_contains_text \
  "R33 vfio_menu dispatches live-attach" \
  'install_live_attach' \
  "$_menu_fn"
assert_contains_text \
  "R33 vfio_menu dispatches verify (read-only)" \
  'verify_setup' \
  "$_menu_fn"
assert_contains_text \
  "R33 vfio_menu dispatches reset" \
  'reset_vfio_all' \
  "$_menu_fn"
assert_contains_text \
  "R33 vfio_menu has an Exit option" \
  'Exiting vfio.sh menu.' \
  "$_menu_fn"

# --- R34: self-install (--install-self/--uninstall-self) + config pickup ---
# --install-self copies this script to /usr/local/bin/vfio (on PATH as vfio) and
# drops the fish/bash/zsh completions into their vendor auto-load dirs (no
# 'source' needed). --uninstall-self removes both (separate from --reset).
# maybe_pickup_leftover_conf: when $CONF_FILE is missing but a .bak.* exists,
# offer to restore the SAME config + re-apply binding instead of re-running the
# wizard. Called from preflight_existing_config_gate (wizard + --menu option 0).
assert_contains_file \
  "R34 SELF_INSTALL_BIN constant defined" \
  'SELF_INSTALL_BIN="/usr/local/bin/vfio"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 FISH_COMPLETION_DIR constant defined" \
  'FISH_COMPLETION_DIR="/usr/share/fish/vendor_completions.d"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 BASH_COMPLETION_DIR constant defined" \
  'BASH_COMPLETION_DIR="/usr/share/bash-completion/completions"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 ZSH_COMPLETION_DIR constant defined" \
  'ZSH_COMPLETION_DIR="/usr/share/zsh/site-functions"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 install_self function defined" \
  'install_self()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 uninstall_self function defined" \
  'uninstall_self()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 maybe_pickup_leftover_conf function defined" \
  'maybe_pickup_leftover_conf()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 parse_args handles --install-self" \
  '--install-self)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 parse_args sets MODE=install-self" \
  'MODE="install-self"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 parse_args handles --uninstall-self" \
  '--uninstall-self)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 parse_args sets MODE=uninstall-self" \
  'MODE="uninstall-self"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 MODE comment lists install-self | uninstall-self" \
  'menu | install-self | uninstall-self | completion printers' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 main dispatch wires install-self" \
  '[[ "$MODE" == "install-self" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 main dispatch wires uninstall-self" \
  '[[ "$MODE" == "uninstall-self" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 usage help documents --install-self" \
  'Install this script to /usr/local/bin/vfio' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 usage one-liner includes --install-self/--uninstall-self" \
  '[--install-self] [--uninstall-self]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 fish completion includes --install-self" \
  'complete -c $cmd -l install-self' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 fish completion includes --uninstall-self" \
  'complete -c $cmd -l uninstall-self' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 bash completion opts include --install-self --uninstall-self" \
  '--menu --install-self --uninstall-self --install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R34 zsh completion includes --install-self" \
  "'--install-self[" \
  "$VFIO_SCRIPT"
_self_fn="$(sed -n '/^install_self()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R34 install_self copies to SELF_INSTALL_BIN" \
  'cp -a "$src" "$SELF_INSTALL_BIN"' \
  "$_self_fn"
assert_contains_text \
  "R34 install_self chmods 0755" \
  'chmod 0755 "$SELF_INSTALL_BIN"' \
  "$_self_fn"
assert_contains_text \
  "R34 install_self has a same-file guard" \
  '-ef "$SELF_INSTALL_BIN"' \
  "$_self_fn"
assert_contains_text \
  "R34 install_self installs fish completion" \
  'print_fish_completion >"$_fc"' \
  "$_self_fn"
assert_contains_text \
  "R34 install_self installs bash completion" \
  'print_bash_completion >"$_fc"' \
  "$_self_fn"
assert_contains_text \
  "R34 install_self installs zsh completion" \
  'print_zsh_completion >"$_fc"' \
  "$_self_fn"
_unself_fn="$(sed -n '/^uninstall_self()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R34 uninstall_self removes the installed script" \
  'rm -f "$SELF_INSTALL_BIN"' \
  "$_unself_fn"
assert_contains_text \
  "R34 uninstall_self prompts before removing" \
  'prompt_yn "Uninstall the self-installed vfio + completions now?"' \
  "$_unself_fn"
_pickup_fn="$(sed -n '/^maybe_pickup_leftover_conf()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R34 pickup globs newest conf backup" \
  '"${CONF_FILE}".bak.*' \
  "$_pickup_fn"
assert_contains_text \
  "R34 pickup reads guest GPU from backup without sourcing" \
  '/^GUEST_GPU_BDF=/' \
  "$_pickup_fn"
assert_contains_text \
  "R34 pickup restores the backup to CONF_FILE" \
  'cp -a "$_bak" "$CONF_FILE"' \
  "$_pickup_fn"
assert_contains_text \
  "R34 pickup re-applies dynamic binding" \
  'install_dynamic_binding_from_existing_config' \
  "$_pickup_fn"
assert_contains_text \
  "R34 pickup re-applies early binding" \
  'install_early_binding_from_existing_config' \
  "$_pickup_fn"
assert_contains_text \
  "R34 pickup prompts (default Y) to restore" \
  'instead of re-running the wizard?" Y "Config pickup"' \
  "$_pickup_fn"
_preflight_fn="$(sed -n '/^preflight_existing_config_gate()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R34 preflight calls maybe_pickup_leftover_conf" \
  'maybe_pickup_leftover_conf' \
  "$_preflight_fn"
_reset_fn2="$(sed -n '/^reset_vfio_all()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R34 reset hints at --uninstall-self" \
  '--uninstall-self' \
  "$_reset_fn2"
# --- R37: --reset removes ALL stealth/perf backups + --full also removes the CLI ---
# reset_vfio_all now calls _remove_vm_tuning_backups (wipes fixed-name + legacy
# ~/Desktop timestamped stealth/perf XML backups) and accepts a 'full' arg that
# also removes the self-installed vfio CLI + completions (repo script untouched).
assert_contains_file \
  "R37 _remove_vm_tuning_backups helper defined" \
  '_remove_vm_tuning_backups()' \
  "$VFIO_SCRIPT"
assert_contains_text \
  "R37 reset calls _remove_vm_tuning_backups" \
  '_remove_vm_tuning_backups' \
  "$_reset_fn2"
# The backup-removal globs live in _remove_vm_tuning_backups (called by reset),
# so extract that helper and assert the legacy ~/Desktop globs are present.
_rm_bak_fn="$(sed -n '/^_remove_vm_tuning_backups()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R37 reset helper removes legacy ~/Desktop timestamped stealth backups" \
  '*_stealth_*.xml' \
  "$_rm_bak_fn"
assert_contains_text \
  "R37 reset helper removes legacy ~/Desktop timestamped perf backups" \
  '*_perf_*.xml' \
  "$_rm_bak_fn"
assert_contains_text \
  "R37 reset full-arg removes the self-installed CLI" \
  'rm -f "$SELF_INSTALL_BIN"' \
  "$_reset_fn2"
assert_contains_text \
  "R37 reset full-arg removes fish completion" \
  'FISH_COMPLETION_DIR}/${_installed_cmd}.fish' \
  "$_reset_fn2"
assert_contains_file \
  "R37 RESET_FULL var declared" \
  'RESET_FULL=0' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R37 parse_args handles --full" \
  '--full)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R37 usage one-liner includes --full" \
  '[--full]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R37 fish completion includes --full" \
  'complete -c $cmd -l full' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R37 zsh completion includes --full" \
  "'--full[" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R37 bash completion opts include --full" \
  '--reset --full --reset-usb-mitigation' \
  "$VFIO_SCRIPT"
# The mid-wizard preflight reset (preflight_existing_config_gate) must stay
# SCOPED (no 'full' arg) so it does not nuke the CLI the user is configuring with.
_preflight_reset_fn="$(sed -n '/^preflight_existing_config_gate()/,/^}/p' "$VFIO_SCRIPT")"
_preflight_resets="$(printf '%s\n' "$_preflight_reset_fn" | grep -cF 'reset_vfio_all')"
if (( _preflight_resets >= 1 )); then
  printf 'PASS: R37 preflight reset calls reset_vfio_all (%d call(s))\n' "$_preflight_resets"
else
  printf 'FAIL: R37 preflight reset does not call reset_vfio_all\n' >&2
  record_failure "R37 preflight reset calls reset_vfio_all"
fi
if printf '%s\n' "$_preflight_reset_fn" | grep -Fq 'reset_vfio_all full'; then
  printf 'FAIL: R37 preflight reset passes full (would nuke the CLI mid-wizard)\n' >&2
  record_failure "R37 preflight reset stays scoped (no full arg)"
else
  printf 'PASS: R37 preflight reset stays scoped (no full arg)\n'
fi

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

# --- R28: virtio-win guest-agent uninstaller (ISO CD-ROM detach) + archive link ---
# remove_virtio_win_guest_agent detaches the script-attached virtio-win ISO CD-ROM
# from each shut-off VM and removes the downloaded fallback ISO. Wired into
# remove_live_attach so --reset and --install-early-binding both clean it. SAFETY:
# only removes a cdrom whose source file is one of the two script-managed ISO paths
# (never a real ODD / different ISO); the distro ISO is never deleted.
assert_contains_file \
  "R28 remove_virtio_win_guest_agent function defined" \
  'remove_virtio_win_guest_agent()' \
  "$VFIO_SCRIPT"
assert_contains_text \
  "R28 remove_live_attach calls remove_virtio_win_guest_agent" \
  'remove_virtio_win_guest_agent' \
  "$_rm_la_fn"
_vw_rm_fn="$(sed -n '/^remove_virtio_win_guest_agent()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R28 detach matches device=cdrom" \
  "d.get('device') == 'cdrom'" \
  "$_vw_rm_fn"
assert_contains_text \
  "R28 detach matches only the script-managed ISO source paths" \
  "src.get('file') in iso_paths" \
  "$_vw_rm_fn"
assert_contains_text \
  "R28 detach is idempotent (exit 3 when not attached)" \
  'sys.exit(3)' \
  "$_vw_rm_fn"
assert_contains_text \
  "R28 detach removes the downloaded fallback ISO" \
  'rm -f "$VIRTIO_WIN_FALLBACK_ISO"' \
  "$_vw_rm_fn"
if printf '%s\n' "$_vw_rm_fn" | grep -Fq 'rm -f "$VIRTIO_WIN_ISO_PATH"'; then
  printf 'FAIL: R28 detach deletes the distro ISO (owned by the package manager)\n' >&2
  record_failure "R28 detach does not delete the distro ISO"
else
  printf 'PASS: R28 detach never deletes the distro ISO\n'
fi
assert_contains_file \
  "R28 VIRTIO_WIN_ARCHIVE_URL constant defined" \
  'VIRTIO_WIN_ARCHIVE_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/?C=M;O=A"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R28 archive link in manual-fallback note" \
  'All released ISOs (pick a specific version): $VIRTIO_WIN_ARCHIVE_URL' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R28 archive link in next-steps block" \
  'Driver ISO archive (all released versions, if you need a specific one):' \
  "$VFIO_SCRIPT"
_r28_sw_fn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R28 dynamic-setup rec mentions --install-virtio-win-guest-agent" \
  '--install-virtio-win-guest-agent' \
  "$_r28_sw_fn"
assert_contains_text \
  "R28 dynamic-setup rec shows the archive URL" \
  'VIRTIO_WIN_ARCHIVE_URL' \
  "$_r28_sw_fn"

# --- R28b: distro-aware virtio-win ISO resolution ---
# install_virtio_win_guest_agent must detect the distro and use the right package
# manager, naming the distro in the message. virtio-win ships as a package only on
# Fedora/RHEL-family (dnf) and openSUSE (zypper); apt/pacman have no official
# package -> skip to the download fallback with an explanation. On package-install
# failure the archive link must be shown so the operator can grab a specific ISO.
_vw_fn="$(sed -n '/^install_virtio_win_guest_agent()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R28b detects Fedora/RHEL-family via is_fedora_like (dnf)" \
  'is_fedora_like || have_cmd dnf' \
  "$_vw_fn"
assert_contains_text \
  "R28b detects openSUSE-family via is_opensuse_like (zypper)" \
  'is_opensuse_like || have_cmd zypper' \
  "$_vw_fn"
assert_contains_text \
  "R28b apt branch explains no official virtio-win package" \
  'NO official virtio-win package' \
  "$_vw_fn"
assert_contains_text \
  "R28b pacman branch explains no official virtio-win package" \
  'NO official virtio-win' \
  "$_vw_fn"
assert_contains_text \
  "R28b dnf-failure note points to the ISO archive link" \
  'grab a specific ISO version from: $VIRTIO_WIN_ARCHIVE_URL' \
  "$_vw_fn"
assert_contains_text \
  "R28b zypper-failure note points to the ISO archive link" \
  'zypper install virtio-win failed' \
  "$_vw_fn"

# --- R29: dynamic-binding RDNA4 rec wires the virtio-win ISO attach (opt-in + disclaimer) ---
# install_dynamic_binding_from_existing_config must actually CALL install_virtio_win_guest_agent
# as an opt-in (set-e-safe via `||`), not just print the flag string. It must be gated on
# live-attach being active (the guest agent only helps the live-attach helper's guest-ping),
# and include a DISCLAIMER that the ISO attach is host-side only (agent install is manual
# inside Windows).
_r29_sw_fn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R29 dynamic-setup rec calls install_virtio_win_guest_agent (opt-in, set-e-safe)" \
  'install_virtio_win_guest_agent || {' \
  "$_r29_sw_fn"
assert_contains_text \
  "R29 dynamic-setup rec gates the ISO attach on live-attach being active" \
  'VFIO_DYNAMIC_LIVE_ATTACH="1"' \
  "$_r29_sw_fn"
assert_contains_text \
  "R29 dynamic-setup rec includes the disclaimer (host-side ISO attach only)" \
  'does NOT install the agent into Windows' \
  "$_r29_sw_fn"
assert_contains_text \
  "R29 dynamic-setup rec notes the VM must be shut off for the attach" \
  'VM MUST be shut off for the attach' \
  "$_r29_sw_fn"
assert_contains_text \
  "R29 dynamic-setup rec notes the fixed-delay fallback still works" \
  'delay fallback still works' \
  "$_r29_sw_fn"

# --- R31: R26 idempotency path must regenerate the helper/hook/bind-script ---
# BUG: the R26 'already active' early-return used to return 0 BEFORE
# install_live_attach_helper, so a re-run on an already-active setup never
# regenerated the helper on disk -> the helper stayed stale (pre-R27, no
# _notify_desktop) and the hotplug-ready desktop notification never fired even
# though the attach succeeded (observed live: journal showed 'GPU attached
# successfully' but no notification popped). R31 fixes it: the already-active
# path now regenerates the helper + hook + bind-script before returning.
# Extract the R26 'already active' block and assert it deploys the helper.
_r26_block="$(sed -n '/Live-attach is already active/,/return 0/p' <<<"$_la_fn")"
assert_contains_text \
  "R31 R26 already-active path regenerates the live-attach helper" \
  'install_live_attach_helper' \
  "$_r26_block"
assert_contains_text \
  "R31 R26 already-active path reinstalls the libvirt hook" \
  'install_libvirt_hook' \
  "$_r26_block"
assert_contains_text \
  "R31 R26 already-active path regenerates the bind script" \
  'install_bind_script' \
  "$_r26_block"

# --- R32: SATA cdrom target naming (sdX, not vdX) + guarded virsh define ---
# BUG: the attach python picked a free vdX target (vda) for a SATA bus cdrom, but vdX is
# virtio-blk naming — SATA bus requires sdX (sda, sdb, sdc...). Libvirt rejected the
# define: 'duplicated address for disk with target name sda' (auto-assigned a colliding
# SATA drive address to the invalid vda-on-SATA disk). The script then died on `set -e`
# before printing 'Attached', so the operator saw no error and no cdrom. R32 fixes it:
# the python now finds a free sdX target (sdc after the existing sda/sdb).
assert_contains_text \
  "R32 attach python uses sdX target naming for the SATA cdrom" \
  "cand = 'sd' + c" \
  "$_vw_fn"
# Negative: the vdX target naming must be gone from the attach python.
if printf '%s\n' "$_vw_fn" | grep -Fq "cand = 'vd' + c"; then
  printf 'FAIL: R32 attach python still uses vdX target naming (causes libvirt address collision)\n' >&2
  record_failure "R32 attach python does not use vdX target for SATA cdrom"
else
  printf 'PASS: R32 attach python does not use vdX target for SATA cdrom\n'
fi
# The virsh define must be guarded so a failure is reported, not silently aborted by set -e.
assert_contains_text \
  "R32 attach guards the virsh define (reports failure instead of aborting)" \
  'virsh -c qemu:///system define "$_tmp_vm" 2>/dev/null || _define_rc=$?' \
  "$_vw_fn"

# --- R36: live-attach opt-out reverts an already-active setup (bug fix) ---
# BUG: in install_dynamic_binding_from_existing_config, selecting "no" at the
# RX 9070 live-attach prompt only printed skip notes and NEVER reverted an
# already-active live-attach setup -- so the VM stayed GPU-less (the hostdev
# was still stripped from the persistent XML) and the conf key stayed 1. The
# sibling opt-ins (vBIOS, stealth) both revert on "no"; live-attach was the
# inconsistent one. R36 mirrors them: a "no" (prompt) AND --no-live-attach
# both call remove_live_attach (restores the GPU hostdev to the VM XML from
# the per-VM backup, detaches the virtio-win ISO, flips the conf to 0). Also
# adds --live-attach / --no-live-attach override flags + LIVE_ATTACH_OVERRIDE
# var, and makes remove_live_attach best-effort (return 0) so the bare calls
# under set -e (dynamic opt-out, --install-early-binding, --reset) cannot
# abort mid-cleanup when live-attach was never active.
_r36_fn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_file \
  "R36 LIVE_ATTACH_OVERRIDE var declared" \
  'LIVE_ATTACH_OVERRIDE=""' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 parse_args handles --live-attach" \
  '--live-attach)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 parse_args handles --no-live-attach" \
  '--no-live-attach)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 usage one-liner includes --live-attach" \
  '[--live-attach]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 usage one-liner includes --no-live-attach" \
  '[--no-live-attach]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 fish completion includes --live-attach" \
  'complete -c $cmd -l live-attach' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 fish completion includes --no-live-attach" \
  'complete -c $cmd -l no-live-attach' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 bash completion opts include --live-attach --no-live-attach" \
  '--no-vbios --live-attach --no-live-attach --verify' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 zsh completion includes --live-attach" \
  "'--live-attach[" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R36 zsh completion includes --no-live-attach" \
  "'--no-live-attach[" \
  "$VFIO_SCRIPT"
# The dynamic installer must honor the override (force-on / force-skip+revert).
assert_contains_text \
  "R36 dynamic install honors LIVE_ATTACH_OVERRIDE force-on" \
  'LIVE_ATTACH_OVERRIDE:-}" == "1"' \
  "$_r36_fn"
assert_contains_text \
  "R36 dynamic install honors LIVE_ATTACH_OVERRIDE force-off (revert)" \
  'LIVE_ATTACH_OVERRIDE:-}" == "0"' \
  "$_r36_fn"
# The RX 9070 recommendation prompt must be gated on NO override given.
assert_contains_text \
  "R36 dynamic install gates the RX9070 prompt on no override" \
  '[[ -z "${LIVE_ATTACH_OVERRIDE:-}" ]] && _is_guest_rx9070_family' \
  "$_r36_fn"
# CRITICAL: the prompt "no" branch must revert (the bug fix). The override-0
# branch + the prompt-no branch = 2 remove_live_attach calls (the bug was 0).
assert_contains_text \
  "R36 dynamic install prompt-no branch says Skipping live-attach setup" \
  'Skipping live-attach setup.' \
  "$_r36_fn"
_r36_reverts="$(printf '%s\n' "$_r36_fn" | grep -cF 'remove_live_attach')"
if (( _r36_reverts >= 2 )); then
  printf 'PASS: R36 dynamic install reverts live-attach on opt-out (%d remove_live_attach calls)\n' "$_r36_reverts"
else
  printf 'FAIL: R36 dynamic install does NOT revert live-attach on opt-out (only %d remove_live_attach calls, expected >= 2)\n' "$_r36_reverts" >&2
  record_failure "R36 dynamic install reverts live-attach on opt-out"
fi
# remove_live_attach must be best-effort (return 0) so bare callers under set -e
# are not aborted when live-attach was never active (nothing to remove).
assert_contains_text \
  "R36 remove_live_attach returns 0 (best-effort cleanup)" \
  '  return 0' \
  "$_rm_la_fn"

# --- R41: system-tray on/off toggle + real mode switch (not backup-restore) ---
# A persisted on/off mode (VFIO_LIVE_ATTACH_MODE conf key + world-readable
# /var/lib/vfio-dynamic/live-attach-mode file) replaces the backup-restore
# toggle. install_live_attach keeps BOTH VM XML variants (with-gpu / without-
# gpu); live_attach_toggle virsh-defines the right one. A PySide6 QSystemTrayIcon
# applet (native SNI on KDE Plasma 6) toggles via zenity --question + pkexec +
# notify-send, with a polkit policy (auth_admin_keep) + per-user autostart.
assert_contains_file \
  "R41 LIVE_ATTACH_MODE_FILE constant defined" \
  'LIVE_ATTACH_MODE_FILE="/var/lib/vfio-dynamic/live-attach-mode"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 LIVE_ATTACH_TRAY constant defined" \
  'LIVE_ATTACH_TRAY="/usr/local/bin/vfio-hotplug-tray"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 LIVE_ATTACH_POLKIT constant defined" \
  'LIVE_ATTACH_POLKIT="/usr/share/polkit-1/actions/dev.vfio.live-attach-toggle.policy"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 LIVE_ATTACH_POLKIT_ACTION constant defined" \
  'LIVE_ATTACH_POLKIT_ACTION="dev.vfio.live-attach-toggle"' \
  "$VFIO_SCRIPT"
# Mode helpers + toggle + status + tray install/remove functions defined.
assert_contains_file \
  "R41 _la_read_mode helper defined" \
  '_la_read_mode()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 _la_write_mode helper defined" \
  '_la_write_mode()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 live_attach_toggle function defined" \
  'live_attach_toggle()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 live_attach_status function defined" \
  'live_attach_status()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 install_live_attach_tray function defined" \
  'install_live_attach_tray()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 remove_live_attach_tray function defined" \
  'remove_live_attach_tray()' \
  "$VFIO_SCRIPT"
# parse_args handles the 4 new toggle/status flags.
assert_contains_file \
  "R41 parse_args handles --live-attach-on" \
  '--live-attach-on)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 parse_args handles --live-attach-off" \
  '--live-attach-off)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 parse_args handles --live-attach-toggle" \
  '--live-attach-toggle)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 parse_args handles --live-attach-status" \
  '--live-attach-status)' \
  "$VFIO_SCRIPT"
# MODE comment lists the 4 new modes.
assert_contains_file \
  "R41 MODE comment lists live-attach-on/off/toggle/status" \
  'install-live-attach | live-attach-on | live-attach-off | live-attach-toggle | live-attach-status | install-virtio-win-guest-agent' \
  "$VFIO_SCRIPT"
# main dispatch wires the 4 new modes.
assert_contains_file \
  "R41 main dispatch wires live-attach-on" \
  '[[ "$MODE" == "live-attach-on" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 main dispatch wires live-attach-off" \
  '[[ "$MODE" == "live-attach-off" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 main dispatch wires live-attach-toggle" \
  '[[ "$MODE" == "live-attach-toggle" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 main dispatch wires live-attach-status" \
  '[[ "$MODE" == "live-attach-status" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 main dispatch calls live_attach_toggle toggle" \
  'live_attach_toggle toggle' \
  "$VFIO_SCRIPT"
# usage one-liner + help document the toggle.
assert_contains_file \
  "R41 usage one-liner includes --live-attach-toggle" \
  '[--live-attach-toggle]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 usage help documents --live-attach-toggle" \
  'system-tray applet (vfio-hotplug-tray) calls via pkexec' \
  "$VFIO_SCRIPT"
# fish/bash/zsh completions cover the toggle/status flags.
assert_contains_file \
  "R41 fish completion includes --live-attach-toggle" \
  'complete -c $cmd -l live-attach-toggle' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 fish completion includes --live-attach-status" \
  'complete -c $cmd -l live-attach-status' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 bash completion opts include --live-attach-toggle" \
  '--live-attach-on --live-attach-off --live-attach-toggle --live-attach-status' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 zsh completion includes --live-attach-toggle" \
  "'--live-attach-toggle[" \
  "$VFIO_SCRIPT"
# install_live_attach saves BOTH named VM XML variants + sets mode=on + installs tray.
assert_contains_text \
  "R41 install_live_attach saves with-gpu variant" \
  'live-attach-vm-with-gpu-$_dom.xml' \
  "$_la_fn"
assert_contains_text \
  "R41 install_live_attach saves without-gpu variant" \
  'live-attach-vm-without-gpu-$_dom.xml' \
  "$_la_fn"
assert_contains_text \
  "R41 install_live_attach sets mode=on" \
  '_la_write_mode "on"' \
  "$_la_fn"
assert_contains_text \
  "R41 install_live_attach calls install_live_attach_tray" \
  'install_live_attach_tray' \
  "$_la_fn"
# live_attach_toggle defines the right named variant per target mode.
assert_contains_text \
  "R41 live_attach_toggle picks without-gpu for on" \
  '_without_gpu="/var/lib/vfio-dynamic/live-attach-vm-without-gpu-$_dom.xml"' \
  "$(sed -n '/^live_attach_toggle()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R41 live_attach_toggle picks with-gpu for off" \
  '_with_gpu="/var/lib/vfio-dynamic/live-attach-vm-with-gpu-$_dom.xml"' \
  "$(sed -n '/^live_attach_toggle()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R41 live_attach_toggle flips the mode file" \
  '_la_write_mode "$_target"' \
  "$(sed -n '/^live_attach_toggle()/,/^}/p' "$VFIO_SCRIPT")"
# remove_live_attach: restore prefers named with-gpu variant, removes variants + mode + tray.
assert_contains_text \
  "R41 remove_live_attach falls back to named with-gpu variant" \
  'live-attach-vm-with-gpu-$_dom.xml' \
  "$_rm_la_fn"
assert_contains_text \
  "R41 remove_live_attach removes named variants glob" \
  'live-attach-vm-with-gpu-*.xml /var/lib/vfio-dynamic/live-attach-vm-without-gpu-*.xml' \
  "$_rm_la_fn"
assert_contains_text \
  "R41 remove_live_attach removes the mode file" \
  'run rm -f "$LIVE_ATTACH_MODE_FILE"' \
  "$_rm_la_fn"
assert_contains_text \
  "R41 remove_live_attach calls remove_live_attach_tray" \
  'remove_live_attach_tray' \
  "$_rm_la_fn"
assert_contains_text \
  "R41 remove_live_attach flips VFIO_LIVE_ATTACH_MODE off" \
  'rewrite_conf_key "VFIO_LIVE_ATTACH_MODE" "off"' \
  "$_rm_la_fn"
# Hook reads the mode file + gates the helper on mode=on.
assert_contains_text \
  "R41 hook reads the live-attach mode file" \
  'read -r _la_mode </var/lib/vfio-dynamic/live-attach-mode' \
  "$hook_block"
assert_contains_text \
  "R41 hook gates helper launch on mode=on" \
  '&& [[ "$_la_mode" == "on" ]]' \
  "$hook_block"
# reset rm -f includes the new artifacts.
assert_contains_text \
  "R41 reset rm -f includes mode file + tray + polkit" \
  '"$LIVE_ATTACH_MODE_FILE" "$LIVE_ATTACH_TRAY" "$LIVE_ATTACH_POLKIT"' \
  "$_reset_fn"
# Tray applet: PySide6 QSystemTrayIcon + zenity confirm + pkexec toggle + notify-send.
assert_contains_file \
  "R41 tray applet uses PySide6 QSystemTrayIcon" \
  'QtWidgets.QSystemTrayIcon' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 tray applet confirms via zenity --question" \
  'zenity", "--question"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 tray applet toggles via pkexec vfio --live-attach-toggle" \
  '"pkexec", VFIO_BIN, "--live-attach-toggle"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 tray applet reports result via notify-send" \
  'notify-send", "-u"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 tray applet reads the world-readable mode file (no root)" \
  'MODE_FILE = "/var/lib/vfio-dynamic/live-attach-mode"' \
  "$VFIO_SCRIPT"
# Polkit policy: auth_admin_keep + scoped to /usr/local/bin/vfio --live-attach-toggle.
assert_contains_file \
  "R41 polkit policy uses auth_admin_keep" \
  '<allow_active>auth_admin_keep</allow_active>' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 polkit policy scopes exec.path to the self-installed vfio" \
  'org.freedesktop.policykit.exec.path">/usr/local/bin/vfio' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41 polkit policy scopes argv1 to --live-attach-toggle" \
  'org.freedesktop.policykit.exec.argv1">--live-attach-toggle' \
  "$VFIO_SCRIPT"
# Autostart desktop file installed for SUDO_USER.
assert_contains_file \
  "R41 tray autostart desktop file installed" \
  'vfio-hotplug-tray.desktop' \
  "$VFIO_SCRIPT"
# Menu offers the toggle + dispatches live_attach_toggle.
assert_contains_text \
  "R41 menu has a toggle hotplug entry" \
  'Toggle live-attach hotplug on/off' \
  "$_menu_fn"
assert_contains_text \
  "R41 menu dispatches live_attach_toggle" \
  'live_attach_toggle toggle' \
  "$_menu_fn"

# --- R41+ hardening: atomic mode-file write, polkit action-id DRY, --json status, tray single-instance ---
assert_contains_file \
  "R41+ _la_write_mode writes the mode file atomically via write_file_atomic" \
  'write_file_atomic "$LIVE_ATTACH_MODE_FILE" 0644 "root:root"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41+ polkit heredoc is unquoted so the action id expands" \
  '<<POLEOF' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41+ polkit action id is single-sourced from LIVE_ATTACH_POLKIT_ACTION" \
  '<action id="$LIVE_ATTACH_POLKIT_ACTION">' \
  "$VFIO_SCRIPT"
if grep -Fq '<action id="dev.vfio.live-attach-toggle">' "$VFIO_SCRIPT"; then
  printf 'FAIL: R41+ polkit still hardcodes the action id instead of $LIVE_ATTACH_POLKIT_ACTION\n' >&2
  record_failure "R41+ polkit action id is DRY (no hardcoded action id)"
else
  printf 'PASS: R41+ polkit action id is DRY (no hardcoded action id)\n'
fi
assert_contains_file \
  "R41+ parse_args allows --json with --live-attach-status" \
  '"$MODE" != "live-attach-status"' \
  "$VFIO_SCRIPT"
_la_status_fn="$(sed -n '/^live_attach_status()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R41+ live_attach_status has a --json branch" \
  'if (( JSON_OUTPUT )); then' \
  "$_la_status_fn"
assert_contains_text \
  "R41+ live_attach_status JSON emits an installed + mode + vms object" \
  '"vms": [' \
  "$_la_status_fn"
assert_contains_file \
  "R41+ tray applet defines ensure_single_instance" \
  'def ensure_single_instance():' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41+ tray applet single-instance guard uses QLocalServer" \
  'QLocalServer' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41+ tray applet uses a named single-instance socket" \
  'SOCK_NAME = "/tmp/vfio-hotplug-tray.sock"' \
  "$VFIO_SCRIPT"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'R23 live-attach regression checks passed.\n'
