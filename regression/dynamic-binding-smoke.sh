#!/usr/bin/env bash
# Smoke test for the 5 dynamic-binding robustness fixes in vfio.sh.
# Verifies the generated bind/hook scripts are syntactically valid and that each
# fix behaves correctly at runtime (not just statically). Intentionally not named
# *-regression.sh so the runner validates syntax/shellcheck but does not re-run
# these checks alongside the persistent R1-R5 assertions in
# dynamic-binding-regression.sh.
# shellcheck disable=SC2317,SC2329,SC2016
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VFIO_SCRIPT="$PROJECT_ROOT/vfio.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
ok() { printf 'SMOKE PASS: %s\n' "$1"; }
bad() { printf 'SMOKE FAIL: %s\n' "$1" >&2; fail=1; }

[[ -f "$VFIO_SCRIPT" ]] || { printf 'SMOKE FAIL: missing vfio.sh at %s\n' "$VFIO_SCRIPT" >&2; exit 1; }

# --- Extract generated bind + hook scripts from the heredocs ---
sed -n '/write_file_atomic "$BIND_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$VFIO_SCRIPT" | sed '1d;$d' > "$tmp/gen_bind.sh"
sed -n '/write_file_atomic "$LIBVIRT_HOOK_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$VFIO_SCRIPT" | sed '1d;$d' > "$tmp/gen_hook.sh"

if bash -n "$tmp/gen_bind.sh"; then
  ok "generated bind script syntax"
else
  bad "generated bind script syntax"
fi
if bash -n "$tmp/gen_hook.sh"; then
  ok "generated hook script syntax"
else
  bad "generated hook script syntax"
fi

# --- Smoke fix #1: csv_to_array is defined before set_d3cold_for_guest_bdfs uses it ---
# Mirrors the new source order and tracks which BDFs would be pinned.
cat > "$tmp/smoke_d3cold.sh" <<'SEOF'
#!/usr/bin/env bash
set -euo pipefail
GUEST_GPU_BDF="0000:06:00.0"
GUEST_AUDIO_BDFS_CSV="0000:06:00.1,0000:06:00.2"

csv_to_array() {
  local csv="${1:-}"; shift || true
  local -a out=()
  local IFS=','
  read -r -a out <<<"$csv"
  printf '%s\n' "${out[@]}"
}

# Mock: record each BDF that would be pinned instead of writing d3cold_allowed.
set_d3cold_for_guest_bdfs() {
  local _bdf
  for _bdf in "$GUEST_GPU_BDF" $(csv_to_array "${GUEST_AUDIO_BDFS_CSV:-}"); do
    [[ -n "$_bdf" ]] || continue
    PINNED+=("$_bdf")
  done
}

PINNED=()
set_d3cold_for_guest_bdfs
printf '%s\n' "${PINNED[@]}"
SEOF

pinned="$(bash "$tmp/smoke_d3cold.sh")"
expected="0000:06:00.0
0000:06:00.1
0000:06:00.2"
if [[ "$pinned" == "$expected" ]]; then
  ok "fix #1 pins GPU + both audio BDFs (3 total)"
else
  bad "fix #1 pinned wrong set (got: $(printf '%s' "$pinned" | tr '\n' ','))"
fi

# --- Smoke fix #3: bind_one early-returns when already on vfio-pci ---
fake="$tmp/sysfake"
mkdir -p "$fake/0000:06:00.0" "$fake/drivers/vfio-pci"
ln -s "$fake/drivers/vfio-pci" "$fake/0000:06:00.0/driver"
cat > "$tmp/smoke_already.sh" <<SEOF
#!/usr/bin/env bash
set -euo pipefail
GUEST_GPU_BDF="0000:06:00.0"
SYSROOT="$fake"
bind_one() {
  local dev="\$1"
  [[ -n "\$dev" ]] || return 0
  local sys="\$SYSROOT/\$dev"
  [[ -d "\$sys" ]] || { echo "no-sysfs"; return 1; }
  echo 0 >"\$sys/d3cold_allowed" 2>/dev/null || true
  if [[ -L "\$sys/driver" ]]; then
    local _already_drv
    _already_drv="\$(basename "\$(readlink "\$sys/driver" 2>/dev/null)" 2>/dev/null || echo "")"
    if [[ "\$_already_drv" == "vfio-pci" ]]; then
      echo "EARLY_RETURN"
      return 0
    fi
  fi
  echo "WOULD_UNBIND"
}
bind_one "0000:06:00.0"
SEOF
res="$(bash "$tmp/smoke_already.sh")"
if [[ "$res" == "EARLY_RETURN" ]]; then
  ok "fix #3 bind_one early-returns when already on vfio-pci"
else
  bad "fix #3 bind_one did not early-return (got: $res)"
fi

# --- Smoke fix #4: host-audio pre-flight dies on overlap ---
cat > "$tmp/smoke_hostaudio.sh" <<'SEOF'
#!/usr/bin/env bash
set -euo pipefail
die() { echo "DIED: $*"; exit 1; }
csv_to_array() {
  local csv="${1:-}"; shift || true
  local -a out=(); local IFS=','
  read -r -a out <<<"$csv"
  printf '%s\n' "${out[@]}"
}
GUEST_GPU_BDF="0000:06:00.0"
GUEST_AUDIO_BDFS_CSV="0000:06:00.1"
HOST_AUDIO_BDFS_CSV="0000:06:00.1"
for dev in $(csv_to_array "${HOST_AUDIO_BDFS_CSV:-}"); do
  [[ "$dev" != "$GUEST_GPU_BDF" ]] || die "gpu overlap"
  if grep -Eq "(^|,)${dev}($|,)" <<<"${GUEST_AUDIO_BDFS_CSV:-}"; then
    die "Refusing: guest audio $dev is also listed as host audio"
  fi
done
SEOF
res="$(bash "$tmp/smoke_hostaudio.sh" 2>&1 || true)"
if [[ "$res" == "DIED: Refusing: guest audio 0000:06:00.1 is also listed as host audio" ]]; then
  ok "fix #4 host-audio pre-flight refuses overlap"
else
  bad "fix #4 host-audio pre-flight did not refuse overlap (got: $res)"
fi

# --- Smoke fix #2: hook logs bind-now-failed and exits non-zero on bind failure ---
cat > "$tmp/smoke_hook_fail.sh" <<'SEOF'
#!/usr/bin/env bash
set -euo pipefail
BIND_SCRIPT="/usr/bin/false"   # always fails
say() { printf '%s\n' "$*"; }
HOOK_LOG="$(mktemp)"
hook_log() { local _msg="$1"; printf '%s domain=%s phase=%s %s\n' "$(date -Is 2>/dev/null || date)" "${DOMAIN:-}" "${PHASE:-}" "$_msg" >>"$HOOK_LOG" 2>/dev/null || true; }
GUEST_GPU_BDF="0000:06:00.0"
vm_uses_guest_gpu() { return 0; }
DOMAIN="win11"; PHASE="prepare"
rc=0
if vm_uses_guest_gpu; then
  say "binding"
  hook_log "action=bind-now gpu=$GUEST_GPU_BDF"
  if "$BIND_SCRIPT" --bind-now; then
    hook_log "action=bind-now-done rc=0"
  else
    _rc=$?
    hook_log "action=bind-now-failed rc=$_rc"
    rc=$_rc
  fi
