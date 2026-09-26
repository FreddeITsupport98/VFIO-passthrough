#!/usr/bin/env bash
# R40 regression: Looking Glass host-side VM setup (absorbed from
# looking-glass-setup/look-setup.sh). Static wiring + functional python-patcher
# assertions for _lg_attach_shmem_to_vm (idempotent exit 3, dedup, validates),
# _lg_enable_vm_rebar / _lg_disable_vm_rebar. Does NOT need root or a real
# libvirt VM — it extracts the embedded python heredocs and runs them on a mock
# VM XML.
# shellcheck disable=SC2317,SC2329,SC2016
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VFIO_SCRIPT="$PROJECT_ROOT/vfio.sh"

if [[ ! -f "$VFIO_SCRIPT" ]]; then
  printf 'FAIL: missing vfio.sh at %s\n' "$VFIO_SCRIPT" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$VFIO_SCRIPT"

fail=0
FAILED_ASSERTIONS=()
record_failure() { FAILED_ASSERTIONS+=("$1"); fail=1; }
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (expected="%s", got="%s")\n' "$name" "$expected" "$actual" >&2
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
assert_not_contains_file() {
  local name="$1" pattern="$2" file="$3"
  if grep -Fq -- "$pattern" "$file"; then
    printf 'FAIL: %s (unexpected pattern found: %s)\n' "$name" "$pattern" >&2
    record_failure "$name"
  else
    printf 'PASS: %s\n' "$name"
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ===================== Static wiring =====================
assert_contains_file "LG_SHMEM_TMPFILES constant present" 'LG_SHMEM_TMPFILES="/etc/tmpfiles.d/10-looking-glass.conf"' "$VFIO_SCRIPT"
assert_contains_file "LG_SHMEM_NODE constant present" 'LG_SHMEM_NODE="/dev/shm/looking-glass"' "$VFIO_SCRIPT"
assert_contains_file "LG_SHMEM_NAME constant present" 'LG_SHMEM_NAME="looking-glass"' "$VFIO_SCRIPT"
assert_contains_file "LG_CLIENT_BIN constant present" 'LG_CLIENT_BIN="/usr/local/bin/looking-glass-client"' "$VFIO_SCRIPT"
assert_contains_file "install_looking_glass function exists" 'install_looking_glass() {' "$VFIO_SCRIPT"
assert_contains_file "remove_looking_glass function exists" 'remove_looking_glass() {' "$VFIO_SCRIPT"
assert_contains_file "looking_glass_status function exists" 'looking_glass_status() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_attach_shmem_to_vm helper exists" '_lg_attach_shmem_to_vm() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_enable_vm_rebar helper exists" '_lg_enable_vm_rebar() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_disable_vm_rebar helper exists" '_lg_disable_vm_rebar() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_remove_shmem_from_vm helper exists" '_lg_remove_shmem_from_vm() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_generate_user_config helper exists" '_lg_generate_user_config() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_write_tmpfiles helper exists" '_lg_write_tmpfiles() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_resize_shmem helper exists" '_lg_resize_shmem() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_setup_security helper exists" '_lg_setup_security() {' "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --install-looking-glass" '--install-looking-glass)' "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --remove-looking-glass" '--remove-looking-glass)' "$VFIO_SCRIPT"
assert_contains_file "MODE comment lists install-looking-glass" 'install-looking-glass' "$VFIO_SCRIPT"
assert_contains_file "MODE comment lists remove-looking-glass" 'remove-looking-glass' "$VFIO_SCRIPT"
assert_contains_file "main dispatch install-looking-glass" '"install-looking-glass"' "$VFIO_SCRIPT"
assert_contains_file "main dispatch remove-looking-glass" '"remove-looking-glass"' "$VFIO_SCRIPT"
assert_contains_file "menu has Set up Looking Glass option" 'Set up Looking Glass' "$VFIO_SCRIPT"
assert_contains_file "menu has Remove Looking Glass option" 'Remove Looking Glass' "$VFIO_SCRIPT"
assert_contains_file "fish completion includes --install-looking-glass" 'complete -c $cmd -l install-looking-glass' "$VFIO_SCRIPT"
assert_contains_file "fish completion includes --remove-looking-glass" 'complete -c $cmd -l remove-looking-glass' "$VFIO_SCRIPT"
assert_contains_file "bash completion opts include install-looking-glass" '--install-looking-glass' "$VFIO_SCRIPT"
assert_contains_file "zsh completion includes --install-looking-glass" "'--install-looking-glass[" "$VFIO_SCRIPT"
assert_contains_file "usage one-liner includes --install-looking-glass" '[--install-looking-glass]' "$VFIO_SCRIPT"
assert_contains_file "usage one-liner includes --remove-looking-glass" '[--remove-looking-glass]' "$VFIO_SCRIPT"
assert_contains_file "usage help has --install-looking-glass block" '  --install-looking-glass' "$VFIO_SCRIPT"
assert_contains_file "usage help has --remove-looking-glass block" '  --remove-looking-glass' "$VFIO_SCRIPT"
# R40b: compile/remove client functions + flags + menu + completions.
assert_contains_file "install_looking_glass_client function exists" 'install_looking_glass_client() {' "$VFIO_SCRIPT"
assert_contains_file "remove_looking_glass_client function exists" 'remove_looking_glass_client() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_binary_valid helper exists" '_lg_binary_valid() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_compile_from_source helper exists" '_lg_compile_from_source() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_set_vm_display_none helper exists" '_lg_set_vm_display_none() {' "$VFIO_SCRIPT"
assert_contains_file "_lg_restore_vm_display helper exists" '_lg_restore_vm_display() {' "$VFIO_SCRIPT"
assert_contains_file "_vm_tuning_status_block function exists" '_vm_tuning_status_block() {' "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --install-looking-glass-client" '--install-looking-glass-client)' "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --remove-looking-glass-client" '--remove-looking-glass-client)' "$VFIO_SCRIPT"
assert_contains_file "main dispatch install-looking-glass-client" '"install-looking-glass-client"' "$VFIO_SCRIPT"
assert_contains_file "main dispatch remove-looking-glass-client" '"remove-looking-glass-client"' "$VFIO_SCRIPT"
assert_contains_file "menu has Install (compile) looking-glass-client option" 'Install (compile) looking-glass-client' "$VFIO_SCRIPT"
assert_contains_file "menu has Remove looking-glass-client option" 'Remove looking-glass-client binary' "$VFIO_SCRIPT"
assert_contains_file "fish completion includes --install-looking-glass-client" 'complete -c $cmd -l install-looking-glass-client' "$VFIO_SCRIPT"
assert_contains_file "fish completion includes --remove-looking-glass-client" 'complete -c $cmd -l remove-looking-glass-client' "$VFIO_SCRIPT"
assert_contains_file "usage one-liner includes --install-looking-glass-client" '[--install-looking-glass-client]' "$VFIO_SCRIPT"
assert_contains_file "usage one-liner includes --remove-looking-glass-client" '[--remove-looking-glass-client]' "$VFIO_SCRIPT"
assert_contains_file "remove_looking_glass_client checks rpm -qf" 'rpm -qf' "$VFIO_SCRIPT"
assert_contains_file "remove_looking_glass_client checks dpkg -S" 'dpkg -S' "$VFIO_SCRIPT"
assert_contains_file "_vm_tuning_status_block called below menu" '_vm_tuning_status_block' "$VFIO_SCRIPT"
# R48d/R48f: the status block now shows a FULL 9-feature per-VM checklist (not just
# stealth/perf/LG). R48f split hypervisor-hide (core) and stealth-tune (cosmetic
# extension) into separate items. Assert the detection markers for the new features.
assert_contains_file "R48f status block line 1 has hypervisor-hide label" 'hypervisor-hide $_hh_sym' "$VFIO_SCRIPT"
assert_contains_file "R48f status block line 1 has stealth-tune label" 'stealth-tune $_st_sym' "$VFIO_SCRIPT"
assert_contains_file "R48d status block detects vBIOS ROM injection" '<rom file=' "$VFIO_SCRIPT"
assert_contains_file "R48d status block detects live-attach enrollment" '_la_list' "$VFIO_SCRIPT"
assert_contains_file "R48d status block detects hugepages" "<hugepages" "$VFIO_SCRIPT"
assert_contains_file "R48d status block detects virtio-win ISO path 1" 'VIRTIO_WIN_ISO_PATH' "$VFIO_SCRIPT"
assert_contains_file "R48d status block detects virtio-win ISO path 2" 'VIRTIO_WIN_FALLBACK_ISO' "$VFIO_SCRIPT"
assert_contains_file "R48d status block detects SATA disks via bus count" "bus='sata'" "$VFIO_SCRIPT"
assert_contains_file "R48d status block builds 2 lines per VM" '_line1' "$VFIO_SCRIPT"
assert_contains_file "R48d status block line 2 has vBIOS" 'vBIOS $_vb_sym' "$VFIO_SCRIPT"
assert_contains_file "R48d status block line 2 has live-attach" 'live-attach $_la_sym' "$VFIO_SCRIPT"
assert_contains_file "R48d status block line 2 has hugepages" 'hugepages $_hp_sym' "$VFIO_SCRIPT"
assert_contains_file "R48d status block line 2 has virtio-win" 'virtio-win $_vw_sym' "$VFIO_SCRIPT"
assert_contains_file "R48d status block line 2 has disks-virtio" 'disks-virtio $_dk_sym' "$VFIO_SCRIPT"
assert_contains_file "R48d status block line 1 uses ultimate-perf label" 'ultimate-perf $_p_sym' "$VFIO_SCRIPT"
# R48g: LG detection is now anchored to the shmem named 'looking-glass'
# specifically (a shared _lg_vm_shmem_info helper) instead of matching ANY
# ivshmem-plain + grabbing the size from any <size> element. Also the
# install_looking_glass header now warns the user to compile the client FIRST.
assert_contains_file "R48g _lg_vm_shmem_info helper defined" '_lg_vm_shmem_info() {' "$VFIO_SCRIPT"
assert_contains_file "R48g _lg_vm_shmem_info anchors to looking-glass name" 'blk ~ /looking-glass/' "$VFIO_SCRIPT"
assert_contains_file "R48g checklist uses _lg_vm_shmem_info (not any ivshmem-plain)" '_lg_vm_shmem_info "$_xml"' "$VFIO_SCRIPT"
assert_contains_file "R48g install_looking_glass has compile-client-first disclaimer" 'PREREQUISITE: Looking Glass needs the looking-glass-client binary' "$VFIO_SCRIPT"
assert_contains_file "R48g install_looking_glass disclaimer names the client install flag" '--install-looking-glass-client' "$VFIO_SCRIPT"
# R48h: the disclaimer is SMART (silent ✔ when compiled, full warning only when
# not) + a new _lg_client_warn_if_missing helper wired before the LG prompts +
# the per-VM checklist appends 'compiled ✔/✖' to the LG detail.
assert_contains_file "R48h _lg_client_warn_if_missing helper defined" '_lg_client_warn_if_missing() {' "$VFIO_SCRIPT"
assert_contains_file "R48h smart disclaimer prints the brief ✔-compiled branch" 'already compiled at $LG_CLIENT_BIN' "$VFIO_SCRIPT"
assert_contains_file "R48h checklist appends compiled marker to LG detail" 'compiled $_lg_compiled_sym' "$VFIO_SCRIPT"
assert_contains_file "R48h checklist computes compiled marker via _lg_binary_valid" '_lg_binary_valid "${LG_CLIENT_BIN' "$VFIO_SCRIPT"
_lg_warn_count="$(grep -cF '_lg_client_warn_if_missing' "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _lg_warn_count >= 3 )); then
  printf 'PASS: R48h _lg_client_warn_if_missing wired in >=3 places (def + 2 prompts: %d)\n' "$_lg_warn_count"
