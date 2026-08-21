#!/usr/bin/env bash
# Convention: this regression overrides sourced vfio.sh helpers that are invoked indirectly.
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

# --- Static wiring: --binding-mode CLI flag ---
assert_contains_file \
  "normalize_binding_mode_arg function exists" \
  "normalize_binding_mode_arg()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "parse_args handles --binding-mode" \
  "--binding-mode)" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "BINDING_MODE_OVERRIDE var declared" \
  "BINDING_MODE_OVERRIDE=" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "usage help documents --binding-mode" \
  "--binding-mode early|dynamic" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "fish completion includes --binding-mode" \
  "complete -c \$cmd -l binding-mode" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "bash completion opts include --binding-mode" \
  "--binding-mode --stealth-vm-tuning" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "zsh completion includes --binding-mode" \
  "'--binding-mode=" \
  "$VFIO_SCRIPT"

# --- Static wiring: normalize_binding_mode_arg behavior ---
assert_eq \
  "normalize_binding_mode_arg accepts early" \
  "EARLY" \
  "$(normalize_binding_mode_arg early)"
assert_eq \
  "normalize_binding_mode_arg accepts dynamic" \
  "DYNAMIC" \
  "$(normalize_binding_mode_arg dynamic)"
assert_eq \
  "normalize_binding_mode_arg accepts DYNAMIC (uppercase)" \
  "DYNAMIC" \
  "$(normalize_binding_mode_arg DYNAMIC)"
if normalize_binding_mode_arg invalid 2>/dev/null; then
  printf 'FAIL: normalize_binding_mode_arg should reject invalid value\n' >&2
  record_failure "normalize_binding_mode_arg rejects invalid"
else
  printf 'PASS: normalize_binding_mode_arg rejects invalid\n'
fi

# --- Static wiring: constants ---
assert_contains_file \
  "LIBVIRT_HOOK_SCRIPT constant exists" \
  "LIBVIRT_HOOK_SCRIPT=" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "LIBVIRT_HOOK_ENTRY constant exists" \
  "LIBVIRT_HOOK_ENTRY=" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "LIBVIRT_HOOK_DIR constant exists" \
  "LIBVIRT_HOOK_DIR=" \
  "$VFIO_SCRIPT"

# --- Static wiring: install_libvirt_hook function ---
assert_contains_file \
  "install_libvirt_hook function exists" \
  "install_libvirt_hook()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "install_libvirt_hook writes hook script" \
  'write_file_atomic "$LIBVIRT_HOOK_SCRIPT" 0755' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "install_libvirt_hook writes qemu entry" \
  'write_file_atomic "$LIBVIRT_HOOK_ENTRY" 0755' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "hook entry is generic (no hardcoded VM names)" \
  "exec /usr/local/sbin/vfio-libvirt-hook.sh" \
  "$VFIO_SCRIPT"

# --- Static wiring: SELinux auto-detect + virtqemud policy (R19) ---
# On SELinux-enforcing distros (Fedora/RHEL), virtqemud_t cannot execute the
# qemu hook nor write the PCI sysfs entries the bind script uses, so every VM
# start/stop floods the audit log with AVC denials. install_libvirt_hook must
# auto-detect SELinux and install a targeted policy module (vfio_virtqemud)
# granting exactly those permissions. No-op on non-SELinux systems.
assert_contains_file \
  "Q3sel install_selinux_virtqemud_policy helper defined" \
  "install_selinux_virtqemud_policy()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3sel helper gates on selinuxenabled" \
  "selinuxenabled" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3sel helper reads getenforce" \
  "getenforce" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3sel helper requires checkmodule + semodule_package + semodule" \
  "have_cmd checkmodule" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3sel helper checks virtqemud_t exists via seinfo" \
  "seinfo -t virtqemud_t" \
  "$VFIO_SCRIPT"
# The targeted .te content: only virtqemud_t + virt_hook_t + sysfs_t + kmod
# (NOT the firehose audit2allow output that sweeps up unrelated services).
assert_contains_file \
  "Q3sel policy module targets virtqemud_t -> virt_hook_t execute" \
  "allow virtqemud_t virt_hook_t:file { execute execute_no_trans }" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3sel policy module targets virtqemud_t -> sysfs_t write" \
  "allow virtqemud_t sysfs_t:file { create write }" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3sel policy module targets virtqemud_t -> kmod_exec_t execute" \
  "allow virtqemud_t kmod_exec_t:file { execute execute_no_trans map }" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3sel policy module compiles via checkmodule" \
  "checkmodule -M -m -o" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3sel policy module installs via semodule -i" \
  "semodule -i" \
  "$VFIO_SCRIPT"
# install_libvirt_hook must call the SELinux policy installer. (Use a
# whole-file grep instead of sed extraction: the function body contains
# heredocs whose generated bash has ^} lines that would stop a sed range
# early, so the extracted block would miss the call at the end.)
assert_contains_file \
  "Q3sel install_libvirt_hook calls install_selinux_virtqemud_policy" \
  "install_selinux_virtqemud_policy" \
  "$VFIO_SCRIPT"

# --- Static wiring: generated hook VM-XML detection + phase handling ---
hook_block="$(sed -n '/write_file_atomic "$LIBVIRT_HOOK_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "generated hook has vm_uses_guest_gpu" \
  "vm_uses_guest_gpu" \
  "$hook_block"
assert_contains_text \
  "generated hook has extract_hostdev_bdfs" \
  "extract_hostdev_bdfs" \
  "$hook_block"
assert_contains_text \
  "generated hook handles prepare phase" \
  "prepare)" \
  "$hook_block"
assert_contains_text \
  "generated hook handles stopped phase" \
  "stopped" \
  "$hook_block"
assert_contains_text \
  "generated hook calls --bind-now" \
  "--bind-now" \
  "$hook_block"
assert_contains_text \
  "generated hook calls --release" \
  "--release" \
  "$hook_block"
assert_contains_text \
  "generated hook reads domain and phase args" \
  'DOMAIN="${1:-}"' \
  "$hook_block"
assert_contains_text \
  "generated hook reads phase arg" \
  'PHASE="${2:-}"' \
  "$hook_block"

# --- Static wiring: generated bind script dynamic no-op + d3cold_allowed ---
bind_block="$(sed -n '/write_file_atomic "$BIND_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "generated bind script has ACTION=boot" \
  'ACTION="boot"' \
  "$bind_block"
assert_contains_text \
  "generated bind script has --bind-now arg" \
  "--bind-now" \
  "$bind_block"
assert_contains_text \
  "generated bind script has --release arg" \
  "--release" \
  "$bind_block"
assert_contains_text \
  "generated bind script has dynamic boot no-op guard" \
  "Dynamic binding mode: skipping boot-time vfio-pci bind" \
  "$bind_block"
assert_contains_text \
  "generated bind script sets d3cold_allowed=0" \
  'd3cold_allowed' \
  "$bind_block"
assert_contains_text \
  "generated bind script has VFIO_DYNAMIC_REBIND_HOST" \
  "VFIO_DYNAMIC_REBIND_HOST" \
  "$bind_block"

# --- Static wiring: write_conf persists VFIO_BINDING_MODE ---
assert_contains_file \
  "write_conf emits VFIO_BINDING_MODE" \
  "VFIO_BINDING_MODE=" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "write_conf emits VFIO_DYNAMIC_REBIND_HOST" \
  "VFIO_DYNAMIC_REBIND_HOST=" \
  "$VFIO_SCRIPT"

# --- Static wiring: dynamic-mode cmdline gating ---
assert_contains_file \
  "openSUSE persistence gates vfio-pci.ids in dynamic" \
  'Dynamic binding mode: skipping vfio-pci.ids (libvirt hook will bind at VM start).' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "openSUSE persistence gates rd.driver.pre in dynamic" \
  'Dynamic binding mode: skipping rd.driver.pre=vfio-pci (libvirt hook will bind at VM start).' \
  "$VFIO_SCRIPT"

# --- Static wiring: reset cleanup ---
assert_contains_file \
  "reset restores pre-existing libvirt qemu hook" \
  "restoring pre-existing libvirt qemu hook" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "reset rm -f includes LIBVIRT_HOOK_SCRIPT" \
  '"$LIBVIRT_HOOK_SCRIPT"' \
  "$VFIO_SCRIPT"

# --- Static wiring: verify/detect binding-mode awareness ---
assert_contains_file \
  "verify shows binding mode" \
  "Binding mode:" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "verify dynamic hook check" \
  "Dynamic binding hook check:" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "detect shows binding mode" \
  "Binding mode" \
  "$VFIO_SCRIPT"

# --- Functional: write_conf persists dynamic binding mode (static heredoc check) ---
assert_contains_file \
  "write_conf heredoc contains VFIO_BINDING_MODE line" \
  'VFIO_BINDING_MODE="$binding_mode"' \
  "$VFIO_SCRIPT"

# --- Functional: vm_uses_guest_gpu with sample XML ---
# Extract the hook script's detection functions and test them.
gen_hook="${tmp_dir}/gen_hook.sh"
sed -n '/write_file_atomic "$LIBVIRT_HOOK_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$VFIO_SCRIPT" | sed '1d;$d' > "$gen_hook"

# Build a sourceable fragment with the detection functions.
hook_funcs="${tmp_dir}/hook_funcs.sh"
{
  echo 'GUEST_GPU_BDF="0000:06:00.0"'
  echo 'GUEST_AUDIO_BDFS_CSV="0000:06:00.1"'
  echo 'BIND_SCRIPT="/bin/true"'
  sed -n '/^# Comma-separated set of configured guest BDFs/,/^}/p' "$gen_hook"
  sed -n '/^# Parse libvirt domain XML/,/^}/p' "$gen_hook"
  sed -n '/^# Return 0 if any configured guest BDF/,/^}/p' "$gen_hook"
  sed -n '/^# Return 0 if the configured guest GPU is currently bound/,/^}/p' "$gen_hook"
} > "$hook_funcs"

# shellcheck disable=SC1091
# shellcheck disable=SC1090
source "$hook_funcs"

# VM with guest GPU attached -> vm_uses_guest_gpu should return 0.
cat > "${tmp_dir}/vm_with_gpu.xml" <<'XEOF'
<domain type='kvm'>
  <name>win11</name>
  <devices>
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x06' slot='0x00' function='0x0'/>
      </source>
    </hostdev>
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x06' slot='0x00' function='0x1'/>
      </source>
    </hostdev>
  </devices>
</domain>
XEOF

# VM without guest GPU -> vm_uses_guest_gpu should return 1.
cat > "${tmp_dir}/vm_without_gpu.xml" <<'XEOF'
<domain type='kvm'>
  <name>linux-test</name>
  <devices>
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
      </source>
    </hostdev>
  </devices>
</domain>
XEOF

if xml=$(cat "${tmp_dir}/vm_with_gpu.xml") && echo "$xml" | { vm_uses_guest_gpu; }; then
  printf 'PASS: vm_uses_guest_gpu returns 0 when VM has guest GPU\n'
else
  printf 'FAIL: vm_uses_guest_gpu should return 0 for attached GPU\n' >&2
  record_failure "vm_uses_guest_gpu returns 0 for attached GPU"
fi

if echo "$(<"${tmp_dir}/vm_without_gpu.xml")" | { vm_uses_guest_gpu; }; then
  printf 'FAIL: vm_uses_guest_gpu should return 1 for non-attached GPU\n' >&2
  record_failure "vm_uses_guest_gpu returns 1 for non-attached GPU"
else
  printf 'PASS: vm_uses_guest_gpu returns 1 when VM does NOT have guest GPU\n'
fi

# --- Functional: awk parser ignores USB hostdevs ---
awk_output="$(awk '
    /<hostdev/ { in_hostdev=1; is_pci=0 }
    in_hostdev && /type=.pci./ { is_pci=1 }
    in_hostdev && is_pci && /<address/ {
      line=$0; dom=""; bus=""; slot=""; fn=""
      if (match(line, /domain=.0x[0-9a-fA-F]+/)) {
        s=substr(line, RSTART, RLENGTH); sub(/^domain=./, "", s); sub(/^0x/, "", s); dom=s
      }
      if (match(line, /bus=.0x[0-9a-fA-F]+/)) {
        s=substr(line, RSTART, RLENGTH); sub(/^bus=./, "", s); sub(/^0x/, "", s); bus=s
      }
      if (match(line, /slot=.0x[0-9a-fA-F]+/)) {
        s=substr(line, RSTART, RLENGTH); sub(/^slot=./, "", s); sub(/^0x/, "", s); slot=s
      }
      if (match(line, /function=.0x[0-9a-fA-F]+/)) {
        s=substr(line, RSTART, RLENGTH); sub(/^function=./, "", s); sub(/^0x/, "", s); fn=s
      }
      if (dom != "" && bus != "" && slot != "" && fn != "") {
        while (length(dom) < 4) dom = "0" dom
        while (length(bus) < 2) bus = "0" bus
        while (length(slot) < 2) slot = "0" slot
        printf "%s:%s:%s.%s\n", dom, bus, slot, fn
      }
    }
    /<\/hostdev>/ { in_hostdev=0; is_pci=0 }
  ' "${tmp_dir}/vm_with_gpu.xml")"
assert_eq \
  "awk parser extracts 2 PCI BDFs from VM with GPU" \
  "0000:06:00.0
0000:06:00.1" \
  "$awk_output"

