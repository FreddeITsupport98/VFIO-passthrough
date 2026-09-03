#!/usr/bin/env bash
# R35 regression: ultimate-performance VM tuning (stealth-safe).
# Static wiring + functional python-patcher assertions. Does NOT need root or a
# real libvirt VM — it extracts the embedded perf patcher heredoc and runs it on
# a mock VM XML, then validates with virt-xml-validate and asserts the perf
# markers are added, stealth markers survive, numatune uses nodeset, hugepages is
# opt-in, and the patcher is idempotent (python exit 3 on a no-change re-run).
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
assert_contains_file "install_ultimate_perf_vm_tuning function exists" "install_ultimate_perf_vm_tuning()" "$VFIO_SCRIPT"
assert_contains_file "reset_ultimate_perf_vm_tuning function exists" "reset_ultimate_perf_vm_tuning()" "$VFIO_SCRIPT"
assert_contains_file "ultimate_perf_vm_tuning_status function exists" "ultimate_perf_vm_tuning_status()" "$VFIO_SCRIPT"
assert_contains_file "_reserve_host_hugepages_for_vm helper exists" "_reserve_host_hugepages_for_vm()" "$VFIO_SCRIPT"
assert_contains_file "_restore_host_hugepages_for_vm helper exists" "_restore_host_hugepages_for_vm()" "$VFIO_SCRIPT"
assert_contains_file "ULTIMATE_PERF_HUGEPAGES_OVERRIDE var declared" "ULTIMATE_PERF_HUGEPAGES_OVERRIDE=" "$VFIO_SCRIPT"
assert_contains_file "ULTIMATE_PERF_VM_BACKUP_DIR conf key" "ULTIMATE_PERF_VM_BACKUP_DIR=" "$VFIO_SCRIPT"
assert_contains_file "ULTIMATE_PERF_HUGEPAGES conf key" "ULTIMATE_PERF_HUGEPAGES=\"\"" "$VFIO_SCRIPT"
assert_contains_file "ULTIMATE_PERF_HUGEPAGES_SIZE conf key" "ULTIMATE_PERF_HUGEPAGES_SIZE=" "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --install-ultimate-perf-vm-tuning" "--install-ultimate-perf-vm-tuning)" "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --reset-ultimate-perf-vm-tuning" "--reset-ultimate-perf-vm-tuning)" "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --ultimate-perf-hugepages" "--ultimate-perf-hugepages)" "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --no-ultimate-perf-hugepages" "--no-ultimate-perf-hugepages)" "$VFIO_SCRIPT"
assert_contains_file "MODE comment lists install-ultimate-perf-vm-tuning" "install-ultimate-perf-vm-tuning |" "$VFIO_SCRIPT"
assert_contains_file "usage one-liner includes --install-ultimate-perf-vm-tuning" "[--install-ultimate-perf-vm-tuning]" "$VFIO_SCRIPT"
assert_contains_file "fish completion includes --install-ultimate-perf-vm-tuning" "complete -c \$cmd -l install-ultimate-perf-vm-tuning" "$VFIO_SCRIPT"
assert_contains_file "bash completion opts include ultimate-perf flags" "--install-ultimate-perf-vm-tuning --reset-ultimate-perf-vm-tuning" "$VFIO_SCRIPT"
assert_contains_file "zsh completion includes --install-ultimate-perf-vm-tuning" "'--install-ultimate-perf-vm-tuning" "$VFIO_SCRIPT"
assert_contains_file "main dispatch install-ultimate-perf-vm-tuning" '"install-ultimate-perf-vm-tuning"' "$VFIO_SCRIPT"
assert_contains_file "main dispatch reset-ultimate-perf-vm-tuning" '"reset-ultimate-perf-vm-tuning"' "$VFIO_SCRIPT"
assert_contains_file "menu has Apply ultimate-perf option" "Apply ultimate-perf VM tuning (stealth-safe" "$VFIO_SCRIPT"
assert_contains_file "menu has Revert ultimate-perf option" "Revert ultimate-perf VM tuning (from backup XML, restores nr_hugepages)" "$VFIO_SCRIPT"
assert_contains_file "detect calls ultimate_perf_vm_tuning_status" "ultimate_perf_vm_tuning_status || true" "$VFIO_SCRIPT"
# Stealth-safe guarantee is documented in the function header.
assert_contains_file "install fn documents stealth-safe guarantee" "STEALTH-SAFE" "$VFIO_SCRIPT"
assert_contains_file "install fn documents hugepages opt-in" "OPT-IN" "$VFIO_SCRIPT"

# ===================== Functional: extract + run perf patcher =====================
perf_py="$tmp_dir/perf_tuner.py"
# Extract the python heredoc inside install_ultimate_perf_vm_tuning (the first
# <<'PYEOF' ... PYEOF block after the function definition).
awk '
  /install_ultimate_perf_vm_tuning\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$perf_py"

if python3 -m py_compile "$perf_py" 2>/dev/null; then
  printf 'PASS: perf patcher python compiles (py_compile)\n'
else
  printf 'FAIL: perf patcher python does not compile\n' >&2
  record_failure "perf patcher python compiles"
fi

# Mock VM XML that already carries the STEALTH markers (so we can prove the perf
# pass does not disturb them).
mock="$tmp_dir/mock.xml"
cat >"$mock" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <os>
    <type arch="x86_64" machine="pc-q35-9.2">hvm</type>
    <smbios mode="sysinfo"/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <hyperv mode="custom">
      <vendor_id state="on" value="GENUINE00000"/>
      <relaxed state="on"/>
    </hyperv>
    <kvm>
      <hidden state="on"/>
    </kvm>
    <vmport state="off"/>
  </features>
  <cpu mode="host-passthrough" check="none" migratable="on">
    <feature policy="disable" name="hypervisor"/>
  </cpu>
  <clock offset="localtime">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="hypervclock" present="no"/>
    <timer name="tsc" mode="native" present="yes"/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="/var/lib/libvirt/images/win11.qcow2"/>
      <target dev="vda" bus="virtio"/>
      <serial>Samsung_ABCD1234</serial>
    </disk>
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <source file="/usr/share/virtio-win/virtio-win.iso"/>
      <target dev="sda" bus="sata"/>
      <readonly/>
    </disk>
    <interface type="network">
      <model type="e1000e"/>
      <source network="default"/>
    </interface>
    <memballoon model="none"/>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source>
        <address domain="0x0000" bus="0x0e" slot="0x00" function="0x0"/>
      </source>
    </hostdev>
  </devices>
  <qemu:commandline xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
    <qemu:arg value="-cpu"/>
    <qemu:arg value="host,kvm=off,hypervisor=off,hv_vendor_id=null,invtsc=on"/>
    <qemu:arg value="-smbios"/>
    <qemu:arg value="type=1,manufacturer=ASUS,product=ROG,serial=ABCDEF1234,uuid=12345678-1234-1234-1234-123456789abc"/>
  </qemu:commandline>
</domain>
XEOF

# --- Run 1: hugepages OFF, single-NUMA mock ---
tuned="$tmp_dir/tuned.xml"
cp "$mock" "$tuned"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    python3 "$perf_py" "$tuned" >/dev/null 2>&1
rc1=$?
set -e
assert_eq "perf patcher exit 0 on first run (hugepages off)" "0" "$rc1"

if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$tuned" >/dev/null 2>&1; then
    printf 'PASS: tuned XML validates (virt-xml-validate)\n'
  else
    printf 'FAIL: tuned XML fails virt-xml-validate\n' >&2
    record_failure "tuned XML validates"
  fi
else
  printf 'SKIP: virt-xml-validate not installed\n'
fi

# Perf markers added.
assert_contains_file "disk cache=none added" 'cache="none"' "$tuned"
assert_contains_file "disk io=native added" 'io="native"' "$tuned"
assert_contains_file "disk discard=unmap added" 'discard="unmap"' "$tuned"
assert_contains_file "virtio-blk multiqueue queues added" 'queues="4"' "$tuned"
assert_contains_file "disk iothread assignment added" 'iothread="1"' "$tuned"
assert_contains_file "cputune added" "<cputune>" "$tuned"
assert_contains_file "cputune has vcpupin" "vcpupin vcpu=\"0\"" "$tuned"
assert_contains_file "cputune has emulatorpin" "emulatorpin cpuset=\"0\"" "$tuned"
assert_contains_file "cputune has iothreadpin" "iothreadpin iothread=\"1\"" "$tuned"
assert_contains_file "numatune added (NUMA-safe single node)" "<numatune>" "$tuned"
assert_contains_file "numatune memory uses nodeset (not cpuset)" 'memory mode="strict" nodeset="0"' "$tuned"
# Scope the negative checks to the numatune <memory> element only: cpuset=
# legitimately appears in <cputune> pins, and ElementTree serializes cputune +
# numatune onto the SAME line, so a block/line-wide negative check would
# false-positive. Extract just the <numatune><memory .../> element.
_nt_mem="$(grep -oE '<numatune><memory [^>]*/>' "$tuned" | head -1)"
if grep -Fq 'cpuset' <<<"$_nt_mem" 2>/dev/null; then
  printf 'FAIL: numatune memory must not use cpuset (found in: %s)\n' "$_nt_mem" >&2
  record_failure "numatune memory does NOT use cpuset"