else
  printf 'FAIL: R48h _lg_client_warn_if_missing wired in only %d places (expected >=3)\n' "$_lg_warn_count" >&2
  record_failure "R48h _lg_client_warn_if_missing wired before the LG prompts"
fi
# R44/live-attach: _lg_set_vm_display_live_attach helper (the live-attach boot-
# display path, never video=none) MUST be defined, and install_looking_glass
# MUST branch on the live-attach mode (video=none for cold-attach / boot display
# for live-attach mode=on). In live-attach mode=on the GPU is ABSENT at boot, so
# video=none leaves Windows headless and the hot-attached GPU's display silently
# fails (black screen).
assert_contains_file "_lg_set_vm_display_live_attach helper exists" '_lg_set_vm_display_live_attach() {' "$VFIO_SCRIPT"
assert_contains_file "_vm_live_attach_mode_on helper exists" '_vm_live_attach_mode_on() {' "$VFIO_SCRIPT"
assert_contains_file "install_looking_glass branches on live-attach mode for video" '_vm_live_attach_mode_on' "$VFIO_SCRIPT"
assert_contains_file "install_looking_glass calls the live-attach display path" '_lg_set_vm_display_live_attach' "$VFIO_SCRIPT"
assert_contains_file "install_looking_glass sets video=none (cold-attach path)" 'video=none' "$VFIO_SCRIPT"
assert_contains_file "install_looking_glass sets the LG spice input block" 'Looking Glass input block' "$VFIO_SCRIPT"
# vBIOS is NOT duplicated in the LG path (vfio.sh already does vBIOS injection).
assert_contains_file "install_looking_glass notes vBIOS NOT touched" 'vBIOS is NOT touched here' "$VFIO_SCRIPT"
assert_contains_file "install_looking_glass notes client NOT auto-installed" 'client binary is NOT auto-installed' "$VFIO_SCRIPT"
# Recommended mode auto-answers Looking Glass = No (advanced opt-in).
assert_contains_file "recommended table: Looking Glass = No" '_RECOMMENDED_ANSWERS["Looking Glass"]=1' "$VFIO_SCRIPT"
# --reset removes Looking Glass.
assert_contains_file "reset calls remove_looking_glass" 'remove_looking_glass' "$VFIO_SCRIPT"
# R44/ReBAR vendor gate: the ReBAR sub-prompt is offered ONLY for NVIDIA (10de)
# / Intel (8086) guest GPUs. AMD (1002) skips it (a resized BAR0 breaks the
# Windows driver on RX 6900/9070 -> display engine fails -> black screen).
assert_contains_file "ReBAR sub-prompt gated by vendor case" '_rebar_vendor' "$VFIO_SCRIPT"
assert_contains_file "ReBAR offered for NVIDIA/Intel (10de|8086)" '10de|8086)' "$VFIO_SCRIPT"
assert_contains_file "ReBAR skipped for AMD (1002) with note" 'ReBAR 64-bit MMIO NOT offered for AMD' "$VFIO_SCRIPT"
# R44/LG video default: cold-attach defaults to video=none (the GPU is the
# only display via LG); live-attach mode=on keeps a virtio-gpu boot display.
assert_contains_file "LG video default none documented for cold-attach" "DEFAULT 'none' for cold-attach" "$VFIO_SCRIPT"
# Dynamic flow offers Looking Glass (both switcher + wizard).
_lg_dyn_count="$(grep -cF 'Set up Looking Glass (shared-memory display mirror) for the guest-GPU VM now?' "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _lg_dyn_count >= 2 )); then
  printf 'PASS: dynamic flow offers Looking Glass in both switcher + wizard (%d)\n' "$_lg_dyn_count"