# --- Static wiring: --install-dynamic-binding / --install-early-binding CLI modes ---
assert_contains_file \
  "parse_args handles --install-dynamic-binding" \
  "--install-dynamic-binding)" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "parse_args handles --install-early-binding" \
  "--install-early-binding)" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "usage help documents --install-dynamic-binding" \
  "--install-dynamic-binding" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "usage help documents --install-early-binding" \
  "--install-early-binding" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "fish completion includes --install-dynamic-binding" \
  "complete -c \$cmd -l install-dynamic-binding" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "fish completion includes --install-early-binding" \
  "complete -c \$cmd -l install-early-binding" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "bash completion opts include --install-dynamic-binding" \
  "--install-dynamic-binding --install-early-binding" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "zsh completion includes --install-dynamic-binding" \
  "'--install-dynamic-binding[" \
  "$VFIO_SCRIPT"

# --- Static wiring: installer functions + dispatch + detect offer ---
assert_contains_file \
  "install_dynamic_binding_from_existing_config exists" \
  "install_dynamic_binding_from_existing_config()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "install_early_binding_from_existing_config exists" \
  "install_early_binding_from_existing_config()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "maybe_offer_detect_dynamic_binding exists" \
  "maybe_offer_detect_dynamic_binding()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "rewrite_conf_key helper exists" \
  "rewrite_conf_key()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "build_vfio_pci_ids_from_conf helper exists" \
  "build_vfio_pci_ids_from_conf()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "strip_early_binding_tokens helper exists" \
  "strip_early_binding_tokens()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "main dispatch wires install-dynamic-binding" \
  '[[ "$MODE" == "install-dynamic-binding" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "main dispatch wires install-early-binding" \
  '[[ "$MODE" == "install-early-binding" ]]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "detect report calls maybe_offer_detect_dynamic_binding" \
  "maybe_offer_detect_dynamic_binding" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "dynamic installer flips VFIO_BINDING_MODE=dynamic" \
  'rewrite_conf_key "VFIO_BINDING_MODE" "dynamic"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "early installer flips VFIO_BINDING_MODE=early" \
  'rewrite_conf_key "VFIO_BINDING_MODE" "early"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "dynamic installer installs libvirt hook" \
  'install_libvirt_hook' \
  "$VFIO_SCRIPT"
# binding-mode prompt: two labeled bullet blocks (early / dynamic) with the
# key trade-off lines. The old cramped two-column table was replaced for
# readability; assert the new layout is present.
assert_contains_file \
  "binding-mode prompt has early binding block label" \
  "early binding" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "binding-mode prompt has dynamic binding block label" \
  "dynamic binding (libvirt hook)" \
  "$VFIO_SCRIPT"
# The source line escapes the inner quotes (\"header type 127\") inside the
# double-quoted say string, so match the literal escaped form with grep -F.
assert_contains_file \
  "binding-mode prompt lists header type 127 trade-off" \
  'can trigger \"header type 127\" on some AMD cards' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "binding-mode prompt lists dynamic VM-start behavior" \
  "only when a VM that has it attached is started" \
  "$VFIO_SCRIPT"
# The old two-column table line must be gone so we do not regress back to it.
if grep -Fq 'early                         | dynamic (libvirt hook)' "$VFIO_SCRIPT"; then
  printf 'FAIL: old two-column binding-mode table still present\n' >&2
  record_failure "old two-column binding-mode table removed"
else
  printf 'PASS: old two-column binding-mode table removed\n'
fi

# --- Functional Q1: install_libvirt_hook writes a working libvirt hook ---
# The generated hook script was already extracted into gen_hook; verify it is valid.
if bash -n "$gen_hook"; then
  printf 'PASS: Q1 generated libvirt hook script is syntactically valid bash\n'
else
  printf 'FAIL: Q1 generated libvirt hook script has syntax errors\n' >&2
  record_failure "Q1 generated libvirt hook is valid bash"
fi
assert_contains_text \
  "Q1 generated hook has vm_uses_guest_gpu + --bind-now" \
  "vm_uses_guest_gpu" \
  "$hook_block"
assert_contains_text \
  "Q1 generated hook calls --bind-now" \
  "--bind-now" \
  "$hook_block"

# --- Functional Q2: dynamic mode avoids vfio-pci.ids= and rd.driver.pre=vfio-pci ---
# Source the cmdline helper functions and verify stripping works.
source_helpers_q2="${tmp_dir}/helpers_q2.sh"
{
  sed -n '/^add_param_once()/,/^}/p' "$VFIO_SCRIPT"
  sed -n '/^remove_param_all()/,/^}/p' "$VFIO_SCRIPT"
  sed -n '/^remove_param_prefix()/,/^}/p' "$VFIO_SCRIPT"
  sed -n '/^trim()/,/^}/p' "$VFIO_SCRIPT"
} > "$source_helpers_q2"
# shellcheck disable=SC1091
# shellcheck disable=SC1090
source "$source_helpers_q2"
sample_q2="amd_iommu=on iommu=pt vfio-pci.ids=1002:7550 rd.driver.pre=vfio-pci amdgpu.runpm=0"
stripped_q2="$sample_q2"
stripped_q2="$(remove_param_prefix "$stripped_q2" "vfio-pci.ids=")"
stripped_q2="$(remove_param_all "$stripped_q2" "rd.driver.pre=vfio-pci")"
if ! grep -Fq "vfio-pci.ids=" <<<"$stripped_q2" && ! grep -Fq "rd.driver.pre=vfio-pci" <<<"$stripped_q2"; then
  printf 'PASS: Q2 dynamic stripping removes vfio-pci.ids + rd.driver.pre (result: %s)\n' "$stripped_q2"
else
  printf 'FAIL: Q2 dynamic stripping did not remove early-binding tokens (result: %s)\n' "$stripped_q2" >&2
  record_failure "Q2 dynamic stripping removes early-binding tokens"
fi
if grep -Fq "amd_iommu=on" <<<"$stripped_q2" && grep -Fq "amdgpu.runpm=0" <<<"$stripped_q2"; then
  printf 'PASS: Q2 dynamic stripping preserves IOMMU + amdgpu params\n'
else
  printf 'FAIL: Q2 dynamic stripping over-stripped IOMMU/amdgpu params (result: %s)\n' "$stripped_q2" >&2
  record_failure "Q2 dynamic stripping preserves IOMMU/amdgpu params"
fi

# --- Functional Q3: hook unbinds amdgpu -> binds vfio-pci on VM start (--bind-now) ---
# The generated bind script was already verified to have ACTION=boot/--bind-now/do_bind;
# verify bind_one does unbind -> driver_override=vfio-pci -> bind + d3cold_allowed.
assert_contains_text \
  "Q3 bind_one unbinds from current driver (amdgpu)" \
  "/unbind" \
  "$bind_block"
assert_contains_text \
  "Q3 bind_one sets driver_override=vfio-pci" \
  'driver_override' \
  "$bind_block"
assert_contains_text \
  "Q3 bind_one binds to vfio-pci" \
  "vfio-pci/bind" \
  "$bind_block"
assert_contains_text \
  "Q3 bind_one sets d3cold_allowed=0 (RX 9070 reset-bug fix)" \
  "d3cold_allowed" \
  "$bind_block"

# --- Functional Q3b: post-bind driver verification (fail hard if not on vfio-pci) ---
assert_contains_text \
  "Q3b bind_one verifies driver is vfio-pci after bind" \
  "failed to bind to vfio-pci" \
  "$bind_block"
assert_contains_text \
  "Q3b bind_one returns 1 on bind failure" \
  "return 1" \
  "$bind_block"
assert_contains_text \
  "Q3b bind_one reads driver via readlink after bind" \
  'readlink "$sys/driver"' \
  "$bind_block"

# --- Functional Q3c: do_bind propagates bind_one failure (die on failure) ---
assert_contains_text \
  "Q3c do_bind GPU call propagates failure" \
  'bind_one "$GUEST_GPU_BDF" || die' \
  "$bind_block"
assert_contains_text \
  "Q3c do_bind audio loop propagates failure" \
  'bind_one "$dev" || die' \
  "$bind_block"

# --- Functional Q3d: clearer post-bind error message ---
assert_contains_text \
  "Q3d bind_one error message says Aborting VM start" \
  "Aborting VM start." \
  "$bind_block"

# --- Functional Q3e: small sleep between unbind and bind (AMD teardown race) ---
assert_contains_text \
  "Q3e bind_one sleeps after unbind before bind" \
  "sleep 0.3" \
  "$bind_block"

# --- Functional Q3f: bind retry loop (transient handoff race) ---
assert_contains_text \
  "Q3f bind_one has bounded retry loop" \
  "_max_attempts=3" \
  "$bind_block"
assert_contains_text \
  "Q3f bind_one retry uses 0.2s backoff" \
  "sleep 0.2" \
  "$bind_block"

# --- Functional Q3g: D3cold pinned early in dynamic boot no-op (covers amdgpu phase) ---
assert_contains_text \
  "Q3g dynamic boot no-op pins d3cold_allowed=0 on guest BDFs" \
  "set_d3cold_for_guest_bdfs" \
  "$bind_block"
assert_contains_text \
  "Q3g dynamic boot no-op logs d3cold pinning" \
  "pinned d3cold_allowed=0 + power/control=on (D0) on guest BDFs" \
  "$bind_block"

# --- Functional Q3h: hook non-zero-exit comment (intentional fail-fast) ---
assert_contains_text \
  "Q3h hook documents non-zero exit aborts VM start" \
  "INTENTIONAL and will abort the VM start" \
  "$hook_block"

# --- Functional Q3i: Boot-VGA guard for bind-now (single-GPU protection) ---
assert_contains_text \
  "Q3i bind-now refuses Boot-VGA guest without override" \
  "VFIO_DYNAMIC_ALLOW_BOOT_VGA" \
  "$bind_block"
assert_contains_text \
  "Q3i bind-now Boot-VGA guard aborts VM start" \
  "refusing --bind-now to keep host display alive" \
  "$bind_block"
assert_contains_file \
  "Q3i write_conf persists VFIO_DYNAMIC_ALLOW_BOOT_VGA" \
  'VFIO_DYNAMIC_ALLOW_BOOT_VGA="0"' \
  "$VFIO_SCRIPT"

# --- Functional Q3i2: bind-now host-assisted escape (dual-GPU Boot-VGA) ---
# bind-now must mirror boot_vga_guard(): allow a Boot-VGA guest GPU when a
# different HOST_GPU_BDF has boot_vga=0 (host display on the other GPU), honored
# via VFIO_BOOT_VGA_POLICY=AUTO or VFIO_ALLOW_BOOT_VGA_IF_HOST_GPU=1. Without
# this, a dual-GPU passthrough setup is blocked by a false-positive Boot-VGA refuse.
assert_contains_text \
  "Q3i2 bind-now host-assisted escape allows dual-GPU topology" \
  "Allowing --bind-now (reason=" \
  "$bind_block"
assert_contains_text \
  "Q3i2 bind-now host-assisted escape jlogs host-assisted decision" \
  'jlog "$GUEST_GPU_BDF: Boot VGA but host-assisted' \
  "$bind_block"
assert_contains_text \
  "Q3i2 bind-now host-assisted escape reads HOST_GPU_BDF boot_vga" \
  '_hbv="$(cat "/sys/bus/pci/devices/$HOST_GPU_BDF/boot_vga"' \
  "$bind_block"
assert_contains_text \
  "Q3i2 bind-now host-assisted escape honors VFIO_BOOT_VGA_POLICY" \
  '_bpolicy="${VFIO_BOOT_VGA_POLICY:-STRICT}"' \
  "$bind_block"
assert_contains_text \
  "Q3i2 bind-now refuse message suggests dual-GPU fix" \
  "For dual-GPU: set HOST_GPU_BDF" \
  "$bind_block"

# --- Functional Q3k: --install-dynamic-binding / --install-early-binding regenerate the bind script ---
# Both switch helpers must call install_bind_script so bind-script fixes (e.g.
# the Boot-VGA host-assisted escape) deploy via `sudo ./vfio.sh --install-dynamic-binding`
# (or --install-early-binding) without forcing a full wizard re-run.
_dyn_fn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
if grep -Fq 'install_bind_script' <<<"$_dyn_fn"; then
  printf 'PASS: Q3k install-dynamic-binding calls install_bind_script\n'
else
  printf 'FAIL: Q3k install-dynamic-binding does not call install_bind_script\n' >&2
  record_failure "Q3k install-dynamic-binding calls install_bind_script"
fi
_early_fn="$(sed -n '/^install_early_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
if grep -Fq 'install_bind_script' <<<"$_early_fn"; then
  printf 'PASS: Q3k install-early-binding calls install_bind_script\n'
else
  printf 'FAIL: Q3k install-early-binding does not call install_bind_script\n' >&2
  record_failure "Q3k install-early-binding calls install_bind_script"
fi

# --- Functional Q3l: libvirt liveness check in install-dynamic-binding ---
# The dynamic-binding installer must verify libvirt is not merely installed but
# actually reachable (running service OR socket-activated OR virsh can connect
# to qemu:///system), and offer to start/enable it when a binary is present but
# inactive. This catches the "virsh installed but libvirtd never enabled" case
# where the qemu hook would silently never fire.
assert_contains_file \
  "Q3l libvirt_runtime_ok helper defined" \
  "libvirt_runtime_ok()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3l _libvirt_unit_to_start helper defined" \
  "_libvirt_unit_to_start()" \
  "$VFIO_SCRIPT"
