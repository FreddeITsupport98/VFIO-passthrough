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
  "--binding-mode --verify" \
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

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'Dynamic binding regression checks passed.\n'