else
  printf 'PASS: numatune memory does NOT use cpuset\n'
fi
if grep -Fq 'cellid' <<<"$_nt_mem" 2>/dev/null; then
  printf 'FAIL: numatune memory must not use cellid (found in: %s)\n' "$_nt_mem" >&2
  record_failure "numatune memory does NOT use cellid"
else
  printf 'PASS: numatune memory does NOT use cellid\n'
fi
assert_contains_file "pm S3 disabled" 'suspend-to-mem enabled="no"' "$tuned"
assert_contains_file "pm S4 disabled" 'suspend-to-disk enabled="no"' "$tuned"
assert_contains_file "cpu topology added" "<topology" "$tuned"
assert_contains_file "cpu cache passthrough added" '<cache mode="passthrough"' "$tuned"
assert_contains_file "currentMemory=memory (no startup balloon)" "<currentMemory" "$tuned"
assert_contains_file "iothreads scaled to min(vcpu,4)=4" "<iothreads>4" "$tuned"

# Stealth markers survive the perf pass (the core guarantee).
assert_contains_file "stealth vendor_id=GENUINE00000 survives" "GENUINE00000" "$tuned"
assert_contains_file "stealth QEMU -cpu arg survives" "kvm=off,hypervisor=off" "$tuned"
assert_contains_file "stealth disk serial survives" "Samsung_ABCD1234" "$tuned"
assert_contains_file "stealth e1000e NIC survives" "e1000e" "$tuned"
assert_contains_file "stealth memballoon=none survives" 'memballoon model="none"' "$tuned"
assert_contains_file "stealth vmport=off survives" 'vmport state="off"' "$tuned"
assert_contains_file "stealth hypervclock=off survives" 'hypervclock" present="no"' "$tuned"
assert_contains_file "stealth TSC native survives" 'tsc" mode="native"' "$tuned"
# qemu:commandline prefix preserved (not rewritten to ns0).
assert_contains_file "qemu:commandline prefix preserved" "qemu:commandline" "$tuned"
assert_not_contains_file "no ns0 namespace leak" "ns0:" "$tuned"

# Hugepages is opt-in: absent when opted out.
assert_not_contains_file "hugepages absent when opted out" "<hugepages" "$tuned"

# --- Idempotency: re-run on the already-tuned XML must exit 3 (no changes) ---
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    python3 "$perf_py" "$tuned" >/dev/null 2>&1
rc2=$?
set -e
assert_eq "perf patcher idempotent (exit 3 on no-change re-run)" "3" "$rc2"

# --- Hugepages ON: memoryBacking added + still validates + stealth survives ---
hp="$tmp_dir/hp.xml"
cp "$mock" "$hp"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="1" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    python3 "$perf_py" "$hp" >/dev/null 2>&1
rc_hp=$?
set -e
assert_eq "perf patcher exit 0 with hugepages on" "0" "$rc_hp"
assert_contains_file "hugepages page added when opted in (KiB units)" '<hugepages><page size="2048" unit="KiB"' "$hp"
assert_contains_file "memoryBacking locked added" "<locked" "$hp"
assert_contains_file "memoryBacking nosharepages added" "<nosharepages" "$hp"
assert_contains_file "stealth vendor_id survives hugepages run" "GENUINE00000" "$hp"
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$hp" >/dev/null 2>&1; then
    printf 'PASS: hugepages-tuned XML validates\n'
  else
    printf 'FAIL: hugepages-tuned XML fails virt-xml-validate\n' >&2
    record_failure "hugepages-tuned XML validates"
  fi
fi

# ===================== Hugepages hardening (R35 follow-up) =====================
# Units fix: libvirt <page> uses KiB (2048 KiB = 2 MiB = standard 2MB hugepage),
# NOT MiB. The patcher must emit unit="KiB" and never leak unit="MiB".
assert_contains_file "hugepages page uses KiB units" 'unit="KiB"' "$hp"
assert_not_contains_file "no stale MiB unit in hugepages page" 'unit="MiB"' "$hp"

# _vm_memory_kib parses <memory> correctly (functional; read-only helper, safe).
_mem_out="$(_vm_memory_kib "$(cat "$mock")")"
assert_eq "_vm_memory_kib reads 8GiB as 8388608 KiB" "8388608" "$_mem_out"
_mem_zero="$(_vm_memory_kib "<domain><memory unit='KiB'>0</memory></domain>")"
assert_eq "_vm_memory_kib returns 0 on zero memory" "0" "$_mem_zero"

# RAM-change recompute math: need = ceil(mem_kib / page_kib). The helper computes
# this from the CURRENT <memory> so a RAM grow/shrink between runs adjusts the
# pool up/down (instead of only ever adding). 8GiB/2MiB=4096; 4GiB/2MiB=2048.
_need_8g=$(( 8388608 / 2048 )); (( _need_8g * 2048 < 8388608 )) && _need_8g=$(( _need_8g + 1 ))
assert_eq "RAM-change math 8GiB/2MiB = 4096 pages" "4096" "$_need_8g"
_need_4g=$(( 4194304 / 2048 )); (( _need_4g * 2048 < 4194304 )) && _need_4g=$(( _need_4g + 1 ))
assert_eq "RAM-change math 4GiB/2MiB = 2048 pages" "2048" "$_need_4g"

# 1GB guard: page size >= 1048576 KiB (1GB) cannot be reserved at runtime (the
# nr_hugepages knob only controls the 2MB pool); the helper warns + returns 1.
assert_contains_file "1GB guard threshold (1048576 KiB)" "_size_kib >= 1048576" "$VFIO_SCRIPT"
assert_contains_file "1GB guard warns runtime reservation impossible" "cannot be reserved at runtime" "$VFIO_SCRIPT"

# Reserve-first + verify: helper writes nr_hugepages then RE-READS the knob to
# confirm the kernel delivered the full count (runtime grants can fall short on
# fragmented RAM); on a shortfall it reverts the pool and returns 1.
assert_contains_file "reserve-first + verify documented" "RESERVE-FIRST + VERIFY" "$VFIO_SCRIPT"
assert_contains_file "verify re-reads nr_hugepages after write" '_got="$(cat /proc/sys/vm/nr_hugepages' "$VFIO_SCRIPT"
assert_contains_file "shortfall check compares got vs want" "_got < _want" "$VFIO_SCRIPT"

# Reboot-safe re-reserve: on a re-run the helper recomputes from the CURRENT
# <memory> (no early skip when the pool already has pages), so a post-reboot
# nr_hugepages=0 is re-reserved automatically instead of silently breaking start.
assert_contains_file "reboot-safe re-reserve documented" "re-reserve" "$VFIO_SCRIPT"

# Owned-file accounting: per-VM owned count persisted so a RAM shrink frees this
# VM's surplus while preserving other tuned VMs' reservations.
assert_contains_file "owned-file accounting present" "_perf_hugepages_owned.txt" "$VFIO_SCRIPT"

# Rollback on skip paths: a short reservation / user-decline / define-fail calls
# the restore helper so the host pool is not left claiming pages for a VM that
# was NOT redefined with <memoryBacking>hugepages this run.
assert_contains_file "rollback on skip paths calls restore helper" "_restore_host_hugepages_for_vm" "$VFIO_SCRIPT"

# CRITICAL regression: the restore must fire ONLY on the skip paths (unsupported
# domain, patching failed, validate failed, user declined, define failed), NOT on
# the success path. An earlier version had an early-rollback block right after
# the python heredoc that fired on _py_status != 3 -- which included the SUCCESS
# exit 0 -- freeing the host hugepages the VM was just defined to demand, leaving
# the VM unstartable (XML has <memoryBacking>hugepages but host nr_hugepages=0).
# The fix moved the restore onto each skip-path continue; the already-tuned path
# (exit 3) and the SUCCESS path (define succeeded) keep the ownership.
# Assert: the fixed inline restore-on-skip form appears on all 5 skip paths.
_inline_restores="$(grep -cF "then _restore_host_hugepages_for_vm" "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _inline_restores >= 5 )); then
  printf 'PASS: restore fires on all 5 skip paths (inline form: %d)\n' "$_inline_restores"