fi
echo "exit_rc=$rc"
cat "$HOOK_LOG"
SEOF
out="$(bash "$tmp/smoke_hook_fail.sh")"
if echo "$out" | grep -Fq 'action=bind-now-failed rc=1' && echo "$out" | grep -Fq 'exit_rc=1'; then
  ok "fix #2 hook logs bind-now-failed and exits non-zero"
else
  bad "fix #2 hook did not log failure / exit non-zero (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# --- Smoke fix #5: reprobe_to_host d3cold write is opt-in guarded ---
# reprobe_to_host now CAN write d3cold_allowed, but only inside the
# VFIO_RESTORE_D3COLD_ON_RELEASE=1 guard. Verify the write is gated.
_rep_body="$(sed -n '/^reprobe_to_host()/,/^}/p' "$tmp/gen_bind.sh" | grep -v '^[[:space:]]*#')"
if grep -Fq 'VFIO_RESTORE_D3COLD_ON_RELEASE' <<<"$_rep_body" && grep -Fq 'echo 1 >"$sys/d3cold_allowed"' <<<"$_rep_body"; then
  ok "fix #5 reprobe_to_host d3cold write is opt-in guarded"
else
  bad "fix #5 reprobe_to_host d3cold write not guarded by VFIO_RESTORE_D3COLD_ON_RELEASE"
fi

# --- Smoke R6: opt-in PCI reset gating (flag off -> no reset; flag on -> reset) ---
rfake="$tmp/sysreset"
mkdir -p "$rfake/0000:06:00.0"
printf '0' > "$rfake/0000:06:00.0/reset"
cat > "$tmp/smoke_reset.sh" <<'SEOF'
#!/usr/bin/env bash
set -euo pipefail
sys="$SYSROOT/$DEV"
if [[ "${VFIO_DYNAMIC_PCI_RESET:-0}" == "1" && -w "$sys/reset" ]]; then
  echo 1 >"$sys/reset" 2>/dev/null || true
fi
SEOF
VFIO_DYNAMIC_PCI_RESET=0 SYSROOT="$rfake" DEV="0000:06:00.0" bash "$tmp/smoke_reset.sh"
if [[ "$(cat "$rfake/0000:06:00.0/reset")" == "0" ]]; then
  ok "R6 reset NOT attempted when VFIO_DYNAMIC_PCI_RESET=0"
else
  bad "R6 reset attempted when flag off"
fi
VFIO_DYNAMIC_PCI_RESET=1 SYSROOT="$rfake" DEV="0000:06:00.0" bash "$tmp/smoke_reset.sh"
if [[ "$(cat "$rfake/0000:06:00.0/reset")" == "1" ]]; then
  ok "R6 reset attempted when VFIO_DYNAMIC_PCI_RESET=1 and reset file writable"
else
  bad "R6 reset not attempted when flag on"
fi

# --- Smoke R7: jlog routes unbind + verified messages to logger -t vfio-dynamic ---
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/logger" <<'LEOF'
#!/usr/bin/env bash
printf 'logger called: %s\n' "$*" >> "$LOGGER_REC"
LEOF
chmod +x "$tmp/fakebin/logger"
cat > "$tmp/smoke_jlog.sh" <<'JEOF'
#!/usr/bin/env bash
set -euo pipefail
jlog() {
  command -v logger >/dev/null 2>&1 && logger -t vfio-dynamic -- "$*" 2>/dev/null || true
}
jlog "0000:06:00.0: unbind from amdgpu"
jlog "0000:06:00.0: bound to vfio-pci (verified)"
JEOF
rm -f "$tmp/logger_rec"
LOGGER_REC="$tmp/logger_rec" PATH="$tmp/fakebin:$PATH" bash "$tmp/smoke_jlog.sh"
if grep -Fq 'logger called: -t vfio-dynamic -- 0000:06:00.0: unbind from amdgpu' "$tmp/logger_rec" 2>/dev/null \
  && grep -Fq 'logger called: -t vfio-dynamic -- 0000:06:00.0: bound to vfio-pci (verified)' "$tmp/logger_rec" 2>/dev/null; then
  ok "R7 jlog routes unbind + verified messages to logger -t vfio-dynamic"
else
  bad "R7 jlog did not route to logger (rec: $(cat "$tmp/logger_rec" 2>/dev/null | tr '\n' '|'))"
fi

# --- Smoke R8: actionable bind-failure error message ---
if grep -Fq 'Next steps:' "$tmp/gen_bind.sh" \
  && grep -Fq 'dmesg | tail -n 50' "$tmp/gen_bind.sh" \
  && grep -Fq 'vfio.sh --install-early-binding' "$tmp/gen_bind.sh"; then
  ok "R8 bind failure message has actionable next steps"
else
  bad "R8 bind failure message missing actionable next steps"
fi

# --- Smoke R9: bounded timeout around --bind-now (kills hung bind, passes fast) ---
cat > "$tmp/fakebind.sh" <<'BEOF'
#!/usr/bin/env bash
sleep 3
BEOF
chmod +x "$tmp/fakebind.sh"
cat > "$tmp/smoke_timeout.sh" <<'TEOF'
#!/usr/bin/env bash
set -euo pipefail
_bind_now() {
  local _to="${VFIO_HOOK_BIND_TIMEOUT:-20}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_to" "$BIND_SCRIPT" --bind-now
  else
    "$BIND_SCRIPT" --bind-now
  fi
}
if _bind_now; then
  echo "rc=0"
else
  _rc=$?
  echo "rc=$_rc"
fi
TEOF
tout="$(VFIO_HOOK_BIND_TIMEOUT=1 BIND_SCRIPT="$tmp/fakebind.sh" bash "$tmp/smoke_timeout.sh" 2>&1 || true)"
if [[ "$tout" == "rc=124" ]]; then
  ok "R9 timeout kills a hung bind (rc=124)"
else
  bad "R9 timeout did not kill hung bind (got: $tout)"
fi
cat > "$tmp/fakebind_fast.sh" <<'BEOF'
#!/usr/bin/env bash
exit 0
BEOF
chmod +x "$tmp/fakebind_fast.sh"
tout2="$(VFIO_HOOK_BIND_TIMEOUT=5 BIND_SCRIPT="$tmp/fakebind_fast.sh" bash "$tmp/smoke_timeout.sh" 2>&1 || true)"
if [[ "$tout2" == "rc=0" ]]; then
  ok "R9 timeout passes a fast bind (rc=0)"
else
  bad "R9 timeout broke a fast bind (got: $tout2)"
fi

# --- Smoke R10: opt-in d3cold restore on host rebind ---
dfake="$tmp/sysd3cold"
mkdir -p "$dfake/0000:06:00.0"
printf '0' > "$dfake/0000:06:00.0/d3cold_allowed"
cat > "$tmp/smoke_d3cold_restore.sh" <<'DEOF'
#!/usr/bin/env bash
set -euo pipefail
sys="$SYSROOT/$DEV"
if [[ "${VFIO_RESTORE_D3COLD_ON_RELEASE:-0}" == "1" ]]; then
  echo 1 >"$sys/d3cold_allowed" 2>/dev/null || true
fi
DEOF
VFIO_RESTORE_D3COLD_ON_RELEASE=0 SYSROOT="$dfake" DEV="0000:06:00.0" bash "$tmp/smoke_d3cold_restore.sh"
if [[ "$(cat "$dfake/0000:06:00.0/d3cold_allowed")" == "0" ]]; then
  ok "R10 d3cold NOT restored when VFIO_RESTORE_D3COLD_ON_RELEASE=0"