else
  printf 'FAIL: dynamic flow does NOT offer Looking Glass in both paths (only %d)\n' "$_lg_dyn_count" >&2
  record_failure "dynamic flow offers Looking Glass in both switcher + wizard"
fi

# ===================== Functional: extract + run shmem patcher =====================
# Extract the python heredoc inside _lg_attach_shmem_to_vm (the first <<'PYEOF'
# ... PYEOF block after the function definition).
lg_shmem_py="$tmp_dir/lg_shmem.py"
awk '
  /_lg_attach_shmem_to_vm\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$lg_shmem_py"

if python3 -m py_compile "$lg_shmem_py" 2>/dev/null; then
  printf 'PASS: LG shmem patcher python compiles (py_compile)\n'
else
  printf 'FAIL: LG shmem patcher python does not compile\n' >&2
  record_failure "LG shmem patcher python compiles"
fi

# Mock VM XML (minimal, with a guest-GPU hostdev so it is a guest-GPU VM).
mock="$tmp_dir/mock.xml"
cat >"$mock" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <devices>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source><address domain="0x0000" bus="0x0e" slot="0x00" function="0x0"/></source>
    </hostdev>
  </devices>
</domain>
XEOF

# --- Run 1: attach a 64MB shmem device (no existing shmem) ---
tuned="$tmp_dir/tuned.xml"
cp "$mock" "$tuned"
set +e
python3 - "$tuned" "64" "looking-glass" <"$lg_shmem_py" >/dev/null 2>&1
rc1=$?
set -e
assert_eq "shmem patcher exit 0 on first attach (no existing shmem)" "0" "$rc1"
# ElementTree.write serializes attributes with double quotes, so the temp
# XML (pre-virsh-define) uses double-quoted attributes (libvirt re-serializes
# to single quotes after define; _lg_vm_has_shmem greps the post-define XML).
assert_contains_file "shmem device added with name=looking-glass" 'name="looking-glass"' "$tuned"
assert_contains_file "shmem model ivshmem-plain" 'model type="ivshmem-plain"' "$tuned"
assert_contains_file "shmem size 64MB" '<size unit="M">64</size>' "$tuned"

# --- Run 2: re-run with same size -> idempotent (exit 3) ---
set +e
python3 - "$tuned" "64" "looking-glass" <"$lg_shmem_py" >/dev/null 2>&1
rc2=$?
set -e
assert_eq "shmem patcher idempotent (exit 3 on same-size re-run)" "3" "$rc2"

# --- Run 3: change size 64 -> 128 -> patches (exit 0), no duplicate ---
set +e
python3 - "$tuned" "128" "looking-glass" <"$lg_shmem_py" >/dev/null 2>&1
rc3=$?
set -e
assert_eq "shmem patcher exit 0 on size change" "0" "$rc3"
assert_contains_file "shmem size updated to 128MB" '<size unit="M">128</size>' "$tuned"
# Must NOT have two looking-glass shmem devices (dedup).
_dups="$(grep -c 'name="looking-glass"' "$tuned" 2>/dev/null || echo 0)"
assert_eq "shmem dedup (exactly one looking-glass device after size change)" "1" "$_dups"

# --- Run 4: validate the patched XML with virt-xml-validate (if available) ---
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$tuned" >/dev/null 2>&1; then
    printf 'PASS: shmem-tuned XML validates (virt-xml-validate)\n'
  else
    printf 'FAIL: shmem-tuned XML fails virt-xml-validate\n' >&2
    record_failure "shmem-tuned XML validates"
  fi
fi

# ===================== Functional: ReBAR patcher =====================
lg_rebar_en="$tmp_dir/lg_rebar_en.py"
awk '
  /_lg_enable_vm_rebar\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$lg_rebar_en.py"

lg_rebar_dis="$tmp_dir/lg_rebar_dis.py"
awk '
  /_lg_disable_vm_rebar\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$lg_rebar_dis.py"

if python3 -m py_compile "$lg_rebar_en.py" 2>/dev/null; then
  printf 'PASS: LG rebar-enable patcher python compiles\n'
else
  printf 'FAIL: LG rebar-enable patcher python does not compile\n' >&2
  record_failure "LG rebar-enable patcher python compiles"