_lv_fn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3l install-dynamic-binding calls libvirt_runtime_ok" \
  "libvirt_runtime_ok" \
  "$_lv_fn"
assert_contains_text \
  "Q3l install-dynamic-binding offers to start libvirt" \
  "Enable + start the libvirt daemon now?" \
  "$_lv_fn"
assert_contains_text \
  "Q3l install-dynamic-binding runs systemctl enable --now" \
  "systemctl enable --now" \
  "$_lv_fn"
assert_contains_file \
  "Q3l libvirt_runtime_ok tests virsh qemu:///system" \
  'virsh -c qemu:///system list' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3l libvirt_runtime_ok checks socket-activated virtqemud.socket" \
  "virtqemud.socket" \
  "$VFIO_SCRIPT"

# --- Functional Q3m: Wayland render-device safety (compositor-on-guest guard) ---
# When the guest GPU is Boot VGA, KWin/Wayland renders on it by default; binding
# it to vfio-pci at VM start crashes the compositor mid-frame. Two defenses:
# (1) the generated bind script refuses --bind-now if a Wayland compositor has
# the guest GPU render node open, with an actionable KWIN_DRM_DEVICES message;
# (2) the installer writes a Plasma session env pin (KWIN_DRM_DEVICES=host card)
# so the compositor renders on the host GPU instead. Reset removes the pin.
assert_contains_file \
  "Q3m KWIN_RENDER_PIN_FILE constant defined" \
  "KWIN_RENDER_PIN_FILE=" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3m install_wayland_render_device_pin defined" \
  "install_wayland_render_device_pin()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3m remove_wayland_render_device_pin defined" \
  "remove_wayland_render_device_pin()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3m installer writes KWIN_DRM_DEVICES env pin" \
  "export KWIN_DRM_DEVICES=" \
  "$VFIO_SCRIPT"
assert_contains_text \
  "Q3m generated bind script has _bdf_to_drm_card helper" \
  "_bdf_to_drm_card()" \
  "$bind_block"
assert_contains_text \
  "Q3m generated bind script has _wayland_compositor_uses_bdf helper" \
  "_wayland_compositor_uses_bdf()" \
  "$bind_block"
assert_contains_text \
  "Q3m bind-now guard refuses when compositor renders on guest" \
  'compositor ($_comp) is rendering on it' \
  "$bind_block"
assert_contains_text \
  "Q3m bind-now guard jlogs the refusal (compositor-aware)" \
  'refused --bind-now — $_comp is rendering on the guest' \
  "$bind_block"
assert_contains_text \
  "Q3m bind-now guard message names a render-device env var" \
  'KWIN_DRM_DEVICES' \
  "$bind_block"
assert_contains_text \
  "Q3m bind-now guard message suggests --install-dynamic-binding" \
  "--install-dynamic-binding" \
  "$bind_block"
# Installer wiring: both the wizard dynamic branch and --install-dynamic-binding
# must call install_wayland_render_device_pin; reset must remove the pin file.
_apply_fn="$(sed -n "/^apply_configuration()/,/^}/p" "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3m wizard dynamic branch calls install_wayland_render_device_pin" \
  "install_wayland_render_device_pin" \
  "$_apply_fn"
assert_contains_text \
  "Q3m install-dynamic-binding calls install_wayland_render_device_pin" \
  "install_wayland_render_device_pin" \
  "$_lv_fn"
_reset_fn="$(sed -n "/^reset_vfio_all()/,/^}/p" "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3m reset removes KWIN_RENDER_PIN_FILE" \
  "\$KWIN_RENDER_PIN_FILE" \
  "$_reset_fn"
_early_fn2="$(sed -n "/^install_early_binding_from_existing_config()/,/^}/p" "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3m install-early-binding calls remove_wayland_render_device_pin" \
  "remove_wayland_render_device_pin" \
  "$_early_fn2"

# --- Functional Q3m-wlr: wlroots compositor support (WLR_DRM_DEVICES) ---
# The installer must also cover wlroots-based compositors (sway/hyprland/labwc/
# wlroots), not just KDE/KWin: write a /etc/profile.d drop-in exporting
# WLR_DRM_DEVICES (and KWIN_DRM_DEVICES). The bind-now guard must be
# compositor-aware: name the detected compositor + its correct env var
# (KWIN_DRM_DEVICES for kwin, WLR_DRM_DEVICES for sway/hyprland/labwc/wlroots).
assert_contains_file \
  "Q3m-wlr WLR_RENDER_PIN_FILE constant defined" \
  "WLR_RENDER_PIN_FILE=" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3m-wlr installer exports WLR_DRM_DEVICES" \
  "export WLR_DRM_DEVICES=" \
  "$VFIO_SCRIPT"
_inst_fn="$(sed -n '/^install_wayland_render_device_pin()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3m-wlr remove_wayland_render_device_pin removes WLR_RENDER_PIN_FILE" \
  'WLR_RENDER_PIN_FILE' \
  "$_inst_fn"
assert_contains_text \
  "Q3m-wlr reset removes WLR_RENDER_PIN_FILE" \
  'WLR_RENDER_PIN_FILE' \
  "$_reset_fn"
assert_contains_text \
  "Q3m-wlr bind-now guard maps wlroots compositor to WLR_DRM_DEVICES" \
  '_envvar="WLR_DRM_DEVICES"' \
  "$bind_block"
assert_contains_text \
  "Q3m-wlr bind-now guard message names the detected compositor" \
  'compositor ($_comp) is rendering on it' \
  "$bind_block"
assert_contains_text \
  "Q3m-wlr _wayland_compositor_uses_bdf echoes compositor name on match" \
  "printf '%s\\n' \"\$_comp\"" \
  "$bind_block"

# --- Functional Q3m-fix: guard checks KMS card node, not render node ---
# The original guard checked the guest GPU's *render* node (renderDNN), but Mesa
# opens every renderDNN on the system for EGL/PRIME buffer sharing even when the
# compositor's display is on a different GPU — so on a healthy dual-GPU setup
# (KWin display on the host 6400, renderD129 of the guest 9070 open for PRIME)
# the guard false-refused and required VFIO_DYNAMIC_ALLOW_BOOT_VGA=1. The fix:
# check the KMS *card* node (/dev/dri/cardN), which is the device the compositor
# actually holds DRM master on and scans out to.
assert_contains_text \
  "Q3m-fix guard uses _bdf_to_drm_card (KMS card node)" \
  '_card="$(_bdf_to_drm_card "$_bdf" 2>/dev/null || true)"' \
  "$bind_block"
if grep -Fq 'renderD[0-9]*' <<<"$bind_block"; then
  printf 'FAIL: Q3m-fix guard still references renderD* nodes (would false-positive)\n' >&2
  record_failure "Q3m-fix guard does not reference renderD nodes"
else
  printf 'PASS: Q3m-fix guard does not reference renderD nodes\n'
fi

# --- Functional Q3m-resolve: self-resolving render-device pin (R17c/R17d) ---
# A hardcoded pin (/dev/dri/cardN OR a by-path symlink) can go stale after a
# card-number swap and point KWin at the GUEST GPU -> "Failed to open drm
# device" -> plasmalogin-helper crashed -> no graphical login (observed on
# Fedora). R17c replaced the hardcoded path with a SELF-RESOLVING pin that
# walks /sys/class/drm at session start to find the host GPU's current card by
# PCI BDF. R17d corrected a critical bug: the resolver MUST export the
# colon-free /dev/dri/cardN path, NOT the /dev/dri/by-path/pci-<BDF>-card
# symlink, because KWIN_DRM_DEVICES and WLR_DRM_DEVICES use ':' as a device-
# list separator -- a by-path path like /dev/dri/by-path/pci-0000:06:00.0-card
# gets split into three bogus fragments ("pci-0000", "06", "00.0-card") ->
# "No suitable DRM devices have been found" -> no graphical login. The BDF walk
# makes it swap-safe (re-resolves every session); exporting cardN keeps the env
# var colon-free. If the host card is not found at session start the vars stay
# UNSET (compositor uses its default) -- it never points at a wrong/nonexistent
# device, so it can NEVER break login.
assert_contains_file \
  "Q3m-resolve _bdf_to_drm_card_stable helper defined (main script)" \
  "_bdf_to_drm_card_stable()" \
  "$VFIO_SCRIPT"
assert_contains_text \
  "Q3m-resolve _bdf_to_drm_card_stable defined in generated bind script" \
  "_bdf_to_drm_card_stable()" \
  "$bind_block"
assert_contains_text \
  "Q3m-resolve bind-now error hint uses _bdf_to_drm_card_stable" \
  '_bdf_to_drm_card_stable "$HOST_GPU_BDF"' \
  "$bind_block"
_inst_resolve_fn="$(sed -n '/^install_wayland_render_device_pin()/,/^}/p' "$VFIO_SCRIPT")"
# Install-time pre-check: host BDF must currently map to a DRM card.
assert_contains_text \
  "Q3m-resolve installer pre-checks host BDF has a DRM card" \
  '_bdf_to_drm_card "$host_gpu"' \
  "$_inst_resolve_fn"
# The pin file bakes in the host BDF (not a device path) for the resolver.
assert_contains_file \
  "Q3m-resolve pin bakes in host BDF for session-start resolution" \
  '_vfio_host_bdf="$host_gpu"' \
  "$VFIO_SCRIPT"
# The resolver walks /sys/class/drm to find the host card at session start.
assert_contains_file \
  "Q3m-resolve pin walks /sys/class/drm at session start" \
  'for _c in /sys/class/drm/card[0-9]; do' \
  "$VFIO_SCRIPT"
# CRITICAL (R17d): the resolver must export the COLON-FREE /dev/dri/cardN path,
# NOT the by-path symlink (KWIN/WLR_DRM_DEVICES use ':' as a device-list
# separator -> a by-path path with colons in the BDF gets split into bogus
# fragments and breaks the greeter). The resolver's $ is escaped as \$ in the
# unquoted heredoc source, so the patterns include the backslash to match the
# source literally under grep -F.
assert_contains_file \
  "Q3m-resolve pin exports colon-free /dev/dri/cardN (not by-path)" \
  'export KWIN_DRM_DEVICES="/dev/dri/\$_vfio_nm"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3m-resolve pin exports WLR_DRM_DEVICES colon-free cardN" \
  'export WLR_DRM_DEVICES="/dev/dri/\$_vfio_nm"' \
  "$VFIO_SCRIPT"
# The by-path symlink must NOT appear in any exported KWIN/WLR_DRM_DEVICES value
# (it contains colons -> splits into bogus fragments -> breaks login).
if grep -Fq 'KWIN_DRM_DEVICES="/dev/dri/by-path' "$VFIO_SCRIPT" || grep -Fq 'WLR_DRM_DEVICES="/dev/dri/by-path' "$VFIO_SCRIPT"; then
  printf 'FAIL: Q3m-resolve pin exports a by-path path in KWIN/WLR_DRM_DEVICES (colon separator breaks login)\n' >&2
  record_failure "Q3m-resolve pin does not export by-path in KWIN/WLR_DRM_DEVICES"
else
  printf 'PASS: Q3m-resolve pin does not export by-path in KWIN/WLR_DRM_DEVICES (colon-safe)\n'
fi
# No hardcoded literal /dev/dri/cardN export remains in the installer function
# body (the resolver replaces it; the only export is the resolver's \$_vfio_nm).
if grep -Fq 'export KWIN_DRM_DEVICES="/dev/dri/card' <<<"$_inst_resolve_fn"; then
  printf 'FAIL: Q3m-resolve installer still hardcodes a literal /dev/dri/cardN pin (fragile)\n' >&2
  record_failure "Q3m-resolve installer does not hardcode a literal cardN pin"
else
  printf 'PASS: Q3m-resolve installer does not hardcode a literal cardN pin\n'
fi
# The resolver must NOT export when the host BDF is not found -- it must leave
# the vars unset (safe). Assert the loop only exports on a BDF match and breaks.
assert_contains_file \
  "Q3m-resolve pin only exports on host-BDF match" \
  'if [ "\$_vfio_cbdf" = "\$_vfio_host_bdf" ]; then' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3m-resolve pin cleans up its temp vars" \
  'unset _vfio_host_bdf _c _vfio_nm _vfio_cbdf' \
  "$VFIO_SCRIPT"

# --- Functional Q3n: PCI device alive-check (header type 127 / reset-bug fix) ---
# The RX 9070 / RDNA4 reset bug can drop the card off the bus between a VM stop
# and the next start, leaving a vfio-pci driver symlink pointing at a dead
# device whose config space reads all 0xff (qemu surfaces "Unknown PCI header
# type 127"). The old "already on vfio-pci, skipping rebind" early-return only
# checked the driver symlink and returned success, so qemu hit the dead card.
# Fix: _pci_dev_alive() reads vendor sysfs + live config space; the early-return
# and the post-bind verify both require alive, else attempt a PCI reset and fail
# hard so libvirt aborts the VM start cleanly.
assert_contains_text \
  "Q3n _pci_dev_alive helper defined" \
  "_pci_dev_alive()" \
  "$bind_block"
assert_contains_text \
  "Q3n _pci_dev_alive reads config space" \
  'head -c 4 "$_sys/config"' \
  "$bind_block"