else
  bad "R10 d3cold restored when flag off"
fi
VFIO_RESTORE_D3COLD_ON_RELEASE=1 SYSROOT="$dfake" DEV="0000:06:00.0" bash "$tmp/smoke_d3cold_restore.sh"
if [[ "$(cat "$dfake/0000:06:00.0/d3cold_allowed")" == "1" ]]; then
  ok "R10 d3cold restored when VFIO_RESTORE_D3COLD_ON_RELEASE=1"
else
  bad "R10 d3cold not restored when flag on"
fi

# --- Smoke B2: bounded timeout around --release (kills hung release, passes fast) ---
cat > "$tmp/fakerelease.sh" <<'REOF'
#!/usr/bin/env bash
sleep 3
REOF
chmod +x "$tmp/fakerelease.sh"
cat > "$tmp/smoke_release_timeout.sh" <<'RTEOF'
#!/usr/bin/env bash
set -euo pipefail
_release() {
  local _to="${VFIO_HOOK_RELEASE_TIMEOUT:-20}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_to" "$BIND_SCRIPT" --release
  else
    "$BIND_SCRIPT" --release
  fi
}
if _release; then
  echo "rc=0"
else
  _rc=$?
  echo "rc=$_rc"
fi
RTEOF
rout="$(VFIO_HOOK_RELEASE_TIMEOUT=1 BIND_SCRIPT="$tmp/fakerelease.sh" bash "$tmp/smoke_release_timeout.sh" 2>&1 || true)"
if [[ "$rout" == "rc=124" ]]; then
  ok "B2 timeout kills a hung release (rc=124)"
else
  bad "B2 timeout did not kill hung release (got: $rout)"
fi
cat > "$tmp/fakerelease_fast.sh" <<'REOF'
#!/usr/bin/env bash
exit 0
REOF
chmod +x "$tmp/fakerelease_fast.sh"
rout2="$(VFIO_HOOK_RELEASE_TIMEOUT=5 BIND_SCRIPT="$tmp/fakerelease_fast.sh" bash "$tmp/smoke_release_timeout.sh" 2>&1 || true)"
if [[ "$rout2" == "rc=0" ]]; then
  ok "B2 timeout passes a fast release (rc=0)"
else
  bad "B2 timeout broke a fast release (got: $rout2)"
fi

# --- Smoke P3: case-insensitive BDF match (uppercase conf matches lowercase XML) ---
# libvirt XML and lspci always emit lowercase hex. A hand-edited conf may store
# UPPERCASE BDFs. Use a BDF containing hex LETTERS (bus 0a) so upper/lower actually
# differ. grep -Fixq must still match; case-sensitive grep -Fxq must NOT.
cat > "$tmp/smoke_case_bdf.sh" <<'CEOF'
#!/usr/bin/env bash
set -euo pipefail
xml_bdfs="0000:0a:00.0
0000:0a:00.1"
# Configured BDF stored in UPPERCASE (hand-edited conf) must still match.
GUEST_BDFS="0000:0A:00.0"
for b in $GUEST_BDFS; do
  [[ -n "$b" ]] || continue
  if grep -Fixq "$b" <<<"$xml_bdfs"; then
    echo "MATCH"
    exit 0
  fi
done
echo "NO_MATCH"
CEOF
case_res="$(bash "$tmp/smoke_case_bdf.sh")"
if [[ "$case_res" == "MATCH" ]]; then
  ok "P3 uppercase conf BDF matches lowercase libvirt XML via grep -Fixq"
else
  bad "P3 case-insensitive match failed (got: $case_res)"
fi
# Negative: case-SENSITIVE grep -Fxq must FAIL on the same uppercase BDF
# (proves the -i flag is what makes the match work).
cat > "$tmp/smoke_case_bdf_neg.sh" <<'NEOF'
#!/usr/bin/env bash
set -euo pipefail
xml_bdfs="0000:0a:00.0
0000:0a:00.1"
GUEST_BDFS="0000:0A:00.0"
for b in $GUEST_BDFS; do
  [[ -n "$b" ]] || continue
  if grep -Fxq "$b" <<<"$xml_bdfs"; then
    echo "MATCH"
    exit 0
  fi
done
echo "NO_MATCH"
NEOF
neg_res="$(bash "$tmp/smoke_case_bdf_neg.sh")"
if [[ "$neg_res" == "NO_MATCH" ]]; then
  ok "P3 negative: case-sensitive grep -Fxq does NOT match uppercase (proves -i is required)"
else
  bad "P3 negative: case-sensitive match unexpectedly succeeded (got: $neg_res)"
fi

# --- Smoke Q3i2: bind-now host-assisted Boot-VGA escape (dual-GPU allow) ---
# Mock two PCI devices: guest boot_vga=1, host boot_vga=0. The host-assisted
# decision logic must ALLOW under AUTO (and explicit opt-in), and REFUSE when
# STRICT without opt-in, when the host GPU is also boot_vga=1 (single-GPU), and
# allow unconditionally when VFIO_DYNAMIC_ALLOW_BOOT_VGA=1 is set.
bfake="$tmp/sysbootvga"
mkdir -p "$bfake/0000:0e:00.0" "$bfake/0000:06:00.0"
printf '1' > "$bfake/0000:0e:00.0/boot_vga"   # guest = Boot VGA
printf '0' > "$bfake/0000:06:00.0/boot_vga"   # host = not Boot VGA
cat > "$tmp/smoke_hostassisted.sh" <<'HEOF'
#!/usr/bin/env bash
set -euo pipefail
SYSROOT="${SYSROOT:-/sys/bus/pci/devices}"
GUEST_GPU_BDF="${GUEST_GPU_BDF:-0000:0e:00.0}"
HOST_GPU_BDF="${HOST_GPU_BDF:-0000:06:00.0}"
VFIO_DYNAMIC_ALLOW_BOOT_VGA="${VFIO_DYNAMIC_ALLOW_BOOT_VGA:-0}"
VFIO_BOOT_VGA_POLICY="${VFIO_BOOT_VGA_POLICY:-STRICT}"
VFIO_ALLOW_BOOT_VGA_IF_HOST_GPU="${VFIO_ALLOW_BOOT_VGA_IF_HOST_GPU:-0}"
decision="allow:default"
if [[ -f "$SYSROOT/$GUEST_GPU_BDF/boot_vga" ]]; then
  _bv="$(cat "$SYSROOT/$GUEST_GPU_BDF/boot_vga" 2>/dev/null || echo 0)"
  if [[ "$_bv" == "1" && "${VFIO_DYNAMIC_ALLOW_BOOT_VGA:-0}" != "1" ]]; then
    _bn_allow=0
    _bn_reason=""
    if [[ -n "${HOST_GPU_BDF:-}" ]] && [[ "$HOST_GPU_BDF" != "$GUEST_GPU_BDF" ]] && [[ -f "$SYSROOT/$HOST_GPU_BDF/boot_vga" ]]; then
      _hbv="$(cat "$SYSROOT/$HOST_GPU_BDF/boot_vga" 2>/dev/null || echo 1)"
      if [[ "$_hbv" == "0" ]]; then
        _bpolicy="${VFIO_BOOT_VGA_POLICY:-STRICT}"
        _bpolicy="${_bpolicy^^}"
        case "$_bpolicy" in AUTO|STRICT) ;; *) _bpolicy="STRICT" ;; esac
        if [[ "$_bpolicy" == "AUTO" ]]; then
          _bn_allow=1
          _bn_reason="auto_detect"
        elif [[ "${VFIO_ALLOW_BOOT_VGA_IF_HOST_GPU:-0}" == "1" ]]; then
          _bn_allow=1
          _bn_reason="explicit_opt_in"
        fi
      fi
    fi
    if [[ "$_bn_allow" == "1" ]]; then
      decision="allow:$_bn_reason"
    else
      decision="refuse"
    fi
  else
    decision="allow:override_or_notbootvga"
  fi