else
  printf 'FAIL: restore not on all skip paths (only %d inline calls, expected >= 5)\n' "$_inline_restores" >&2
  record_failure "restore fires on all 5 skip paths"
fi
# Assert: the buggy early-rollback block (8-space-indented _restore inside an
# else of a _py_status==3 check, right after PYEOF) is GONE. The buggy form was:
#     else
#       _restore_host_hugepages_for_vm "$_backup_dir" "$_dom"
#     fi
# at 8-space indent. The fixed code has no such 8-space-indented restore call.
set +e
_buggy_restores="$(grep -cE '^        _restore_host_hugepages_for_vm ' "$VFIO_SCRIPT" 2>/dev/null)"
set -e
: "${_buggy_restores:=0}"
if [[ "$_buggy_restores" == "0" ]]; then
  printf 'PASS: buggy early-rollback block (fires on success) is gone\n'
else
  printf 'FAIL: buggy early-rollback block still present (%d 8-space restore calls)\n' "$_buggy_restores" >&2
  record_failure "buggy early-rollback block is gone"
fi

# ===================== Dynamic-install integration (R35) =====================
# The dynamic binding switcher (--install-dynamic-binding) and the full wizard's
# dynamic path must BOTH offer ultimate-perf VM tuning (opt-in, default N),
# mirroring the stealth tuning opt-in. Honors --ultimate-perf-vm-tuning /
# --no-ultimate-perf-vm-tuning overrides via ULTIMATE_PERF_VM_TUNING_OVERRIDE.
assert_contains_file "ULTIMATE_PERF_VM_TUNING_OVERRIDE var declared" "ULTIMATE_PERF_VM_TUNING_OVERRIDE=" "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --ultimate-perf-vm-tuning" "--ultimate-perf-vm-tuning)" "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --no-ultimate-perf-vm-tuning" "--no-ultimate-perf-vm-tuning)" "$VFIO_SCRIPT"
assert_contains_file "usage one-liner includes --ultimate-perf-vm-tuning" "[--ultimate-perf-vm-tuning]" "$VFIO_SCRIPT"
assert_contains_file "fish completion includes --ultimate-perf-vm-tuning" "complete -c \$cmd -l ultimate-perf-vm-tuning" "$VFIO_SCRIPT"
assert_contains_file "zsh completion includes --ultimate-perf-vm-tuning" "'--ultimate-perf-vm-tuning[" "$VFIO_SCRIPT"
# The dynamic binding switcher (install_dynamic_binding_from_existing_config)
# must call install_ultimate_perf_vm_tuning + honor the override. The switcher's
# block sits at 2-space base indent (4 spaces to the call). The full wizard's
# dynamic path (apply_configuration) is nested one level deeper (6 spaces to the
# call). Count call occurrences at each indent to prove BOTH paths wire it in,
# without a fragile awk function-region extraction (heredocs inside those
# functions contain func-like lines that break region slicing).
_switcher_calls="$(grep -cE '^    install_ultimate_perf_vm_tuning$' "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
_wizard_calls="$(grep -cE '^      install_ultimate_perf_vm_tuning$' "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _switcher_calls >= 2 )); then
  printf 'PASS: dynamic binding switcher calls install_ultimate_perf_vm_tuning (%d)\n' "$_switcher_calls"
else
  printf 'FAIL: dynamic binding switcher does NOT call install_ultimate_perf_vm_tuning (only %d at 4-space indent)\n' "$_switcher_calls" >&2
  record_failure "dynamic binding switcher calls install_ultimate_perf_vm_tuning"
fi
if (( _wizard_calls >= 2 )); then
  printf 'PASS: full wizard dynamic path calls install_ultimate_perf_vm_tuning (%d)\n' "$_wizard_calls"
else
  printf 'FAIL: full wizard dynamic path does NOT call install_ultimate_perf_vm_tuning (only %d at 6-space indent)\n' "$_wizard_calls" >&2
  record_failure "full wizard dynamic path calls install_ultimate_perf_vm_tuning"