assert_contains_text \
  "Q3n _pci_dev_alive rejects vendor 0xffff" \
  '[[ "$_vendor" != "0xffff" ]]' \
  "$bind_block"
assert_contains_text \
  "Q3n _pci_dev_alive rejects all-ff config" \
  '[[ "$_cfg" != "ffffffff" ]]' \
  "$bind_block"
assert_contains_text \
  "Q3n early-return verifies alive before skipping" \
  'if _pci_dev_alive "$dev"; then' \
  "$bind_block"
assert_contains_text \
  "Q3n early-return attempts PCI reset when dead (via _rx9070_gated_soft_flr)" \
  'echo 1 >"$_sys/reset" 2>/dev/null || true' \
  "$bind_block"
assert_contains_text \
  "Q3n early-return dies with header 127 message when unrecoverable" \
  'Unknown PCI header type 127' \
  "$bind_block"
assert_contains_text \
  "Q3n early-return die message says reboot needed" \
  'card needs a host reboot to come back' \
  "$bind_block"
assert_contains_text \
  "Q3n post-bind verify calls _pci_dev_alive" \
  'if ! _pci_dev_alive "$dev"; then' \
  "$bind_block"
assert_contains_text \
  "Q3n post-bind verify die message mentions header 127" \
  'Unknown PCI header type 127' \
  "$bind_block"
assert_contains_text \
  "Q3n success log now says alive" \
  'bound to vfio-pci (verified, alive)' \
  "$bind_block"

# --- Functional Q3o: rapid stop/start cooldown guard (proactive reset-bug prevention) ---
# The alive-check (Q3n) is REACTIVE -- it catches a dead card AFTER it falls off
# the bus. The cooldown is PROACTIVE -- it refuses a --bind-now within
# VFIO_DYNAMIC_COOLDOWN_SECONDS of the last --release (VM stop) so the rapid
# stop/start that drops the RX 9070 / RDNA4 off the bus never happens in the
# first place. The bind script writes a stop-timestamp on --release and checks
# it at the start of --bind-now (before any sysfs writes / boot-vga checks).
assert_contains_text \
  "Q3o bind script defines COOLDOWN_TS_FILE" \
  'COOLDOWN_TS_FILE=' \
  "$bind_block"
assert_contains_text \
  "Q3o bind-now reads VFIO_DYNAMIC_COOLDOWN_SECONDS" \
  'VFIO_DYNAMIC_COOLDOWN_SECONDS' \
  "$bind_block"
assert_contains_text \
  "Q3o bind-now probes card readiness with _pci_dev_alive" \
  'if _pci_dev_alive "$GUEST_GPU_BDF"; then' \
  "$bind_block"
assert_contains_text \
  "Q3o bind-now die message says reboot when card still dead" \
  'card needs a host reboot to come back on the bus' \
  "$bind_block"
assert_contains_text \
  "Q3o bind-now jlogs cooldown readiness probe" \
  'probing card readiness' \
  "$bind_block"
assert_contains_text \
  "Q3o bind-now jlogs card alive during probe" \
  'card alive during cooldown probe' \
  "$bind_block"
assert_contains_text \
  "Q3o release writes stop timestamp" \
  'date +%s >"$COOLDOWN_TS_FILE"' \
  "$bind_block"
assert_contains_text \
  "Q3o release cooldown notice tells user to wait" \
  'wait before restarting' \
  "$bind_block"
assert_contains_text \
  "Q3o post-bind die hints at cooldown" \
  'keep VFIO_DYNAMIC_COOLDOWN_SECONDS (default 10) above 0' \
  "$bind_block"
assert_contains_file \
  "Q3o write_conf persists VFIO_DYNAMIC_COOLDOWN_SECONDS" \
  'VFIO_DYNAMIC_COOLDOWN_SECONDS="10"' \
  "$VFIO_SCRIPT"
# Ordering: the readiness probe must run BEFORE the boot-vga check in --bind-now
# so a too-soon restart is handled before any sysfs writes / topology checks.
_cooldown_line=$(grep -Fn 'probing card readiness' <<<"$bind_block" | head -n1 | cut -d: -f1)
_bootvga_line=$(grep -Fn 'refusing --bind-now to keep host display alive' <<<"$bind_block" | head -n1 | cut -d: -f1)
if [[ -n "$_cooldown_line" && -n "$_bootvga_line" ]] && (( _cooldown_line < _bootvga_line )); then
  printf 'PASS: Q3o readiness probe runs before boot-vga check in bind-now\n'
else
  printf 'FAIL: Q3o readiness probe must run before boot-vga check (probe=%s bootvga=%s)\n' "$_cooldown_line" "$_bootvga_line" >&2
  record_failure "Q3o readiness probe runs before boot-vga check"
fi

# --- Functional Q3p: ensure_amd_reset_bug_params (non-interactive AMD reset-bug params) ---
# The standalone binding-mode switchers (--install-dynamic-binding /
# --install-early-binding) must also deploy the AMD reset-bug-critical kernel
# params (vfio-pci.disable_idle_d3=1, pcie_port_pm=off) non-interactively, not
# just strip early-binding tokens. The release note / README promise these are
# "kept on the kernel cmdline for both modes", so a quick mode switch must
# ensure them without re-running the full wizard's interactive AMD prompt.
assert_contains_file \
  "Q3p ensure_amd_reset_bug_params helper defined" \
  "ensure_amd_reset_bug_params()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p helper reads GUEST_GPU_VENDOR_ID from conf" \
  '/^GUEST_GPU_VENDOR_ID=/' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p helper adds vfio-pci.disable_idle_d3=1" \
  'add_param_once "$cmdline" "vfio-pci.disable_idle_d3=1"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p helper adds pcie_port_pm=off" \
  'add_param_once "$cmdline" "pcie_port_pm=off"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p helper honors AMD_D3_OVERRIDE=0 opt-out" \
  '"${AMD_D3_OVERRIDE:-}" != "0"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p helper honors AMD_PORTPM_OVERRIDE=0 opt-out" \
  '"${AMD_PORTPM_OVERRIDE:-}" != "0"' \
  "$VFIO_SCRIPT"
# Both standalone switchers must call the helper (non-interactive deploy).
_dyn_fn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3p install-dynamic-binding calls ensure_amd_reset_bug_params" \
  'ensure_amd_reset_bug_params' \
  "$_dyn_fn"
_early_fn3="$(sed -n '/^install_early_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3p install-early-binding calls ensure_amd_reset_bug_params" \
  'ensure_amd_reset_bug_params' \
  "$_early_fn3"
# The dynamic switcher's 'What this will do' note must document step 4b.
assert_contains_text \
  "Q3p dynamic note documents step 4b AMD reset-bug params" \
  'Ensure the AMD reset-bug kernel params' \
  "$_dyn_fn"
assert_contains_text \
  "Q3p early note documents step 4b AMD reset-bug params" \
  'Ensure the AMD reset-bug kernel params' \
  "$_early_fn3"

# --- Functional Q3p2: Navi 48 (RX 9070) disable_idle_d3 gate (R16) ---
# vfio-pci.disable_idle_d3=1 worsens D3 issues on RX 9070 / RDNA4 (Navi 48,
# device 7550): two independent working guides (CachyOS single-GPU 9070 XT
# gist; Proxmox uzumo months-stable recipe) report it triggers a
# vfio_bar_restore reset loop that drops the card off the host bus mid-session.
# The installer must SKIP it for Navi 48 by default. The bind script's D0-lock
# (d3cold_allowed=0 + power/control=on) is the correct reset-bug defense.
# Honors --amd-disable-idle-d3 (force add even on Navi 48) and
# --no-amd-disable-idle-d3 (always skip).
assert_contains_file \
  "Q3p2 _is_guest_rx9070_family helper defined" \
  "_is_guest_rx9070_family()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2 _should_add_disable_idle_d3 helper defined" \
  "_should_add_disable_idle_d3()" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2 helper gates on Navi 48 device 7550" \
  '"7550"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2 helper reads guest device id from CTX[guest_vfio_ids]" \
  'CTX[guest_vfio_ids]' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2 helper honors AMD_D3_OVERRIDE=0 opt-out" \
  '"${AMD_D3_OVERRIDE:-}" != "0"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2 helper honors AMD_D3_OVERRIDE=1 force-add" \
  '"${AMD_D3_OVERRIDE:-}" == "1"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2 ensure_amd_reset_bug_params gates via the helper" \
  'if _should_add_disable_idle_d3; then' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2 wizard openSUSE spot gates via the helper" \
  'if _should_add_disable_idle_d3; then' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2 helper documents the Navi 48 D3-worsen finding" \
  'worsens D3 issues' \
  "$VFIO_SCRIPT"

# --- Functional Q3p2b: durable GUEST_GPU_DEVICE_ID persistence (R16 hardening) ---
# write_conf must persist the guest GPU device id so _is_guest_rx9070_family
# can detect Navi 48 (device 7550) DURABLY -- even when the card is dead / off
# the bus at standalone-switcher time (sysfs + lspci return nothing then). The
# helper must prefer the persisted conf key over the runtime fallback, and the
# standalone switchers must backfill the key if it is missing.
assert_contains_file \
  "Q3p2b write_conf emits GUEST_GPU_DEVICE_ID" \
  'GUEST_GPU_DEVICE_ID="$guest_device"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2b write_conf reads guest device id from sysfs" \
  '"/sys/bus/pci/devices/$guest_gpu/device"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2b helper prefers GUEST_GPU_DEVICE_ID from conf" \
  '/^GUEST_GPU_DEVICE_ID=/' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3p2b _ensure_guest_device_id_persisted helper defined" \
  "_ensure_guest_device_id_persisted()" \
  "$VFIO_SCRIPT"
assert_contains_text \
  "Q3p2b dynamic switcher calls _ensure_guest_device_id_persisted" \
  "_ensure_guest_device_id_persisted" \
  "$_dyn_fn"
assert_contains_text \
  "Q3p2b early switcher calls _ensure_guest_device_id_persisted" \
  "_ensure_guest_device_id_persisted" \
  "$_early_fn3"
# Functional: with a persisted device id, the helper detects Navi 48 even when
# CTX[guest_vfio_ids] is empty and the BDF is absent from sysfs (card dead).
# Save/restore globals so later assertions see the real conf.
_rx9070_conf="${tmp_dir}/fake_rx9070.conf"
_other_conf="${tmp_dir}/fake_other.conf"
printf 'GUEST_GPU_BDF="0000:0e:00.0"\nGUEST_GPU_DEVICE_ID="0x7550"\n' > "$_rx9070_conf"
printf 'GUEST_GPU_BDF="0000:06:00.0"\nGUEST_GPU_DEVICE_ID="0x743f"\n' > "$_other_conf"
_save_conf="$CONF_FILE"
_save_d3="${AMD_D3_OVERRIDE:-}"
CONF_FILE="$_rx9070_conf"; AMD_D3_OVERRIDE=""
if _is_guest_rx9070_family; then
  printf 'PASS: Q3p2b helper detects Navi 48 from persisted GUEST_GPU_DEVICE_ID=7550\n'
else
  printf 'FAIL: Q3p2b helper should detect Navi 48 from persisted device id 7550\n' >&2
  record_failure "Q3p2b helper detects Navi 48 from persisted device id"
fi
CONF_FILE="$_other_conf"
if _is_guest_rx9070_family; then
  printf 'FAIL: Q3p2b helper should NOT flag non-Navi-48 device 743f as RX 9070\n' >&2
  record_failure "Q3p2b helper rejects non-Navi-48 persisted device id"
else
  printf 'PASS: Q3p2b helper rejects non-Navi-48 persisted device id (743f)\n'
fi
# _should_add_disable_idle_d3 decision matrix on Navi 48 (persisted id):
CONF_FILE="$_rx9070_conf"; AMD_D3_OVERRIDE=""
if _should_add_disable_idle_d3; then
  printf 'FAIL: Q3p2b _should_add_disable_idle_d3 should SKIP Navi 48 by default\n' >&2
  record_failure "Q3p2b _should_add_disable_idle_d3 skips Navi 48 by default"
else
  printf 'PASS: Q3p2b _should_add_disable_idle_d3 skips Navi 48 by default\n'
fi
AMD_D3_OVERRIDE=1
if _should_add_disable_idle_d3; then
  printf 'PASS: Q3p2b _should_add_disable_idle_d3 forces add on Navi 48 with --amd-disable-idle-d3\n'
else
  printf 'FAIL: Q3p2b _should_add_disable_idle_d3 should force add on Navi 48 with override=1\n' >&2
  record_failure "Q3p2b _should_add_disable_idle_d3 forces add on Navi 48 with override"
fi
AMD_D3_OVERRIDE=0
if _should_add_disable_idle_d3; then
  printf 'FAIL: Q3p2b _should_add_disable_idle_d3 should SKIP with --no-amd-disable-idle-d3\n' >&2
  record_failure "Q3p2b _should_add_disable_idle_d3 skips with --no-amd-disable-idle-d3"
else
  printf 'PASS: Q3p2b _should_add_disable_idle_d3 skips with --no-amd-disable-idle-d3\n'
fi
CONF_FILE="$_save_conf"; AMD_D3_OVERRIDE="$_save_d3"

