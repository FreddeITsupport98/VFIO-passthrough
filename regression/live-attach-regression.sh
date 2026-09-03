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
  'timeout "$_la_timeout" virsh -c qemu:///system attach-device "$DOMAIN" "$_xml" --live' \
  "$helper_block"
assert_contains_text \
  "R23 helper times out the audio attach-device (anti-hang)" \
  'timeout "$_la_timeout" virsh -c qemu:///system attach-device "$DOMAIN" "$_xml" --live' \
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
  'virsh -c qemu:///system attach-device "$DOMAIN" "$_xml" --live' \
  "$helper_block"
assert_contains_text \
  "R23 helper hot-attaches the audio function via virsh attach-device --live" \
  'attach-device "$DOMAIN" "$_xml" --live' \
  "$helper_block"
# R44/IOMMU-group fix: the helper MUST hot-attach the AUDIO BEFORE the GPU so qemu
# owns the audio's IOMMU group before the GPU attach fires its bus reset (on
# boards where GPU+audio sit in separate IOMMU groups, a GPU-first attach
# leaves the audio group not owned by qemu -> partial single-function reset
# -> Windows display init silently fails / black screen).
assert_contains_text \
  "R23 helper hot-attaches the AUDIO BEFORE the GPU (IOMMU group ownership fix)" \
  '_hot_attach_one "audio" "$AUDIO_XML" "audio"' \
  "$helper_block"
assert_contains_text \
  "R23 helper hot-attaches the GPU AFTER the audio (IOMMU group ownership fix)" \
  '_hot_attach_one "GPU" "$GPU_XML" "GPU"' \
  "$helper_block"
# R44/rom-strip: the helper MUST pass the expected vBIOS romfile path to
# _strip_guest_addr for the GPU so the python can STRIP a stale <rom file='...'/>
# when the referenced romfile is MISSING on disk (virsh attach-device --live
# otherwise fails with "failed to find romfile"). The helper does NOT inject a
# <rom> when the fragment has none — cold-attach works WITHOUT a <rom> line
# (vfio reads the card's own ROM from /sys/.../rom at boot and OVMF runs it for
# the GOP framebuffer), and on hot-attach OVMF is already done so an injected
# <rom> cannot produce a GOP framebuffer anyway (the vendor driver initializes
# the hot-plugged display). Shipping a romless hot-attach matches the romless
# cold-attach that already works.
# R44/keep-addr: the call now takes a 3rd arg (the keep_guest_addr conf value).
# Default 1 = KEEP the fixed guest PCI address so the GPU explicitly claims its
# cold-attach slot (e.g. bus 0x06) on hot-attach (Windows binds the AMD driver
# by PCI location, so a different slot = a different device instance = Code 28).
# The earlier strip-by-default let libvirt auto-assign the GPU to bus 0x07 ->
# Windows saw a new device -> Code 28; the black screen that masked it was ReBAR
# (amdgpu BAR0=16GB), now fixed via amdgpu.rebar=0. Strip is opt-OUT (=0) for
# the rare collision case.
assert_contains_text \
  "R23 helper passes the GPU romfile path + keep_addr to _strip_guest_addr" \
  '_strip_guest_addr "$_GPU_SRC" "$_GPU_ROM" "$_keep_addr"' \
  "$helper_block"
assert_contains_text \
  "R23 helper passes an empty rom path + keep_addr for the audio" \
  '_strip_guest_addr "$_AUDIO_SRC" "" "$_keep_addr"' \
  "$helper_block"
# R44/keep-addr: the helper MUST default to KEEPING the fixed guest PCI address
# (VFIO_LIVE_ATTACH_KEEP_GUEST_ADDR default 1) so the GPU lands at the SAME
# guest slot as cold-attach (no Code 28). Confirmed this session: strip-by-
# default (old :-0) shifted bus 0x06 -> 0x07 -> Windows "no driver installed".
# Strip is opt-OUT (=0) for the rare collision case.
assert_contains_text \
  "R44 helper reads VFIO_LIVE_ATTACH_KEEP_GUEST_ADDR (default 1 = keep guest addr)" \
  '_keep_addr="${VFIO_LIVE_ATTACH_KEEP_GUEST_ADDR:-1}"' \
  "$helper_block"
assert_contains_text \
  "R44 helper python reads keep_addr from argv" \
  'keep_addr = (len(sys.argv) > 4 and sys.argv[4] == "1")' \
  "$helper_block"
assert_contains_text \
  "R44 helper python only strips guest addr when keep_addr is False (opt-out)" \
  'if not keep_addr:' \
  "$helper_block"
# The OLD unconditional strip (a bare 'for a in list(hd.findall('address')):'
# NOT inside the keep_addr guard) MUST be GONE — the strip must be INSIDE the
# `if not keep_addr:` block so the opt-IN (keep) does NOT strip. Assert by line
# number: the strip line must come AFTER the `if not keep_addr:` guard line.
_strip_line="$(grep -n "for a in list(hd.findall('address')):" <<<"$helper_block" | head -1 | cut -d: -f1)"
_guard_line="$(grep -n 'if not keep_addr:' <<<"$helper_block" | head -1 | cut -d: -f1)"
if [[ -n "$_strip_line" && -n "$_guard_line" && "$_strip_line" -gt "$_guard_line" ]]; then
  printf 'PASS: R44 helper strip is inside the keep_addr guard (line %d > %d)\n' "$_strip_line" "$_guard_line"
else
  printf 'FAIL: R44 helper strip is NOT inside the keep_addr guard (strip=%s guard=%s)\n' "$_strip_line" "$_guard_line" >&2
  record_failure "R44 helper strip is gated on keep_addr (inside the if-not-keep_addr block)"
fi
assert_contains_text \
  "R23 helper resolves the GPU romfile path from the GPU BDF (live-<BDF>.rom)" \
  '_GPU_ROM="$_VBIOS_DIR/live-${GUEST_GPU_BDF}.rom"' \
  "$helper_block"
# R44/set -u fix: _GPU_ROM references GUEST_GPU_BDF which is unbound until the
# conf is sourced. If _GPU_ROM= appears BEFORE `. "$CONF_FILE"` in the helper,
# set -u crashes the helper at launch (no GPU attaches -> silent fail). Assert
# the _GPU_ROM line comes AFTER the conf source line.
_rom_line="$(grep -n '_GPU_ROM="' <<<"$helper_block" | head -1 | cut -d: -f1)"
_conf_line="$(grep -n '^\. "\$CONF_FILE"' <<<"$helper_block" | head -1 | cut -d: -f1)"
if [[ -n "$_rom_line" && -n "$_conf_line" && "$_rom_line" -gt "$_conf_line" ]]; then
  printf 'PASS: R44 helper sets _GPU_ROM after . "$CONF_FILE" (no set -u crash)\n'
else
  printf 'FAIL: R44 helper sets _GPU_ROM before . "$CONF_FILE" (set -u crash on unbound GUEST_GPU_BDF)\n' >&2
  record_failure "R44 helper _GPU_ROM placement crashes under set -u"
fi
# R44/rom-strip: the helper python MUST strip a stale <rom file='...'/> when the
# referenced romfile is MISSING on disk (prevents virsh attach-device --live
# "failed to find romfile"), and MUST NOT inject a <rom> when the fragment has
# none (cold-attach works romless via vfio's own /sys/.../rom read; an injected
# <rom> cannot help hot-attach because OVMF is not running to execute it).
assert_contains_text \
  "R23 helper python strips stale <rom> when the romfile is missing" \
  'if rf and not os.path.isfile(rf):' \
  "$helper_block"
assert_contains_text \
  "R23 helper python keeps a <rom> whose romfile still exists" \
  "rom = hd.find('rom')" \
  "$helper_block"