fi
if python3 -m py_compile "$lg_rebar_dis.py" 2>/dev/null; then
  printf 'PASS: LG rebar-disable patcher python compiles\n'
else
  printf 'FAIL: LG rebar-disable patcher python does not compile\n' >&2
  record_failure "LG rebar-disable patcher python compiles"
fi

# Enable ReBAR on the tuned XML (already has shmem from above).
set +e
python3 - "$tuned" <"$lg_rebar_en.py" >/dev/null 2>&1
rc_reb1=$?
set -e
assert_eq "rebar-enable exit 0 on first enable" "0" "$rc_reb1"
assert_contains_file "rebar fw_cfg arg added" 'opt/ovmf/X-PciMmio64Mb' "$tuned"
# Idempotent: re-run -> exit 3.
set +e
python3 - "$tuned" <"$lg_rebar_en.py" >/dev/null 2>&1
rc_reb2=$?
set -e
assert_eq "rebar-enable idempotent (exit 3 on re-run)" "3" "$rc_reb2"
# Disable ReBAR -> exit 0, arg removed.
set +e
python3 - "$tuned" <"$lg_rebar_dis.py" >/dev/null 2>&1
rc_reb3=$?
set -e
assert_eq "rebar-disable exit 0 after enable" "0" "$rc_reb3"
assert_not_contains_file "rebar fw_cfg arg removed after disable" 'opt/ovmf/X-PciMmio64Mb' "$tuned"
# Disable again (not present) -> exit 3.
set +e
python3 - "$tuned" <"$lg_rebar_dis.py" >/dev/null 2>&1
rc_reb4=$?
set -e
assert_eq "rebar-disable idempotent (exit 3 when not present)" "3" "$rc_reb4"
# shmem device survives rebar toggle (rebar patcher must not drop shmem).
assert_contains_file "shmem device survives rebar toggle" 'name="looking-glass"' "$tuned"

# ===================== R40b/R42: Functional display patcher =====================
# _lg_set_vm_display_none: set <video><model type='none'/> + normalize spice to
# the Looking Glass input block (port=-1, autoport=no, <listen type='address'/>,
# <image compression='off'/> — a local 127.0.0.1 port for LG's PureSpice input).
# _lg_restore_vm_display: restore <video><model type='virtio' heads='1' primary='yes'/>.
lg_display_none_py="$tmp_dir/lg_display_none.py"
awk '
  /_lg_set_vm_display_none\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$lg_display_none_py"

lg_display_restore_py="$tmp_dir/lg_display_restore.py"
awk '
  /_lg_restore_vm_display\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$lg_display_restore_py"

if python3 -m py_compile "$lg_display_none_py" 2>/dev/null; then
  printf 'PASS: LG display-none patcher python compiles\n'
else
  printf 'FAIL: LG display-none patcher python does not compile\n' >&2
  record_failure "LG display-none patcher python compiles"
fi
if python3 -m py_compile "$lg_display_restore_py" 2>/dev/null; then
  printf 'PASS: LG display-restore patcher python compiles\n'
else
  printf 'FAIL: LG display-restore patcher python does not compile\n' >&2
  record_failure "LG display-restore patcher python compiles"
fi

# Mock XML with <video><model type='virtio'> and <graphics type='spice'><listen type='none'>.
mock_display="$tmp_dir/mock_display.xml"
cat >"$mock_display" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <devices>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source><address domain="0x0000" bus="0x0e" slot="0x00" function="0x0"/></source>
    </hostdev>
    <graphics type="spice">
      <listen type="address" address="127.0.0.1"/>
    </graphics>
    <video>
      <model type="virtio" heads="1" primary="yes"/>
    </video>
  </devices>
</domain>
XEOF

# --- Run 1: set video=none + spice local-only ---
disp="$tmp_dir/disp.xml"
cp "$mock_display" "$disp"
set +e
python3 - "$disp" <"$lg_display_none_py" >/dev/null 2>&1
rc_dn1=$?
set -e
assert_eq "display-none exit 0 on first run" "0" "$rc_dn1"
assert_contains_file "video model set to none" 'type="none"' "$disp"
# R42: spice normalized to the Looking Glass input block (local 127.0.0.1 port).
assert_contains_file "spice graphics type spice" 'type="spice"' "$disp"
assert_contains_file "spice port=-1 (auto-alloc one insecure port)" 'port="-1"' "$disp"
assert_contains_file "spice autoport=no" 'autoport="no"' "$disp"
assert_contains_file "spice listen type=address (local 127.0.0.1)" 'listen type="address"' "$disp"
assert_contains_file "spice image compression=off (LG does its own compression)" 'compression="off"' "$disp"

# --- Run 2: idempotent (already none+local) -> exit 3 ---
set +e
python3 - "$disp" <"$lg_display_none_py" >/dev/null 2>&1
rc_dn2=$?
set -e
assert_eq "display-none idempotent (exit 3 on re-run)" "3" "$rc_dn2"

# --- Run 3: restore video to virtio ---
set +e
python3 - "$disp" <"$lg_display_restore_py" >/dev/null 2>&1
rc_dr1=$?
set -e
assert_eq "display-restore exit 0 after none" "0" "$rc_dr1"
assert_contains_file "video model restored to virtio" 'type="virtio"' "$disp"
assert_contains_file "video heads=1 preserved" 'heads="1"' "$disp"
assert_contains_file "video primary=yes preserved" 'primary="yes"' "$disp"
# spice input block stays after restore (restore only touches video, not spice).
assert_contains_file "spice listen stays address after restore" 'listen type="address"' "$disp"

# --- Run 4: restore idempotent (not currently 'none') -> exit 3 ---
set +e
python3 - "$disp" <"$lg_display_restore_py" >/dev/null 2>&1
rc_dr2=$?
set -e
assert_eq "display-restore idempotent (exit 3 when not none)" "3" "$rc_dr2"

# --- Run 5: validate the display-patched XML (if virt-xml-validate available) ---
if command -v virt-xml-validate >/dev/null 2>&1; then
  disp_val="$tmp_dir/disp_val.xml"
  cp "$mock_display" "$disp_val"
  python3 - "$disp_val" <"$lg_display_none_py" >/dev/null 2>&1 || true
  if virt-xml-validate "$disp_val" >/dev/null 2>&1; then
    printf 'PASS: display-none XML validates (virt-xml-validate)\n'
  else
    printf 'FAIL: display-none XML fails virt-xml-validate\n' >&2
    record_failure "display-none XML validates"
  fi
fi