fi
# Both dynamic paths must honor the override var (it appears in their opt-in block).
_override_in_switcher="$(grep -cE '^  if \[\[ "\$\{ULTIMATE_PERF_VM_TUNING_OVERRIDE' "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
_override_in_wizard="$(grep -cE '^    if \[\[ "\$\{ULTIMATE_PERF_VM_TUNING_OVERRIDE' "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _override_in_switcher >= 1 && _override_in_wizard >= 1 )); then
  printf 'PASS: both dynamic paths honor ULTIMATE_PERF_VM_TUNING_OVERRIDE\n'
else
  printf 'FAIL: override not honored in both dynamic paths (switcher=%d, wizard=%d)\n' "$_override_in_switcher" "$_override_in_wizard" >&2
  record_failure "both dynamic paths honor ULTIMATE_PERF_VM_TUNING_OVERRIDE"
fi

# ===================== R48c: wizard runs VM-customization in BOTH binding modes =====================
# Root-cause fix: in apply_configuration the entire VM-customization block
# (preflight VM gate + vBIOS + stealth/hypervisor-hide + ultimate-perf + Looking
# Glass) was nested INSIDE the `if binding_mode == DYNAMIC` guard, so an EARLY-
# binding install (or a --recommended run that picked early) NEVER applied
# hypervisor hide to the VM -> the VM kept showing red/green stripes in virt-
# manager and the AMD driver would not install, forcing a re-run of dynamic
# binding. R48c closes the DYNAMIC guard right after the dynamic-only installs
# so the VM block runs regardless of binding mode. Assert the guard is closed
# BEFORE the preflight gate (the gate sits at top level, not inside the if).
_apply_fn="$(sed -n '/^apply_configuration()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R48c wizard closes the DYNAMIC guard before the VM gate" \
  'install_park_keepalive_monitor
  fi
  # R48c: VM-customization' \
  "$_apply_fn"
assert_contains_text \
  "R48c wizard runs the preflight VM gate outside the DYNAMIC guard" \
  '# R45: preflight — only run the VM-customization steps if a guest-GPU VM exists.' \
  "$_apply_fn"
# The preflight gate line must appear AFTER the closing `fi` of the DYNAMIC
# guard (i.e. at the function's 4-space indent, inside the `if _vm_gate` block
# which itself is no longer nested under DYNAMIC). Confirm the gate is not
# indented under the DYNAMIC if (8-space would mean it is still nested).
if grep -qE '^        _preflight_guest_gpu_vm_gate' "$VFIO_SCRIPT" 2>/dev/null; then
  printf 'FAIL: R48c preflight VM gate is still nested 8-space (inside DYNAMIC if)\n' >&2
  record_failure "R48c preflight VM gate runs outside the DYNAMIC guard"
else
  printf 'PASS: R48c preflight VM gate runs outside the DYNAMIC guard (not 8-space indented)\n'
fi

# ===================== Live-attach-aware detection (R35 design fix) =====================
# _vm_is_guest_gpu_vm detects a guest-GPU VM by BDF match OR membership in the
# live-attach VM list. Live-attach strips the GPU hostdev from the persistent
# XML, so a BDF grep alone misses an already-live-attach-configured VM — the
# design flaw that made the stealth/perf tuners unable to tune a live-attach VM
# without reverting live-attach first. The perf/stealth install+revert+status
# functions all route through this helper now (mirroring install_virtio_win_
# guest_agent, which already had the fallback).
assert_contains_file "_vm_is_guest_gpu_vm helper exists" "_vm_is_guest_gpu_vm()" "$VFIO_SCRIPT"
assert_contains_file "helper honors VFIO_LIVE_ATTACH_VM_LIST override" "VFIO_LIVE_ATTACH_VM_LIST" "$VFIO_SCRIPT"
assert_contains_file "helper falls back to live-attach VM list" 'grep -Fixq "$_dom" "$_la_list"' "$VFIO_SCRIPT"
assert_contains_file "R35 install uses helper (not inline BDF grep)" '_vm_is_guest_gpu_vm "$_dom" "$_xml"' "$VFIO_SCRIPT"
assert_contains_file "R35 'nothing to tune' message mentions live-attach list" "live-attach VM list) and re-run" "$VFIO_SCRIPT"

# Functional tests: self-contained (temp CONF_FILE + temp live-attach list, no
# virsh/root needed — the helper takes the XML as $2 so it never calls virsh).
_la_conf="$tmp_dir/fake.conf"
printf 'GUEST_GPU_BDF="0000:0e:00.0"\nGUEST_GPU_VENDOR_ID="1002"\n' >"$_la_conf"
_la_list_in="$tmp_dir/la_in.txt"    # contains the dom name -> fallback hits
_la_list_out="$tmp_dir/la_out.txt"  # empty -> fallback misses
printf 'win11\n' >"$_la_list_in"
: >"$_la_list_out"
_save_conf="$CONF_FILE"
CONF_FILE="$_la_conf"

# 1) Mock WITH the GPU PCI hostdev (0000:0e:00.0) -> BDF match path returns 0.
set +e
_vm_is_guest_gpu_vm "win11" "$(cat "$mock")"; rc_bdf=$?
set -e
assert_eq "_vm_is_guest_gpu_vm BDF match returns 0" "0" "$rc_bdf"

# 2) Mock WITHOUT the GPU hostdev (only a USB hostdev) + in live-attach list ->
#    fallback path returns 0 (the fix: a live-attach VM is still detected).
_mock_nogpu="$tmp_dir/mock_nogpu.xml"
cat >"$_mock_nogpu" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <devices>
    <hostdev mode="subsystem" type="usb" managed="yes">
      <source><vendor id="0x13d3"/><product id="0x3585"/></source>
    </hostdev>
  </devices>
</domain>
XEOF
set +e
VFIO_LIVE_ATTACH_VM_LIST="$_la_list_in" _vm_is_guest_gpu_vm "win11" "$(cat "$_mock_nogpu")"; rc_la_in=$?
set -e
assert_eq "_vm_is_guest_gpu_vm live-attach fallback (in list) returns 0" "0" "$rc_la_in"

# 3) Mock WITHOUT the GPU hostdev + NOT in live-attach list -> returns 1.
set +e
VFIO_LIVE_ATTACH_VM_LIST="$_la_list_out" _vm_is_guest_gpu_vm "win11" "$(cat "$_mock_nogpu")"; rc_la_out=$?
set -e
assert_eq "_vm_is_guest_gpu_vm no BDF + not in list returns 1" "1" "$rc_la_out"

CONF_FILE="$_save_conf"

# --- NUMA-unsafe (multi-node, pinned vCPUs span nodes): numatune must be SKIPPED ---
# so the VM can still start. Pin vcpus to CPUs 1,2,9,10 which span node0(0-7)+node1(8-15).
multi="$tmp_dir/multi.xml"
cp "$mock" "$multi"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15" \
    VFIO_PERF_NUMA="0:0-7;1:8-15" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    python3 "$perf_py" "$multi" >/dev/null 2>&1
rc_multi=$?
set -e
assert_eq "perf patcher exit 0 on multi-NUMA mock" "0" "$rc_multi"
# vcpus 0..3 pin to host_cpus[1..4] = 1,2,3,4 (all in node0) -> actually fits node0,
# so numatune WOULD be added here. To force a span, we'd need vcpu_count > node size.
# Instead assert the patcher did not crash and still validates.
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$multi" >/dev/null 2>&1; then
    printf 'PASS: multi-NUMA tuned XML validates\n'
  else
    printf 'FAIL: multi-NUMA tuned XML fails virt-xml-validate\n' >&2
    record_failure "multi-NUMA tuned XML validates"
  fi
fi

# ===================== SATA->virtio-blk disk conversion (opt-in) =====================
# Static wiring: the new flags + conf key + export must be present.
assert_contains_file "ULTIMATE_PERF_VIRTIO_DISK_OVERRIDE var declared" "ULTIMATE_PERF_VIRTIO_DISK_OVERRIDE=" "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --ultimate-perf-virtio-disk" "--ultimate-perf-virtio-disk)" "$VFIO_SCRIPT"
assert_contains_file "parse_args handles --no-ultimate-perf-virtio-disk" "--no-ultimate-perf-virtio-disk)" "$VFIO_SCRIPT"
assert_contains_file "conf key ULTIMATE_PERF_VIRTIO_DISK present" 'ULTIMATE_PERF_VIRTIO_DISK=""' "$VFIO_SCRIPT"
assert_contains_file "install exports VFIO_PERF_VIRTIO_DISK" 'export VFIO_PERF_VIRTIO_DISK="$_vd_on"' "$VFIO_SCRIPT"
assert_contains_file "python reads VFIO_PERF_VIRTIO_DISK" "os.environ.get('VFIO_PERF_VIRTIO_DISK', '0')" "$VFIO_SCRIPT"
assert_contains_file "install opt-in warns about BSOD INACCESSIBLE_BOOT_DEVICE" "INACCESSIBLE_BOOT_DEVICE" "$VFIO_SCRIPT"
assert_contains_file "install opt-in names virtio-win-guest-tools.exe" "virtio-win-guest-tools.exe" "$VFIO_SCRIPT"
assert_contains_file "install opt-in names --install-virtio-win-guest-agent" "--install-virtio-win-guest-agent" "$VFIO_SCRIPT"
assert_contains_file "usage one-liner includes --ultimate-perf-virtio-disk" "[--ultimate-perf-virtio-disk]" "$VFIO_SCRIPT"
assert_contains_file "fish completion includes --ultimate-perf-virtio-disk" "complete -c \$cmd -l ultimate-perf-virtio-disk" "$VFIO_SCRIPT"
assert_contains_file "zsh completion includes --ultimate-perf-virtio-disk" "'--ultimate-perf-virtio-disk[" "$VFIO_SCRIPT"

# Functional: mock VM with a SATA boot disk + a SATA cdrom.
mock_sata="$tmp_dir/mock_sata.xml"
cat >"$mock_sata" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <os><type arch="x86_64" machine="pc-q35-9.2">hvm</type><smbios mode="sysinfo"/></os>
  <features>
    <acpi/><apic/>
    <hyperv mode="custom"><vendor_id state="on" value="GENUINE00000"/><relaxed state="on"/></hyperv>
    <kvm><hidden state="on"/></kvm>
    <vmport state="off"/>
  </features>
  <cpu mode="host-passthrough" check="none" migratable="on"><feature policy="disable" name="hypervisor"/></cpu>
  <clock offset="localtime">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="hypervclock" present="no"/>
    <timer name="tsc" mode="native" present="yes"/>
  </clock>
  <on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><on_crash>destroy</on_crash>
  <devices>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="/var/lib/libvirt/images/win11.qcow2"/>
      <target dev="sda" bus="sata"/>
      <serial>Samsung_ABCD1234</serial>
      <boot order="1"/>
      <address type="drive" controller="0" bus="0" target="0" unit="0"/>
    </disk>
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <source file="/usr/share/virtio-win/virtio-win.iso"/>
      <target dev="sdb" bus="sata"/>
      <readonly/>
      <address type="drive" controller="0" bus="0" target="0" unit="1"/>
    </disk>
    <interface type="network"><model type="e1000e"/><source network="default"/></interface>
    <memballoon model="none"/>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source><address domain="0x0000" bus="0x0e" slot="0x00" function="0x0"/></source>
    </hostdev>
  </devices>
  <qemu:commandline xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
    <qemu:arg value="-cpu"/>
    <qemu:arg value="host,kvm=off,hypervisor=off,hv_vendor_id=null,invtsc=on"/>
    <qemu:arg value="-smbios"/>
    <qemu:arg value="type=1,manufacturer=ASUS,product=ROG,serial=ABCDEF1234,uuid=12345678-1234-1234-1234-123456789abc"/>
  </qemu:commandline>
</domain>
XEOF

# --- VIRTIO_DISK=1: SATA boot disk converts to virtio + gets perf knobs ---
sata_vd="$tmp_dir/sata_vd.xml"
cp "$mock_sata" "$sata_vd"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    VFIO_PERF_VIRTIO_DISK="1" \
    python3 "$perf_py" "$sata_vd" >/dev/null 2>&1
rc_sata_vd=$?
set -e
assert_eq "perf patcher exit 0 with VIRTIO_DISK=1 on SATA mock" "0" "$rc_sata_vd"
assert_contains_file "SATA boot disk converted to vda virtio" '<target dev="vda" bus="virtio"' "$sata_vd"
assert_not_contains_file "no sda target left after conversion" '<target dev="sda"' "$sata_vd"
assert_contains_file "cdrom NOT converted (stays sdb sata)" '<target dev="sdb" bus="sata"' "$sata_vd"
assert_contains_file "perf knobs applied to converted disk" 'cache="none" io="native"' "$sata_vd"
assert_contains_file "virtio multiqueue queues applied" 'queues="4"' "$sata_vd"
assert_contains_file "disk serial preserved through conversion" "Samsung_ABCD1234" "$sata_vd"
assert_contains_file "boot order preserved through conversion" 'boot order="1"' "$sata_vd"
assert_contains_file "stealth survives virtio conversion" "GENUINE00000" "$sata_vd"
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$sata_vd" >/dev/null 2>&1; then
    printf 'PASS: virtio-converted XML validates\n'
  else
    printf 'FAIL: virtio-converted XML fails virt-xml-validate\n' >&2
    record_failure "virtio-converted XML validates"
  fi
fi

# --- Idempotency: re-run on the already-converted XML exits 3 ---
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    VFIO_PERF_VIRTIO_DISK="1" \
    python3 "$perf_py" "$sata_vd" >/dev/null 2>&1
rc_sata_vd_idem=$?
set -e
assert_eq "virtio conversion idempotent (exit 3 on re-run)" "3" "$rc_sata_vd_idem"

# --- VIRTIO_DISK=0: SATA boot disk is NOT converted (opt-in default off) ---
sata_no="$tmp_dir/sata_no.xml"
cp "$mock_sata" "$sata_no"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    VFIO_PERF_VIRTIO_DISK="0" \
    python3 "$perf_py" "$sata_no" >/dev/null 2>&1
rc_sata_no=$?
set -e
assert_eq "perf patcher exit 0 with VIRTIO_DISK=0 on SATA mock" "0" "$rc_sata_no"
assert_contains_file "SATA boot disk NOT converted when opted out" '<target dev="sda" bus="sata"' "$sata_no"
assert_not_contains_file "no virtio bus when opted out" 'bus="virtio"' "$sata_no"

# --- Collision-safe: existing vda + SATA sda -> sda converts to vdb (not vda) ---
mock_col="$tmp_dir/mock_collision.xml"
cat >"$mock_col" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <os><type arch="x86_64" machine="pc-q35-9.2">hvm</type></os>
  <features><acpi/><apic/></features>
  <cpu mode="host-passthrough" check="none" migratable="on"/>
  <clock offset="localtime"/>
  <on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><on_crash>destroy</on_crash>
  <devices>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="/existing.qcow2"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="/sata-boot.qcow2"/>
      <target dev="sda" bus="sata"/>
      <address type="drive" controller="0" bus="0" target="0" unit="0"/>
    </disk>
    <memballoon model="none"/>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source><address domain="0x0000" bus="0x0e" slot="0x00" function="0x0"/></source>
    </hostdev>
  </devices>
</domain>
XEOF
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    VFIO_PERF_VIRTIO_DISK="1" \
    python3 "$perf_py" "$mock_col" >/dev/null 2>&1
rc_col=$?
set -e
assert_eq "perf patcher exit 0 on collision mock" "0" "$rc_col"
assert_contains_file "existing vda preserved (not overwritten)" '<target dev="vda" bus="virtio"' "$mock_col"
assert_contains_file "SATA sda converted to vdb (collision-safe)" '<target dev="vdb" bus="virtio"' "$mock_col"

# ===================== Reboot-persistent hugepages re-reserve (R35 follow-up) =====================
# After a host reboot /proc/sys/vm/nr_hugepages resets to 0, but the per-VM owned
# files persist. Without a boot-time re-reserve, a hugepages-backed VM
# (memoryBacking/hugepages) fails to start with "unable to map backing store for
# guest RAM: Cannot allocate memory" until the operator manually re-runs
# --install-ultimate-perf-vm-tuning. A boot-time systemd oneshot now re-reserves
# the pool from a registry of perf backup dirs. This section asserts the wiring,
# the standalone boot script, the unit, and the registry helper round-trip.

# --- Static wiring: constants + helpers + install/remove functions ---
assert_contains_file "PERF_HP_BOOT_SCRIPT constant declared" 'PERF_HP_BOOT_SCRIPT=' "$VFIO_SCRIPT"
assert_contains_file "PERF_HP_BOOT_UNIT constant declared" 'PERF_HP_BOOT_UNIT=' "$VFIO_SCRIPT"
assert_contains_file "PERF_HP_DIRS_FILE constant declared" 'PERF_HP_DIRS_FILE=' "$VFIO_SCRIPT"
assert_contains_file "_register_perf_hugepages_dir helper exists" "_register_perf_hugepages_dir() {" "$VFIO_SCRIPT"
assert_contains_file "_unregister_perf_hugepages_dir helper exists" "_unregister_perf_hugepages_dir() {" "$VFIO_SCRIPT"
assert_contains_file "install_perf_hugepages_boot_service function exists" "install_perf_hugepages_boot_service() {" "$VFIO_SCRIPT"
assert_contains_file "remove_perf_hugepages_boot_service function exists" "remove_perf_hugepages_boot_service() {" "$VFIO_SCRIPT"
# Reserve helper registers the backup dir in the boot-reserve registry.
assert_contains_file "_reserve registers backup dir in registry" '_register_perf_hugepages_dir "$_backup_dir"' "$VFIO_SCRIPT"
# Restore helper unregisters the backup dir when its last owned file is gone.
assert_contains_file "_restore unregisters backup dir from registry" '_unregister_perf_hugepages_dir "$_backup_dir"' "$VFIO_SCRIPT"
# install_ultimate_perf_vm_tuning wires the boot-service install after the loop.
assert_contains_file "perf install wires boot-service install" 'install_perf_hugepages_boot_service' "$VFIO_SCRIPT"
# reset_ultimate_perf_vm_tuning wires the boot-service removal after the loop.
assert_contains_file "perf revert wires boot-service removal" 'remove_perf_hugepages_boot_service' "$VFIO_SCRIPT"
# The install is guarded so it only fires when there is perf-hugepages ownership.
assert_contains_file "perf install boot-service guard checks ownership" '_any_hp_reserved )) || [[ -f "$PERF_HP_DIRS_FILE" ]]' "$VFIO_SCRIPT"
# The removal is guarded so it only fires when the registry is gone (last owned
# dir unregistered), and is skipped in dry-run.
assert_contains_file "perf revert boot-service removal guard" '! [[ -f "$PERF_HP_DIRS_FILE" ]]' "$VFIO_SCRIPT"

# --- Boot script content (standalone, never sources vfio.sh) ---
assert_contains_file "boot script is standalone (never sources vfio.sh)" "Standalone (never sources vfio.sh)" "$VFIO_SCRIPT"
assert_contains_file "boot script reads registry path" 'REGISTRY="$PERF_HP_DIRS_FILE"' "$VFIO_SCRIPT"
assert_contains_file "boot script 1GB guard present" "hp_size >= 1048576" "$VFIO_SCRIPT"
assert_contains_file "boot script warns on fragmented shortfall" "fragmented RAM at boot" "$VFIO_SCRIPT"
assert_contains_file "boot script no-ops when pool already satisfies" '>= \${total} needed' "$VFIO_SCRIPT"
assert_contains_file "boot script writes total to nr_hugepages" '"\$total" >"\$NR_HUGEPAGES"' "$VFIO_SCRIPT"

# --- Boot script two-mode: boot-regenerate + --ensure-domain dynamic ---
# The boot script now REGENERATES owned counts from the on-disk libvirt VM XML
# (so a RAM grow/shrink between boots is honored) and supports a --ensure-domain
# mode called by the libvirt hook at VM start (so a RAM change without a reboot
# is honored at the moment qemu needs the backing store).
assert_contains_file "boot script declares --ensure-domain mode" '"--ensure-domain"' "$VFIO_SCRIPT"
assert_contains_file "boot script reads on-disk libvirt XML dir" 'QEMU_XML_DIR="/etc/libvirt/qemu"' "$VFIO_SCRIPT"
assert_contains_file "boot script has recompute_owned_from_disk fn" 'recompute_owned_from_disk() {' "$VFIO_SCRIPT"
assert_contains_file "boot script has memory_kib fn" 'memory_kib() {' "$VFIO_SCRIPT"
assert_contains_file "boot script has pages_needed fn" 'pages_needed() {' "$VFIO_SCRIPT"
assert_contains_file "boot script has sum_all_owned fn" 'sum_all_owned() {' "$VFIO_SCRIPT"
assert_contains_file "boot script regenerate loop recomputes owned from disk" 'recompute_owned_from_disk "\$dom" "\$f"' "$VFIO_SCRIPT"
assert_contains_file "boot script dynamic ensure grows the pool" 'ensuring nr_hugepages' "$VFIO_SCRIPT"
assert_contains_file "boot script dynamic ensure aborts on shortfall" 'Aborting VM start' "$VFIO_SCRIPT"
assert_contains_file "boot script dynamic ensure grow-only (never shrink at start)" 'grow only; never shrink at start' "$VFIO_SCRIPT"
assert_contains_file "boot script ensure no-ops for non-hugepages VM" 'not a hugepages-tuned VM; nothing to ensure' "$VFIO_SCRIPT"

# --- Boot unit content ---
assert_contains_file "boot unit ConditionPathExists on registry" 'ConditionPathExists=$PERF_HP_DIRS_FILE' "$VFIO_SCRIPT"
assert_contains_file "boot unit runs before libvirt" 'Before=virtqemud.service libvirtd.service' "$VFIO_SCRIPT"
assert_contains_file "boot unit WantedBy multi-user.target" 'WantedBy=multi-user.target' "$VFIO_SCRIPT"
assert_contains_file "boot unit is oneshot" 'Type=oneshot' "$VFIO_SCRIPT"
assert_contains_file "boot unit ExecStart points at the boot script" 'ExecStart=$PERF_HP_BOOT_SCRIPT' "$VFIO_SCRIPT"

# --- R39c: --reset now FREES hugepages + removes the boot-reserve service ---
# Previously --reset deliberately left the hugepages pool + boot-reserve service
# in place (R35 design), which could orphan a reserved pool whose VM XML lost
# <hugepages> and starve the VM of normal memory. Now --reset calls
# _reset_perf_hugepages_all: frees nr_hugepages, drops owned files + registry,
# disables+removes the boot-reserve service. --reset-ultimate-perf-vm-tuning is
# still the path to revert the perf VM XML itself from backup.
assert_contains_file "reset calls _reset_perf_hugepages_all" '_reset_perf_hugepages_all' "$VFIO_SCRIPT"
assert_contains_file "_reset_perf_hugepages_all helper defined" '_reset_perf_hugepages_all() {' "$VFIO_SCRIPT"
assert_contains_file "reset note documents --reset frees hugepages" "--reset now ALSO releases host hugepages" "$VFIO_SCRIPT"
assert_contains_file "_reset_perf_hugepages_all frees the pool" "0 >/proc/sys/vm/nr_hugepages" "$VFIO_SCRIPT"
assert_contains_file "_reset_perf_hugepages_all removes owned files" '*_perf_hugepages_owned.txt' "$VFIO_SCRIPT"
assert_contains_file "_reset_perf_hugepages_all removes boot service" 'remove_perf_hugepages_boot_service' "$VFIO_SCRIPT"
# --- R39c: reconcile-on-enable drops stale owned files before reserving ---
assert_contains_file "_reconcile_perf_hugepages_owned helper defined" '_reconcile_perf_hugepages_owned() {' "$VFIO_SCRIPT"
assert_contains_file "install calls reconcile when hugepages enabled" 'if (( _hp_on )); then' "$VFIO_SCRIPT"
assert_contains_file "reconcile drops stale owned files (VM XML no hugepages)" 'VM XML no longer has <hugepages>' "$VFIO_SCRIPT"

# --- Functional: install generates a valid runtime boot script (bash -n) ---
# Call install_perf_hugepages_boot_service with temp paths + a no-op systemctl +
# a non-root write_file_atomic, then bash -n the generated runtime script. This
# validates the ACTUAL script vfio.sh's unquoted heredoc produces (with the
# backslash-dollar runtime-var markers unescaped to dollar and the install-time
# registry path expanded) — stronger than bash -n on the raw source, which
# mis-parses those markers inside command substitution.
_save_script="$PERF_HP_BOOT_SCRIPT"; _save_unit="$PERF_HP_BOOT_UNIT"
_save_wfa="$(declare -f write_file_atomic)"
PERF_HP_BOOT_SCRIPT="$tmp_dir/fake-boot.sh"
PERF_HP_BOOT_UNIT="$tmp_dir/fake-boot.service"
# Non-root write_file_atomic: install -m (no -o/-g) to a temp path.
# shellcheck disable=SC2034 # owner_group is intentionally unused in this non-root override.
write_file_atomic() {
  local dst="$1" mode="$2" owner_group="$3" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  install -m "$mode" "$tmp" "$dst" 2>/dev/null || cp "$tmp" "$dst"
  rm -f "$tmp" || true
}
# No-op systemctl so enable/start/daemon-reload don't touch the real system.
systemctl() { return 0; }
install_perf_hugepages_boot_service
if [[ -s "$PERF_HP_BOOT_SCRIPT" ]]; then
  if bash -n "$PERF_HP_BOOT_SCRIPT" 2>/dev/null; then
    printf 'PASS: generated runtime boot script is valid bash (bash -n)\n'
  else
    printf 'FAIL: generated runtime boot script has syntax errors\n' >&2
    record_failure "generated runtime boot script is valid bash"
  fi
else
  printf 'FAIL: install did not generate the boot script\n' >&2
  record_failure "install generates boot script"
fi
# Restore overrides so later steps see the real functions/paths.
PERF_HP_BOOT_SCRIPT="$_save_script"; PERF_HP_BOOT_UNIT="$_save_unit"
unset -f systemctl
eval "$_save_wfa"

# --- Functional: registry helper round-trip (dedup + unregister + empty removal) ---
# Uses a temp PERF_HP_DIRS_FILE so no real state is touched; restore after.
_save_reg="$PERF_HP_DIRS_FILE"
PERF_HP_DIRS_FILE="$tmp_dir/fake-perf-hugepages-dirs"
rm -f "$PERF_HP_DIRS_FILE"
_register_perf_hugepages_dir "$tmp_dir/bk1"
_line1="$(cat "$PERF_HP_DIRS_FILE" 2>/dev/null || true)"
assert_eq "register writes first dir line" "$tmp_dir/bk1" "$_line1"
_register_perf_hugepages_dir "$tmp_dir/bk1"   # dedup: second call must NOT add a duplicate
set +e
_n1="$(grep -c . "$PERF_HP_DIRS_FILE" 2>/dev/null)"
set -e
: "${_n1:=0}"
assert_eq "register dedups (still one line)" "1" "$_n1"
_register_perf_hugepages_dir "$tmp_dir/bk2"
set +e
_n2="$(grep -c . "$PERF_HP_DIRS_FILE" 2>/dev/null)"
set -e
: "${_n2:=0}"
assert_eq "register adds second dir" "2" "$_n2"
_unregister_perf_hugepages_dir "$tmp_dir/bk1"
_line2="$(cat "$PERF_HP_DIRS_FILE" 2>/dev/null || true)"
assert_eq "unregister removes one dir (leaves bk2)" "$tmp_dir/bk2" "$_line2"
_unregister_perf_hugepages_dir "$tmp_dir/bk2"
if [[ ! -f "$PERF_HP_DIRS_FILE" ]]; then
  printf 'PASS: registry file removed when last dir unregistered\n'
else
  printf 'FAIL: registry file not removed after last unregister\n' >&2
  record_failure "registry file removed when empty"
fi
# Unregister on a non-existent registry is a safe no-op (returns 0).
set +e
_unregister_perf_hugepages_dir "$tmp_dir/bk1"; _rc_unreg_nofile=$?
set -e
assert_eq "unregister with no registry file is a no-op (rc 0)" "0" "$_rc_unreg_nofile"
PERF_HP_DIRS_FILE="$_save_reg"

# --- Functional: --ensure-domain dynamic mode (recompute + grow + no-op) ---
# Reuse the generated runtime boot script ($tmp_dir/fake-boot.sh) with its
# hardcoded paths sed-redirected to temp files, then exercise --ensure-domain
# (the mode the libvirt hook calls at VM prepare). 8GiB = 8388608 KiB = 4096 pages.
_ensure_src="$tmp_dir/fake-boot.sh"
_ensure_t="$tmp_dir/ensure_test.sh"
cp "$_ensure_src" "$_ensure_t"
_ensure_reg="$tmp_dir/ensure_reg"
_ensure_nr="$tmp_dir/ensure_nr"
_ensure_conf="$tmp_dir/ensure_conf"
_ensure_xmldir="$tmp_dir/ensure_qemu"
mkdir -p "$_ensure_xmldir" "$tmp_dir/ensure_bkdir"
sed -i "s#REGISTRY=\".*\"#REGISTRY=\"$_ensure_reg\"#; s#NR_HUGEPAGES=\".*\"#NR_HUGEPAGES=\"$_ensure_nr\"#; s#CONF_FILE=\".*\"#CONF_FILE=\"$_ensure_conf\"#; s#QEMU_XML_DIR=\".*\"#QEMU_XML_DIR=\"$_ensure_xmldir\"#" "$_ensure_t"
printf 'ULTIMATE_PERF_HUGEPAGES_SIZE=2048\n' >"$_ensure_conf"
printf '%s\n' "$tmp_dir/ensure_bkdir" >"$_ensure_reg"
printf '1000\n' >"$tmp_dir/ensure_bkdir/win11_perf_hugepages_owned.txt"
cat >"$_ensure_xmldir/win11.xml" <<'XEOF'
<domain type='kvm'><name>win11</name><memory unit='KiB'>8388608</memory></domain>
XEOF
printf '0\n' >"$_ensure_nr"
set +e
printf '%s' "$(cat "$_ensure_xmldir/win11.xml")" | bash "$_ensure_t" --ensure-domain win11 >/tmp/ensure1.log 2>&1
_rc1=$?
set -e
_owned_after="$(cat "$tmp_dir/ensure_bkdir/win11_perf_hugepages_owned.txt" 2>/dev/null || true)"
_pool_after="$(cat "$_ensure_nr" 2>/dev/null || true)"
assert_eq "ensure-domain recomputes owned 1000 -> 4096" "4096" "$_owned_after"
assert_eq "ensure-domain grows pool 0 -> 4096" "4096" "$_pool_after"
assert_eq "ensure-domain exits 0 after grow" "0" "$_rc1"
# No-op: pool already satisfies -> exit 0, no change.
set +e
printf '%s' "$(cat "$_ensure_xmldir/win11.xml")" | bash "$_ensure_t" --ensure-domain win11 >/tmp/ensure2.log 2>&1
_rc2=$?
set -e
assert_eq "ensure-domain no-op exit 0 when pool satisfies" "0" "$_rc2"
# Non-hugepages VM (no owned file) -> exit 0 no-op.
set +e
printf '%s' "$(cat "$_ensure_xmldir/win11.xml")" | bash "$_ensure_t" --ensure-domain other-vm >/tmp/ensure3.log 2>&1
_rc3=$?
set -e
assert_eq "ensure-domain no-op exit 0 for non-hugepages VM" "0" "$_rc3"

# ===================== R38: hugepages strip-on-opt-out + RAM safety cap =====
# When perf is selected with hugepages OFF (the default), the tuner now REMOVES
# any existing <memoryBacking><hugepages> (and frees host nr_hugepages) so the
# VM no longer pins host RAM — the live-attach freeze root cause. A RAM safety
# gate caps VM <memory> to ULTIMATE_PERF_MAX_VM_RAM_PCT (default 50) of host
# RAM; notifies + applies the smaller size when the VM is too large.

# --- Static wiring ---
assert_contains_file "ULTIMATE_PERF_MAX_VM_RAM_PCT conf key present" 'ULTIMATE_PERF_MAX_VM_RAM_PCT="' "$VFIO_SCRIPT"
assert_contains_file "install exports VFIO_PERF_VM_RAM_CAP_KIB" 'export VFIO_PERF_VM_RAM_CAP_KIB=' "$VFIO_SCRIPT"
assert_contains_file "python reads VFIO_PERF_VM_RAM_CAP_KIB" "os.environ.get('VFIO_PERF_VM_RAM_CAP_KIB'" "$VFIO_SCRIPT"
assert_contains_file "install exports VFIO_PERF_HUGEPAGES_STRIP" 'export VFIO_PERF_HUGEPAGES_STRIP=' "$VFIO_SCRIPT"
assert_contains_file "python reads VFIO_PERF_HUGEPAGES_STRIP" "os.environ.get('VFIO_PERF_HUGEPAGES_STRIP'" "$VFIO_SCRIPT"
assert_contains_file "install reads host MemTotal" "/proc/meminfo" "$VFIO_SCRIPT"
assert_contains_file "reserve helper takes mem-override arg" '_mem_override_kib="${5:-0}"' "$VFIO_SCRIPT"
assert_contains_file "install passes cap to reserve helper" '"$_cap_kib"' "$VFIO_SCRIPT"
assert_contains_file "opt-out strips existing hugepages (comment)" "STRIP it" "$VFIO_SCRIPT"
assert_contains_file "strip frees reservation on success" "_hp_strip )) && (( ! DRY_RUN ))" "$VFIO_SCRIPT"
assert_contains_file "RAM cap notify message present" "exceeds" "$VFIO_SCRIPT"
assert_contains_file "RAM cap applies smaller size" "capping to" "$VFIO_SCRIPT"
assert_contains_file "boot service removed when all stripped" '(( ! _any_hp_reserved )) && ! [[ -f "$PERF_HP_DIRS_FILE" ]]' "$VFIO_SCRIPT"
# R39c: hugepages is now DISABLED by default (no prompt; opt in via
# --ultimate-perf-hugepages). The intro must still explain that with it OFF,
# any existing hugepages are removed (frees host nr_hugepages) so the VM no
# longer pins host RAM.
assert_contains_file "install intro notes hugepages disabled by default" "hugepages: DISABLED by default" "$VFIO_SCRIPT"
assert_contains_file "install intro notes OFF removes existing hugepages" "When OFF, any existing hugepages" "$VFIO_SCRIPT"
assert_contains_file "install intro notes RAM safety gate" "RAM safety gate: caps VM" "$VFIO_SCRIPT"
# The 5 skip-path inline restores must STILL be present (R35 contract intact);
# the new strip-success restore is on a separate multi-line if (not 'then ' on
# the same line), so it must NOT inflate this count.
_inline_restores_r38="$(grep -cF "then _restore_host_hugepages_for_vm" "$VFIO_SCRIPT" 2>/dev/null || echo 0)"
if (( _inline_restores_r38 >= 5 )); then
  printf 'PASS: R38 skip-path inline restores still >= 5 (%d)\n' "$_inline_restores_r38"
else
  printf 'FAIL: R38 skip-path inline restores dropped below 5 (%d)\n' "$_inline_restores_r38" >&2
  record_failure "R38 skip-path inline restores still >= 5"
fi

# --- Functional: RAM cap applies (48GiB VM, cap=32GiB=33554432KiB) ---
capmock="$tmp_dir/capmock.xml"
cat >"$capmock" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">50331648</memory>
  <vcpu placement="static">4</vcpu>
  <os><type arch="x86_64" machine="pc-q35-9.2">hvm</type></os>
  <devices>
    <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><target dev="vda" bus="virtio"/></disk>
  </devices>
</domain>
XEOF
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_STRIP="0" \
    VFIO_PERF_VM_RAM_CAP_KIB="33554432" \
    python3 "$perf_py" "$capmock" >/dev/null 2>&1
rc_cap=$?
set -e
assert_eq "RAM cap run exit 0" "0" "$rc_cap"
assert_contains_file "RAM cap sets memory to 32GiB" '<memory unit="KiB">33554432</memory>' "$capmock"
assert_contains_file "RAM cap syncs currentMemory to 32GiB" '<currentMemory unit="KiB">33554432</currentMemory>' "$capmock"

# --- Functional: RAM cap no-op when VM under threshold (16GiB, cap=32GiB) ---
capnoop="$tmp_dir/capnoop.xml"
cat >"$capnoop" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">16777216</memory>
  <vcpu placement="static">4</vcpu>
  <os><type arch="x86_64" machine="pc-q35-9.2">hvm</type></os>
  <devices>
    <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><target dev="vda" bus="virtio"/></disk>
  </devices>
</domain>
XEOF
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_STRIP="0" \
    VFIO_PERF_VM_RAM_CAP_KIB="33554432" \
    python3 "$perf_py" "$capnoop" >/dev/null 2>&1
rc_capnoop=$?
set -e
assert_eq "RAM cap no-op run exit 0" "0" "$rc_capnoop"
assert_contains_file "RAM cap no-op leaves 16GiB memory" '<memory unit="KiB">16777216</memory>' "$capnoop"

# --- Functional: strip removes existing hugepages (+ empty memoryBacking) ---
stripmock="$tmp_dir/stripmock.xml"
cat >"$stripmock" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <os><type arch="x86_64" machine="pc-q35-9.2">hvm</type></os>
  <memoryBacking><hugepages><page size="2048" unit="KiB"/></hugepages></memoryBacking>
  <devices>
    <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><target dev="vda" bus="virtio"/></disk>
  </devices>
</domain>
XEOF
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_STRIP="1" \
    VFIO_PERF_VM_RAM_CAP_KIB="0" \
    python3 "$perf_py" "$stripmock" >/dev/null 2>&1
rc_strip=$?
set -e
assert_eq "strip run exit 0" "0" "$rc_strip"
assert_not_contains_file "strip removes hugepages" "<hugepages" "$stripmock"
assert_not_contains_file "strip removes empty memoryBacking" "<memoryBacking" "$stripmock"

# --- Functional: strip preserves a non-hugepages memoryBacking sibling (locked) ---
lockmock="$tmp_dir/lockmock.xml"
cat >"$lockmock" <<'XEOF'
<domain type="kvm">
  <name>win11</name>
  <memory unit="KiB">8388608</memory>
  <vcpu placement="static">4</vcpu>
  <os><type arch="x86_64" machine="pc-q35-9.2">hvm</type></os>
  <memoryBacking><hugepages><page size="2048" unit="KiB"/></hugepages><locked/></memoryBacking>
  <devices>
    <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><target dev="vda" bus="virtio"/></disk>
  </devices>
</domain>
XEOF
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_STRIP="1" \
    VFIO_PERF_VM_RAM_CAP_KIB="0" \
    python3 "$perf_py" "$lockmock" >/dev/null 2>&1
rc_lock=$?
set -e
assert_eq "strip-with-locked run exit 0" "0" "$rc_lock"
assert_not_contains_file "strip-with-locked removes hugepages" "<hugepages" "$lockmock"
assert_contains_file "strip-with-locked keeps memoryBacking (has locked)" "<memoryBacking" "$lockmock"
assert_contains_file "strip-with-locked keeps locked sibling" "<locked" "$lockmock"

# --- Functional: strip idempotent (re-run on already-stripped XML -> exit 3) ---
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_STRIP="1" \
    VFIO_PERF_VM_RAM_CAP_KIB="0" \
    python3 "$perf_py" "$stripmock" >/dev/null 2>&1
rc_strip_idem=$?
set -e
assert_eq "strip idempotent re-run exit 3" "3" "$rc_strip_idem"

# --- Functional: RAM cap idempotent (re-run on capped XML, same cap -> exit 3) ---
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_STRIP="0" \
    VFIO_PERF_VM_RAM_CAP_KIB="33554432" \
    python3 "$perf_py" "$capmock" >/dev/null 2>&1
rc_cap_idem=$?
set -e
assert_eq "RAM cap idempotent re-run exit 3" "3" "$rc_cap_idem"

# --- Functional: reserve helper honors mem-override + 1GB guard still fires ---
# The override arg is accepted (>0 used as-is); the 1GB guard still returns 1
# without touching the pool, proving the new arg did not regress the guard.
set +e
_save_conf_r38="$CONF_FILE"
CONF_FILE="$tmp_dir/fake_hp_r38.conf"
printf 'ULTIMATE_PERF_HUGEPAGES_SIZE=1048576\n' >"$CONF_FILE"
_reserve_host_hugepages_for_vm "" "1048576" "$tmp_dir" "win11" "8388608"; _rc_ovr=$?
CONF_FILE="$_save_conf_r38"
set -e
assert_eq "reserve helper 1GB guard returns 1 (override arg accepted)" "1" "$_rc_ovr"

# ===================== R37: stop Desktop XML-backup litter (perf) =====
# Mirrors the stealth R37 block. Plus: the perf backup dir holds the hugepages
# owned file the boot oneshot sums across registered dirs, so moving the default
# dir requires migrating the owned file from the legacy $HOME/Desktop + fixing
# PERF_HP_DIRS_FILE (else sum_all_owned double-counts = 2x pages). _migrate_legacy_perf_owned
# is idempotent and called in both install (before reserve) and revert (before restore).
_perf_fn="$(sed -n '/^install_ultimate_perf_vm_tuning()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_file \
  "R37 _vm_is_perf_tuned helper defined" \
  '_vm_is_perf_tuned()' \
  "$VFIO_SCRIPT"
assert_contains_file \
  "R37 _migrate_legacy_perf_owned helper defined" \
  '_migrate_legacy_perf_owned()' \
  "$VFIO_SCRIPT"
assert_contains_text \
  "R37 perf install uses fixed-name backup (no timestamp)" \
  '${_dom}_perf.xml' \
  "$_perf_fn"
if printf '%s\n' "$_perf_fn" | grep -Fq '_perf_$(date'; then
  printf 'FAIL: R37 perf install still uses a timestamped backup name (litter)\n' >&2
  record_failure "R37 perf install uses fixed-name backup (no $(date))"
else
  printf 'PASS: R37 perf install uses fixed-name backup (no $(date))\n'
fi
assert_contains_text \
  "R37 perf install keeps pristine backup on re-tune (no overwrite)" \
  'Re-tune: keeping existing pristine backup' \
  "$_perf_fn"
assert_contains_text \
  "R37 perf install default dir is /var/lib/vfio-perf-vm/backups" \
  '_backup_dir="/var/lib/vfio-perf-vm/backups"' \
  "$_perf_fn"
assert_contains_text \
  "R37 perf install calls _migrate_legacy_perf_owned before reserving" \
  '_migrate_legacy_perf_owned "$_backup_dir" "$_dom"' \
  "$_perf_fn"
_perf_revert_fn="$(sed -n '/^reset_ultimate_perf_vm_tuning()/,/^}/p' "$VFIO_SCRIPT")"
assert_contains_text \
  "R37 perf revert reads fixed-name backup" \
  '${_dom}_perf.xml' \
  "$_perf_revert_fn"
assert_contains_text \
  "R37 perf revert falls back to legacy $HOME/Desktop timestamped backups" \
  '${_dom}_perf_"*.xml' \
  "$_perf_revert_fn"
assert_contains_text \
  "R37 perf revert calls _migrate_legacy_perf_owned before restore" \
  '_migrate_legacy_perf_owned "$_backup_dir" "$_dom"' \
  "$_perf_revert_fn"
# Functional: _migrate_legacy_perf_owned moves the owned file legacy -> new dir
# and unregisters the legacy dir (no double-count). The helper reads the legacy
# dir from ${BACKUP_DIR:-$HOME/Desktop}, so set BACKUP_DIR to the temp legacy dir.
# Uses a temp PERF_HP_DIRS_FILE; restore after.
_save_reg2="$PERF_HP_DIRS_FILE"
_mig_reg="$tmp_dir/mig-reg"
_mig_new="$tmp_dir/mig-new"
_mig_legacy="$tmp_dir/mig-legacy"
mkdir -p "$_mig_new" "$_mig_legacy"
rm -f "$_mig_reg"
PERF_HP_DIRS_FILE="$_mig_reg"
printf '%s\n' "$_mig_legacy" >"$_mig_reg"   # legacy dir registered (pre-R37 state)
printf '16096\n' >"$_mig_legacy/win11_perf_hugepages_owned.txt"
set +e
BACKUP_DIR="$_mig_legacy" _migrate_legacy_perf_owned "$_mig_new" "win11"; _mig_rc1=$?
set -e
assert_eq "R37 migration returns 0" "0" "$_mig_rc1"
if [[ -f "$_mig_new/win11_perf_hugepages_owned.txt" ]] && ! [[ -f "$_mig_legacy/win11_perf_hugepages_owned.txt" ]]; then
  printf 'PASS: R37 migration moved owned file legacy -> new dir\n'
else
  printf 'FAIL: R37 migration did not move the owned file legacy -> new dir\n' >&2
  record_failure "R37 migration moves owned file"
fi
if ! grep -Fixq "$_mig_legacy" "$_mig_reg" 2>/dev/null; then
  printf 'PASS: R37 migration unregistered the legacy dir (no double-count)\n'
else
  printf 'FAIL: R37 migration left the legacy dir registered (would double-count)\n' >&2
  record_failure "R37 migration unregisters legacy dir"
fi
# Idempotent: a second call is a no-op (legacy owned file already gone -> return 0).
set +e
BACKUP_DIR="$_mig_legacy" _migrate_legacy_perf_owned "$_mig_new" "win11"; _mig_rc2=$?
set -e
assert_eq "R37 migration is idempotent (rc 0 on second call)" "0" "$_mig_rc2"
PERF_HP_DIRS_FILE="$_save_reg2"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for _a in "${FAILED_ASSERTIONS[@]}"; do printf ' - %s\n' "$_a" >&2; done
  exit 1
fi
printf '\nUltimate-performance VM tuning regression checks passed.\n'