# --- Functional Q3q: _pci_dev_remove_rescan (last-resort bus recovery) ---
# When the alive-check (Q3n) catches a dead card and the soft PCI reset does not
# recover it, the bind script now attempts a remove+rescan bus recovery as a
# final step before telling the user to reboot. This forces the kernel to
# re-enumerate the device, which can sometimes bring a borderline-dead card back.
assert_contains_text \
  "Q3q _pci_dev_remove_rescan helper defined" \
  '_pci_dev_remove_rescan()' \
  "$bind_block"
assert_contains_text \
  "Q3q helper writes to sysfs remove" \
  'echo 1 >"$_sys/remove"' \
  "$bind_block"
assert_contains_text \
  "Q3q helper triggers PCI bus rescan" \
  'echo 1 >/sys/bus/pci/rescan' \
  "$bind_block"
assert_contains_text \
  "Q3q helper sets driver_override before bind" \
  'echo vfio-pci >"$_sys/driver_override"' \
  "$bind_block"
assert_contains_text \
  "Q3q helper verifies alive after recovery" \
  'if _pci_dev_alive "$_bdf"; then' \
  "$bind_block"
# Both dead-card recovery paths must call remove+rescan before giving up.
# Each path has a unique recovery-jlog string, so we assert those instead of
# trying to extract the post-bind section with a fragile nested sed.
assert_contains_text \
  "Q3q early-return dead path calls _pci_dev_remove_rescan" \
  'recovered after remove+rescan (alive); keeping on vfio-pci' \
  "$bind_block"
assert_contains_text \
  "Q3q post-bind dead path calls _pci_dev_remove_rescan" \
  'recovered after remove+rescan (alive) post-bind' \
  "$bind_block"
# The die messages must mention remove+rescan was attempted.
assert_contains_text \
  "Q3q early-return die mentions remove+rescan failed" \
  'PCI reset + remove+rescan did not recover' \
  "$bind_block"
assert_contains_text \
  "Q3q post-bind die mentions remove+rescan failed" \
  'A PCI reset and a remove+rescan bus recovery both failed' \
  "$bind_block"
# The helper must check if the device came back after rescan (sysfs path check).
assert_contains_text \
  "Q3q helper checks device reappeared after rescan" \
  'did not reappear after rescan' \
  "$bind_block"

# --- Functional Q3r: release-time zombie-card recovery ---
# The card dies on VM stop (D3cold exit during release), not on start. The bind
# path (Q3n/Q3q) only catches the death at the NEXT --bind-now, after the card
# has been sitting dead. Q3r adds a zombie check to the --release path itself:
# if the card is dead at release time, attempt remove+rescan immediately (while
# the card may be in a fresher, more recoverable state). ONLY acts on dead cards
# — a healthy card is never reset (that would risk triggering the reset bug and
# break the parked-on-vfio-pci invariant when REBIND_HOST=0).
# The release-path zombie gate uses $GUEST_GPU_BDF (the bind-one paths use
# $dev), so these strings are unique to the release path — assert against the
# full bind_block without a fragile sed extraction.
assert_contains_text \
  "Q3r release path has zombie check (_pci_dev_alive gate)" \
  'if ! _pci_dev_alive "$GUEST_GPU_BDF"; then' \
  "$bind_block"
assert_contains_text \
  "Q3r release path calls _pci_dev_remove_rescan when dead" \
  'if _pci_dev_remove_rescan "$GUEST_GPU_BDF"; then' \
  "$bind_block"
assert_contains_text \
  "Q3r release path jlogs zombie detection" \
  'zombie detected at release time' \
  "$bind_block"
assert_contains_text \
  "Q3r release path logs recovery success" \
  'recovered at release time after remove+rescan' \
  "$bind_block"
assert_contains_text \
  "Q3r release path logs recovery failure (non-fatal)" \
  'still dead at release time after remove+rescan' \
  "$bind_block"
assert_contains_text \
  "Q3r release path does NOT unbind healthy cards" \
  'a healthy card is never reset' \
  "$bind_block"

# --- Functional Q3s: reboot-FLR monitor (soft FLR on guest warm reboot) ---
# On RX 9070 / RDNA4 with on_reboot=restart (warm reboot), the card survives
# (qemu never releases the vfio device, link stays up), but the GPU's display
# engine wedges and OVMF can't re-POST (frozen screen). A systemd service
# watches libvirt for guest reboot lifecycle events and does a soft FLR to
# clear the display wedge so OVMF re-POSTs without a host reboot. Libvirt's
# qemu hook does NOT fire a 'reboot' phase, so this requires an external monitor.
assert_contains_file \
  "Q3s REBOOT_FLR_SCRIPT constant defined" \
  'REBOOT_FLR_SCRIPT=' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3s REBOOT_FLR_UNIT constant defined" \
  'REBOOT_FLR_UNIT=' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3s install_reboot_flr_monitor function defined" \
  'install_reboot_flr_monitor()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3s remove_reboot_flr_monitor function defined" \
  'remove_reboot_flr_monitor()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3s monitor script uses virsh event --all --loop" \
  'virsh -c qemu:///system event --all --loop' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3s monitor script does soft FLR via sysfs reset" \
  'echo 1 >"$_sys/reset"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3s monitor script checks domain has GPU before FLR" \
  'domain_has_gpu' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3s systemd service unit defined with Restart=always" \
  'Restart=always' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3s systemd service unit runs the monitor script" \
  'ExecStart=$REBOOT_FLR_SCRIPT' \
  "$VFIO_SCRIPT"
# install-dynamic-binding must call install_reboot_flr_monitor
assert_contains_text \
  "Q3s install-dynamic-binding calls install_reboot_flr_monitor" \
  'install_reboot_flr_monitor' \
  "$_dyn_fn"
# install-early-binding must call remove_reboot_flr_monitor
assert_contains_text \
  "Q3s install-early-binding calls remove_reboot_flr_monitor" \
  'remove_reboot_flr_monitor' \
  "$_early_fn3"
# reset must disable + remove the reboot-FLR service + script
_reset_fn2="$(sed -n '/^reset_vfio_all()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3s reset disables vfio-reboot-flr.service" \
  'vfio-reboot-flr.service' \
  "$_reset_fn2"
assert_contains_text \
  "Q3s reset removes REBOOT_FLR_SCRIPT + REBOOT_FLR_UNIT" \
  '$REBOOT_FLR_SCRIPT' \
  "$_reset_fn2"

# --- Functional Q3t: RX 9070 family-gated pre-FLR Gen1 downtrain + adaptive restore ---
# On the RX 9070 family / RDNA4 the post-FLR link retrain at the card's max gen
# can fail (the on-card switch can't retrain Gen5 after a function reset). The
# fix: force the target link speed to Gen1 BEFORE the FLR so the retrain happens
# at Gen1 (fast + reliable), then adaptively restore the link to the hardware's
# actual max (Gen5 on Gen5 boards, Gen4 on slower slots/mobos) with a degraded-
# link fallback. Gated to the RX 9070 family (vendor 1002, device 7550 — the RX
# 9070, 9070 XT, and 9070 GRE all share 0x7550) so it does not run on other
# cards. Uses setpci on the auto-detected upstream port + sysfs speed detection.
_reboot_block="$(sed -n '/write_file_atomic "$REBOOT_FLR_SCRIPT" 0755/,/^EOF$/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3t _RX9070_DEVICE_ID constant defined" \
  '_RX9070_DEVICE_ID=' \
  "$_reboot_block"
assert_contains_text \
  "Q3t device-ID comment documents the RX 9070 family (9070/9070XT/9070GRE share 7550)" \
  'RX 9070 XT, and RX 9070 GRE ALL' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _is_rx9070 gate reads vendor+device from config" \
  '_is_rx9070()' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _is_rx9070 checks device 7550" \
  '7550' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _gpu_upstream_port auto-detects upstream port" \
  '_gpu_upstream_port()' \
  "$_reboot_block"
# --- Hardware detection helpers (sysfs link speed -> PCIe gen) ---
assert_contains_text \
  "Q3t _speed_to_gen helper maps GT/s string to a generation" \
  '_speed_to_gen()' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _port_speed_gen reads sysfs max_link_speed" \
  'max_link_speed' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _port_speed_gen reads sysfs current_link_speed" \
  'current_link_speed' \
  "$_reboot_block"
# --- New helpers: SKU resolver, defensive setpci reader, link width, alive-check ---
assert_contains_text \
  "Q3t _rx9070_sku_name resolves 9070/XT/GRE by PCI revision" \
  '_rx9070_sku_name()' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _rx9070_sku_name maps rev c0 to 9070 XT" \
  'RX 9070 XT' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _rx9070_sku_name maps rev c2 to 9070 GRE" \
  'RX 9070 GRE' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _rx9070_sku_name maps rev c3 to 9070 base" \
  'printf' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _setpci_word defensive setpci reader defined" \
  '_setpci_word()' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _setpci_word trims whitespace from setpci output" \
  "tr -d '[:space:]'" \
  "$_reboot_block"
assert_contains_text \
  "Q3t _setpci_word left-pads to 4 hex digits" \
  'while (( ${#_v} < 4 ))' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _port_link_width reads sysfs current_link_width" \
  '_port_link_width()' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _port_link_width reads current_link_width sysfs attr" \
  'current_link_width' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _gpu_alive endpoint alive-check defined" \
  '_gpu_alive()' \
  "$_reboot_block"
assert_contains_text \
  "Q3t _gpu_alive rejects vendor 0xffff" \
  '0xffff' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain detects link capability into _FLR_DETECTED_CAP" \
  '_FLR_DETECTED_CAP=' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain detects current speed into _FLR_DETECTED_CUR" \
  '_FLR_DETECTED_CUR=' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain detects link width into _FLR_DETECTED_WIDTH" \
  '_FLR_DETECTED_WIDTH=' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain stashes SKU name into _FLR_SKU_NAME" \
  '_FLR_SKU_NAME=' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain logs SKU + width in jlog" \
  'width=x' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain reads LnkCtl2 via _setpci_word (defensive)" \
  '_setpci_word "$_upstream" 88.w' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain saves original LnkCtl2 target nibble" \
  '_FLR_SAVED_TARGET=' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain writes LnkCtl2 at 0x88" \
  '88.w' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain sets Gen1 target (low nibble 1)" \
  '${_saved_hi}1' \
  "$_reboot_block"
assert_contains_text \
  "Q3t pre-FLR downtrain forces retrain via LnkCtl bit 5" \
  '0x0020' \
  "$_reboot_block"
assert_contains_text \
  "Q3t polls LnkSta at 0x6A for link active bit 13" \
  '6A.w' \
  "$_reboot_block"
assert_contains_text \
  "Q3t polls Data Link Layer Link Active bit (0x2000)" \
  '0x2000' \
  "$_reboot_block"
# --- Adaptive post-FLR restore (replaces the old hardcoded Gen5 restore) ---
assert_contains_text \
  "Q3t _post_flr_restore_target helper defined (replaces Gen5-only restore)" \
  '_post_flr_restore_target()' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore adapts when current < cap (slower slot/hardware)" \
  'adapting restore to Gen' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore falls back to saved LnkCtl2 target when sysfs unavailable" \
  'restoring to saved LnkCtl2 target' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore last-resort defaults to Gen5" \
  'defaulting restore to Gen5' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore clamps target to a sane PCIe gen range" \
  'out of range; defaulting to Gen5' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore sets adaptive LnkCtl2 target via printf %x" \
  '${_saved_hi}$(printf' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore verifies negotiated speed after retrain" \
  'link negotiated at Gen' \
  "$_reboot_block"
# --- Bounded descent (replaces the old one-step fallback) + MAX_GEN cap + width + alive ---
assert_contains_text \
  "Q3t post-FLR restore uses a bounded descent C-style for loop" \
  'for (( _g = _target; _g >= 1; _g-- ))' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore descends one gen on a missed target" \
  'descending to Gen' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore accepts highest stable gen into _best" \
  '_best=' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore polls current_link_speed per gen attempt" \
  'for _p in $(seq 1 6)' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore reads VFIO_REBOOT_FLR_MAX_GEN operator cap" \
  'VFIO_REBOOT_FLR_MAX_GEN' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore logs the MAX_GEN clamp" \
  'clamps restore target from Gen' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore includes width in negotiated log" \
  'link negotiated at Gen' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore includes width in restore-OK log" \
  'restore OK — link back at Gen' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore logs a hardware-problem diagnostic when link stays degraded" \
  'possible hardware/signal-integrity issue' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore runs a GPU-endpoint alive-check" \
  'if ! _gpu_alive; then' \
  "$_reboot_block"
assert_contains_text \
  "Q3t post-FLR restore logs a wedged-GPU warning" \
  'GPU is still wedged — a host reboot may be needed' \
  "$_reboot_block"
assert_contains_text \
  "Q3t do_flr gates downtrain on _is_rx9070" \
  'if _is_rx9070; then' \
  "$_reboot_block"
assert_contains_text \
  "Q3t do_flr logs non-RX9070 skip" \
  'not RX 9070, skipping pre-FLR Gen1 downtrain' \
  "$_reboot_block"
assert_contains_text \
  "Q3t do_flr resets _FLR_DETECTED_WIDTH stash" \
  '_FLR_DETECTED_WIDTH=""' \
  "$_reboot_block"
assert_contains_text \
  "Q3t do_flr resets _FLR_SKU_NAME stash" \
  '_FLR_SKU_NAME=""' \
  "$_reboot_block"