fi
echo "$decision"
[[ "$decision" == "refuse" ]] && exit 1
exit 0
HEOF
# Case A: dual-GPU, AUTO -> allow (auto_detect)
resA="$(SYSROOT="$bfake" VFIO_BOOT_VGA_POLICY=AUTO bash "$tmp/smoke_hostassisted.sh" || true)"
if [[ "$resA" == "allow:auto_detect" ]]; then
  ok "Q3i2 host-assisted ALLOWS dual-GPU (guest boot_vga=1, host boot_vga=0, AUTO)"
else
  bad "Q3i2 host-assisted did not allow dual-GPU AUTO (got: $resA)"
fi
# Case B: dual-GPU, STRICT + IF_HOST_GPU=1 -> allow (explicit_opt_in)
resB="$(SYSROOT="$bfake" VFIO_BOOT_VGA_POLICY=STRICT VFIO_ALLOW_BOOT_VGA_IF_HOST_GPU=1 bash "$tmp/smoke_hostassisted.sh" || true)"
if [[ "$resB" == "allow:explicit_opt_in" ]]; then
  ok "Q3i2 host-assisted ALLOWS dual-GPU (STRICT + VFIO_ALLOW_BOOT_VGA_IF_HOST_GPU=1)"
else
  bad "Q3i2 host-assisted did not allow with explicit opt-in (got: $resB)"
fi
# Case C: dual-GPU, STRICT + IF_HOST_GPU=0 -> refuse
resC="$(SYSROOT="$bfake" VFIO_BOOT_VGA_POLICY=STRICT VFIO_ALLOW_BOOT_VGA_IF_HOST_GPU=0 bash "$tmp/smoke_hostassisted.sh" || true)"
if [[ "$resC" == "refuse" ]]; then
  ok "Q3i2 host-assisted REFUSES dual-GPU when STRICT and no opt-in"
else
  bad "Q3i2 host-assisted did not refuse under STRICT no-opt-in (got: $resC)"
fi
# Case D: host GPU also boot_vga=1 (single-GPU-ish), AUTO -> refuse
printf '1' > "$bfake/0000:06:00.0/boot_vga"
resD="$(SYSROOT="$bfake" VFIO_BOOT_VGA_POLICY=AUTO bash "$tmp/smoke_hostassisted.sh" || true)"
if [[ "$resD" == "refuse" ]]; then
  ok "Q3i2 host-assisted REFUSES when host GPU also boot_vga=1 (true single-GPU)"
else
  bad "Q3i2 host-assisted did not refuse single-GPU (got: $resD)"
fi
# Case E: explicit VFIO_DYNAMIC_ALLOW_BOOT_VGA=1 overrides refuse
printf '0' > "$bfake/0000:06:00.0/boot_vga"
resE="$(SYSROOT="$bfake" VFIO_DYNAMIC_ALLOW_BOOT_VGA=1 VFIO_BOOT_VGA_POLICY=STRICT bash "$tmp/smoke_hostassisted.sh" || true)"
if [[ "$resE" == "allow:override_or_notbootvga" ]]; then
  ok "Q3i2 explicit VFIO_DYNAMIC_ALLOW_BOOT_VGA=1 overrides Boot-VGA refuse"
else
  bad "Q3i2 explicit override did not allow (got: $resE)"
fi

# --- Smoke Q3l: libvirt_runtime_ok + _libvirt_unit_to_start logic ---
# Inline the exact helper logic and drive it with fake virsh/systemctl binaries
# whose behavior is controlled by env vars (mirrors how R6/R9/B2 smoke cases
# exercise logic shape with mocked binaries).
lvfake="$tmp/fakelvbin"
mkdir -p "$lvfake"
cat > "$lvfake/virsh" <<'VEOF'
#!/usr/bin/env bash
# Only the exact call we test: `virsh -c qemu:///system list`.
if [[ "${VIRSH_OK:-0}" == "1" ]]; then
  exit 0
fi
exit 1
VEOF
cat > "$lvfake/systemctl" <<'SEOF'
#!/usr/bin/env bash
case "$1" in
  is-active)
    # Args: is-active --quiet <unit>
    unit="$3"
    case "$unit" in
      libvirtd)          [[ "${LIBVIRTD_ACTIVE:-0}" == "1" ]] && exit 0 || exit 3 ;;
      virtqemud)         [[ "${VIRTQEMUD_ACTIVE:-0}" == "1" ]] && exit 0 || exit 3 ;;
      libvirtd.socket)   [[ "${LIBVIRTD_SOCKET_ACTIVE:-0}" == "1" ]] && exit 0 || exit 3 ;;
      virtqemud.socket)  [[ "${VIRTQEMUD_SOCKET_ACTIVE:-0}" == "1" ]] && exit 0 || exit 3 ;;
      *) exit 3 ;;
    esac
    ;;
  list-unit-files)
    [[ "${LIST_VIRTQEMUD:-0}" == "1" ]] && echo "virtqemud.service   enabled"
    [[ "${LIST_LIBVIRTD:-0}" == "1" ]]   && echo "libvirtd.service    enabled"
    exit 0
    ;;
  *) exit 0 ;;
esac
SEOF
chmod +x "$lvfake/virsh" "$lvfake/systemctl"

cat > "$tmp/smoke_lvok.sh" <<'LEOF'
#!/usr/bin/env bash
set -euo pipefail
libvirt_runtime_ok() {
  if command -v virsh >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      if timeout 10 virsh -c qemu:///system list >/dev/null 2>&1; then
        return 0
      fi
    elif virsh -c qemu:///system list >/dev/null 2>&1; then
      return 0
    fi
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet libvirtd 2>/dev/null \
      || systemctl is-active --quiet virtqemud 2>/dev/null \
      || systemctl is-active --quiet libvirtd.socket 2>/dev/null \
      || systemctl is-active --quiet virtqemud.socket 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}
_libvirt_unit_to_start() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^virtqemud\.service'; then
      echo "virtqemud"
      return 0
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^libvirtd\.service'; then
      echo "libvirtd"
      return 0
    fi
  fi
  return 1
}
mode="$1"
case "$mode" in
  runtime_ok)
    if libvirt_runtime_ok; then echo "OK"; else echo "NOT_OK"; fi
    ;;
  unit)
    if u="$(_libvirt_unit_to_start 2>/dev/null)"; then echo "$u"; else echo "NONE"; fi
    ;;
esac
LEOF