# The OLD rom-INJECT branch (elif rom is None and rom_path and os.path.isfile(rom_path))
# MUST be GONE — injecting a <rom> on hot-attach was based on the wrong premise
# that OVMF runs option ROMs on hot-attach (it does not).
if grep -Fq "elif rom is None and rom_path and os.path.isfile(rom_path):" <<<"$helper_block"; then
  printf 'FAIL: R23 helper still injects <rom> on hot-attach (OVMF does not run option ROMs on hot-attach)\n' >&2
  record_failure "R23 helper does not inject <rom> on hot-attach (inject branch removed)"
else
  printf 'PASS: R23 helper does not inject <rom> on hot-attach (inject branch removed)\n'
fi
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

# --- Static wiring: install_live_attach (R44: recognition + device fragments) ---
assert_contains_file \
  "R23 install_live_attach requires python3" \
  'have_cmd python3 || die "python3 not available (needed to extract hostdev XML)."' \
  "$VFIO_SCRIPT"
# R44: install extracts the GPU (+ audio) hostdevs into per-domain FRAGMENTS
# (profiles/<dom>/devices/*.xml) via the shared _la_extract_hostdev_fragment
# helper — NOT the old inline python that wrote flat LIVE_ATTACH_GPU_XML +
# full-domain with/without-gpu dumps. The fragment KEEPS the guest address in
# the on-disk file (so the toggle/define path has the original slot); the live-
# attach helper STRIPS it at runtime by default (v7-proven) so libvirt auto-
# assigns a free slot on hot-attach.
assert_contains_file \
  "R44 _la_extract_hostdev_fragment helper defined" \
  '_la_extract_hostdev_fragment() {' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R44 install_live_attach extracts the GPU fragment via the helper" \
  '| _la_extract_hostdev_fragment "$_gpu_bdf" "$_pdir/devices/gpu.xml"' \
  "$VFIO_SCRIPT"
# R44/vfio-backend: BOTH the fragment extractor AND the live-attach helper's
# _strip_guest_addr python MUST inject <driver name='vfio'/> so virsh
# attach-device --live uses the vfio PCI backend (Red Hat Bugzilla 1035490,
# kubevirt #17124 — without it the hot-add can fall back to a default/non-vfio
# backend). The same ET.Element('driver', {'name': 'vfio'}) string appears in
# both python blocks, so assert it occurs at least twice in vfio.sh.
_vfio_driver_inject_count="$(grep -cF "ET.Element('driver', {'name': 'vfio'})" "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _vfio_driver_inject_count >= 2 )); then
  printf 'PASS: R44 <driver name=vfio/> injected in both extractor + helper (%d sites)\n' "$_vfio_driver_inject_count"
else
  printf 'FAIL: R44 <driver name=vfio/> injection missing (expected >=2, got %s)\n' "$_vfio_driver_inject_count" >&2
  record_failure "R44 driver=vfio injected in both extractor + helper"
fi
# R44/RDNA4: the helper MUST resize BAR2 to 8MB (resource2_resize=3) + lock D0
# (d3cold_allowed=0) + unbind amdgpu BEFORE vfio-pci binding, or the RX 9070 XT /
# Navi 48 Windows AMD driver throws Code 43/28 ("no driver installed"). Gated on
# VFIO_LIVE_ATTACH_BAR2_RESIZE (default 1) and AMD vendor (0x1002). Proven RDNA4
# bind sequence from the PhialsBasement RX 9070 XT CachyOS guide.
assert_contains_text \
  "R44 helper resizes BAR2 to 8MB before vfio-pci bind (RDNA4)" \
  'resource2_resize' \
  "$helper_block"
assert_contains_text \
  "R44 helper locks D0 before amdgpu unbind (RDNA4 D3cold guard)" \
  'd3cold_allowed' \
  "$helper_block"
assert_contains_text \
  "R44 helper unbinds amdgpu by BDF before BAR2 resize (RDNA4)" \
  'drivers/$_g_drv/unbind' \
  "$helper_block"
assert_contains_text \
  "R44 helper BAR2 resize is gated on the VFIO_LIVE_ATTACH_BAR2_RESIZE conf key" \
  'VFIO_LIVE_ATTACH_BAR2_RESIZE' \
  "$helper_block"
assert_contains_text \
  "R44 helper BAR2 resize is AMD-only (vendor 0x1002 guard)" \
  '0x1002' \
  "$helper_block"
# The BAR2 resize MUST come BEFORE the --bind-now call (the resize must happen
# while the card is driverless, between amdgpu-unbind and vfio-pci-bind).
_bar2_line="$(grep -n 'resource2_resize' <<<"$helper_block" | head -1 | cut -d: -f1)"
_bind_line="$(grep -n '"\$BIND_SCRIPT" --bind-now' <<<"$helper_block" | head -1 | cut -d: -f1)"
if [[ -n "$_bar2_line" && -n "$_bind_line" && "$_bar2_line" -lt "$_bind_line" ]]; then
  printf 'PASS: R44 helper BAR2 resize comes before --bind-now (line %d < %d)\n' "$_bar2_line" "$_bind_line"
else
  printf 'FAIL: R44 helper BAR2 resize does NOT come before --bind-now (bar2=%s bind=%s)\n' "$_bar2_line" "$_bind_line" >&2
  record_failure "R44 helper BAR2 resize comes before --bind-now"
fi
assert_contains_file \
  "R44 install_live_attach recognizes each VM (writes the manifest)" \
  'profile_recognize "$_dom"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R44 install_live_attach strips the GPU via profile_apply_mode on" \
  'profile_apply_mode "$_dom" on' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R44 install_live_attach creates the per-domain profile devices dir" \
  'profiles/$DOMAIN/devices/gpu.xml' \
  "$VFIO_SCRIPT"
# R44: install MUST NOT write the R41/R42 full-domain variant dumps as the
# switch mechanism (they go stale and wipe user edits). They are at most a
# one-release read-only fallback, never the switch path.
assert_contains_file \
  "R44 _la_profile_dir helper defined" \
  '_la_profile_dir() {' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R44 profile_recognize helper defined" \
  'profile_recognize() {' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R44 profile_apply_mode helper defined" \
  'profile_apply_mode() {' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R44 _la_devices_signature safety-invariant helper defined" \
  '_la_devices_signature() {' \
  "$VFIO_SCRIPT"
# install_live_attach must auto-inject the qemu guest-agent channel (idempotent)
# so the live-attach helper can poll guest-ping. R44 injects it in its own
# GAPYEOF heredoc (separate from the fragment extraction).
assert_contains_file \
  "R23 python injector adds guest-agent channel target" \
  "'org.qemu.guest_agent.0'" \
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
# R44 compat: install symlinks the old flat LIVE_ATTACH_GPU_XML to the fragment
# so a not-yet-reinstalled helper keeps working.
assert_contains_file \
  "R44 install_live_attach symlinks the flat GPU XML to the fragment" \
  'ln -sf "$_pdir/devices/gpu.xml" "$LIVE_ATTACH_GPU_XML"' \
  "$VFIO_SCRIPT"
# install_live_attach must reinstall the libvirt hook AND regenerate the bind
# script (the helper calls --bind-now).
_la_fn="$(sed -n '/^install_live_attach()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R23 install_live_attach calls install_libvirt_hook (deploys live-attach hook)" \
  'install_libvirt_hook' \
  "$_la_fn"
assert_contains_text \
  "R23 install_live_attach calls install_bind_script (helper uses --bind-now)" \
  'install_bind_script' \
  "$_la_fn"
# R44/VM-choice: install_live_attach MUST detect existing guest-GPU VMs (shut
# off OR running), let the user pick which one to set up when there is more than
# one (select_from_list), and prompt to shut off a running chosen VM (virsh
# destroy) instead of silently skipping — so the user doesn't have to re-run the
# installer to get their VM attached.
assert_contains_file \
  "R44 install_live_attach detects guest-GPU VMs into a candidate array" \
  '_la_candidate_vms+=("$_la_dom")' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R44 install_live_attach lets the user pick which VM when >1 candidate" \
  'select_from_list "Which VM should be set up for live-attach (hotplug)?"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R44 install_live_attach prompts to shut off a running chosen VM (virsh destroy)" \
  'virsh -c qemu:///system destroy "$_dom"' \
  "$VFIO_SCRIPT"
