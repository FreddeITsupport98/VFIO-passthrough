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
  "pinned d3cold_allowed=0 on guest BDFs" \
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
  "pinned d3cold_allowed=0 on guest BDFs (GPU + audio)" \
  "$bind_block"

# --- Functional R2: bind_one skips rebind when already on vfio-pci ---
assert_contains_text \
  "R2 bind_one has already-on-vfio-pci early return" \
  "Already on vfio-pci: nothing to do" \
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
  "R6 bind_one writes reset" \
  'echo 1 >"$sys/reset"' \
  "$bind_block"
assert_contains_file \
  "R6 write_conf persists VFIO_DYNAMIC_PCI_RESET" \
  'VFIO_DYNAMIC_PCI_RESET="0"' \
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
  'jlog "$dev: unbind from $drv"' \
  "$bind_block"
assert_contains_text \
  "R7 jlog logs verified bind" \
  'jlog "$dev: bound to vfio-pci (verified)"' \
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

# --- Functional R10: opt-in d3cold restore on host rebind ---
assert_contains_text \
  "R10 reprobe_to_host gates d3cold restore on VFIO_RESTORE_D3COLD_ON_RELEASE" \
  'VFIO_RESTORE_D3COLD_ON_RELEASE' \
  "$bind_block"
assert_contains_text \
  "R10 reprobe_to_host restores d3cold_allowed=1 when opted in" \
  'echo 1 >"$sys/d3cold_allowed"' \
  "$bind_block"
assert_contains_file \
  "R10 write_conf persists VFIO_RESTORE_D3COLD_ON_RELEASE" \
  'VFIO_RESTORE_D3COLD_ON_RELEASE="0"' \
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

# --- Functional P1: already-on-vfio-pci early-return is journal-logged ---
assert_contains_text \
  "P1 bind_one jlogs already-on-vfio-pci skip" \
  'jlog "$dev: already on vfio-pci, skipping rebind"' \
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
for _why_key in 'VFIO_BINDING_MODE' 'VFIO_DYNAMIC_REBIND_HOST' 'VFIO_DYNAMIC_ALLOW_BOOT_VGA' 'VFIO_DYNAMIC_PCI_RESET' 'VFIO_RESTORE_D3COLD_ON_RELEASE' 'VFIO_HOOK_BIND_TIMEOUT'; do
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

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi
printf 'Dynamic binding regression checks passed.\n'