# ===================== R44/live-attach: Functional live-attach display patcher =====================
# _lg_set_vm_display_live_attach: normalize spice to the LG input block BUT ensure
# the VM KEEPS a boot display (virtio-gpu), NEVER video=none. In live-attach
# mode=on the GPU is absent at boot; video=none leaves Windows headless and the
# hot-attached GPU's display silently fails (black screen). The patcher flips an
# existing video=none -> virtio and normalizes the spice graphics block.
lg_display_la_py="$tmp_dir/lg_display_la.py"
awk '
  /_lg_set_vm_display_live_attach\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$lg_display_la_py"

if python3 -m py_compile "$lg_display_la_py" 2>/dev/null; then
  printf 'PASS: LG display-live-attach patcher python compiles\n'
else
  printf 'FAIL: LG display-live-attach patcher python does not compile\n' >&2
  record_failure "LG display-live-attach patcher python compiles"
fi

# Mock XML #1: video=none (the broken state _lg_apply_to_vm used to leave) -> must flip to virtio.
mock_la_none="$tmp_dir/mock_la_none.xml"
cat >"$mock_la_none" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <devices>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source><address domain="0x0000" bus="0x0e" slot="0x00" function="0x0"/></source>
    </hostdev>
    <graphics type="spice">
      <listen type="address" address="127.0.0.1"/>
    </graphics>
    <video>
      <model type="none"/>
    </video>
  </devices>
</domain>
XEOF
# Mock XML #2: no video at all -> must add a virtio boot display.
mock_la_novideo="$tmp_dir/mock_la_novideo.xml"
cat >"$mock_la_novideo" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <devices>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source><address domain="0x0000" bus="0x0e" slot="0x00" function="0x0"/></source>
    </hostdev>
    <graphics type="spice">
      <listen type="address" address="127.0.0.1"/>
    </graphics>
  </devices>
</domain>
XEOF

# --- Run 1: video=none -> flip to virtio (the live-attach boot display) ---
la1="$tmp_dir/la1.xml"
cp "$mock_la_none" "$la1"
set +e
python3 - "$la1" <"$lg_display_la_py" >/dev/null 2>&1
rc_la1=$?
set -e
assert_eq "live-attach display patcher exit 0 on video=none -> virtio" "0" "$rc_la1"
assert_contains_file "live-attach video flipped none -> virtio (boot display)" 'type="virtio"' "$la1"
assert_not_contains_file "live-attach video is NOT none (boot display kept)" 'type="none"' "$la1"
assert_contains_file "live-attach video heads=1" 'heads="1"' "$la1"
assert_contains_file "live-attach video primary=yes" 'primary="yes"' "$la1"
assert_contains_file "live-attach spice normalized (port=-1)" 'port="-1"' "$la1"
assert_contains_file "live-attach spice normalized (autoport=no)" 'autoport="no"' "$la1"
assert_contains_file "live-attach spice listen type=address" 'listen type="address"' "$la1"
assert_contains_file "live-attach spice image compression=off" 'compression="off"' "$la1"

# --- Run 2: idempotent (already virtio + LG spice block) -> exit 3 ---
set +e
python3 - "$la1" <"$lg_display_la_py" >/dev/null 2>&1
rc_la2=$?
set -e
assert_eq "live-attach display patcher idempotent (exit 3 on re-run)" "3" "$rc_la2"

# --- Run 3: no video element -> add a virtio boot display ---
la3="$tmp_dir/la3.xml"
cp "$mock_la_novideo" "$la3"
set +e
python3 - "$la3" <"$lg_display_la_py" >/dev/null 2>&1
rc_la3=$?
set -e
assert_eq "live-attach display patcher exit 0 on missing video (adds boot display)" "0" "$rc_la3"
assert_contains_file "live-attach adds virtio boot display on missing video" 'type="virtio"' "$la3"
assert_contains_file "live-attach added video heads=1" 'heads="1"' "$la3"
assert_contains_file "live-attach added video primary=yes" 'primary="yes"' "$la3"

# --- Run 4: validate the live-attach-patched XML (if virt-xml-validate available) ---
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$la1" >/dev/null 2>&1; then
    printf 'PASS: live-attach display XML validates (virt-xml-validate)\n'
  else
    printf 'FAIL: live-attach display XML fails virt-xml-validate\n' >&2
    record_failure "live-attach display XML validates"
  fi
fi

# --- Run 5: boot-display pin OFF the GPU/audio reserved guest buses ---
# _lg_set_vm_display_live_attach MUST pin the virtio-gpu boot display to a free
# pcie-root-port whose bus is NOT the GPU's (0x06) or audio's (0x07) reserved
# guest bus (VFIO_LA_RESERVED_GUEST_BUSES). Otherwise libvirt auto-places the
# boot display on the GPU's freed root-port at boot (mode=on strips the GPU)
# and the later GPU hot-attach (keep-guest-address 0x06) collides -> libvirt
# reassigns the GPU to another bus -> Windows sees a new device -> Code 28
# "no driver installed". Root-cause fix for the hotplug "no driver installed"
# symptom on a primed VM.
mock_la_pin="$tmp_dir/mock_la_pin.xml"
cat >"$mock_la_pin" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <devices>
    <controller type="pci" index="5" model="pcie-root-port"/>
    <controller type="pci" index="6" model="pcie-root-port"/>
    <controller type="pci" index="7" model="pcie-root-port"/>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source><address domain="0x0000" bus="0x0e" slot="0x00" function="0x0"/></source>
      <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x0"/>
    </hostdev>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source><address domain="0x0000" bus="0x0e" slot="0x00" function="0x1"/></source>
      <address type="pci" domain="0x0000" bus="0x07" slot="0x00" function="0x0"/>
    </hostdev>
    <graphics type="spice">
      <listen type="address" address="127.0.0.1"/>
    </graphics>
    <video>
      <model type="none"/>
    </video>
  </devices>
</domain>
XEOF
la5="$tmp_dir/la5.xml"
cp "$mock_la_pin" "$la5"
set +e
VFIO_LA_RESERVED_GUEST_BUSES="0x06,0x07" python3 - "$la5" <"$lg_display_la_py" >/dev/null 2>&1
rc_la5=$?
set -e
assert_eq "live-attach display patcher exit 0 on pin run (video=none -> virtio + pin)" "0" "$rc_la5"
assert_contains_file "live-attach boot display pinned off GPU/audio bus (to 0x05)" 'bus="0x05"' "$la5"