# The old hardcoded Gen5-only restore name/value AND one-step fallback must be gone.
if grep -Fq '_post_flr_restore_gen5' <<<"$_reboot_block"; then
  printf 'FAIL: Q3t old _post_flr_restore_gen5 name still present\n' >&2
  record_failure "Q3t old Gen5-only restore name removed"
else
  printf 'PASS: Q3t old _post_flr_restore_gen5 name removed\n'
fi
if grep -Fq '${_saved_hi}5' <<<"$_reboot_block"; then
  printf 'FAIL: Q3t old hardcoded Gen5 LnkCtl2 restore still present\n' >&2
  record_failure "Q3t old hardcoded Gen5 restore value removed"
else
  printf 'PASS: Q3t old hardcoded Gen5 LnkCtl2 restore removed\n'
fi
if grep -Fq 'adapting to Gen' <<<"$_reboot_block"; then
  printf 'FAIL: Q3t old one-step fallback log (adapting to Gen) still present\n' >&2
  record_failure "Q3t old one-step fallback log removed"
else
  printf 'PASS: Q3t old one-step fallback log removed\n'
fi
if grep -Fq 'for _try in 1 2' <<<"$_reboot_block"; then
  printf 'FAIL: Q3t old one-step retry loop (for _try in 1 2) still present\n' >&2
  record_failure "Q3t old one-step retry loop removed"
else
  printf 'PASS: Q3t old one-step retry loop removed\n'
fi
# --- write_conf persists the new VFIO_REBOOT_FLR_MAX_GEN default ---
assert_contains_file \
  "Q3t write_conf persists VFIO_REBOOT_FLR_MAX_GEN default (empty)" \
  'VFIO_REBOOT_FLR_MAX_GEN=""' \
  "$VFIO_SCRIPT"
# --- installer warns when setpci (pciutils) is missing, with distro commands ---
_inst_flr_fn="$(sed -n '/^install_reboot_flr_monitor()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3t installer checks for setpci" \
  'have_cmd setpci' \
  "$_inst_flr_fn"
assert_contains_text \
  "Q3t installer warns the downtrain/restore will be skipped" \
  'adaptive PCIe link restore will be SKIPPED' \
  "$_inst_flr_fn"
assert_contains_text \
  "Q3t installer names the openSUSE pciutils install command" \
  'zypper in pciutils' \
  "$_inst_flr_fn"

# --- Functional Q3u: install_hypervisor_hiding (AMD driver install fix) ---
# The AMD Windows driver detects the hypervisor (CPUID leaves + Hyper-V vendor
# ID) and refuses to install the real display driver — card shows as Microsoft
# Basic Display Adapter + unknown PCI devices. install_hypervisor_hiding()
# automatically adds vendor_id=random, hidden state=on, kvm hidden to the XML
# of shut-off VMs that have the guest GPU. Gated to AMD guest GPUs.
assert_contains_file \
  "Q3u install_hypervisor_hiding function defined" \
  'install_hypervisor_hiding()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3u helper gates on AMD vendor 1002" \
  '"${_vendor,,}" != "1002"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3u helper uses virsh dumpxml + define" \
  'virsh -c qemu:///system define' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3u helper adds vendor_id=random" \
  "vendor_id state='on' value='random'" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3u helper adds kvm hidden" \
  '<kvm>' \
  "$VFIO_SCRIPT"
# The sed must add vendor_id before </hyperv> but NOT <hidden> (unsupported by
# older libvirt). Verify the sed line has vendor_id but NOT hidden before </hyperv>.
assert_contains_file \
  "Q3u helper adds vendor_id before close hyperv" \
  "vendor_id state='on' value='random'/>\\n    </hyperv>" \
  "$VFIO_SCRIPT"
# The <hidden> must only appear inside <kvm>, not inside <hyperv>. The first sed
# (no <kvm> present) inserts the whole <kvm> block with <hidden> inside it — that
# is correct. The SECOND sed (else branch, <kvm> already exists) should only add
# vendor_id before </hyperv> and NOT <hidden>. Check that the else-branch sed
# does not have <hidden> before </hyperv>.
_hyperv_fn="$(sed -n '/^install_hypervisor_hiding()/,/^}/p' "$VFIO_SCRIPT")"
# The else-branch sed is the one that does NOT contain <kvm> in its replacement.
_else_sed="$(printf '%s' "$_hyperv_fn" | grep 's|</hyperv>|' | grep -v '<kvm>' | head -1)"
if [[ -n "$_else_sed" ]] && ! printf '%s' "$_else_sed" | grep -Fq '<hidden' 2>/dev/null; then
  printf 'PASS: Q3u else-branch sed does NOT add hidden inside hyperv\n'
else
  printf 'FAIL: Q3u else-branch sed wrongly adds hidden inside hyperv (unsupported by older libvirt)\n' >&2
  record_failure "Q3u else-branch sed does not add hidden inside hyperv"
fi
assert_contains_file \
  "Q3u helper checks VM state (shut off only)" \
  'domstate' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3u helper is idempotent (skips already-hidden)" \
  'already has hypervisor hiding' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3u helper validates XML before define" \
  'virt-xml-validate' \
  "$VFIO_SCRIPT"
# install-dynamic-binding must call install_stealth_vm_tuning (opt-in) — the old
# install_hypervisor_hiding() call was replaced by the fuller stealth/perf tuning
# (which includes the hypervisor hide as a subset with vendor_id=GENUINE00000).
assert_contains_text \
  "Q3v install-dynamic-binding calls install_stealth_vm_tuning" \
  'install_stealth_vm_tuning' \
  "$_dyn_fn"
# The old install_hypervisor_hiding() must NOT be called from the dynamic path
# (avoids a duplicate vendor_id conflict with the stealth tuning).
if grep -Fq 'install_hypervisor_hiding' <<<"$_dyn_fn"; then
  printf 'FAIL: Q3v old install_hypervisor_hiding call still present in dynamic path\n' >&2
  record_failure "Q3v old install_hypervisor_hiding call removed from dynamic path"
else
  printf 'PASS: Q3v old install_hypervisor_hiding call removed from dynamic path\n'
fi
# The 'What this will do' note must document step 8 (stealth/perf VM tuning)
assert_contains_text \
  "Q3v dynamic note documents step 8 stealth/perf VM tuning" \
  'Stealth/perf VM tuning' \
  "$_dyn_fn"
assert_contains_text \
  "Q3v dynamic note mentions SMBIOS spoofing" \
  'SMBIOS spoofing' \
  "$_dyn_fn"
assert_contains_text \
  "Q3v dynamic note mentions virt-xml-validate verification" \
  'virt-xml-validate' \
  "$_dyn_fn"
# --- Q3v: install_stealth_vm_tuning function + CLI flags + standalone mode ---
assert_contains_file \
  "Q3v install_stealth_vm_tuning function defined" \
  'install_stealth_vm_tuning()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v STEALTH_VM_TUNING_OVERRIDE var declared" \
  'STEALTH_VM_TUNING_OVERRIDE=' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v parse_args handles --stealth-vm-tuning" \
  '--stealth-vm-tuning)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v parse_args handles --no-stealth-vm-tuning" \
  '--no-stealth-vm-tuning)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v parse_args handles --install-stealth-vm-tuning" \
  '--install-stealth-vm-tuning)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v usage documents --stealth-vm-tuning" \
  '--stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v usage documents --install-stealth-vm-tuning" \
  '--install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v fish completion includes --stealth-vm-tuning" \
  'complete -c $cmd -l stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v fish completion includes --install-stealth-vm-tuning" \
  'complete -c $cmd -l install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v bash completion includes --stealth-vm-tuning" \
  '--stealth-vm-tuning --no-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v bash completion includes --install-stealth-vm-tuning" \
  '--install-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v zsh completion includes --stealth-vm-tuning" \
  "'--stealth-vm-tuning" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v zsh completion includes --install-stealth-vm-tuning" \
  "'--install-stealth-vm-tuning" \
  "$VFIO_SCRIPT"
# --- Q3v: the function uses the Stealthy-VM tuning (vendor_id=GENUINE00000, python3) ---
assert_contains_file \
  "Q3v stealth tuning uses GENUINE00000 vendor_id" \
  'GENUINE00000' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning uses python3" \
  'python3 - "$_tmp"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning adds -cpu arg with kvm=off" \
  'kvm=off,hypervisor=off' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning adds -smbios arg (DMI-driven manufacturer/product)" \
  'type=1,manufacturer=' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning changes e1000e NIC" \
  "e1000e" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning randomizes disk serials" \
  'Samsung_' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning sets memballoon=none" \
  "mb.set('model', 'none')" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning handles python exit 3 (no changes)" \
  '_py_status == 3' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning validates XML before define" \
  'virt-xml-validate "$_tmp"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning prompts before redefine" \
  'Redefine VM' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning skips running VMs" \
  'not shut off' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning checks for python3" \
  'have_cmd python3' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v standalone install-stealth-vm-tuning MODE dispatch" \
  'MODE" == "install-stealth-vm-tuning"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v stealth tuning notes MIT license attribution" \
  'MIT-licensed' \
  "$VFIO_SCRIPT"

# --- Q3v+: the 7 stealth improvements (DMI / preserve commandline / reset mode / status / dry-run diff / backup dir / README) ---
# #1: host DMI sysfs reads for SMBIOS spoofing
assert_contains_file \
  "Q3v+ reads host DMI sys_vendor for SMBIOS" \
  '/sys/class/dmi/id/sys_vendor' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ reads host DMI product_name for SMBIOS" \
  '/sys/class/dmi/id/product_name' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ exports VFIO_STEALTH_DMI_SYS_VENDOR for python" \
  'VFIO_STEALTH_DMI_SYS_VENDOR' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ python reads DMI env var for SMBIOS manufacturer" \
  "os.environ.get('VFIO_STEALTH_DMI_SYS_VENDOR'" \
  "$VFIO_SCRIPT"
# #2: preserve existing qemu:commandline (dedupe instead of wipe)
assert_contains_file \
  "Q3v+ uses get_or_create_qemu_commandline (preserve, not wipe)" \
  'get_or_create_qemu_commandline' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ uses remove_qemu_arg_pair for idempotent dedupe" \
  'remove_qemu_arg_pair' \
  "$VFIO_SCRIPT"
if grep -Fq 'reset_qemu_commandline' "$VFIO_SCRIPT"; then
  printf 'FAIL: Q3v+ old reset_qemu_commandline (wipe) still present\n' >&2
  record_failure "Q3v+ old reset_qemu_commandline removed"
else
  printf 'PASS: Q3v+ old reset_qemu_commandline (wipe) removed\n'
fi
# #3: --reset-stealth-vm-tuning standalone revert mode
assert_contains_file \
  "Q3v+ reset_stealth_vm_tuning function defined" \
  'reset_stealth_vm_tuning()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ parse_args handles --reset-stealth-vm-tuning" \
  '--reset-stealth-vm-tuning)' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ usage documents --reset-stealth-vm-tuning" \
  '--reset-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ fish completion includes --reset-stealth-vm-tuning" \
  'complete -c $cmd -l reset-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ bash completion includes --reset-stealth-vm-tuning" \
  '--reset-stealth-vm-tuning' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ zsh completion includes --reset-stealth-vm-tuning" \
  "'--reset-stealth-vm-tuning" \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ standalone reset-stealth-vm-tuning MODE dispatch" \
  'MODE" == "reset-stealth-vm-tuning"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ reset_vfio_all notes stealth VM XMLs not reverted by --reset" \
  'stealth/perf-tuned VM XMLs are NOT reverted by --reset' \
  "$VFIO_SCRIPT"
# #4: stealth_vm_tuning_status in detect + verify
assert_contains_file \
  "Q3v+ stealth_vm_tuning_status function defined" \
  'stealth_vm_tuning_status()' \
  "$VFIO_SCRIPT"
_detect_fn="$(sed -n '/^detect_existing_vfio_report()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3v+ detect report calls stealth_vm_tuning_status" \
  'stealth_vm_tuning_status' \
  "$_detect_fn"
_verify_fn="$(sed -n '/^verify_vfio_setup()/,/^}/p' "$VFIO_SCRIPT" 2>/dev/null || true)"
if [[ -z "$_verify_fn" ]]; then
  # verify function may have a different name; check the whole script for the status call near RESULT
  if grep -Fq 'stealth_vm_tuning_status || true' "$VFIO_SCRIPT"; then
    printf 'PASS: Q3v+ verify calls stealth_vm_tuning_status\n'
  else
    printf 'FAIL: Q3v+ verify does not call stealth_vm_tuning_status\n' >&2
    record_failure "Q3v+ verify calls stealth_vm_tuning_status"
  fi
else
  assert_contains_text \
    "Q3v+ verify calls stealth_vm_tuning_status" \
    'stealth_vm_tuning_status' \
    "$_verify_fn"
fi
# #5: dry-run diff in the tuning function
assert_contains_file \
  "Q3v+ dry-run shows diff -u of current vs tuned XML" \
  'diff -u "$_backup_xml" "$_tmp"' \
  "$VFIO_SCRIPT"
# #6: STEALTH_VM_BACKUP_DIR conf key + fallback
assert_contains_file \
  "Q3v+ write_conf persists STEALTH_VM_BACKUP_DIR default" \
  'STEALTH_VM_BACKUP_DIR=""' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ backup dir falls back to /var/lib/vfio-stealth-vm/backups" \
  '/var/lib/vfio-stealth-vm/backups' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "Q3v+ reads STEALTH_VM_BACKUP_DIR from conf" \
  'STEALTH_VM_BACKUP_DIR=' \
  "$VFIO_SCRIPT"
