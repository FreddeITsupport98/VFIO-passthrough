#!/usr/bin/env bash
# R40b smoke: extract the Looking Glass display patchers from vfio.sh and run
# them on a mock VM XML. Confirms:
#   - _lg_set_vm_display_none sets <video><model type='none'/> (NO leftover
#     heads/primary) and spice <listen type='none'/> (NO leftover address) so
#     the patched XML passes virt-xml-validate (the 'Extra element devices in
#     interleave' regression: the libvirt RNG forbids the 'none' variants from
#     carrying the active-variant attributes).
#   - idempotent (exit 3 on re-run).
#   - _lg_restore_vm_display restores <video><model type='virtio' heads='1'
#     primary='yes'/>, leaves spice local-only, validates, idempotent (exit 3).
# Does NOT need root or a real libvirt VM — exercises the core XML-patching
# logic only (safe code).
# Run: bash regression/looking-glass-smoke.sh
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

# Extract the display-none + display-restore patcher heredocs.
dn_py="$tmp/display_none.py"
awk '
  /_lg_set_vm_display_none\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$dn_py"
dr_py="$tmp/display_restore.py"
awk '
  /_lg_restore_vm_display\(\)/ { in_fn=1 }
  in_fn && /<<.PYEOF./ { grab=1; next }
  grab && /^PYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$dr_py"

if python3 -m py_compile "$dn_py" 2>/dev/null; then
  ok "display-none patcher python compiles"
else
  bad "display-none patcher python does not compile"
fi
if python3 -m py_compile "$dr_py" 2>/dev/null; then
  ok "display-restore patcher python compiles"
else
  bad "display-restore patcher python does not compile"
fi

# Mock VM XML: virtio video (heads/primary) + spice listen on 127.0.0.1
# (address) + a guest-GPU hostdev so it qualifies as a guest-GPU VM.
mock="$tmp/mock.xml"
cat >"$mock" <<'XEOF'
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

disp="$tmp/disp.xml"
cp "$mock" "$disp"

# --- set video=none + spice local-only ---
set +e
python3 - "$disp" <"$dn_py" >/dev/null 2>&1
rc_dn1=$?
set -e
if [[ "$rc_dn1" -eq 0 ]]; then ok "display-none run 1 exit 0"; else bad "display-none run 1 exit $rc_dn1"; fi

# ElementTree writes double-quoted attributes on the temp (pre-define) XML.
if grep -Fq 'type="none"' "$disp"; then ok "video model set to none"; else bad "video model not set to none"; fi
if grep -Fq 'listen type="none"' "$disp"; then ok "spice listen set to none"; else bad "spice listen not set to none"; fi

# BUG GUARD: the 'none' variants must NOT carry leftover active-variant attrs.
# (Leftover heads/primary on model none, or address on listen none, make the
# element fail its RNG branch -> 'Extra element devices in interleave'.)
if grep -Fq '<model type="none"' "$disp"; then
  if grep -Fq '<model type="none" heads' "$disp"; then
    bad "video model none still carries heads= (RNG-invalid)"
  else
    ok "video model none carries no leftover heads/primary"
  fi
else
  bad "video model none element not found"
fi
if grep -Fq 'listen type="none"' "$disp"; then
  if grep -Fq 'listen type="none" address' "$disp"; then
    bad "spice listen none still carries address= (RNG-invalid)"
  else
    ok "spice listen none carries no leftover address"
  fi
else
  bad "spice listen none element not found"
fi

if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$disp" >/dev/null 2>&1; then
    ok "display-none XML validates (virt-xml-validate)"
  else
    bad "display-none XML fails virt-xml-validate"
  fi
else
  ok "virt-xml-validate not installed (skipping validate)"
fi

# --- idempotent (already none+local) -> exit 3 ---
set +e
python3 - "$disp" <"$dn_py" >/dev/null 2>&1
rc_dn2=$?
set -e
if [[ "$rc_dn2" -eq 3 ]]; then ok "display-none idempotent (exit 3 on re-run)"; else bad "display-none not idempotent (exit $rc_dn2 on re-run)"; fi

# --- restore video to virtio ---
set +e
python3 - "$disp" <"$dr_py" >/dev/null 2>&1
rc_dr1=$?
set -e
if [[ "$rc_dr1" -eq 0 ]]; then ok "display-restore exit 0 after none"; else bad "display-restore exit $rc_dr1 after none"; fi
if grep -Fq 'type="virtio"' "$disp"; then ok "video model restored to virtio"; else bad "video model not restored to virtio"; fi
if grep -Fq 'heads="1"' "$disp"; then ok "video heads=1 preserved on restore"; else bad "video heads=1 lost on restore"; fi
if grep -Fq 'primary="yes"' "$disp"; then ok "video primary=yes preserved on restore"; else bad "video primary=yes lost on restore"; fi
# spice stays local-only (restore does not re-expose spice).
if grep -Fq 'listen type="none"' "$disp"; then ok "spice listen stays none after restore"; else bad "spice listen changed after restore"; fi
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$disp" >/dev/null 2>&1; then
    ok "display-restored XML validates (virt-xml-validate)"
  else
    bad "display-restored XML fails virt-xml-validate"
  fi
fi

# --- restore idempotent (not currently 'none') -> exit 3 ---
set +e
python3 - "$disp" <"$dr_py" >/dev/null 2>&1
rc_dr2=$?
set -e
if [[ "$rc_dr2" -eq 3 ]]; then ok "display-restore idempotent (exit 3 when not none)"; else bad "display-restore not idempotent (exit $rc_dr2 when not none)"; fi

# --- round-trip: none -> restore -> none again still validates ---
set +e
python3 - "$disp" <"$dn_py" >/dev/null 2>&1
rc_rt=$?
set -e
if [[ "$rc_rt" -eq 0 ]]; then ok "round-trip re-none exit 0"; else bad "round-trip re-none exit $rc_rt"; fi
if command -v virt-xml-validate >/dev/null 2>&1; then
  if virt-xml-validate "$disp" >/dev/null 2>&1; then
    ok "round-trip re-none XML validates"
  else
    bad "round-trip re-none XML fails virt-xml-validate"
  fi
fi

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for _a in "${FAILED_ASSERTIONS[@]}"; do printf ' - %s\n' "$_a" >&2; done
  exit 1
fi
printf '\nSMOKE SUMMARY: PASS\n'