# ===================== R48j: Fedora build-deps before source compile + LIVE build output + progress =====================
# Bug 1: on the Fedora/dnf path, when the COPR package failed and the code fell
# back to _lg_compile_from_source, it NEVER installed the Fedora build deps
# (the apt branch installs deps first; the dnf branch did not), so the clone +
# cmake + make died on missing headers and the binary was never produced.
# Bug 2: _lg_compile_from_source returned 0/1 via `printf '0'`/`printf '1'` on
# STDOUT, and the caller did `_ok=$(_lg_compile_from_source)` which captures ALL
# of stdout — so every note() + the build output + the log tail were SWALLOWED
# into $_ok and never reached the terminal (the user saw nothing for minutes,
# then just the final error). R48j-fix: the function now returns via EXIT CODE,
# tees the clone/cmake/make output to BOTH the terminal (live progress — git's
# clone %, cmake config, make compiling each file) AND $LG_BUILD_LOG (failure
# tail preserved), adds --progress to git clone, and prints step indicators
# (1/4 ... 4/4). The deps install also shows dnf/apt's own download progress.
assert_contains_file "R48j dnf fallback installs Fedora build deps" 'Installing Looking Glass client build dependencies (Fedora' "$VFIO_SCRIPT"
assert_contains_file "R48j dnf fallback deps note mentions dnf download progress" 'dnf shows download progress' "$VFIO_SCRIPT"
assert_contains_file "R48j dnf fallback installs spice-protocol" 'spice-protocol' "$VFIO_SCRIPT"
assert_contains_file "R48j dnf fallback installs libglvnd-devel" 'libglvnd-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j dnf fallback installs wayland-protocols-devel" 'wayland-protocols-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j dnf fallback installs pipewire-devel" 'pipewire-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j dnf fallback installs libdecor-devel" 'libdecor-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j apt fallback deps note mentions apt download progress" 'apt shows download progress' "$VFIO_SCRIPT"
assert_contains_file "R48j LG_BUILD_LOG constant defined" 'LG_BUILD_LOG="/tmp/looking-glass-client-build.log"' "$VFIO_SCRIPT"
assert_contains_file "R48j compile helper tees clone to terminal + log" 'git clone --progress --recurse-submodules https://github.com/gnif/LookingGlass.git "$_src" 2>&1 | tee -a "$LG_BUILD_LOG"' "$VFIO_SCRIPT"
_cmretry_fn="$(sed -n '/^_lg_cmake_with_retry()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R48j/R48j-cross _lg_cmake_with_retry tees cmake to terminal + log" \
  'cmake -G "$_gen" "$@" ../) 2>&1 | tee -a "$LG_BUILD_LOG"' \
  "$_cmretry_fn"
assert_contains_file "R48j compile helper tees make to terminal + log" '"$_builder" -j"$_nproc") 2>&1 | tee -a "$LG_BUILD_LOG"' "$VFIO_SCRIPT"
assert_contains_file "R48j compile helper prints log tail on clone failure" '_lg_dump_log_tail "$LG_BUILD_LOG"' "$VFIO_SCRIPT"
assert_contains_file "R48j _lg_dump_log_tail helper defined" '_lg_dump_log_tail() {' "$VFIO_SCRIPT"
assert_contains_file "R48j _lg_dump_log_tail prints log path note" 'Full build log kept at' "$VFIO_SCRIPT"
assert_contains_file "R48j compile helper prints Step 1/4 clone indicator" 'Step 1/4: Cloning Looking Glass source' "$VFIO_SCRIPT"
assert_contains_file "R48j compile helper prints Step 3/4 build indicator" 'Step 3/4: Building with' "$VFIO_SCRIPT"
assert_contains_file "R48j compile helper prints Step 4/4 install indicator" 'Step 4/4: Installing binary to' "$VFIO_SCRIPT"
# R48j-fix: the function must return via EXIT CODE, not stdout printf. The old
# `printf '0'`/`printf '1'` on stdout got captured by `_ok=$(...)` and hid all
# the diagnostics. Assert the stdout-printf return is GONE from the function body.
_lg_compile_fn_body="$(sed -n '/^_lg_compile_from_source()/,/^}/p' "$VFIO_SCRIPT")"
if printf '%s\n' "$_lg_compile_fn_body" | grep -Fq "printf '0'"; then
  printf 'FAIL: R48j-fix _lg_compile_from_source still returns via stdout printf (swallowed diagnostics)\n' >&2
  record_failure "R48j-fix compile helper returns via exit code (no stdout printf)"
else
  printf 'PASS: R48j-fix compile helper returns via exit code (no stdout printf)\n'
fi
# The caller must NOT capture stdout (the old `_ok=$(_lg_compile_from_source)`);
# it should use the exit code so diagnostics reach the terminal.
assert_contains_file "R48j-fix dnf caller uses exit code (no stdout capture)" '_lg_compile_from_source && _ok=1 || _ok=0' "$VFIO_SCRIPT"
# The old full-silence redirect on every step must be gone (no bare >/dev/null 2>&1
# after the git clone/cmake/make lines in the compile helper).
_lg_old_silence_count="$(awk '/_lg_compile_from_source\(\)/{in_fn=1} in_fn&&/git clone --recurse-submodules.*>\/dev\/null 2>&1/{c++} in_fn&&/cmake -G.*>\/dev\/null 2>&1/{c++} in_fn&&/"\$_builder" -j.*>\/dev\/null 2>&1/{c++} /^}/{if(in_fn){in_fn=0}} END{print c+0}' "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _lg_old_silence_count == 0 )); then
  printf 'PASS: R48j compile helper no longer fully silences clone/cmake/make (%d old-redirects)\n' "$_lg_old_silence_count"
else
  printf 'FAIL: R48j compile helper still fully silences clone/cmake/make (%d old-redirects remain)\n' "$_lg_old_silence_count" >&2
  record_failure "R48j compile helper no longer fully silences clone/cmake/make"
fi
# Sanity: the build log is actually USED (output tee'd via $LG_BUILD_LOG, not
# dropped). Count lines referencing LG_BUILD_LOG inside the compile helper (the
# : >"$LG_BUILD_LOG" init + clone/cmake/make/cp tee redirects + the tail call).
_lg_log_refs="$(awk '/_lg_compile_from_source\(\)/{in_fn=1} in_fn&&/LG_BUILD_LOG/{c++} in_fn&&/^}/{in_fn=0} END{print c+0}' "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _lg_log_refs >= 5 )); then
  printf 'PASS: R48j build log referenced on %d line(s) inside compile helper (init + clone + cmake + make + cp + tail)\n' "$_lg_log_refs"
else
  printf 'FAIL: R48j build log referenced on only %d line(s) (expected >=5: init + clone + cmake + make + cp/tail)\n' "$_lg_log_refs" >&2
  record_failure "R48j build log referenced on enough lines inside compile helper"
fi