# The OLD silent-skip behavior (a bare WARN + continue with no shut-off prompt)
# MUST be GONE for the running-VM case — the user should be offered a shut-off.
if printf '%s\n' "$_la_fn" | grep -Fq 'not shut off); skipping. Shut it off and re-run.'; then
  printf 'FAIL: R44 install_live_attach still silently skips running VMs (no shut-off prompt)\n' >&2
  record_failure "R44 install_live_attach prompts to shut off running VMs (no silent skip)"
else
  printf 'PASS: R44 install_live_attach does NOT silently skip running VMs (offers shut-off prompt)\n'
fi
assert_contains_file \
  "R23 install_live_attach regenerates the bind script" \
  'Regenerated $BIND_SCRIPT (bind logic for the live-attach helper)' \
  "$VFIO_SCRIPT"

# --- Static wiring: remove_live_attach (R44: restores via FRAGMENT, not backup) ---
assert_contains_file \
  "R23 remove_live_attach removes the helper script" \
  'run rm -f "$LIVE_ATTACH_HELPER"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R23 remove_live_attach flips VFIO_DYNAMIC_LIVE_ATTACH=0" \
  'rewrite_conf_key "VFIO_DYNAMIC_LIVE_ATTACH" "0"' \
  "$VFIO_SCRIPT"
_rm_la_fn="$(sed -n '/^remove_live_attach()/,/^}/p' "$VFIO_SCRIPT")"
# R44: remove_live_attach puts the GPU back via profile_apply_mode off (re-
# inserts ONLY the GPU/audio hostdev into the CURRENT live XML), NEVER by
# virsh-defining an old full-domain backup.
assert_contains_text \
  "R44 remove_live_attach restores the GPU via profile_apply_mode off" \
  'profile_apply_mode "$_dom" off' \
  "$_rm_la_fn"
assert_contains_text \
  "R44 remove_live_attach recognizes before restoring" \
  'profile_recognize "$_dom"' \
  "$_rm_la_fn"
assert_contains_text \
  "R44 remove_live_attach deletes per-domain profile dirs" \
  'rm -rf "$_pdir"' \
  "$_rm_la_fn"
assert_contains_text \
  "R44 remove_live_attach only restores shut-off VMs" \
  '[[ "$_state" != "shut off" ]]' \
  "$_rm_la_fn"
# R44: remove_live_attach must NOT virsh-define an old full-domain backup.
if printf '%s\n' "$_rm_la_fn" | grep -Fq 'virsh -c qemu:///system define "$_backup_xml"'; then
  printf 'FAIL: R44 remove_live_attach still virsh-defines an old full backup\n' >&2
  record_failure "R44 remove_live_attach does not define an old full backup"
else
  printf 'PASS: R44 remove_live_attach does not define an old full backup\n'
fi

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
# fedorapeople repo first, then `dnf install virtio-win` (the proven fix). R46:
# the repo file path is now the VIRTIO_WIN_REPO_FILE constant (not a literal),
# so remove_virtio_win_guest_agent can sweep the same path on cleanup.
assert_contains_text \
  "R30 adds the virtio-win repo on Fedora before dnf install" \
  'curl -fsSL -o "$VIRTIO_WIN_REPO_FILE" "$VIRTIO_WIN_REPO_URL"' \
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
# R46: the on-disk repo file path constant (used by install + remove so both
# agree on the path; --reset sweeps it via remove_virtio_win_guest_agent).
assert_contains_file \
  "R46 VIRTIO_WIN_REPO_FILE constant defined" \
  'VIRTIO_WIN_REPO_FILE="/etc/yum.repos.d/virtio-win.repo"' \
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

# --- R48b: vfio_menu header + dialog prompt show a context-aware ReBAR
# disclaimer so the GUI operator is told about the Resizable BAR / AMD
# black-screen caveat (and that NVIDIA/Intel handle a resized BAR cleanly)
# before picking an action. Mirrors the tray applet's R45 ReBAR warning;
# read-only (conf + /proc/cmdline). ---
assert_contains_file \
  "R48b _menu_rebar_disclaimer function defined" \
  '_menu_rebar_disclaimer()' \
  "$VFIO_SCRIPT"
assert_contains_text \
  "R48b vfio_menu calls _menu_rebar_disclaimer full in the header" \
  '_menu_rebar_disclaimer full' \
  "$_menu_fn"
assert_contains_text \
  "R48b vfio menu embeds the compact disclaimer in the select_from_list prompt" \
  '_menu_rebar_disclaimer compact' \
  "$_menu_fn"
_rebar_fn="$(sed -n '/^_menu_rebar_disclaimer()/,/^}/p' "$VFIO_SCRIPT")"
if [[ -n "$_rebar_fn" ]]; then
  printf 'PASS: R48b _menu_rebar_disclaimer body extracted\n'
else
  printf 'FAIL: R48b _menu_rebar_disclaimer body extracted (empty)\n' >&2
  record_failure "R48b _menu_rebar_disclaimer body extracted"
fi
assert_contains_text \
  "R48b disclaimer is AMD-gated on vendor 1002" \
  '1002)' \
  "$_rebar_fn"
assert_contains_text \
  "R48b disclaimer covers NVIDIA (10de) / Intel (8086)" \
  '10de|8086)' \
  "$_rebar_fn"
assert_contains_text \
  "R48b disclaimer warns amdgpu auto-resizes BAR0 -> Windows display black" \
  'breaks the Windows AMD' \
  "$_rebar_fn"
assert_contains_text \
  "R48b disclaimer points at the --amd-rebar fix" \
  '--install-dynamic-binding --amd-rebar' \
  "$_rebar_fn"
assert_contains_text \
  "R48b disclaimer notes NVIDIA/Intel handle a resized BAR cleanly" \
  'NVIDIA/Intel handle a resized BAR' \
  "$_rebar_fn"
assert_contains_text \
  "R48b disclaimer OK path checks /proc/cmdline for amdgpu.rebar=0" \
  'amdgpu.rebar=0' \
  "$_rebar_fn"
assert_contains_text \
  "R48b disclaimer has a compact mode for the dialog prompt" \
  'compact' \
  "$_rebar_fn"

# --- R48c/R48e/R48f: a standalone "Apply hypervisor hide / stealth" menu option
# (position 3) + the FULL 9-feature per-VM checklist on the menu's FIRST page
# (header notes + the whiptail dialog prompt, right where the ReBAR disclaimer
# is) so the GUI operator sees which VM is detected + what tuning is applied
# (✔) vs not (✖) BEFORE picking an action — not hidden in a post-action popup.
# Also fixes the root cause: the wizard now runs VM-customization in BOTH binding
# modes (asserted in ultimate-perf-regression.sh). R48f SPLIT hypervisor-hide
# (the core stripes fix) and stealth-tune (the cosmetic SMBIOS/NIC/serial
# extension) into SEPARATE checklist items — they are not the same thing. ---
assert_contains_text \
  "R48c menu offers the hypervisor hide / stealth option" \
  'Apply hypervisor hide / stealth to detected guest-GPU VMs' \
  "$_menu_fn"
assert_contains_text \
  "R48c menu hypervisor-hide option calls install_stealth_vm_tuning" \
  'Applying hypervisor hide / stealth to detected guest-GPU VMs' \
  "$_menu_fn"
assert_contains_text \
  "R48c/R48e menu offers the Show VFIO status option" \
  'Show VFIO status (per-VM tuning checklist + ReBAR)' \
  "$_menu_fn"
assert_contains_text \
  "R48e menu Show-VFIO-status option re-opens the panel (gui_msgbox)" \
  'gui_msgbox "VFIO status"' \
  "$_menu_fn"
assert_contains_text \
  "R48c/R48e menu Exit is now option 22 (renumbered from 20)" \
  'Exiting vfio.sh menu.' \
  "$_menu_fn"