# #7: README subsection
assert_contains_file \
  "Q3v+ README has stealth/perf VM tuning subsection" \
  'Stealth/perf VM tuning (SMBIOS / CPU / NIC / disk serials / iothreads)' \
  "${PROJECT_ROOT}/README.md"
assert_contains_file \
  "Q3v+ README documents --reset-stealth-vm-tuning" \
  '--reset-stealth-vm-tuning' \
  "${PROJECT_ROOT}/README.md"
assert_contains_file \
  "Q3v+ README documents --install-stealth-vm-tuning" \
  '--install-stealth-vm-tuning' \
  "${PROJECT_ROOT}/README.md"
assert_contains_file \
  "Q3v+ README notes MIT license attribution" \
  'MIT-licensed, by Fredrik Bäckström' \
  "${PROJECT_ROOT}/README.md"
# vmport state=off (VMware backdoor port — stops Windows "Is Virtual Machine: yes")
assert_contains_file \
  "Q3v+ stealth tuning sets vmport state=off" \
  "vmport.set('state', 'off')" \
  "$VFIO_SCRIPT"
# Full wizard (apply_configuration) dynamic block: reboot-FLR monitor + stealth prompt
_apply_fn="$(sed -n '/^apply_configuration()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "Q3v+ full wizard calls install_reboot_flr_monitor in dynamic block" \
  'install_reboot_flr_monitor' \
  "$_apply_fn"
assert_contains_text \
  "Q3v+ full wizard calls install_stealth_vm_tuning in dynamic block" \
  'install_stealth_vm_tuning' \
  "$_apply_fn"
assert_contains_text \
  "Q3v+ full wizard prompts for stealth/perf VM tuning" \
  'Apply stealth/perf VM tuning to detected guest-GPU VMs' \
  "$_apply_fn"
assert_contains_text \
  "Q3v+ full wizard stealth prompt mentions vmport off" \
  'vmport off' \
  "$_apply_fn"

# --- Functional Q3j: dedicated hook log ---
assert_contains_text \
  "Q3j hook has dedicated log file" \
  "/var/log/vfio-libvirt-hook.log" \
  "$hook_block"
assert_contains_text \
  "Q3j hook has hook_log helper function" \
  "hook_log()" \
  "$hook_block"
assert_contains_text \
  "Q3j hook logs bind-now action" \
  "action=bind-now" \
  "$hook_block"
assert_contains_text \
  "Q3j hook logs release action" \
  "action=release" \
  "$hook_block"

# --- Functional R1: csv_to_array defined BEFORE dynamic boot block (audio D3cold pin) ---
# csv_to_array must be defined above the dynamic boot block so audio BDFs are
# pinned too; the old ordering silently fell back to GPU-only pinning.
_csv_line=$(grep -Fn 'csv_to_array() {' <<<"$bind_block" | head -n1 | cut -d: -f1)
_dyn_line=$(grep -Fn 'if [[ "$ACTION" == "boot" && "$binding_mode" == "DYNAMIC" ]]; then' <<<"$bind_block" | head -n1 | cut -d: -f1)
if [[ -n "$_csv_line" && -n "$_dyn_line" ]] && (( _csv_line < _dyn_line )); then
  printf 'PASS: R1 csv_to_array defined before dynamic boot block\n'
else
  printf 'FAIL: R1 csv_to_array must be defined before the dynamic boot block (csv=%s dyn=%s)\n' "$_csv_line" "$_dyn_line" >&2
  record_failure "R1 csv_to_array defined before dynamic boot block"
fi
if grep -Fq 'command -v csv_to_array' <<<"$bind_block"; then
  printf 'FAIL: R1 broken csv_to_array guard still present\n' >&2
  record_failure "R1 broken csv_to_array guard removed"
else
  printf 'PASS: R1 broken csv_to_array guard removed\n'
fi
assert_contains_text \
  "R1 dynamic boot pins GPU + audio" \
  "pinned d3cold_allowed=0 + power/control=on (D0) on guest BDFs (GPU + audio)" \
  "$bind_block"

# --- Functional R2: bind_one skips rebind when already on vfio-pci ---
assert_contains_text \
  "R2 bind_one has already-on-vfio-pci early return" \
  "Already on vfio-pci: avoid a wasteful unbind" \
  "$bind_block"
assert_contains_text \
  "R2 bind_one early-return checks driver symlink" \
  'if [[ "$_already_drv" == "vfio-pci" ]]; then' \
  "$bind_block"

# --- Functional R3: host-audio safety pre-flight uses real membership test ---
assert_contains_text \
  "R3 host-audio pre-flight checks guest audio membership" \
  'grep -Eq "(^|,)${dev}($|,)" <<<"${GUEST_AUDIO_BDFS_CSV:-}"' \
  "$bind_block"
assert_contains_text \
  "R3 host-audio pre-flight dies on overlap" \
  'Refusing: guest audio $dev is also listed as host audio' \
  "$bind_block"
if grep -Fq '[[ "$dev" != "${GUEST_AUDIO_BDFS_CSV:-}" ]] || true' <<<"$bind_block"; then
  printf 'FAIL: R3 dead host-audio no-op check still present\n' >&2
  record_failure "R3 dead host-audio no-op check removed"
else
  printf 'PASS: R3 dead host-audio no-op check removed\n'
fi

# --- Functional R4: reprobe_to_host documents D3cold intentionally kept at 0 ---
assert_contains_text \
  "R4 reprobe_to_host documents d3cold left at 0" \
  "d3cold_allowed is deliberately left at 0" \
  "$bind_block"
assert_contains_text \
  "R4 reprobe_to_host warns not to restore d3cold" \
  'Do NOT restore it to 1' \
  "$bind_block"

# --- Functional R5: hook logs bind-now failure before aborting VM start ---
assert_contains_text \
  "R5 hook logs bind-now-failed on failure" \
  'action=bind-now-failed rc=$_rc' \
  "$hook_block"
assert_contains_text \
  "R5 hook exits non-zero on bind failure" \
  'exit "$_rc"' \
  "$hook_block"
if grep -Fq 'hook_log "action=bind-now-done rc=$?"' <<<"$hook_block"; then
  printf 'FAIL: R5 old uncaptured bind-now-done rc=$? log still present\n' >&2
  record_failure "R5 old uncaptured bind-now-done log removed"
else
  printf 'PASS: R5 old uncaptured bind-now-done log removed\n'
fi

# --- Functional R6: opt-in PCI function-level reset before bind ---
assert_contains_text \
  "R6 bind_one gates reset on VFIO_DYNAMIC_PCI_RESET" \
  'VFIO_DYNAMIC_PCI_RESET' \
  "$bind_block"
assert_contains_text \
  "R6 bind_one reset only when sysfs reset file writable" \
  '-w "$sys/reset"' \
  "$bind_block"
assert_contains_text \
  "R6 bind_one writes reset (via _rx9070_gated_soft_flr)" \
  'echo 1 >"$_sys/reset"' \
  "$bind_block"
# R20: VFIO_DYNAMIC_PCI_RESET default is now auto-detected (1 for RX 9070 /
# Navi 48 device 7550, 0 for other cards) instead of a hardcoded 0. Assert
# the variable form in the heredoc + the auto-detect logic.
assert_contains_file \
  "R6 write_conf persists VFIO_DYNAMIC_PCI_RESET (variable form)" \
  'VFIO_DYNAMIC_PCI_RESET="$pci_reset_default"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R20 write_conf auto-detects pci_reset_default for Navi 48" \
  'pci_reset_default="1"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R20 write_conf gates pci_reset_default on device 7550" \
  '"${guest_device,,}" == "7550"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R20 _sync_conf_defaults reads GUEST_GPU_DEVICE_ID for PCI_RESET default" \
  'GUEST_GPU_DEVICE_ID=' \
  "$VFIO_SCRIPT"

# --- Functional R7: journal logging of the bind sequence (jlog helper) ---
assert_contains_text \
  "R7 bind script has jlog helper" \
  "jlog()" \
  "$bind_block"
assert_contains_text \
  "R7 jlog uses logger -t vfio-dynamic" \
  "logger -t vfio-dynamic" \
  "$bind_block"
assert_contains_text \
  "R7 jlog logs unbind" \
  'jlog "$dev: unbind from $drv (before)' \
  "$bind_block"
assert_contains_text \
  "R7 jlog logs unbind after" \
  'jlog "$dev: unbind from $drv (after)' \
  "$bind_block"
assert_contains_text \
  "R7 jlog logs verified bind" \
  'jlog "$dev: bound to vfio-pci (verified, alive)"' \
  "$bind_block"

# --- Functional R8: actionable bind-failure error message ---
assert_contains_text \
  "R8 bind failure message lists next steps" \
  "Next steps:" \
  "$bind_block"
assert_contains_text \
  "R8 bind failure suggests dmesg" \
  "dmesg | tail -n 50" \
  "$bind_block"
assert_contains_text \
  "R8 bind failure suggests journalctl libvirtd" \
  "journalctl -u libvirtd --no-pager" \
  "$bind_block"
assert_contains_text \
  "R8 bind failure suggests --install-early-binding" \
  "vfio.sh --install-early-binding" \
  "$bind_block"

# --- Functional R9: bounded timeout around --bind-now in the hook ---
assert_contains_text \
  "R9 hook has _bind_now helper" \
  "_bind_now()" \
  "$hook_block"
assert_contains_text \
  "R9 hook _bind_now uses timeout" \
  'command -v timeout' \
  "$hook_block"
assert_contains_text \
  "R9 hook _bind_now honors VFIO_HOOK_BIND_TIMEOUT" \
  "VFIO_HOOK_BIND_TIMEOUT" \
  "$hook_block"
assert_contains_text \
  "R9 hook prepare calls _bind_now" \
  "if _bind_now; then" \
  "$hook_block"

# --- Functional R11: reprobe_to_host is instrumented + robust (step-by-step
# jlog, settle, verify host driver bound) so a segfault/hang during the
# vfio-pci -> amdgpu rebind is attributable AND the release case re-checks
# _pci_dev_alive + runs remove+rescan recovery if the card fell off. This
# was added after --release exited 139/SIGSEGV on an RX 9070 and a follow-up
# --bind-now wedged libvirt in D-state, with no way to see the crash site.
assert_contains_text \
  "R11 reprobe_to_host jlogs each step (before/after)" \
  'reprobe step 1/4 unbind from $drv (before)' \
  "$bind_block"
assert_contains_text \
  "R11 reprobe_to_host settles after drivers_probe + verifies host driver" \
  'reprobe step 3b/4 verified on' \
  "$bind_block"
assert_contains_text \
  "R11 release re-checks alive after reprobe + runs remove+rescan recovery" \
  'DEAD after reprobe_to_host (RX 9070 reset bug); attempting remove+rescan recovery at release' \
  "$bind_block"
assert_contains_text \
  "R11 bind_one brackets the vfio-pci bind write (D-state hang attribution)" \
  'vfio-pci bind attempt $_attempt/$_max_attempts (before)' \
  "$bind_block"
assert_contains_file \
  "R11 write_conf persists VFIO_REBIND_VERIFY_TIMEOUT" \
  'VFIO_REBIND_VERIFY_TIMEOUT="2"' \
  "$VFIO_SCRIPT"

# --- Functional B1: do_bind post-check uses local drv (no global leak) ---
assert_contains_text \
  "B1 do_bind post-check declares local drv" \
  'local drv' \
  "$bind_block"
# The post-check is the second `local drv` in do_bind; ensure the do_bind block
# contains exactly the guarded form, not the old unguarded assignment.
if grep -Fq 'drv="$(basename "$(readlink "/sys/bus/pci/devices/$GUEST_GPU_BDF/driver")")"' <<<"$(sed -n '/^do_bind()/,/^}/p' "$bind_block" | grep -v 'local drv')"; then
  printf 'FAIL: B1 unguarded drv assignment still present in do_bind\n' >&2
  record_failure "B1 do_bind drv is local (no unguarded assignment)"
else
  printf 'PASS: B1 do_bind drv is local (no unguarded assignment)\n'
fi

# --- Functional B2: --release path is timeout-wrapped in the hook ---
assert_contains_text \
  "B2 hook has _release helper" \
  "_release()" \
  "$hook_block"
assert_contains_text \
  "B2 hook _release honors VFIO_HOOK_RELEASE_TIMEOUT" \
  "VFIO_HOOK_RELEASE_TIMEOUT" \
  "$hook_block"
assert_contains_text \
  "B2 hook stopped/release calls _release" \
  "_release" \
  "$hook_block"
if grep -Fq '"$BIND_SCRIPT" --release' <<<"$hook_block" && ! grep -Fq '_release' <<<"$hook_block"; then
  printf 'FAIL: B2 raw --release call still present without _release helper\n' >&2
  record_failure "B2 --release routed through _release"
else
  printf 'PASS: B2 --release routed through _release\n'
fi

# --- Functional P1: already-on-vfio-pci applies a soft FLR to clear display state ---
# (was: "skipping rebind" — now does a soft FLR so OVMF can re-POST after a
# normal shutdown or forced kill, same as the reboot-FLR monitor does for a
# warm reboot.)
assert_contains_text \
  "P1 bind_one jlogs already-on-vfio-pci soft FLR" \
  'jlog "$dev: already on vfio-pci (alive); applying soft FLR' \
  "$bind_block"