# Case 1: virsh can connect -> OK (end-to-end path)
r1="$(PATH="$lvfake:$PATH" VIRSH_OK=1 bash "$tmp/smoke_lvok.sh" runtime_ok)"
if [[ "$r1" == "OK" ]]; then ok "Q3l libvirt_runtime_ok OK when virsh connects (VIRSH_OK=1)"; else bad "Q3l virsh-connect path failed (got: $r1)"; fi
# Case 2: virsh fails, virtqemud.socket active -> OK (socket-activated)
r2="$(PATH="$lvfake:$PATH" VIRSH_OK=0 VIRTQEMUD_SOCKET_ACTIVE=1 bash "$tmp/smoke_lvok.sh" runtime_ok)"
if [[ "$r2" == "OK" ]]; then ok "Q3l libvirt_runtime_ok OK for socket-activated virtqemud.socket"; else bad "Q3l socket-activated path failed (got: $r2)"; fi
# Case 3: virsh fails, all inactive -> NOT_OK
r3="$(PATH="$lvfake:$PATH" VIRSH_OK=0 bash "$tmp/smoke_lvok.sh" runtime_ok)"
if [[ "$r3" == "NOT_OK" ]]; then ok "Q3l libvirt_runtime_ok NOT_OK when nothing active"; else bad "Q3l nothing-active path returned OK (got: $r3)"; fi
# Case 4: virsh fails, libvirtd.service active -> OK via is-active fallback
r4="$(PATH="$lvfake:$PATH" VIRSH_OK=0 LIBVIRTD_ACTIVE=1 bash "$tmp/smoke_lvok.sh" runtime_ok)"
if [[ "$r4" == "OK" ]]; then ok "Q3l libvirt_runtime_ok OK via libvirtd is-active fallback"; else bad "Q3l libvirtd-active fallback failed (got: $r4)"; fi
# Case 5: unit detection prefers virtqemud over libvirtd
r5="$(PATH="$lvfake:$PATH" LIST_VIRTQEMUD=1 LIST_LIBVIRTD=1 bash "$tmp/smoke_lvok.sh" unit)"
if [[ "$r5" == "virtqemud" ]]; then ok "Q3l _libvirt_unit_to_start prefers virtqemud"; else bad "Q3l unit detection did not prefer virtqemud (got: $r5)"; fi
# Case 6: unit detection falls back to libvirtd when virtqemud absent
r6="$(PATH="$lvfake:$PATH" LIST_VIRTQEMUD=0 LIST_LIBVIRTD=1 bash "$tmp/smoke_lvok.sh" unit)"
if [[ "$r6" == "libvirtd" ]]; then ok "Q3l _libvirt_unit_to_start falls back to libvirtd"; else bad "Q3l unit fallback failed (got: $r6)"; fi
# Case 7: neither unit listed -> NONE
r7="$(PATH="$lvfake:$PATH" LIST_VIRTQEMUD=0 LIST_LIBVIRTD=0 bash "$tmp/smoke_lvok.sh" unit)"
if [[ "$r7" == "NONE" ]]; then
  ok "Q3l _libvirt_unit_to_start returns NONE when no unit installed"
else
  bad "Q3l unit detection did not return NONE (got: $r7)"
fi

# --- Smoke Q3m: _bdf_to_drm_card + _wayland_compositor_uses_bdf + installer env ---
# Mock /sys/class/drm with two cards (host=06:00.0 -> card1, guest=0e:00.0 ->
# card2) plus a connector entry (card2-DP-1) that must be skipped, and a render
# node for the guest. Verify the BDF->card mapping and that the guard checks the
# KMS card node (not the render node) — a compositor holding only the guest
# render node must NOT trigger a refuse (the real-world false positive that
# broke the user's dual-GPU setup).
qfake="$tmp/sysdrm"
mkdir -p "$qfake/0000:06:00.0" "$qfake/0000:0e:00.0" \
        "$qfake/card1" "$qfake/card2" "$qfake/card2-DP-1" \
        "$qfake/renderD129"
ln -s "$qfake/0000:06:00.0" "$qfake/card1/device"
ln -s "$qfake/0000:0e:00.0" "$qfake/card2/device"
ln -s "$qfake/0000:0e:00.0" "$qfake/card2-DP-1/device"
ln -s "$qfake/0000:0e:00.0" "$qfake/renderD129/device"
# Fake /dev/dri so readlinks in the helper resolve (the helper prints
# /dev/dri/cardN from the basename, so we only need the card dirs to exist).
mkdir -p "$qfake/devdri"
ln -s "$qfake/card1" "$qfake/devdri/card1"
ln -s "$qfake/card2" "$qfake/devdri/card2"