# R48e: the shared detector + the first-page summary renderer.
assert_contains_file \
  "R48e _vm_checklist_records function defined" \
  '_vm_checklist_records()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R48e _menu_vm_status_summary function defined" \
  '_menu_vm_status_summary()' \
  "$VFIO_SCRIPT"
assert_contains_text \
  "R48e vfio_menu builds the compact status block" \
  '_menu_vm_status_summary compact' \
  "$_menu_fn"
assert_contains_text \
  "R48e vfio_menu shows the status as a separate gui_msgbox panel" \
  'gui_msgbox "VFIO status"' \
  "$_menu_fn"
assert_contains_text \
  "R48e vfio_menu tracks _last_status so the panel only re-shows on change" \
  '_last_status' \
  "$_menu_fn"
assert_contains_text \
  "R48e vfio_menu CLI path still prints the full header notes" \
  '_menu_vm_status_summary full' \
  "$_menu_fn"
# gui_msgbox is now dynamically sized (width from longest line, height from
# line count) so the long status panel does not truncate at a fixed 18x72 box.
assert_contains_file \
  "R48e gui_msgbox sizes dynamically from content" \
  'whiptail --title "$title" --msgbox "$msg" "$_h" "$_w"' \
  "$VFIO_SCRIPT"
_checklist_fn="$(sed -n '/^_vm_checklist_records()/,/^}/p' "$VFIO_SCRIPT")"
if [[ -n "$_checklist_fn" ]]; then
  printf 'PASS: R48e _vm_checklist_records body extracted\n'
else
  printf 'FAIL: R48e _vm_checklist_records body extracted (empty)\n' >&2
  record_failure "R48e _vm_checklist_records body extracted"
fi
assert_contains_text \
  "R48e checklist scans guest-GPU VMs via _list_guest_gpu_vms" \
  '_list_guest_gpu_vms' \
  "$_checklist_fn"
assert_contains_text \
  "R48f checklist detects hypervisor-hide (GENUINE00000 + kvm hidden)" \
  'GENUINE00000' \
  "$_checklist_fn"
assert_contains_text \
  "R48f checklist line 1 has hypervisor-hide label (core stripes fix)" \
  'hypervisor-hide $_hh_sym' \
  "$_checklist_fn"
assert_contains_text \
  "R48f checklist line 1 has stealth-tune label (cosmetic extension)" \
  'stealth-tune $_st_sym' \
  "$_checklist_fn"
assert_contains_text \
  "R48f checklist detects stealth-tune via SMBIOS type-1 spoofing" \
  'type=1,manufacturer=' \
  "$_checklist_fn"
assert_contains_text \
  "R48e checklist line 1 has ultimate-perf label" \
  'ultimate-perf $_p_sym' \
  "$_checklist_fn"
assert_contains_text \
  "R48e checklist line 2 has vBIOS" \
  'vBIOS $_vb_sym' \
  "$_checklist_fn"
assert_contains_text \
  "R48e checklist line 2 has live-attach" \
  'live-attach $_la_sym' \
  "$_checklist_fn"
assert_contains_text \
  "R48e checklist line 2 has hugepages" \
  'hugepages $_hp_sym' \
  "$_checklist_fn"
assert_contains_text \
  "R48e checklist line 2 has virtio-win" \
  'virtio-win $_vw_sym' \
  "$_checklist_fn"
assert_contains_text \
  "R48e checklist line 2 has disks-virtio" \
  'disks-virtio $_dk_sym' \
  "$_checklist_fn"
_vm_summary_fn="$(sed -n '/^_menu_vm_status_summary()/,/^}/p' "$VFIO_SCRIPT")"
if [[ -n "$_vm_summary_fn" ]]; then
  printf 'PASS: R48e _menu_vm_status_summary body extracted\n'
else
  printf 'FAIL: R48e _menu_vm_status_summary body extracted (empty)\n' >&2
  record_failure "R48e _menu_vm_status_summary body extracted"
fi
assert_contains_text \
  "R48e summary reports the no-VM-detected case" \
  'no guest-GPU VM detected' \
  "$_vm_summary_fn"
assert_contains_text \
  "R48e summary has a compact mode for the dialog prompt" \
  'compact' \
  "$_vm_summary_fn"
# _vm_tuning_status_block consumes the shared detector (still renders the
# post-action popup/card) so header + popup agree.
assert_contains_file \
  "R48e status block consumes _vm_checklist_records" \
  '_vm_checklist_records' \
  "$VFIO_SCRIPT"
# R48e: select_from_list now sizes the whiptail dialog DYNAMICALLY from the
# prompt content (longest line + line count) so the multi-line VM checklist +
# ReBAR prompt no longer truncate at the old fixed 78-col width.
_sfl_fn="$(sed -n '/^select_from_list()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R48e select_from_list computes a dynamic dialog width" \
  '_maxw' \
  "$_sfl_fn"
assert_contains_text \
  "R48e select_from_list computes a dynamic dialog height" \
  '_nh' \
  "$_sfl_fn"
assert_contains_text \
  "R48e select_from_list reads terminal cols via COLUMNS/tput" \
  'tput cols' \
  "$_sfl_fn"
assert_contains_text \
  "R48e select_from_list no longer hardcodes 20 78 10" \
  '"$_nh" "$_maxw" "$_lh"' \
  "$_sfl_fn"

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
# --- R37/R43: --reset removes ALL stage backups + --full also removes the CLI ---
# reset_vfio_all now calls _wipe_vm_stage_backups (R43: unifies + supersedes the
# R37 _remove_vm_tuning_backups — wipes fixed-name + legacy ~/Desktop timestamped
# stealth/perf XML backups AND the live-attach stage XML variants) and accepts a
# 'full' arg that also removes the self-installed vfio CLI + completions (repo
# script untouched).
assert_contains_file \
  "R43 _wipe_vm_stage_backups helper defined (replaces R37 _remove_vm_tuning_backups)" \
  '_wipe_vm_stage_backups()' \
  "$VFIO_SCRIPT"
assert_contains_text \
  "R43 reset calls _wipe_vm_stage_backups" \
  '_wipe_vm_stage_backups' \
  "$_reset_fn2"
# The backup-removal globs live in _wipe_vm_stage_backups (called by reset), so
# extract that helper and assert the legacy ~/Desktop globs are still present.
_rm_bak_fn="$(sed -n '/^_wipe_vm_stage_backups()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R43 reset helper removes legacy ~/Desktop timestamped stealth backups" \
  '*_stealth_*.xml' \
  "$_rm_bak_fn"
assert_contains_text \
  "R43 reset helper removes legacy ~/Desktop timestamped perf backups" \
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
# R44: install sets mode=on + installs tray. It does NOT save the R41/R42 full-
# domain with-gpu/without-gpu variant dumps (replaced by recognition + fragments).
assert_contains_text \
  "R41 install_live_attach sets mode=on" \
  '_la_write_mode "on"' \
  "$_la_fn"
assert_contains_text \
  "R41 install_live_attach calls install_live_attach_tray" \
  'install_live_attach_tray' \
  "$_la_fn"
# R44: install MUST NOT write the full-domain variant dumps as the switch path.
if printf '%s\n' "$_la_fn" | grep -Fq 'live-attach-vm-with-gpu-$_dom.xml'; then
  printf 'FAIL: R44 install_live_attach still writes the with-gpu full-domain dump\n' >&2
  record_failure "R44 install_live_attach does not write the with-gpu full-domain dump"
else
  printf 'PASS: R44 install_live_attach does not write the with-gpu full-domain dump\n'
fi
if printf '%s\n' "$_la_fn" | grep -Fq 'live-attach-vm-without-gpu-$_dom.xml'; then
  printf 'FAIL: R44 install_live_attach still writes the without-gpu full-domain dump\n' >&2
  record_failure "R44 install_live_attach does not write the without-gpu full-domain dump"
else
  printf 'PASS: R44 install_live_attach does not write the without-gpu full-domain dump\n'