# ===================== R48j-cross: openSUSE / Void / Gentoo build-dep branches =====================
# The compile fallback previously only handled dnf / pacman / apt. R48j-cross
# adds the official Looking Glass wiki build-dependency lists for openSUSE
# (zypper), Void (xbps-install), and Gentoo (emerge), and aligns the Arch list
# with the wiki (libgl/libegl, ttf-dejavu, libsamplerate). Each branch shows the
# package manager's own download progress live and then calls the shared
# _lg_compile_from_source (exit-code return) so diagnostics reach the terminal.
assert_contains_file "R48j-cross detects openSUSE (zypper)" 'Detected openSUSE-family (zypper).' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross zypper installs spice-protocol-devel" 'spice-protocol-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross zypper installs libglvnd-devel" 'libglvnd-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross zypper installs wayland-protocols-devel" 'wayland-protocols-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross zypper installs libdecor-devel" 'libdecor-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross zypper installs pipewire-devel" 'pipewire-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross zypper installs libsamplerate-devel" 'libsamplerate-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross zypper notes download progress" 'zypper shows download progress' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross detects Void (xbps-install)" 'Detected Void Linux (xbps).' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross xbps installs spice-protocol" 'spice-protocol' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross xbps installs libglvnd-devel" 'libglvnd-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross xbps installs wayland-devel" 'wayland-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross xbps installs libdecor-devel" 'libdecor-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross xbps installs pipewire-devel" 'pipewire-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross xbps installs dejavu-fonts-ttf" 'dejavu-fonts-ttf' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross xbps notes download progress" 'xbps shows download progress' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross detects Gentoo (emerge)" 'Detected Gentoo (emerge).' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross emerge installs spice-protocol" 'app-emulation/spice-protocol' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross emerge installs libglvnd" 'media-libs/libglvnd' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross emerge installs wayland-protocols" 'dev-libs/wayland-protocols' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross emerge installs libdecor" 'gui-libs/libdecor' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross emerge installs libsamplerate" 'media-libs/libsamplerate' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross emerge notes build progress" 'emerge shows build progress' "$VFIO_SCRIPT"
# Arch list aligned with the official wiki (libgl/libegl, ttf-dejavu, libsamplerate).
assert_contains_file "R48j-cross Arch aligned: installs libgl" 'libgl libegl' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross Arch aligned: installs ttf-dejavu" 'ttf-dejavu' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross Arch aligned: installs libsamplerate" 'libsamplerate' "$VFIO_SCRIPT"
assert_contains_file "R48j-cross Arch notes download progress" 'pacman shows download progress' "$VFIO_SCRIPT"
# Each new branch must call _lg_compile_from_source (exit-code return) so the
# live build output + diagnostics are NOT swallowed by stdout capture.
assert_contains_file "R48j-cross zypper calls compile via exit code" '_lg_compile_from_source && _ok=1 || _ok=0' "$VFIO_SCRIPT"
# The fallback error message must name all six package managers now.
assert_contains_file "R48j-cross fallback error names all six package managers" 'dnf/pacman/apt/zypper/xbps-install/emerge' "$VFIO_SCRIPT"
# Sanity: the install function body must reference all six package-manager checks.
_lg_install_fn_body="$(sed -n '/^install_looking_glass_client()/,/^}/p' "$VFIO_SCRIPT")"
_lg_pm_count="$(printf '%s\n' "$_lg_install_fn_body" | grep -cE 'have_cmd (dnf|pacman|apt-get|zypper|xbps-install|emerge)')"
if (( _lg_pm_count >= 6 )); then
  printf 'PASS: R48j-cross install body checks all 6 package managers (%d)\n' "$_lg_pm_count"
else
  printf 'FAIL: R48j-cross install body only checks %d package manager(s) (expected >=6)\n' "$_lg_pm_count" >&2
  record_failure "R48j-cross install body checks all 6 package managers"
fi

# ===================== R48j-selfheal: auto-install missing deps + cmake retry =====================
# Bug: the bleeding-edge Looking Glass master CMakeLists requires fuse3>=3.10
# (via pkg_check_modules), which was NOT in any of the up-front dep lists, so
# cmake configure died with "The following required packages were not found: -
# fuse3>=3.10" and the build aborted. R48j-selfheal adds fuse3 to every distro's
# up-front dep list AND makes cmake self-healing: on a missing pkg-config module
# failure, parse the error, map the module(s) to distro packages, auto-install
# them, and retry (caps at 3 attempts so a non-missing-module failure does not
# loop forever).
assert_contains_file "R48j-selfheal _lg_pkg_to_distro_pkg helper defined" '_lg_pkg_to_distro_pkg() {' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal _lg_install_pkgs helper defined" '_lg_install_pkgs() {' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal _lg_extract_missing_modules helper defined" '_lg_extract_missing_modules() {' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal _lg_cmake_with_retry helper defined" '_lg_cmake_with_retry() {' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal _lg_compile_from_source uses _lg_cmake_with_retry" '_lg_cmake_with_retry "$_build" "$_gen" -DENABLE_BACKTRACE=no' "$VFIO_SCRIPT"
# fuse3 is now in EVERY distro's up-front dep list (so the known gap is closed).
assert_contains_file "R48j-selfheal dnf installs fuse3-devel" 'fuse3-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal pacman installs fuse3" 'fuse3' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal apt installs libfuse3-dev" 'libfuse3-dev' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal zypper installs fuse3-devel" 'fuse3-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal xbps installs fuse3-devel" 'fuse3-devel' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal emerge installs sys-fs/fuse:3" 'sys-fs/fuse:3' "$VFIO_SCRIPT"
# The extractor parses the cmake "required packages were not found" block.
_extract_fn="$(sed -n '/^_lg_extract_missing_modules()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R48j-selfheal extractor parses the missing-packages block" \
  'The following required packages were not found:' \
  "$_extract_fn"
assert_contains_text \
  "R48j-selfheal retry caps attempts at 3" \
  '_max=3' \
  "$_cmretry_fn"
assert_contains_text \
  "R48j-selfheal retry calls _lg_install_pkgs to auto-install" \
  '_lg_install_pkgs "${_lg_pm:-}" $_pkgs' \
  "$_cmretry_fn"
assert_contains_text \
  "R48j-selfheal retry prints the missing-modules display" \
  'missing pkg-config module(s): $_miss_disp' \
  "$_cmretry_fn"
assert_contains_text \
  "R48j-selfheal retry maps fuse3 module to dnf fuse3-devel" \
  'fuse3-devel' \
  "$(sed -n '/^_lg_pkg_to_distro_pkg()/,/^}/p' "$VFIO_SCRIPT")"