# --- Functional P1b: after the alive-parked soft FLR, rebind vfio-pci to restore the ROM BAR ---
# The soft FLR zeroes the ROM BAR -> qemu's live option-ROM read at the fresh VM
# start returns 0xffff (dmesg: "Invalid PCI ROM header signature: expecting
# 0xaa55, got 0xffff") -> OVMF cannot run the GPU's UEFI GOP -> no firmware logo /
# signal but black until the Windows driver loads. This is exactly why a warm
# reboot (qemu never re-reads the ROM, display already POSTed) works but a
# shutdown->start does not. The fix: unbind vfio-pci and rebind so the PCI core
# re-enables the device and restores the ROM BAR (same as a cold amdgpu ->
# vfio-pci handoff). bind_one must NOT return 0 immediately after the FLR.
assert_contains_text \
  "P1b bind_one jlogs soft-FLR rebind to restore ROM/BARs" \
  'jlog "$dev: alive after soft FLR; rebinding vfio-pci to restore ROM/BARs' \
  "$bind_block"
assert_contains_text \
  "P1b bind_one unbinds vfio-pci after the soft FLR (post-FLR rebind)" \
  'echo "$dev" >"/sys/bus/pci/drivers/vfio-pci/unbind"' \
  "$bind_block"
assert_contains_text \
  "P1b bind_one rebinds vfio-pci after the soft FLR" \
  'jlog "$dev: bound to vfio-pci (verified, alive) after soft-FLR rebind"' \
  "$bind_block"

# --- Functional P2: retry loop logs which attempt succeeded ---
assert_contains_text \
  "P2 bind_one jlogs bound-on-attempt" \
  'jlog "$dev: bound on attempt $_attempt"' \
  "$bind_block"

# --- Functional P3: vm_uses_guest_gpu BDF match is case-insensitive ---
assert_contains_text \
  "P3 vm_uses_guest_gpu uses case-insensitive match" \
  'grep -Fixq "$b"' \
  "$hook_block"
if grep -Fq 'grep -Fxq "$b"' <<<"$hook_block"; then
  printf 'FAIL: P3 old case-sensitive grep -Fxq still present\n' >&2
  record_failure "P3 case-sensitive BDF match removed"
else
  printf 'PASS: P3 case-sensitive BDF match removed\n'
fi

# --- Functional conf-notes: every dynamic conf key has a WHY note ---
# A WHY note (comment line starting with '# WHY this value:') must appear within
# the few lines preceding each key="..." assignment. Use awk to pair them.
for _why_key in 'VFIO_BINDING_MODE' 'VFIO_DYNAMIC_REBIND_HOST' 'VFIO_DYNAMIC_ALLOW_BOOT_VGA' 'VFIO_DYNAMIC_PCI_RESET' 'VFIO_DYNAMIC_COOLDOWN_SECONDS' 'VFIO_RESTORE_D3COLD_ON_RELEASE' 'VFIO_HOOK_BIND_TIMEOUT'; do
  _ctx="$(awk -v k="$_why_key" '
    /^# WHY this value:/ { saw_why=1; next }
    $0 ~ "^" k "=" { if (saw_why) { print "FOUND"; saw_why=0 } }
    /^[A-Z_]+="/ { saw_why=0 }
  ' "$VFIO_SCRIPT" || true)"
  if [[ "$_ctx" == "FOUND" ]]; then
    printf 'PASS: conf-note %s has WHY rationale\n' "$_why_key"
  else
    printf 'FAIL: conf-note %s missing WHY rationale\n' "$_why_key" >&2
    record_failure "conf-note $_why_key has WHY rationale"
  fi
done
assert_contains_file \
  "conf persists VFIO_HOOK_BIND_TIMEOUT" \
  'VFIO_HOOK_BIND_TIMEOUT="20"' \
  "$VFIO_SCRIPT"

# --- Functional R12: _sync_conf_defaults closes the conf-drift gap ---
# The binding switchers (--install-dynamic-binding / --install-early-binding)
# only flip VFIO_BINDING_MODE via rewrite_conf_key; they never call write_conf
# (which needs full wizard context), so advanced keys added to write_conf in
# later releases never land in an older live conf. _sync_conf_defaults merges
# any MISSING fixed-default keys into the existing conf (preserving user values),
# and BOTH switchers must call it so the conf stays in sync with the script.
assert_contains_file \
  "R12 _sync_conf_defaults helper is defined" \
  '_sync_conf_defaults()' \
  "$VFIO_SCRIPT"
_dyn_fn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
_early_fn="$(sed -n '/^install_early_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
if printf '%s\n' "$_dyn_fn" | grep -Fq '_sync_conf_defaults'; then
  printf 'PASS: R12 install_dynamic_binding_from_existing_config calls _sync_conf_defaults\n'
else
  printf 'FAIL: R12 install_dynamic_binding_from_existing_config missing _sync_conf_defaults call\n' >&2
  record_failure "R12 install_dynamic_binding calls _sync_conf_defaults"
fi
if printf '%s\n' "$_early_fn" | grep -Fq '_sync_conf_defaults'; then
  printf 'PASS: R12 install_early_binding_from_existing_config calls _sync_conf_defaults\n'
else
  printf 'FAIL: R12 install_early_binding_from_existing_config missing _sync_conf_defaults call\n' >&2
  record_failure "R12 install_early_binding calls _sync_conf_defaults"
fi
# The helper must be idempotent (only add MISSING keys) and must NOT touch
# computed/identity keys (HOST_GPU_BDF, GUEST_*, VFIO_BINDING_MODE). Verify it
# uses a fixed-default map and a grep presence check, not a full rewrite.
_sync_fn="$(sed -n '/^_sync_conf_defaults()/,/^}/p' "$VFIO_SCRIPT")"
if printf '%s\n' "$_sync_fn" | grep -Fq 'local -A _defs=' \
  && printf '%s\n' "$_sync_fn" | grep -Fq 'grep -Eq "^${_k}="' \
  && printf '%s\n' "$_sync_fn" | grep -Fq 'Synced $_added missing default conf key(s)'; then
  printf 'PASS: R12 _sync_conf_defaults is idempotent (missing-only merge) with a fixed-default map\n'
else
  printf 'FAIL: R12 _sync_conf_defaults missing idempotent merge logic or fixed-default map\n' >&2
  record_failure "R12 _sync_conf_defaults is idempotent missing-only merge"
fi

# --- Functional R13: reprobe_to_host binds DIRECTLY to the remembered host
# driver (not the generic /sys/bus/pci/drivers_probe re-probe that SEGFAULTS
# exit 139 on Navi 48 / RX 9070 after vfio-pci). bind_one remembers the
# pre-vfio-pci host driver (amdgpu/snd_hda_intel) to a state file; reprobe_to_host
# reads it and binds directly via /sys/bus/pci/drivers/<prev>/bind, falling back
# to drivers_probe ONLY if no prior driver was remembered or the direct bind
# did not land. Confirmed crash site: 21:25:21 --release died at the
# drivers_probe write (SIGSEGV, wedged libvirt).
assert_contains_text \
  "R13 bind_one remembers pre-vfio-pci host driver to state file" \
  'remembered pre-vfio-pci host driver' \
  "$bind_block"
assert_contains_text \
  "R13 bind_one persists the driver name to <state-dir>/<bdf>.prev_driver" \
  '.prev_driver' \
  "$bind_block"
assert_contains_text \
  "R13 reprobe_to_host reads the remembered prev driver" \
  'prev_driver' \
  "$bind_block"
assert_contains_text \
  "R13 reprobe_to_host prefers direct bind to the remembered driver" \
  'direct bind to $_prev_drv' \
  "$bind_block"
assert_contains_text \
  "R13 reprobe_to_host falls back to drivers_probe only when direct bind fails" \
  'CRASH-PRONE on Navi 48' \
  "$bind_block"

# --- Functional R14: amdgpu-readiness gate + opt-in pre-rebind FLR ---
# The amdgpu->vfio-pci handoff in --bind-now D-stated (15:36:49) because amdgpu
# had not FINISHED probing (DRM card not up) when bind-now unbound it 9s after a
# release rebind. "Config space readable" (_pci_dev_alive) is NOT readiness --
# amdgpu's DRM card appears at the END of async probe. R14 adds:
#  (a) _amdgpu_ready / _wait_amdgpu_ready helpers (DRM-card-up = probe done);
#  (b) reprobe_to_host settles for amdgpu-readiness after the rebind (step 3c/4);
#  (c) an opt-in pre-rebind soft FLR (VFIO_DYNAMIC_FLR_BEFORE_REBIND) at step 2b/4;
#  (d) a bind-now amdgpu-readiness gate right before do_bind.
assert_contains_text \
  "R14 _amdgpu_ready helper defined (DRM-card-up = amdgpu probe done)" \
  '_amdgpu_ready()' \
  "$bind_block"
assert_contains_text \
  "R14 _wait_amdgpu_ready bounded poll defined" \
  '_wait_amdgpu_ready()' \
  "$bind_block"
assert_contains_text \
  "R14 reprobe_to_host settles for amdgpu-readiness after rebind (step 3c/4)" \
  'reprobe step 3c/4' \
  "$bind_block"
assert_contains_text \
  "R14 reprobe_to_host has opt-in pre-rebind soft FLR gate (step 2b/4)" \
  'reprobe step 2b/4 pre-rebind soft FLR' \
  "$bind_block"
assert_contains_text \
  "R14 bind-now waits for amdgpu-readiness before do_bind" \
  'waiting for amdgpu-readiness (DRM card up) before bind' \
  "$bind_block"
assert_contains_file \
  "R14 write_conf persists VFIO_DYNAMIC_FLR_BEFORE_REBIND" \
  'VFIO_DYNAMIC_FLR_BEFORE_REBIND="0"' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R14 write_conf persists VFIO_AMDGPU_READY_TIMEOUT" \
  'VFIO_AMDGPU_READY_TIMEOUT="5"' \
  "$VFIO_SCRIPT"

# --- Functional R15: opt-in Secondary Bus Reset (SBR) before the host-driver
# rebind -- a HEAVIER reset than the R14 soft FLR, for the case where the soft
# FLR did NOT fix the amdgpu rebind hang (observed 16:16:25 on Navi 48: the FLR
# fired cleanly but the direct amdgpu/bind still hung in D-state, amdgpu's probe
# never finished, DRM card never came up). R15 adds:
#  (a) _secondary_bus_reset helper (pulses RST# on the upstream port's secondary
#      bus via setpci Bridge Control offset 0x3E bit 6 = 0x0040, wrapped in the
#      SAME Gen1 downtrain + adaptive link restore as the other reset paths);
#  (b) reprobe_to_host step 2c/4 opt-in SBR gate (VFIO_DYNAMIC_SBR_BEFORE_REBIND),
#      GPU BDF only (one SBR resets the audio sibling too), taking PRECEDENCE
#      over the 2b/4 soft FLR (heavier, supersedes);
#  (c) the new conf key persisted in write_conf + _sync_conf_defaults.
assert_contains_text \
  "R15 _secondary_bus_reset helper defined (pulses RST# on the upstream port)" \
  '_secondary_bus_reset()' \
  "$bind_block"
assert_contains_text \
  "R15 _secondary_bus_reset reads Bridge Control at offset 0x3E" \
  '3E.w' \
  "$bind_block"
assert_contains_text \
  "R15 _secondary_bus_reset asserts SBR bit 6 (0x0040)" \
  '0x0040' \
  "$bind_block"
assert_contains_text \
  "R15 _secondary_bus_reset de-asserts SBR (clears bit 6 via 0xFFBF)" \
  '0xFFBF' \
  "$bind_block"
assert_contains_text \
  "R15 reprobe_to_host has opt-in pre-rebind SBR gate (step 2c/4)" \
  'reprobe step 2c/4 pre-rebind SBR' \
  "$bind_block"
assert_contains_text \
  "R15 SBR gate is GPU BDF only (avoids double-resetting the audio sibling)" \
  '"$dev" == "${GUEST_GPU_BDF:-}"' \
  "$bind_block"
assert_contains_text \
  "R15 SBR takes precedence over the soft FLR (elif on FLR after SBR if)" \
  'VFIO_DYNAMIC_SBR_BEFORE_REBIND' \
  "$bind_block"
assert_contains_file \
  "R15 write_conf persists VFIO_DYNAMIC_SBR_BEFORE_REBIND" \
  'VFIO_DYNAMIC_SBR_BEFORE_REBIND="0"' \
  "$VFIO_SCRIPT"
_sync_fn_sbr="$(sed -n '/^_sync_conf_defaults()/,/^}/p' "$VFIO_SCRIPT")"
if printf '%s\n' "$_sync_fn_sbr" | grep -Fq '[VFIO_DYNAMIC_SBR_BEFORE_REBIND]'; then
  printf 'PASS: R15 _sync_conf_defaults merges VFIO_DYNAMIC_SBR_BEFORE_REBIND\n'
else
  printf 'FAIL: R15 _sync_conf_defaults missing VFIO_DYNAMIC_SBR_BEFORE_REBIND\n' >&2
  record_failure "R15 _sync_conf_defaults merges SBR key"
fi

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'Dynamic binding regression checks passed.\n'