fi
# R44: live_attach_toggle recognizes per VM then applies the mode via fragments
# (it does NOT pick a named full-domain variant).
_toggle_fn="$(sed -n '/^live_attach_toggle()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R44 live_attach_toggle recognizes each VM" \
  'profile_recognize "$_dom"' \
  "$_toggle_fn"
assert_contains_text \
  "R44 live_attach_toggle applies the mode via fragments" \
  'profile_apply_mode "$_dom" "$_target"' \
  "$_toggle_fn"
assert_contains_text \
  "R44 live_attach_toggle flips the mode file on success" \
  '_la_write_mode "$_target"' \
  "$_toggle_fn"
assert_contains_text \
  "R44 live_attach_toggle prints a mismatch when no VM was redefined" \
  'MISMATCH: no shut-off VM was redefined' \
  "$_toggle_fn"
# R44: toggle MUST NOT reference the old named full-domain variant paths.
if printf '%s\n' "$_toggle_fn" | grep -Fq 'live-attach-vm-without-gpu-$_dom.xml'; then
  printf 'FAIL: R44 live_attach_toggle still picks the without-gpu full-domain variant\n' >&2
  record_failure "R44 live_attach_toggle does not pick the without-gpu full-domain variant"
else
  printf 'PASS: R44 live_attach_toggle does not pick the without-gpu full-domain variant\n'
fi
if printf '%s\n' "$_toggle_fn" | grep -Fq 'live-attach-vm-with-gpu-$_dom.xml'; then
  printf 'FAIL: R44 live_attach_toggle still picks the with-gpu full-domain variant\n' >&2
  record_failure "R44 live_attach_toggle does not pick the with-gpu full-domain variant"
else
  printf 'PASS: R44 live_attach_toggle does not pick the with-gpu full-domain variant\n'
fi
# remove_live_attach: removes the mode file + tray + flips the conf (kept from R41).
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
# R42: the tray probes guest-GPU liveness so a dead/zombie card (RX 9070/
# RDNA4 reset bug, config space all 0xff / vendor 0xffff / sysfs dir gone)
# surfaces as "GPU DEAD, needs host reboot" and the icon STAYS visible.
assert_contains_file \
  "R42 tray applet reads the guest GPU BDF from the conf" \
  'def read_gpu_bdf():' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray applet has a gpu_state() liveness probe" \
  'def gpu_state():' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray applet gpu_state treats vendor 0xffff as dead" \
  '0xffff' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray applet dead tooltip says GPU DEAD, needs host reboot" \
  'GPU DEAD, needs host reboot' \
  "$VFIO_SCRIPT"
# R42: the icon is color-coded by state — green=ON, red=OFF, yellow=DEAD card.
assert_contains_file \
  "R42 tray applet defines a _status_icon color helper" \
  'def _status_icon(color):' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray applet tints the GPU glyph with the status color" \
  'CompositionMode_DestinationIn' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray applet defines green/red/yellow status colors" \
  '_GREEN, _RED, _YELLOW' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray applet uses a yellow icon when the GPU is dead" \
  '_status_icon(_YELLOW)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray applet uses green when ON, red when OFF" \
  '_GREEN if m == "on" else _RED' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 live_attach_status prints a gpu= liveness line" \
  "printf 'gpu=%s\\n' \"\$_gpu\"" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 live_attach_status JSON emits a gpu field" \
  '"gpu":' \
  "$VFIO_SCRIPT"
# R42: opting into hotplug auto-installs Looking Glass on BOTH VM XML variants
# + the host side, persisting across reboots (the toggle virsh-defines the
# variants, so LG survives every on/off flip; tmpfiles.d recreates the shm node).
assert_contains_file \
  "R42 _lg_apply_to_vm helper defined" \
  '_lg_apply_to_vm() {' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 _install_looking_glass_defaults helper defined" \
  '_install_looking_glass_defaults() {' \
  "$VFIO_SCRIPT"
# R44: install applies LG to the LIVE VM XML working copy once (not to two
# frozen full-domain variants). The device-diff safety invariant preserves the
# shmem through later toggles.
assert_contains_text \
  "R44 install_live_attach applies LG to the live XML working copy" \
  '_lg_apply_to_vm "$_tmp_vm"' \
  "$_la_fn"
# R44: install MUST NOT apply LG to a with-gpu full-domain variant dump (gone).
if printf '%s\n' "$_la_fn" | grep -Fq '_lg_apply_to_vm "$_with_gpu_xml"'; then
  printf 'FAIL: R44 install_live_attach still applies LG to a with-gpu variant dump\n' >&2
  record_failure "R44 install_live_attach does not apply LG to a with-gpu variant dump"
else
  printf 'PASS: R44 install_live_attach does not apply LG to a with-gpu variant dump\n'
fi
assert_contains_text \
  "R42 install_live_attach installs the LG host-side defaults (success path)" \
  '_install_looking_glass_defaults "$LG_DEFAULT_SIZE"' \
  "$_la_fn"
assert_contains_text \
  "R42 install_live_attach refreshes LG host-side on the already-active path" \
  '_install_looking_glass_defaults "$LG_DEFAULT_SIZE"' \
  "$_la_fn"
assert_contains_text \
  "R42 _lg_apply_to_vm attaches the shmem device" \
  '_lg_attach_shmem_to_vm "$_file" "$_size"' \
  "$(sed -n '/^_lg_apply_to_vm()/,/^}/p' "$VFIO_SCRIPT")"
# R44b: _lg_apply_to_vm (the install_live_attach code path) now branches on the
# VFIO_LIVE_ATTACH_BOOT_DISPLAY conf key (default none = video=none, the GPU is
# the only display via LG; virtio = opt back into a boot display). The earlier
# "live-attach needs a virtio boot display or video=none = black screen" premise
# was overturned this session — the black screen was ReBAR (amdgpu BAR0=16GB),
# now fixed via amdgpu.rebar=0. So video=none is the correct default for BOTH
# modes now; virtio is the opt-IN.
assert_contains_text \
  "R44b _lg_apply_to_vm branches on VFIO_LIVE_ATTACH_BOOT_DISPLAY (default none)" \
  '_boot_disp="${VFIO_LIVE_ATTACH_BOOT_DISPLAY:-none}"' \
  "$(sed -n '/^_lg_apply_to_vm()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R44b _lg_apply_to_vm default branch uses _lg_set_vm_display_none (video=none)" \
  '_lg_set_vm_display_none "$_file" || _vd=$?' \
  "$(sed -n '/^_lg_apply_to_vm()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R44b _lg_apply_to_vm virtio opt-in branch uses _lg_set_vm_display_live_attach" \
  '_lg_set_vm_display_live_attach "$_file" || _vd=$?' \
  "$(sed -n '/^_lg_apply_to_vm()/,/^}/p' "$VFIO_SCRIPT")"
# R45/Job1: preflight guest-GPU VM gate — the dynamic installer + full wizard
# must detect a guest-GPU VM BEFORE running the VM-customization steps, and
# print a "you need a VM first" banner if none exists (instead of silently
# skipping every step).
assert_contains_file \
  "R45 _preflight_guest_gpu_vm_gate helper defined" \
  '_preflight_guest_gpu_vm_gate() {' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 dynamic installer calls the preflight gate before VM-customization steps" \
  '_preflight_guest_gpu_vm_gate && _vm_gate=1' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 preflight gate prints a 'No guest-GPU VM found' banner" \
  'No guest-GPU VM found' \
  "$VFIO_SCRIPT"
