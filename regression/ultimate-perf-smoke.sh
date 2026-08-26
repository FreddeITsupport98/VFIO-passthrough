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

# Hugepages ON (R35 follow-up): memoryBacking added with KiB units (2048 KiB =
# 2 MiB = standard 2MB hugepage; libvirt <page> uses KiB, NOT MiB), still
# validates, and stealth survives the hugepages pass.
hp2="$tmp/hp2.xml"
cp "$mock" "$hp2"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="1" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    python3 "$perf_py" "$hp2" >/dev/null 2>&1
rc_hp=$?
set -e
if [[ "$rc_hp" -eq 0 ]]; then ok "perf patcher exit 0 with hugepages on"; else bad "perf patcher exit $rc_hp with hugepages on"; fi
if grep -Fq '<page size="2048" unit="KiB"' "$hp2"; then ok "hugepages page uses KiB units"; else bad "hugepages page not KiB units"; fi
if grep -Fq 'GENUINE00000' "$hp2"; then ok "stealth survives hugepages run"; else bad "stealth lost in hugepages run"; fi
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$hp2" >/dev/null 2>&1; then ok "hugepages-tuned XML validates"; else bad "hugepages-tuned XML fails validate"; fi
fi

# SATA->virtio-blk disk conversion (R35 follow-up, opt-in): a SATA boot disk is
# converted to virtio-blk (sdX->vdX) so the disk perf knobs apply. DANGEROUS in
# real life (Windows needs viostor first or BSOD) — this only tests the XML
# patching logic on a mock. CDROMs are NOT converted.
mock_sata="$tmp/mock_sata.xml"
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
sata_vd="$tmp/sata_vd.xml"
cp "$mock_sata" "$sata_vd"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    VFIO_PERF_VIRTIO_DISK="1" \
    python3 "$perf_py" "$sata_vd" >/dev/null 2>&1
rc_sv=$?
set -e
if [[ "$rc_sv" -eq 0 ]]; then ok "perf patcher exit 0 with VIRTIO_DISK=1"; else bad "perf patcher exit $rc_sv with VIRTIO_DISK=1"; fi
if grep -Fq '<target dev="vda" bus="virtio"' "$sata_vd"; then ok "SATA boot disk converted to vda virtio"; else bad "SATA boot disk not converted"; fi
if grep -Fq '<target dev="sdb" bus="sata"' "$sata_vd"; then ok "cdrom NOT converted (stays sdb sata)"; else bad "cdrom wrongly converted"; fi
if grep -Fq 'cache="none" io="native"' "$sata_vd"; then ok "perf knobs applied to converted disk"; else bad "perf knobs missing on converted disk"; fi
if grep -Fq 'Samsung_ABCD1234' "$sata_vd"; then ok "disk serial preserved through conversion"; else bad "disk serial lost in conversion"; fi
if grep -Fq 'GENUINE00000' "$sata_vd"; then ok "stealth survives virtio conversion"; else bad "stealth lost in virtio conversion"; fi
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$sata_vd" >/dev/null 2>&1; then ok "virtio-converted XML validates"; else bad "virtio-converted XML fails validate"; fi
fi
# Idempotent: re-run exits 3.
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    VFIO_PERF_VIRTIO_DISK="1" \
    python3 "$perf_py" "$sata_vd" >/dev/null 2>&1
rc_sv2=$?
set -e
if [[ "$rc_sv2" -eq 3 ]]; then ok "virtio conversion idempotent (exit 3)"; else bad "virtio conversion not idempotent (exit $rc_sv2)"; fi
# Opt-in default off: SATA disk untouched when VIRTIO_DISK=0.
sata_no="$tmp/sata_no.xml"
cp "$mock_sata" "$sata_no"
set +e
env VFIO_PERF_HOST_CPUS="0,1,2,3,4,5,6,7" VFIO_PERF_NUMA="0:0-7" \
    VFIO_PERF_HUGEPAGES="0" VFIO_PERF_HUGEPAGES_SIZE="2048" \
    VFIO_PERF_VIRTIO_DISK="0" \
    python3 "$perf_py" "$sata_no" >/dev/null 2>&1
rc_sn=$?
set -e
if [[ "$rc_sn" -eq 0 ]]; then ok "perf patcher exit 0 with VIRTIO_DISK=0"; else bad "perf patcher exit $rc_sn with VIRTIO_DISK=0"; fi
if grep -Fq '<target dev="sda" bus="sata"' "$sata_no"; then ok "SATA disk NOT converted when opted out"; else bad "SATA disk wrongly converted when opted out"; fi

# Reboot-persistent hugepages re-reserve (R35 follow-up): install_perf_hugepages_
# boot_service must generate a STANDALONE, syntactically-valid boot script that
# re-reserves nr_hugepages from the registry at boot. Generate it with temp paths
# + a no-op systemctl + a non-root write_file_atomic (no root/virsh needed).
# shellcheck disable=SC1090
source "$VFIO_SCRIPT"
_sm_save_script="$PERF_HP_BOOT_SCRIPT"; _sm_save_unit="$PERF_HP_BOOT_UNIT"
_sm_save_wfa="$(declare -f write_file_atomic)"
PERF_HP_BOOT_SCRIPT="$tmp/fake-boot.sh"
PERF_HP_BOOT_UNIT="$tmp/fake-boot.service"
# shellcheck disable=SC2034 # owner_group intentionally unused in this non-root override.
write_file_atomic() {
  local dst="$1" mode="$2" owner_group="$3" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  install -m "$mode" "$tmp" "$dst" 2>/dev/null || cp "$tmp" "$dst"
  rm -f "$tmp" || true
}
# shellcheck disable=SC2329 # invoked indirectly via `run systemctl ...` inside install_perf_hugepages_boot_service.
systemctl() { return 0; }
install_perf_hugepages_boot_service >/dev/null 2>&1
if [[ -s "$PERF_HP_BOOT_SCRIPT" ]]; then
  ok "boot-reserve service generated the runtime script"
  if bash -n "$PERF_HP_BOOT_SCRIPT" 2>/dev/null; then
    ok "generated boot script is valid bash (bash -n)"
  else
    bad "generated boot script has syntax errors"
  fi
  if grep -Fq 'REGISTRY=' "$PERF_HP_BOOT_SCRIPT"; then ok "boot script reads the registry"; else bad "boot script missing REGISTRY"; fi
  if grep -Fq 'hp_size >= 1048576' "$PERF_HP_BOOT_SCRIPT"; then ok "boot script has 1GB guard"; else bad "boot script missing 1GB guard"; fi
else
  bad "boot-reserve service did not generate the runtime script"
fi
PERF_HP_BOOT_SCRIPT="$_sm_save_script"; PERF_HP_BOOT_UNIT="$_sm_save_unit"
unset -f systemctl
eval "$_sm_save_wfa"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for _a in "${FAILED_ASSERTIONS[@]}"; do printf ' - %s\n' "$_a" >&2; done
  exit 1
fi
printf '\nSMOKE SUMMARY: PASS\n'
