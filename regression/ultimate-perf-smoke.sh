#!/usr/bin/env bash
# R35 smoke: extract the ultimate-perf python patcher from vfio.sh, run it on a
# mock VM XML (with stealth markers present), validate with virt-xml-validate,
# and confirm stealth survives + the patcher is idempotent. Does NOT need root
# or a real libvirt VM — exercises the core XML-patching logic only (safe code).
# Run: bash regression/ultimate-perf-smoke.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VFIO_SCRIPT="$PROJECT_ROOT/vfio.sh"

fail=0
FAILED_ASSERTIONS=()
ok() { printf 'SMOKE PASS: %s\n' "$1"; }
bad() { printf 'SMOKE FAIL: %s\n' "$1" >&2; FAILED_ASSERTIONS+=("$1"); fail=1; }

if [[ ! -f "$VFIO_SCRIPT" ]]; then
  printf 'FAIL: missing vfio.sh at %s\n' "$VFIO_SCRIPT" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Extract the perf patcher heredoc (first <<'PYEOF' ... PYEOF after the function).
perf_py="$tmp/perf_tuner.py"
awk '
  /install_ultimate_perf_vm_tuning\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$perf_py"

if python3 -m py_compile "$perf_py" 2>/dev/null; then
  ok "perf patcher python compiles"
else
  bad "perf patcher python does not compile"
fi

mock="$tmp/mock.xml"
cat >"$mock" <<'XEOF'
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
      <target dev="vda" bus="virtio"/>
      <serial>Samsung_ABCD1234</serial>
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

tuned="$tmp/tuned.xml"
cp "$mock" "$tuned"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    python3 "$perf_py" "$tuned" >/dev/null 2>&1
rc1=$?
set -e
if [[ "$rc1" -eq 0 ]]; then ok "perf patcher run 1 exit 0"; else bad "perf patcher run 1 exit $rc1"; fi

if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$tuned" >/dev/null 2>&1; then
    ok "tuned XML validates (virt-xml-validate)"
  else
    bad "tuned XML fails virt-xml-validate"
  fi
else
  ok "virt-xml-validate not installed (skipping validate)"
fi

# Stealth survives.
if grep -Fq 'GENUINE00000' "$tuned"; then ok "stealth vendor_id survives"; else bad "stealth vendor_id lost"; fi
if grep -Fq 'kvm=off,hypervisor=off' "$tuned"; then ok "stealth -cpu arg survives"; else bad "stealth -cpu arg lost"; fi
if grep -Fq 'Samsung_ABCD1234' "$tuned"; then ok "stealth disk serial survives"; else bad "stealth disk serial lost"; fi
if grep -Fq 'e1000e' "$tuned"; then ok "stealth e1000e NIC survives"; else bad "stealth e1000e NIC lost"; fi
# Perf added.
if grep -Fq 'cache="none"' "$tuned"; then ok "disk cache=none added"; else bad "disk cache=none missing"; fi
if grep -Fq 'io="native"' "$tuned"; then ok "disk io=native added"; else bad "disk io=native missing"; fi
if grep -Fq '<cputune>' "$tuned"; then ok "cputune added"; else bad "cputune missing"; fi
if grep -Fq '<numatune>' "$tuned"; then ok "numatune added"; else bad "numatune missing"; fi
if grep -Fq 'suspend-to-mem enabled="no"' "$tuned"; then ok "pm S3 disabled"; else bad "pm S3 not disabled"; fi
# No ns0 leak.
if grep -Fq 'ns0:' "$tuned"; then bad "ns0 namespace leak"; else ok "no ns0 namespace leak"; fi

# Idempotency.
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    python3 "$perf_py" "$tuned" >/dev/null 2>&1
rc2=$?
set -e
if [[ "$rc2" -eq 3 ]]; then ok "perf patcher idempotent (exit 3 on re-run)"; else bad "perf patcher not idempotent (exit $rc2 on re-run)"; fi

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for _a in "${FAILED_ASSERTIONS[@]}"; do printf ' - %s\n' "$_a" >&2; done
  exit 1
fi
printf '\nSMOKE SUMMARY: PASS\n'