# R45/Job2: VFIO_LIVE_ATTACH_KEEP_GUEST_ADDR + VFIO_LIVE_ATTACH_BOOT_DISPLAY
# conf defaults persisted by write_conf + _sync_conf_defaults.
assert_contains_file \
  "R45 write_conf emits VFIO_LIVE_ATTACH_KEEP_GUEST_ADDR default (1 = keep)" \
  'VFIO_LIVE_ATTACH_KEEP_GUEST_ADDR="1"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 write_conf emits VFIO_LIVE_ATTACH_BOOT_DISPLAY default (none)" \
  'VFIO_LIVE_ATTACH_BOOT_DISPLAY="none"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 _sync_conf_defaults syncs VFIO_LIVE_ATTACH_KEEP_GUEST_ADDR" \
  '[VFIO_LIVE_ATTACH_KEEP_GUEST_ADDR]="1"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 _sync_conf_defaults syncs VFIO_LIVE_ATTACH_BOOT_DISPLAY" \
  '[VFIO_LIVE_ATTACH_BOOT_DISPLAY]="none"' \
  "$VFIO_SCRIPT"
# R45: centralized guest-GPU VM detection — _list_guest_gpu_vms enumerator
# (NUL-delimited name\0xml\0) consumed by the preflight gate + all 9 optional-
# tuner loops (stealth/LG/perf install+status+reset). The gate now PRINTS each
# detected VM instead of a silent break-on-first.
assert_contains_file \
  "R45 _list_guest_gpu_vms enumerator defined" \
  '_list_guest_gpu_vms() {' \
  "$VFIO_SCRIPT"
assert_contains_text \
  "R45 preflight gate consumes _list_guest_gpu_vms" \
  'done < <(_list_guest_gpu_vms)' \
  "$(sed -n '/^_preflight_guest_gpu_vm_gate()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_file \
  "R45 preflight gate prints 'Detected guest-GPU VM:'" \
  'Detected guest-GPU VM:' \
  "$VFIO_SCRIPT"
# R45: the shared enumerator is consumed by >=10 call sites (1 gate + 9 tuners).
# The enumerator itself uses `virsh list --all --name` (the single scan), so it
# is NOT counted here.
_list_guest_done=$(grep -cF 'done < <(_list_guest_gpu_vms)' "$VFIO_SCRIPT" 2>/dev/null || echo 0)
if (( _list_guest_done >= 10 )); then
  printf 'PASS: R45 shared enumerator consumed by >=10 call sites (gate + 9 tuners: %d)\n' "$_list_guest_done"
else
  printf 'FAIL: R45 shared enumerator consumed by only %d call sites (expected >=10)\n' "$_list_guest_done" >&2
  record_failure "R45 shared enumerator consumed by >=10 call sites"
fi
# R45: the old per-function `virsh list --all --name` scan must be GONE from the
# rewired tuners (representative: install_stealth_vm_tuning).
_stealth_fn="$(sed -n '/^install_stealth_vm_tuning()/,/^}/p' "$VFIO_SCRIPT")"
if printf '%s\n' "$_stealth_fn" | grep -Fq 'virsh -c qemu:///system list --all --name'; then
  printf 'FAIL: R45 install_stealth_vm_tuning still has its own virsh list scan\n' >&2
  record_failure "R45 install_stealth_vm_tuning uses the shared enumerator (no own scan)"
else
  printf 'PASS: R45 install_stealth_vm_tuning uses the shared enumerator (no own scan)\n'
fi
# R45: live_attach_status surfaces a rebar_ok field (text + JSON) so the tray +
# non-GUI tooling can warn when the AMD guest GPU is at risk (amdgpu.rebar=0
# missing from the kernel cmdline -> BAR0 auto-resized to full VRAM -> Windows
# AMD display driver black screen).
assert_contains_file \
  "R45 live_attach_status text emits rebar_ok=" \
  "printf 'rebar_ok=%s\\n' \"\$_rebar_ok\"" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 live_attach_status JSON emits rebar_ok" \
  '"rebar_ok": %s,' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 live_attach_status reads /proc/cmdline for amdgpu.rebar=0" \
  "grep -Fq 'amdgpu.rebar=0'" \
  "$VFIO_SCRIPT"
# R45: tray applet ReBAR/AMD-display banner — visible ONLY when the guest GPU
# is AMD + amdgpu.rebar=0 is missing from the kernel cmdline. Clicking pops a
# zenity info dialog with the fix; the tooltip gets a warning line. Absent when
# the param is present so the tray stays clean.
assert_contains_file \
  "R45 tray read_guest_vendor helper defined" \
  'def read_guest_vendor():' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 tray rebar_at_risk helper defined" \
  'def rebar_at_risk():' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 tray show_rebar_warning dialog defined" \
  'def show_rebar_warning():' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 tray banner menu item warns ReBAR ON -> AMD display black" \
  '⚠ ReBAR is ON — AMD display will go black' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 tray banner visibility flips in refresh()" \
  'rebar_warn_act.setVisible(_rebar_bad)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R45 tray tooltip appends ReBAR warning when at risk" \
  '⚠ ReBAR ON — AMD display will go black (add amdgpu.rebar=0)' \
  "$VFIO_SCRIPT"
assert_contains_text \
  "R42 _install_looking_glass_defaults writes the tmpfiles.d entry" \
  '_lg_write_tmpfiles' \
  "$(sed -n '/^_install_looking_glass_defaults()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R42 _install_looking_glass_defaults resizes the shm node" \
  '_lg_resize_shmem "$_size"' \
  "$(sed -n '/^_install_looking_glass_defaults()/,/^}/p' "$VFIO_SCRIPT")"
# R42 foolproof: install_live_attach_tray kills any ALREADY-running tray
# instance BEFORE regenerating the applet (so the new code actually loads —
# the old process holds stale in-memory code), then relaunches with setsid +
# verifies the fresh PID. remove_live_attach_tray uses the same end-anchored
# pattern (no self-match). End-anchored "python3 <path>$" so the pkiller's
# own cmdline (substring) is never matched.
assert_contains_file \
  "R42 tray install kills stale instance before regenerating (end-anchored)" \
  'pkill -f "python3 ${LIVE_ATTACH_TRAY}\$"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray install SIGKILLs any survivor before relaunch" \
  'pkill -9 -f "python3 ${LIVE_ATTACH_TRAY}\$"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray install relaunches with setsid-detach (survives sudo exit)" \
  'setsid runuser -u "$_user" -- env XDG_RUNTIME_DIR="$_rt"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 tray install verifies the fresh instance stayed up" \
  'pgrep -u "$_user" -f "python3 ${LIVE_ATTACH_TRAY}\$"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R42 remove_live_attach_tray uses the end-anchored pattern (no self-match)" \
  'run pkill -f "python3 ${LIVE_ATTACH_TRAY}\$"' \
  "$VFIO_SCRIPT"
# The kill MUST come before the regenerate (write_file_atomic of the applet).
# Assert by checking the kill line appears before the write_file_atomic line.
# grep -Fn (fixed strings + line numbers) so the $ regex anchor is literal.
_kill_line=$(grep -Fn 'pkill -f "python3 ${LIVE_ATTACH_TRAY}\$"' "$VFIO_SCRIPT" | head -1 | cut -d: -f1)
_write_line=$(grep -Fn 'write_file_atomic "$LIVE_ATTACH_TRAY" 0755' "$VFIO_SCRIPT" | head -1 | cut -d: -f1)
if (( _kill_line > 0 && _write_line > _kill_line )); then
  printf 'PASS: R42 tray install kills stale instance before regenerating the applet (line %d < %d)\n' "$_kill_line" "$_write_line"
else
  printf 'FAIL: R42 tray install does NOT kill the stale instance before regenerating (kill=%s write=%s)\n' "$_kill_line" "$_write_line" >&2
  record_failure "R42 tray install kills stale instance before regenerating"
fi
# R44: toggle OFF always restores the GPU to virt-manager — via profile_apply_mode
# off (re-inserts ONLY the GPU/audio hostdev from the fragment into the CURRENT
# live XML). If the fragment is missing, profile_apply_mode off tries the one-
# release fallback (extract from an old full backup) and refuses if that fails.
# The R42 _la_ensure_with_gpu_variant helper is GONE (replaced by recognition +
# fragments); the toggle calls profile_recognize + profile_apply_mode instead.
if grep -Fq '_la_ensure_with_gpu_variant()' "$VFIO_SCRIPT"; then
  printf 'FAIL: R44 _la_ensure_with_gpu_variant helper still defined (replaced by profile_apply_mode)\n' >&2
  record_failure "R44 _la_ensure_with_gpu_variant helper removed"