# _lg_pm is set per-branch so the retry helper knows which package manager to use.
assert_contains_file "R48j-selfheal dnf branch sets _lg_pm=dnf" '_lg_pm="dnf"' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal pacman branch sets _lg_pm=pacman" '_lg_pm="pacman"' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal apt branch sets _lg_pm=apt-get" '_lg_pm="apt-get"' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal zypper branch sets _lg_pm=zypper" '_lg_pm="zypper"' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal xbps branch sets _lg_pm=xbps-install" '_lg_pm="xbps-install"' "$VFIO_SCRIPT"
assert_contains_file "R48j-selfheal emerge branch sets _lg_pm=emerge" '_lg_pm="emerge"' "$VFIO_SCRIPT"

# ===================== R48m: Looking Glass desktop shortcut + localized desktop detection =====================
# After a successful compile/install, the script now installs a .desktop
# application-menu shortcut AND copies it to the operator's ACTUAL desktop folder
# — which is LOCALIZED per the user's language (Swedish "Skrivbord", German
# "Schreibtisch", French "Bureau", etc.), detected via the XDG user-dirs spec
# (~/.config/user-dirs.dirs -> XDG_DESKTOP_DIR), NOT a hardcoded ~/Desktop.
# Reports the detected locale. Idempotent (overwrites = shortcut recovery on
# re-run). Removed by remove_looking_glass_client (both the system menu entry
# AND the desktop copy).
assert_contains_file "R48m LG_CLIENT_DESKTOP constant defined" 'LG_CLIENT_DESKTOP="/usr/share/applications/looking-glass-client.desktop"' "$VFIO_SCRIPT"
assert_contains_file "R48m _lg_install_desktop_entry helper defined" '_lg_install_desktop_entry() {' "$VFIO_SCRIPT"
assert_contains_file "R48m _lg_remove_desktop_entry helper defined" '_lg_remove_desktop_entry() {' "$VFIO_SCRIPT"
assert_contains_file "R48m install_looking_glass_client calls _lg_install_desktop_entry" '_lg_install_desktop_entry' "$VFIO_SCRIPT"
assert_contains_file "R48m remove_looking_glass_client calls _lg_remove_desktop_entry" '_lg_remove_desktop_entry' "$VFIO_SCRIPT"
# The desktop entry has the right Exec + Name + Icon.
assert_contains_file "R48m desktop entry Exec points at LG_CLIENT_BIN" 'Exec=$LG_CLIENT_BIN' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop entry Name is Looking Glass" 'Name=Looking Glass' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop entry Icon is video-display" 'Icon=video-display' "$VFIO_SCRIPT"
# The helper detects the localized desktop folder via XDG user-dirs (NOT hardcoded).
assert_contains_file "R48m desktop helper reads XDG_DESKTOP_DIR from user-dirs.dirs" 'XDG_DESKTOP_DIR=' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop helper parses user-dirs.dirs with awk (not source)" 'awk -F= '"'"'/^XDG_DESKTOP_DIR=/' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop helper detects locale from user-dirs.locale" 'user-dirs.locale' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop helper falls back to LANG for locale" 'LANG' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop helper resolves SUDO_USER home" 'SUDO_USER' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop helper reports the detected locale" 'Desktop language:' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop helper copies shortcut to the desktop folder" 'Copied shortcut to desktop:' "$VFIO_SCRIPT"
assert_contains_file "R48m desktop helper chowns the desktop copy to the user" 'chown' "$VFIO_SCRIPT"
# The remove helper also cleans up the desktop copy (same localized detection).
assert_contains_file "R48m remove helper removes the desktop copy" 'Removed desktop shortcut:' "$VFIO_SCRIPT"
# The install output shows a shortcut-present checkmark (✔/✖) next to the
# compiled line so the operator sees at a glance whether the shortcut exists.
assert_contains_file "R48m install shows shortcut checkmark (✔/✖)" 'shortcut:' "$VFIO_SCRIPT"
assert_contains_file "R48m install computes shortcut symbol from LG_CLIENT_DESKTOP" 'if [[ -f "$LG_CLIENT_DESKTOP" ]]; then _sc_sym' "$VFIO_SCRIPT"
# R48m: auto-recovery helper — if the binary is valid but the .desktop is
# missing (user deleted it), recreate it. Root-gated; best-effort.
assert_contains_file "R48m _lg_recover_desktop_entry_if_missing helper defined" '_lg_recover_desktop_entry_if_missing() {' "$VFIO_SCRIPT"
assert_contains_file "R48m recovery helper checks _lg_binary_valid" '_lg_binary_valid' "$VFIO_SCRIPT"
assert_contains_file "R48m recovery helper checks LG_CLIENT_DESKTOP missing" 'if [[ -f "$LG_CLIENT_DESKTOP" ]]; then' "$VFIO_SCRIPT"
assert_contains_file "R48m recovery helper root-gated (non-root just reports)" 'EUID' "$VFIO_SCRIPT"
assert_contains_file "R48m recovery helper calls _lg_install_desktop_entry" '_lg_install_desktop_entry' "$VFIO_SCRIPT"
# Wired into the read-only status path + the shared menu status-block builder.
assert_contains_file "R48m looking_glass_status calls recovery helper" '_lg_recover_desktop_entry_if_missing' "$VFIO_SCRIPT"
assert_contains_file "R48m _menu_build_vfio_status_block calls recovery helper" '_lg_recover_desktop_entry_if_missing' "$VFIO_SCRIPT"
# --reset sweeps the binary + the system .desktop file.
assert_contains_file "R48m reset _rm_paths includes LG_CLIENT_BIN" '"$LG_CLIENT_BIN"' "$VFIO_SCRIPT"
assert_contains_file "R48m reset _rm_paths includes LG_CLIENT_DESKTOP" '"$LG_CLIENT_DESKTOP"' "$VFIO_SCRIPT"
assert_contains_file "R48m reset calls remove_looking_glass_client" 'remove_looking_glass_client' "$VFIO_SCRIPT"
# R48m: _link must NOT emit the OSC 8 hyperlink escape when whiptail (TUI) is
# active — whiptail passes the raw escapes through as literal ^[]8;;... text and
# corrupts the dialog. Emit plain text in the TUI path.
assert_contains_file "R48m _link gates OSC 8 on HAS_TUI (no corruption in whiptail)" '(( HAS_TUI ))' "$VFIO_SCRIPT"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for _a in "${FAILED_ASSERTIONS[@]}"; do printf ' - %s\n' "$_a" >&2; done
  exit 1
fi
printf '\nLooking Glass host-side VM setup regression checks passed.\n'
