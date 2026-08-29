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
assert_contains_file "install_looking_glass sets video=none" 'video=none' "$VFIO_SCRIPT"
assert_contains_file "install_looking_glass sets spice local-only" 'spice local-only' "$VFIO_SCRIPT"
# vBIOS is NOT duplicated in the LG path (vfio.sh already does vBIOS injection).
assert_contains_file "install_looking_glass notes vBIOS NOT touched" 'vBIOS is NOT touched here' "$VFIO_SCRIPT"
assert_contains_file "install_looking_glass notes client NOT auto-installed" 'client binary is NOT auto-installed' "$VFIO_SCRIPT"
# Recommended mode auto-answers Looking Glass = No (advanced opt-in).
assert_contains_file "recommended table: Looking Glass = No" '_RECOMMENDED_ANSWERS["Looking Glass"]=1' "$VFIO_SCRIPT"
# --reset removes Looking Glass.
assert_contains_file "reset calls remove_looking_glass" 'remove_looking_glass' "$VFIO_SCRIPT"
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

# ===================== R40b: Functional display patcher =====================
# _lg_set_vm_display_none: set <video><model type='none'/> + spice <listen type='none'/>.
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
assert_contains_file "spice listen set to none" 'listen type="none"' "$disp"

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
# spice listen stays none (restore does not re-expose spice).
assert_contains_file "spice listen stays none after restore" 'listen type="none"' "$disp"

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

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for _a in "${FAILED_ASSERTIONS[@]}"; do printf ' - %s\n' "$_a" >&2; done
  exit 1
fi
printf '\nLooking Glass host-side VM setup regression checks passed.\n'