else
  printf 'PASS: R44 _la_ensure_with_gpu_variant helper removed (replaced by profile_apply_mode)\n'
fi
_pam_fn="$(sed -n '/^profile_apply_mode()/,/^}/p' "$VFIO_SCRIPT")"
# profile_apply_mode off must refuse (not guess) when there is no fragment AND no live GPU.
assert_contains_text \
  "R44 profile_apply_mode off refuses when the fragment is missing" \
  'REFUSE: no GPU fragment for' \
  "$_pam_fn"
# profile_apply_mode off must try the one-release fallback from an old full backup.
assert_contains_text \
  "R44 profile_apply_mode off tries the old-backup fallback" \
  'live-attach-backup-$_dom.xml' \
  "$_pam_fn"
# profile_apply_mode must enforce the device-diff safety invariant (only GPU/audio may differ).
assert_contains_text \
  "R44 profile_apply_mode enforces the device-diff safety invariant" \
  'safety invariant' \
  "$_pam_fn"
assert_contains_text \
  "R44 profile_apply_mode gates on the VM being shut off" \
  '[[ "$_state" != "shut off" ]]' \
  "$_pam_fn"

# R41+: the icon itself is clickable (left-click toggles, middle-click status).
assert_contains_file \
  "R41+ tray applet wires an activated (click) handler" \
  'def on_activated(reason):' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41+ tray applet connects the activated signal" \
  'tray.activated.connect(on_activated)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41+ tray applet left-click (Trigger) toggles the hotplug" \
  'QtWidgets.QSystemTrayIcon.Trigger' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R41+ tray applet middle-click shows the status dialog" \
  'QtWidgets.QSystemTrayIcon.MiddleClick' \
  "$VFIO_SCRIPT"

# --- R43b: GPU detection via awk reconstruction (used by R44 recognition) ---
# libvirt splits the PCI address across domain=/bus=/slot=/function= attributes,
# so a LITERAL grep for the BDF string NEVER matches a real dumpxml. R44's
# profile_recognize / profile_apply_mode route GPU detection through
# _xml_has_gpu_hostdev, which reconstructs the BDF with awk (same parser the
# install path uses) before the membership grep.
assert_contains_file \
  "R43b _xml_has_gpu_hostdev helper defined" \
  '_xml_has_gpu_hostdev() {' \
  "$VFIO_SCRIPT"
# R44: profile_recognize must use _xml_has_gpu_hostdev for GPU detection.
_pr_fn="$(sed -n '/^profile_recognize()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R44 profile_recognize detects the GPU via _xml_has_gpu_hostdev" \
  '_xml_has_gpu_hostdev "$_gpu_bdf"' \
  "$_pr_fn"
# Functional proof: on a real libvirt VM XML (split attributes) the OLD literal
# grep fails but the NEW helper succeeds — this is the exact failure that made
# toggle OFF skip the VM and leave the GPU removed from virt-manager.
_mock_xml="<domain type='kvm'><name>win11</name><devices>  <hostdev mode='subsystem' type='pci' managed='yes'>    <source>      <address type='pci' domain='0x0000' bus='0x0e' slot='0x00' function='0x0'/>    </source>  </hostdev></devices></domain>"
# The helper must find the GPU hostdev (BDF reconstructed from the split attrs).
if printf '%s' "$_mock_xml" | _xml_has_gpu_hostdev "0000:0e:00.0" 2>/dev/null; then
  printf 'PASS: R43b helper detects the GPU in split-attribute XML (0000:0e:00.0)\n'
else
  printf 'FAIL: R43b helper did NOT detect the GPU in split-attribute XML\n' >&2
  record_failure "R43b helper detects GPU in split-attribute XML"
fi
# The OLD literal grep must FAIL on the same XML (proves the bug it fixed).
if printf '%s' "$_mock_xml" | grep -Fixq "0000:0e:00.0" 2>/dev/null; then
  printf 'FAIL: R43b a literal BDF grep unexpectedly matched split-attribute XML (the bug premise is wrong)\n' >&2
  record_failure "R43b literal grep fails on split-attribute XML (bug premise)"
else
  printf 'PASS: R43b a literal BDF grep does NOT match split-attribute XML (the bug the helper fixes)\n'
fi
# Negative: a different BDF must not be detected.
if printf '%s' "$_mock_xml" | _xml_has_gpu_hostdev "0000:0f:00.0" 2>/dev/null; then
  printf 'FAIL: R43b helper falsely detected an absent BDF (0000:0f:00.0)\n' >&2
  record_failure "R43b helper rejects an absent BDF"
else
  printf 'PASS: R43b helper rejects an absent BDF (0000:0f:00.0)\n'
fi
# Negative: XML with no hostdev must not be detected.
if printf '%s' "<domain type='kvm'><devices></devices></domain>" | _xml_has_gpu_hostdev "0000:0e:00.0" 2>/dev/null; then
  printf 'FAIL: R43b helper falsely detected the GPU in a hostdev-less XML\n' >&2
  record_failure "R43b helper rejects hostdev-less XML"
else
  printf 'PASS: R43b helper rejects a hostdev-less XML\n'
fi
# Negative: an empty needle is a safe non-match (returns 1, no match).
if printf '%s' "$_mock_xml" | _xml_has_gpu_hostdev "" 2>/dev/null; then
  printf 'FAIL: R43b helper matched on an empty needle\n' >&2
  record_failure "R43b helper rejects an empty needle"
else
  printf 'PASS: R43b helper rejects an empty needle\n'
fi

# ===================== R44 functional: toggle preserves unrelated devices =====================
# ACCEPTANCE: add a <disk> + a Looking-Glass <shmem> to the VM, then toggle off->on->off.
# The extra disk + shmem MUST survive every toggle; ONLY the GPU hostdev is added/removed.
# Also: missing fragment + no live GPU => profile_apply_mode off refuses (no define).
# Uses a fake virsh + fake virt-xml-validate + temp CONF_FILE/profile dir (no root, no real libvirt).
_fn_root="$(mktemp -d)"
_fn_bin="$_fn_root/bin"
mkdir -p "$_fn_bin"
# Local pass/fail helpers for the functional block (record into the shared
# FAILED_ASSERTIONS list so the FAIL SUMMARY covers them).
ok_fn() { printf 'PASS: %s\n' "$1"; }
bad_fn() { printf 'FAIL: %s\n' "$1" >&2; record_failure "$1"; }
# Fake virsh: dumpxml/domstate read the live XML store; define writes to it.
_fn_live="$_fn_root/win11.xml"
_fn_list="$_fn_root/la-vms"
cat >"$_fn_live" <<'XMLEOF'
<domain type='kvm'>
  <name>win11</name>
  <uuid>11111111-2222-3333-4444-555555555555</uuid>
  <memory unit='KiB'>8388608</memory>
  <vcpu placement='static'>4</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type><boot dev='hd'/></os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/win11.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <shmem name='looking-glass'>
      <model type='ivshmem-plain'/>
      <size unit='M'>64</size>
    </shmem>
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source><address type='pci' domain='0x0000' bus='0x0e' slot='0x00' function='0x0'/></source>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </hostdev>
  </devices>
</domain>
XMLEOF
cat >"$_fn_bin/virsh" <<'VIRSH'
#!/usr/bin/env bash
# fake virsh: -c qemu:///system <subcmd> ...
shift 2  # drop -c qemu:///system
sub="$1"; shift
case "$sub" in
  list) echo win11 ;;
  domstate) echo "shut off" ;;
  dumpxml) cat "$VIRSH_LIVE" ;;
  define) cp -f "$1" "$VIRSH_LIVE" ;;