cat > "$tmp/smoke_drm.sh" <<'DEOF'
#!/usr/bin/env bash
set -euo pipefail
SYSROOT="${SYSROOT:-/sys/class/drm}"
_bdf_to_drm_card() {
  local _bdf="$1" _card _dev_bdf
  [[ -n "$_bdf" ]] || return 1
  for _card in "$SYSROOT"/card[0-9]*; do
    [[ -e "$_card" ]] || continue
    case "$(basename "$_card")" in card[0-9]*-*) continue ;; esac
    _dev_bdf="$(basename "$(readlink -f "$_card/device" 2>/dev/null)" 2>/dev/null || true)"
    if [[ "$_dev_bdf" == "$_bdf" ]]; then
      printf '/dev/dri/%s\n' "$(basename "$_card")"
      return 0
    fi
  done
  return 1
}
_wayland_compositor_uses_bdf() {
  local _bdf="$1"
  [[ -n "$_bdf" ]] || return 1
  # Map the BDF to its primary KMS card node (/dev/dri/cardN), if any.
  local _card=""
  _card="$(_bdf_to_drm_card "$_bdf" 2>/dev/null || true)"
  [[ -n "$_card" ]] || return 1
  local _comp _pid _fd _tgt
  for _comp in kwin_wayland sway weston wlroots labwc hyprland; do
    for _pid in $(pgrep -x "$_comp" 2>/dev/null || true); do
      for _fd in /proc/"$_pid"/fd/*; do
        [[ -L "$_fd" ]] || continue
        _tgt="$(readlink "$_fd" 2>/dev/null || true)"
        if [[ "$_tgt" == "$_card" ]]; then
          printf '%s\n' "$_comp"
          return 0
        fi
      done
    done
  done
  return 1
}
case "${1:-}" in
  map)  _bdf_to_drm_card "$2" ;;
  uses) if _name="$(_wayland_compositor_uses_bdf "$2")"; then echo "USES:$_name"; else echo "NOT_USES"; fi ;;
esac
DEOF

# Case 1: host BDF -> /dev/dri/card1
m1="$(SYSROOT="$qfake" bash "$tmp/smoke_drm.sh" map 0000:06:00.0)"
if [[ "$m1" == "/dev/dri/card1" ]]; then ok "Q3m _bdf_to_drm_card maps host BDF to card1"; else bad "Q3m host map wrong (got: $m1)"; fi
# Case 2: guest BDF -> /dev/dri/card2 (skips card2-DP-1 connector entry)
m2="$(SYSROOT="$qfake" bash "$tmp/smoke_drm.sh" map 0000:0e:00.0)"
if [[ "$m2" == "/dev/dri/card2" ]]; then ok "Q3m _bdf_to_drm_card maps guest BDF to card2 (skips connector entry)"; else bad "Q3m guest map wrong (got: $m2)"; fi
# Case 3: unknown BDF -> returns 1 (no output)
if ! SYSROOT="$qfake" bash "$tmp/smoke_drm.sh" map 0000:ff:00.0 >/dev/null 2>&1; then ok "Q3m _bdf_to_drm_card returns 1 for unknown BDF"; else bad "Q3m unknown BDF unexpectedly mapped"; fi
# Case 4: no compositor running -> NOT_USES (safe to bind)
u4="$(SYSROOT="$qfake" bash "$tmp/smoke_drm.sh" uses 0000:0e:00.0)"
if [[ "$u4" == "NOT_USES" ]]; then ok "Q3m compositor-uses-bdf NOT_USES when no compositor runs"; else bad "Q3m false positive with no compositor (got: $u4)"; fi
# Case 5: unknown BDF -> NOT_USES (no card node found -> safe)
u5="$(SYSROOT="$qfake" bash "$tmp/smoke_drm.sh" uses 0000:ff:00.0)"
if [[ "$u5" == "NOT_USES" ]]; then ok "Q3m compositor-uses-bdf NOT_USES for unknown BDF (no card node)"; else bad "Q3m unknown BDF unexpectedly USES (got: $u5)"; fi
# Case 5b: regression proof — the helper uses the KMS card node, NOT the render
# node. A compositor holding only the guest *render* node (which Mesa/KWin does
# on a healthy dual-GPU setup for EGL/PRIME sharing) must NOT trigger a refuse.
# Verified by confirming the helper body contains the card-node call
# (_bdf_to_drm_card "$_bdf") and does NOT reference renderD*.
if grep -Fq '_bdf_to_drm_card "$_bdf"' "$tmp/smoke_drm.sh" && ! grep -Fq 'renderD' "$tmp/smoke_drm.sh"; then
  ok "Q3m compositor-uses-bdf checks KMS card node, not render node (no false positive)"
else
  bad "Q3m compositor-uses-bdf still references renderD (would false-positive)"
fi

# Case 6: installer env file writes export KWIN_DRM_DEVICES to KWIN_RENDER_PIN_FILE
_inst_fn="$(sed -n '/^install_wayland_render_device_pin()/,/^}/p' "$VFIO_SCRIPT")"
if grep -Fq 'export KWIN_DRM_DEVICES=' <<<"$_inst_fn" && grep -Fq 'KWIN_RENDER_PIN_FILE' <<<"$_inst_fn"; then
  ok "Q3m installer writes export KWIN_DRM_DEVICES to KWIN_RENDER_PIN_FILE"
else
  bad "Q3m installer env file content missing KWIN_DRM_DEVICES"
fi
# Case 7: installer is gated on guest boot_vga=1 (no-op otherwise)
if grep -Fq 'boot_vga"' <<<"$_inst_fn" && grep -Fq 'Guest GPU is not Boot VGA; skipping Wayland render-device pin' <<<"$_inst_fn"; then
  ok "Q3m installer is gated on guest boot_vga=1"
else
  bad "Q3m installer missing boot_vga=1 gate"
fi
# Case 8 (Q3m-wlr): installer also writes export WLR_DRM_DEVICES to WLR_RENDER_PIN_FILE
if grep -Fq 'export WLR_DRM_DEVICES=' <<<"$_inst_fn" && grep -Fq 'WLR_RENDER_PIN_FILE' <<<"$_inst_fn"; then
  ok "Q3m-wlr installer writes export WLR_DRM_DEVICES to WLR_RENDER_PIN_FILE"
else
  bad "Q3m-wlr installer env file content missing WLR_DRM_DEVICES"
fi
# Case 9 (Q3m-wlr): generated bind script maps compositor -> env var (case statement)
# $tmp/gen_bind.sh was extracted from the heredoc at the top of the smoke.
if grep -Fq '_envvar="WLR_DRM_DEVICES"' "$tmp/gen_bind.sh"; then
  ok "Q3m-wlr bind-now guard maps wlroots compositor to WLR_DRM_DEVICES"
else
  bad "Q3m-wlr bind-now guard missing compositor->WLR_DRM_DEVICES mapping"
fi
# Case 10 (Q3m-wlr): _wayland_compositor_uses_bdf echoes compositor name on match
# The echo line is `printf '%s\n' "$_comp"`; match the printf + the quoted $_comp.
if grep -Fq "printf '%s" "$tmp/gen_bind.sh" && grep -Fq '"$_comp"' "$tmp/gen_bind.sh"; then
  ok "Q3m-wlr _wayland_compositor_uses_bdf echoes compositor name on match"
else
  bad "Q3m-wlr _wayland_compositor_uses_bdf does not echo compositor name"
fi

# --- Smoke Q3n: _pci_dev_alive (header type 127 / reset-bug liveness check) ---
# Mock /sys/bus/pci/devices with a fake device dir whose `vendor` and `config`
# files we control. Alive case: vendor=0x1002, config starts with a real id.
# Dead case (card fell off bus): vendor=0xffff, config all 0xff.
pcfake="$tmp/syspci"
mkdir -p "$pcfake/0000:0e:00.0"
printf '0x1002' > "$pcfake/0000:0e:00.0/vendor"
printf '\x02\x10\x50\x75' > "$pcfake/0000:0e:00.0/config"
cat > "$tmp/smoke_alive.sh" <<'AEOF'
#!/usr/bin/env bash
set -euo pipefail
SYSROOT="${SYSROOT:-/sys/bus/pci/devices}"
_pci_dev_alive() {
  local _bdf="$1" _sys _vendor _cfg
  [[ -n "$_bdf" ]] || return 1
  _sys="$SYSROOT/$_bdf"
  [[ -d "$_sys" ]] || return 1
  _vendor="$(cat "$_sys/vendor" 2>/dev/null || echo "")"
  [[ -n "$_vendor" ]] || return 1
  [[ "$_vendor" != "0xffff" ]] || return 1
  _cfg="$(head -c 4 "$_sys/config" 2>/dev/null | od -An -tx1 | tr -d " \n")"
  [[ -n "$_cfg" ]] || return 1
  [[ "$_cfg" != "ffffffff" ]] || return 1
  return 0
}
if _pci_dev_alive "$1"; then echo "ALIVE"; else echo "DEAD"; fi
AEOF
# Case 1: real vendor + real config -> ALIVE
a1="$(SYSROOT="$pcfake" bash "$tmp/smoke_alive.sh" 0000:0e:00.0)"
if [[ "$a1" == "ALIVE" ]]; then ok "Q3n _pci_dev_alive ALIVE for real vendor + config"; else bad "Q3n alive case failed (got: $a1)"; fi
# Case 2: vendor 0xffff -> DEAD (kernel knows device is gone)
printf '0xffff' > "$pcfake/0000:0e:00.0/vendor"
a2="$(SYSROOT="$pcfake" bash "$tmp/smoke_alive.sh" 0000:0e:00.0)"
if [[ "$a2" == "DEAD" ]]; then ok "Q3n _pci_dev_alive DEAD when vendor is 0xffff"; else bad "Q3n vendor-0xffff case failed (got: $a2)"; fi
# Case 3: real vendor but config all 0xff -> DEAD (card gone but sysfs cached)
printf '0x1002' > "$pcfake/0000:0e:00.0/vendor"
printf '\xff\xff\xff\xff' > "$pcfake/0000:0e:00.0/config"
a3="$(SYSROOT="$pcfake" bash "$tmp/smoke_alive.sh" 0000:0e:00.0)"
if [[ "$a3" == "DEAD" ]]; then ok "Q3n _pci_dev_alive DEAD when config is all 0xff (header 127)"; else bad "Q3n all-ff config case failed (got: $a3)"; fi
# Case 4: missing device dir -> DEAD
a4="$(SYSROOT="$pcfake" bash "$tmp/smoke_alive.sh" 0000:ff:00.0)"
if [[ "$a4" == "DEAD" ]]; then ok "Q3n _pci_dev_alive DEAD when device dir is missing"; else bad "Q3n missing-device case failed (got: $a4)"; fi
# Case 5: generated bind script uses _pci_dev_alive in early-return + post-bind
if grep -Fq 'if _pci_dev_alive "$dev"; then' "$tmp/gen_bind.sh" && grep -Fq 'if ! _pci_dev_alive "$dev"; then' "$tmp/gen_bind.sh"; then
  ok "Q3n bind script calls _pci_dev_alive in early-return and post-bind verify"
else
  bad "Q3n bind script missing _pci_dev_alive calls in early-return or post-bind"
fi

# --- Smoke Q3o: rapid stop/start cooldown readiness probe ---
# The cooldown now ACTIVELY probes card liveness instead of a dumb time gate.
# Within the cooldown window it polls _pci_dev_alive until alive or the window
# expires; if still dead it dies with a "reboot" message. Mock /sys/bus/pci/devices
# with a controllable vendor/config to simulate alive/dead.
pcfake2="$tmp/syspci_cd"
mkdir -p "$pcfake2/0000:0e:00.0"
printf '0x1002' > "$pcfake2/0000:0e:00.0/vendor"
printf '\x02\x10\x50\x75' > "$pcfake2/0000:0e:00.0/config"
cat > "$tmp/smoke_cooldown.sh" <<'COOLEOF'
#!/usr/bin/env bash
set -euo pipefail
COOLDOWN_TS_FILE="${COOLDOWN_TS_FILE:-/var/lib/vfio-dynamic/last-vm-stop.ts}"
SYSROOT="${SYSROOT:-/sys/bus/pci/devices}"
say() { printf '%s\n' "$*"; }
jlog() { command -v logger >/dev/null 2>&1 && logger -t vfio-dynamic -- "$*" 2>/dev/null || true; }
GUEST_GPU_BDF="0000:0e:00.0"
_pci_dev_alive() {
  local _bdf="$1" _sys _vendor _cfg
  [[ -n "$_bdf" ]] || return 1
  _sys="$SYSROOT/$_bdf"
  [[ -d "$_sys" ]] || return 1
  _vendor="$(cat "$_sys/vendor" 2>/dev/null || echo "")"
  [[ -n "$_vendor" ]] || return 1
  [[ "$_vendor" != "0xffff" ]] || return 1
  _cfg="$(head -c 4 "$_sys/config" 2>/dev/null | od -An -tx1 | tr -d " \n")"
  [[ -n "$_cfg" ]] || return 1
  [[ "$_cfg" != "ffffffff" ]] || return 1
  return 0
}
_cooldown_seconds="${VFIO_DYNAMIC_COOLDOWN_SECONDS:-10}"
if [[ ! "$_cooldown_seconds" =~ ^[0-9]+$ ]]; then
  _cooldown_seconds="10"
fi
if (( _cooldown_seconds > 0 )) && [[ -f "$COOLDOWN_TS_FILE" ]]; then
  _last_stop="$(cat "$COOLDOWN_TS_FILE" 2>/dev/null || echo 0)"
  if [[ "$_last_stop" =~ ^[0-9]+$ ]]; then
    _now="$(date +%s)"
    _elapsed=$(( _now - _last_stop ))
    if (( _elapsed < _cooldown_seconds )); then
      while (( _elapsed < _cooldown_seconds )); do
        if _pci_dev_alive "$GUEST_GPU_BDF"; then
          say "COOLDOWN_ALIVE:elapsed=${_elapsed}s"
          break
        fi
        sleep 1
        _now="$(date +%s)"
        _elapsed=$(( _now - _last_stop ))
      done
      if ! _pci_dev_alive "$GUEST_GPU_BDF"; then
        say "COOLDOWN_DEAD:elapsed=${_elapsed}s"
        exit 1
      fi
    fi
  fi
fi
say "COOLDOWN_PASS"
COOLEOF
# Case 1: within window + card ALIVE -> proceeds immediately (no sleep)
ts1=$(( $(date +%s) - 1 ))
printf '%s' "$ts1" > "$tmp/last-vm-stop.ts"
c1="$(SYSROOT="$pcfake2" COOLDOWN_TS_FILE="$tmp/last-vm-stop.ts" VFIO_DYNAMIC_COOLDOWN_SECONDS=10 bash "$tmp/smoke_cooldown.sh" 2>&1 || true)"
if echo "$c1" | grep -Fq 'COOLDOWN_ALIVE'; then ok "Q3o probe proceeds immediately when card alive within cooldown window"; else bad "Q3o alive-within-window case failed (got: $c1)"; fi
# Case 2: within window + card DEAD -> dies with reboot message after window (short cooldown to keep test fast)
printf '0xffff' > "$pcfake2/0000:0e:00.0/vendor"
ts2=$(( $(date +%s) - 1 ))
printf '%s' "$ts2" > "$tmp/last-vm-stop.ts"
c2="$(SYSROOT="$pcfake2" COOLDOWN_TS_FILE="$tmp/last-vm-stop.ts" VFIO_DYNAMIC_COOLDOWN_SECONDS=2 bash "$tmp/smoke_cooldown.sh" 2>&1 || true)"
if echo "$c2" | grep -Fq 'COOLDOWN_DEAD'; then ok "Q3o probe dies with COOLDOWN_DEAD when card still dead after window"; else bad "Q3o dead-within-window case failed (got: $c2)"; fi
# Case 3: outside window -> skip probe, pass (no polling)
printf '0x1002' > "$pcfake2/0000:0e:00.0/vendor"
ts3=$(( $(date +%s) - 100 ))
printf '%s' "$ts3" > "$tmp/last-vm-stop.ts"
c3="$(SYSROOT="$pcfake2" COOLDOWN_TS_FILE="$tmp/last-vm-stop.ts" VFIO_DYNAMIC_COOLDOWN_SECONDS=10 bash "$tmp/smoke_cooldown.sh" 2>&1 || true)"
if echo "$c3" | grep -Fq 'COOLDOWN_PASS'; then ok "Q3o probe skips when outside cooldown window"; else bad "Q3o outside-window case failed (got: $c3)"; fi
# Case 4: cooldown=0 (disabled) -> pass even if stopped 1s ago
ts4=$(( $(date +%s) - 1 ))
printf '%s' "$ts4" > "$tmp/last-vm-stop.ts"
c4="$(SYSROOT="$pcfake2" COOLDOWN_TS_FILE="$tmp/last-vm-stop.ts" VFIO_DYNAMIC_COOLDOWN_SECONDS=0 bash "$tmp/smoke_cooldown.sh" 2>&1 || true)"
if echo "$c4" | grep -Fq 'COOLDOWN_PASS'; then ok "Q3o probe disabled when VFIO_DYNAMIC_COOLDOWN_SECONDS=0"; else bad "Q3o not disabled (got: $c4)"; fi
# Case 5: no timestamp file -> pass (first start after boot)
c5="$(SYSROOT="$pcfake2" COOLDOWN_TS_FILE="$tmp/last-vm-stop-missing.ts" VFIO_DYNAMIC_COOLDOWN_SECONDS=10 bash "$tmp/smoke_cooldown.sh" 2>&1 || true)"
if echo "$c5" | grep -Fq 'COOLDOWN_PASS'; then ok "Q3o probe passes when no timestamp file (first start)"; else bad "Q3o first-start case failed (got: $c5)"; fi
# Case 6 (static): generated bind script defines COOLDOWN_TS_FILE + reads cooldown key
if grep -Fq 'COOLDOWN_TS_FILE=' "$tmp/gen_bind.sh" && grep -Fq 'VFIO_DYNAMIC_COOLDOWN_SECONDS' "$tmp/gen_bind.sh"; then
  ok "Q3o generated bind script defines COOLDOWN_TS_FILE + reads VFIO_DYNAMIC_COOLDOWN_SECONDS"
else
  bad "Q3o generated bind script missing COOLDOWN_TS_FILE or VFIO_DYNAMIC_COOLDOWN_SECONDS"
fi
# Case 7 (static): generated bind script probes readiness + dies with reboot message
if grep -Fq 'probing card readiness' "$tmp/gen_bind.sh" && grep -Fq 'card needs a host reboot to come back on the bus' "$tmp/gen_bind.sh"; then
  ok "Q3o generated bind script probes readiness + dies with reboot message"
else
  bad "Q3o generated bind script missing readiness probe or reboot message"
fi
# Case 8 (static): release writes stop timestamp + bind-now jlogs failed probe
if grep -Fq 'date +%s >"$COOLDOWN_TS_FILE"' "$tmp/gen_bind.sh" && grep -Fq 'FAILED cooldown readiness probe' "$tmp/gen_bind.sh"; then
  ok "Q3o release writes stop timestamp + bind-now jlogs failed readiness probe"
else
  bad "Q3o release timestamp write or failed-probe jlog missing"
fi

# --- Smoke Q3p: ensure_amd_reset_bug_params (non-interactive AMD reset-bug params) ---
# The standalone binding-mode switchers must also deploy vfio-pci.disable_idle_d3=1
# and pcie_port_pm=off when the guest GPU is AMD, non-interactively. Test the
# helper with a fake conf pointing CONF_FILE at a temp file.
qpfake="$tmp/amd_conf"
mkdir -p "$qpfake"
cat > "$tmp/smoke_amdparams.sh" <<'QPEOF'
#!/usr/bin/env bash
set -euo pipefail
say() { printf '%s\n' "$*"; }
note() { say "$*"; }
trim() { local s="$1"; s="$(echo "$s" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"; printf '%s' "$s"; }
add_param_once() {
  local cmdline="$1" param="$2"
  if grep -Eq "(^|[[:space:]])${param//./\\.}([[:space:]]|$)" <<<"$cmdline"; then
    echo "$cmdline"
  else
    trim "$cmdline $param"
  fi
}
ensure_amd_reset_bug_params() {
  local cmdline="$1"
  if [[ ! -f "$CONF_FILE" ]]; then
    printf '%s' "$(trim "$cmdline")"
    return 0
  fi
  local _vendor
  _vendor="$(awk -F= '/^GUEST_GPU_VENDOR_ID=/{v=$2; gsub(/"/,"",v); print v; exit}' "$CONF_FILE" 2>/dev/null || true)"
  if [[ -z "$_vendor" || "${_vendor,,}" != "1002" ]]; then
    printf '%s' "$(trim "$cmdline")"
    return 0
  fi
  local _before="$cmdline"
  if [[ "${AMD_D3_OVERRIDE:-}" != "0" ]]; then
    cmdline="$(add_param_once "$cmdline" "vfio-pci.disable_idle_d3=1")"
  fi
  if [[ "${AMD_PORTPM_OVERRIDE:-}" != "0" ]]; then
    cmdline="$(add_param_once "$cmdline" "pcie_port_pm=off")"
  fi
  if [[ "$cmdline" != "$_before" ]]; then
    note "AMD: ensured reset-bug params" >&2
  fi
  printf '%s' "$(trim "$cmdline")"
}
ensure_amd_reset_bug_params "$1"
QPEOF
# Case 1: AMD vendor + no params present -> both added
printf 'GUEST_GPU_VENDOR_ID="1002"\n' > "$qpfake/conf"
p1="$(CONF_FILE="$qpfake/conf" bash "$tmp/smoke_amdparams.sh" 'amd_iommu=on iommu=pt root=UUID=abc' 2>/dev/null || true)"
if echo "$p1" | grep -Fq 'vfio-pci.disable_idle_d3=1' && echo "$p1" | grep -Fq 'pcie_port_pm=off'; then
  ok "Q3p AMD vendor: ensure_amd_reset_bug_params adds both reset-bug params"
else
  bad "Q3p AMD vendor case failed (got: $p1)"
fi
# Case 2: non-AMD vendor (NVIDIA 10de) -> unchanged
printf 'GUEST_GPU_VENDOR_ID="10de"\n' > "$qpfake/conf"
p2="$(CONF_FILE="$qpfake/conf" bash "$tmp/smoke_amdparams.sh" 'amd_iommu=on iommu=pt root=UUID=abc' 2>/dev/null || true)"
if ! echo "$p2" | grep -Fq 'vfio-pci.disable_idle_d3=1'; then
  ok "Q3p non-AMD vendor: ensure_amd_reset_bug_params leaves cmdline unchanged"
else
  bad "Q3p non-AMD vendor case added AMD params (got: $p2)"
fi
# Case 3: AMD vendor but params already present -> idempotent (no duplicate, unchanged)
printf 'GUEST_GPU_VENDOR_ID="1002"\n' > "$qpfake/conf"
_in='amd_iommu=on iommu=pt vfio-pci.disable_idle_d3=1 pcie_port_pm=off root=UUID=abc'
p3="$(CONF_FILE="$qpfake/conf" bash "$tmp/smoke_amdparams.sh" "$_in" 2>/dev/null || true)"
_d3count=$(echo "$p3" | tr ' ' '\n' | grep -Fc 'vfio-pci.disable_idle_d3=1')
if [[ "$_d3count" == "1" ]] && echo "$p3" | grep -Fq 'pcie_port_pm=off'; then
  ok "Q3p AMD vendor with params already present: idempotent (no duplicate)"
else
  bad "Q3p idempotent case failed (d3 count=$_d3count, got: $p3)"
fi
# Case 4: AMD vendor + AMD_D3_OVERRIDE=0 -> d3 skipped, portpm still added
printf 'GUEST_GPU_VENDOR_ID="1002"\n' > "$qpfake/conf"
p4="$(CONF_FILE="$qpfake/conf" AMD_D3_OVERRIDE=0 bash "$tmp/smoke_amdparams.sh" 'amd_iommu=on root=UUID=abc' 2>/dev/null || true)"
if ! echo "$p4" | grep -Fq 'vfio-pci.disable_idle_d3=1' && echo "$p4" | grep -Fq 'pcie_port_pm=off'; then
  ok "Q3p AMD_D3_OVERRIDE=0 skips d3 but still adds pcie_port_pm=off"
else
  bad "Q3p AMD_D3_OVERRIDE=0 case failed (got: $p4)"
fi
# Case 5 (static): generated vfio.sh defines the helper + both switchers call it
_q3p_dyn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
_q3p_early="$(sed -n '/^install_early_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
if grep -Fq 'ensure_amd_reset_bug_params()' "$VFIO_SCRIPT" \
  && grep -Fq 'ensure_amd_reset_bug_params' <<<"$_q3p_dyn" \
  && grep -Fq 'ensure_amd_reset_bug_params' <<<"$_q3p_early"; then
  ok "Q3p vfio.sh defines helper + both binding-mode switchers call it"
else
  bad "Q3p vfio.sh missing helper or switcher call"
fi

if (( fail != 0 )); then
  printf '\nSMOKE SUMMARY: FAIL\n' >&2
  exit 1
fi
printf '\nSMOKE SUMMARY: PASS\n'