esac
VIRSH
chmod +x "$_fn_bin/virsh"
# Fake virt-xml-validate: always passes (the mock XML is structurally fine; we
# only test the device-add/remove logic, not libvirt's full schema).
cat >"$_fn_bin/virt-xml-validate" <<'VXV'
#!/usr/bin/env bash
exit 0
VXV
chmod +x "$_fn_bin/virt-xml-validate"
_fn_conf="$_fn_root/vfio.conf"
cat >"$_fn_conf" <<EOF
GUEST_GPU_BDF="0000:0e:00.0"
GUEST_AUDIO_BDFS_CSV=""
VFIO_DYNAMIC_LIVE_ATTACH="1"
EOF
printf 'win11\n' >"$_fn_list"
# R44: redirect the profile dir to a temp dir via VFIO_LA_PROFILES_DIR so the
# fragment extraction + manifest write succeed without root.
_fn_profiles="$_fn_root/profiles"
mkdir -p "$_fn_profiles"
# R44: redirect the one-release fallback backup dir to an EMPTY temp dir so the
# missing-fragment REFUSE path can be exercised without a real system backup
# (whose GPU BDF may match the mock 0000:0e:00.0) satisfying the fallback and
# silently re-inserting the GPU instead of refusing.
_fn_legacy="$_fn_root/legacy"
mkdir -p "$_fn_legacy"
# Run the functional toggle in a subshell with the fakes on PATH + redirected
# CONF_FILE / profile dir / mode file / live-attach list. Source vfio.sh first.
_fn_out="$_fn_root/out.txt"
VIRSH_LIVE="$_fn_live" PATH="$_fn_bin:$PATH" \
  DRY_RUN=0 CONF_FILE="$_fn_conf" \
  VFIO_LA_PROFILES_DIR="$_fn_profiles" \
  LIVE_ATTACH_MODE_FILE="$_fn_root/la-mode" \
  LIVE_ATTACH_VM_LIST="$_fn_list" \
  LIVE_ATTACH_GPU_XML="$_fn_root/la-gpu.xml" \
  LIVE_ATTACH_AUDIO_XML="$_fn_root/la-audio.xml" \
  VFIO_LA_LEGACY_DIR="$_fn_legacy" \
  bash -c "source '$VFIO_SCRIPT' >/dev/null 2>&1; . '$_fn_conf'; \
    profile_recognize win11 >/dev/null; \
    profile_apply_mode win11 on  >/dev/null; echo ON_DONE; \
    profile_recognize win11 >/dev/null; \
    profile_apply_mode win11 off >/dev/null; echo OFF_DONE; \
    profile_recognize win11 >/dev/null; \
    profile_apply_mode win11 on  >/dev/null; echo ON2_DONE" >"$_fn_out" 2>&1 || true

# Helper: check the live XML for a substring.
_has() { grep -Fq -- "$1" "$_fn_live" 2>/dev/null; }
# Quote-agnostic regex helper: a toggle runs the live XML through Python's
# ET.write, which round-trips single-quoted attributes to DOUBLE quotes
# (dev='vda' -> dev="vda"). A fixed-string _has on a quoted attribute would
# falsely report the device "lost" after the first toggle. _hasq matches
# either quote style via an ERE character class ["'].
_hasq() { grep -Eq -- "$1" "$_fn_live" 2>/dev/null; }

# After the off->on->off->on sequence, the live XML is in mode=on (GPU stripped).
# The extra disk + LG shmem MUST survive every toggle.
if _hasq "dev=[\"']vda[\"']"; then ok_fn "extra disk survives the toggle sequence"; else bad_fn "extra disk was lost (safety invariant failed)"; fi
if _hasq "name=[\"']looking-glass[\"']"; then ok_fn "Looking Glass shmem survives the toggle sequence"; else bad_fn "Looking Glass shmem was lost (safety invariant failed)"; fi
# Final state (mode=on): the GPU hostdev source BDF must be ABSENT (stripped).
# Match the source bus 0x0e (unique to the GPU hostdev; the guest address is
# bus 0x01) in either quote style.
if _hasq "bus=[\"']0x0e[\"']"; then bad_fn "GPU hostdev present in mode=on (strip failed)"; else ok_fn "GPU hostdev stripped in mode=on"; fi

# Now toggle OFF (re-insert the GPU from the fragment) and confirm the GPU returns
# while the disk + shmem STILL survive.
VIRSH_LIVE="$_fn_live" PATH="$_fn_bin:$PATH" \
  DRY_RUN=0 CONF_FILE="$_fn_conf" \
  VFIO_LA_PROFILES_DIR="$_fn_profiles" \
  LIVE_ATTACH_MODE_FILE="$_fn_root/la-mode" \
  LIVE_ATTACH_VM_LIST="$_fn_list" \
  LIVE_ATTACH_GPU_XML="$_fn_root/la-gpu.xml" \
  LIVE_ATTACH_AUDIO_XML="$_fn_root/la-audio.xml" \
  VFIO_LA_LEGACY_DIR="$_fn_legacy" \
  bash -c "source '$VFIO_SCRIPT' >/dev/null 2>&1; . '$_fn_conf'; \
    profile_recognize win11 >/dev/null; \
    profile_apply_mode win11 off >/dev/null; echo OFF2_DONE" >>"$_fn_out" 2>&1 || true
if _hasq "bus=[\"']0x0e[\"']"; then ok_fn "GPU hostdev re-inserted in mode=off (toggle off restores the GPU)"; else bad_fn "GPU hostdev missing in mode=off (toggle off did not restore the GPU)"; fi
if _hasq "dev=[\"']vda[\"']"; then ok_fn "extra disk survives toggle off"; else bad_fn "extra disk lost on toggle off"; fi
if _hasq "name=[\"']looking-glass[\"']"; then ok_fn "Looking Glass shmem survives toggle off"; else bad_fn "Looking Glass shmem lost on toggle off"; fi

# Missing-fragment refuse: strip the GPU (mode=on), delete the fragment, then try
# mode=off. profile_apply_mode off must REFUSE (no fragment + no live GPU) and NOT
# define (the live XML stays GPU-less). Returns non-zero.
VIRSH_LIVE="$_fn_live" PATH="$_fn_bin:$PATH" \
  DRY_RUN=0 CONF_FILE="$_fn_conf" \
  VFIO_LA_PROFILES_DIR="$_fn_profiles" \
  LIVE_ATTACH_MODE_FILE="$_fn_root/la-mode" \
  LIVE_ATTACH_VM_LIST="$_fn_list" \
  LIVE_ATTACH_GPU_XML="$_fn_root/la-gpu.xml" \
  LIVE_ATTACH_AUDIO_XML="$_fn_root/la-audio.xml" \
  VFIO_LA_LEGACY_DIR="$_fn_legacy" \
  bash -c "source '$VFIO_SCRIPT' >/dev/null 2>&1; . '$_fn_conf'; \
    profile_recognize win11 >/dev/null; \
    profile_apply_mode win11 on  >/dev/null; \
    rm -f \"\$(_la_profile_dir win11)/devices/gpu.xml\"; \
    profile_recognize win11 >/dev/null; \
    if profile_apply_mode win11 off >/dev/null 2>&1; then echo REFUSE_FAILED; else echo REFUSED_OK; fi" >>"$_fn_out" 2>&1 || true
if grep -Fq 'REFUSED_OK' "$_fn_out"; then ok_fn "missing fragment + no live GPU => profile_apply_mode off refuses (no define)"; else bad_fn "profile_apply_mode off did NOT refuse with a missing fragment (would guess a hostdev)"; fi
# And the live XML must still have NO GPU (the refuse did not define anything).
if _hasq "bus=[\"']0x0e[\"']"; then bad_fn "live XML changed after a refuse (define happened despite the refuse)"; else ok_fn "live XML unchanged after the missing-fragment refuse"; fi

# Sanity: the recognition manifest was written (at the redirected profile dir).
if [[ -f "$_fn_profiles/win11/manifest" ]]; then ok_fn "per-domain manifest written"; else bad_fn "per-domain manifest not written"; fi

rm -rf "$_fn_root"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'R23 live-attach regression checks passed.\n'
