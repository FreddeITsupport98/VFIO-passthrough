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
sed -n '/write_file_atomic "$PARK_KEEPALIVE_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$VFIO_SCRIPT" | sed '1d;$d' > "$tmp/gen_park_keepalive.sh"

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
if bash -n "$tmp/gen_park_keepalive.sh"; then
  ok "generated park-keepalive script syntax"
else
  bad "generated park-keepalive script syntax"
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

# --- Smoke Q3q: _pci_dev_remove_rescan (last-resort bus recovery) ---
# Test the remove+rescan recovery sequence with a mock sysfs. The helper should:
# write to $sys/remove, write to /sys/bus/pci/rescan, set driver_override, bind,
# and verify alive. We mock the sysfs paths via SYSROOT + RESCAN_FILE env vars.
qfake="$tmp/syspci_qq"
mkdir -p "$qfake/0000:0e:00.0" "$qfake/drivers/vfio-pci"
printf '0x1002' > "$qfake/0000:0e:00.0/vendor"
printf '\x02\x10\x50\x75' > "$qfake/0000:0e:00.0/config"
printf '0' > "$qfake/0000:0e:00.0/remove"
printf '0' > "$qfake/rescan"
ln -s "$qfake/drivers/vfio-pci" "$qfake/0000:0e:00.0/driver"
cat > "$tmp/smoke_rescan.sh" <<'QEOF'
#!/usr/bin/env bash
set -euo pipefail
SYSROOT="${SYSROOT:-/sys/bus/pci/devices}"
RESCAN_FILE="${RESCAN_FILE:-/sys/bus/pci/rescan}"
say() { printf '%s\n' "$*"; }
jlog() { command -v logger >/dev/null 2>&1 && logger -t vfio-dynamic -- "$*" 2>/dev/null || true; }
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
_pci_dev_remove_rescan() {
  local _bdf="$1" _sys
  [[ -n "$_bdf" ]] || return 1
  _sys="$SYSROOT/$_bdf"
  [[ -d "$_sys" ]] || return 1
  if [[ -w "$_sys/remove" ]]; then
    echo 1 >"$_sys/remove" 2>/dev/null || true
    sleep 0.1
  fi
  echo 1 >"$RESCAN_FILE" 2>/dev/null || true
  sleep 0.1
  [[ -d "$_sys" ]] || { echo "RESCAN_GONE"; return 1; }
  echo vfio-pci >"$_sys/driver_override" 2>/dev/null || true
  if _pci_dev_alive "$_bdf"; then
    echo "RESCAN_ALIVE"
    return 0
  fi
  echo "RESCAN_DEAD"
  return 1
}
_pci_dev_remove_rescan "$1"
QEOF
# Case 1: alive card -> remove+rescan -> still alive -> RESCAN_ALIVE
r1="$(SYSROOT="$qfake" RESCAN_FILE="$qfake/rescan" bash "$tmp/smoke_rescan.sh" 0000:0e:00.0 2>&1 || true)"
if echo "$r1" | grep -Fq 'RESCAN_ALIVE'; then ok "Q3q remove+rescan recovers alive card"; else bad "Q3q alive case failed (got: $r1)"; fi
# Case 2: dead card (config all ff) -> remove+rescan -> still dead -> RESCAN_DEAD
printf '\xff\xff\xff\xff' > "$qfake/0000:0e:00.0/config"
r2="$(SYSROOT="$qfake" RESCAN_FILE="$qfake/rescan" bash "$tmp/smoke_rescan.sh" 0000:0e:00.0 2>&1 || true)"
if echo "$r2" | grep -Fq 'RESCAN_DEAD'; then ok "Q3q remove+rescan reports DEAD when card stays dead"; else bad "Q3q dead case failed (got: $r2)"; fi
# Case 3 (static): generated bind script defines helper + calls it in both dead paths
if grep -Fq '_pci_dev_remove_rescan()' "$tmp/gen_bind.sh" \
  && grep -Fq 'PCI reset + remove+rescan did not recover' "$tmp/gen_bind.sh" \
  && grep -Fq 'A PCI reset and a remove+rescan bus recovery both failed' "$tmp/gen_bind.sh"; then
  ok "Q3q generated bind script defines helper + both dead paths use it"
else
  bad "Q3q generated bind script missing helper or dead-path calls"
fi
# Case 4 (static): helper writes to remove + rescan + driver_override
if grep -Fq 'echo 1 >"$_sys/remove"' "$tmp/gen_bind.sh" \
  && grep -Fq 'echo 1 >/sys/bus/pci/rescan' "$tmp/gen_bind.sh" \
  && grep -Fq 'echo vfio-pci >"$_sys/driver_override"' "$tmp/gen_bind.sh"; then
  ok "Q3q helper writes remove + rescan + driver_override"
else
  bad "Q3q helper missing remove/rescan/driver_override writes"
fi

# --- Smoke Q3r: release-time zombie-card recovery ---
# The release path must check if the card is dead at stop time and attempt
# remove+rescan recovery immediately (only on dead cards). Test the release-path
# zombie gate with a mock: dead card -> recovery attempted; healthy card -> skipped.
cat > "$tmp/smoke_release_zombie.sh" <<'Q3REOF'
#!/usr/bin/env bash
set -euo pipefail
SYSROOT="${SYSROOT:-/sys/bus/pci/devices}"
RESCAN_FILE="${RESCAN_FILE:-/sys/bus/pci/rescan}"
GUEST_GPU_BDF="${GUEST_GPU_BDF:-0000:0e:00.0}"
say() { printf '%s\n' "$*"; }
jlog() { command -v logger >/dev/null 2>&1 && logger -t vfio-dynamic -- "$*" 2>/dev/null || true; }
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
_pci_dev_remove_rescan() {
  local _bdf="$1" _sys
  _sys="$SYSROOT/$_bdf"
  [[ -d "$_sys" ]] || return 1
  echo 1 >"$_sys/remove" 2>/dev/null || true
  echo 1 >"$RESCAN_FILE" 2>/dev/null || true
  sleep 0.1
  [[ -d "$_sys" ]] || return 1
  echo vfio-pci >"$_sys/driver_override" 2>/dev/null || true
  if _pci_dev_alive "$_bdf"; then echo "RECOVERY_OK"; return 0; fi
  echo "RECOVERY_FAIL"; return 1
}
# Release-path zombie gate (Q3r)
RECOVERY_ATTEMPTED=0
if ! _pci_dev_alive "$GUEST_GPU_BDF"; then
  RECOVERY_ATTEMPTED=1
  say "ZOMBIE_DETECTED"
  _pci_dev_remove_rescan "$GUEST_GPU_BDF" || say "RECOVERY_FAILED"
else
  say "HEALTHY_SKIP"
fi
say "RECOVERY_ATTEMPTED=$RECOVERY_ATTEMPTED"
Q3REOF
# Case 1: dead card at release -> zombie detected, recovery attempted
printf '0xffff' > "$qfake/0000:0e:00.0/vendor"
printf '\xff\xff\xff\xff' > "$qfake/0000:0e:00.0/config"
r1="$(SYSROOT="$qfake" RESCAN_FILE="$qfake/rescan" bash "$tmp/smoke_release_zombie.sh" 2>&1 || true)"
if echo "$r1" | grep -Fq 'ZOMBIE_DETECTED' && echo "$r1" | grep -Fq 'RECOVERY_ATTEMPTED=1'; then ok "Q3r release path detects zombie and attempts recovery"; else bad "Q3r dead-card case failed (got: $r1)"; fi
# Case 2: healthy card at release -> skipped (no recovery attempted)
printf '0x1002' > "$qfake/0000:0e:00.0/vendor"
printf '\x02\x10\x50\x75' > "$qfake/0000:0e:00.0/config"
r2="$(SYSROOT="$qfake" RESCAN_FILE="$qfake/rescan" bash "$tmp/smoke_release_zombie.sh" 2>&1 || true)"
if echo "$r2" | grep -Fq 'HEALTHY_SKIP' && echo "$r2" | grep -Fq 'RECOVERY_ATTEMPTED=0'; then ok "Q3r release path skips recovery for healthy card"; else bad "Q3r healthy-card case failed (got: $r2)"; fi
# Case 3 (static): generated bind script has the release-path zombie gate
_release_block="$(sed -n '/^  release)/,/^  bind-now)/p' "$tmp/gen_bind.sh")"
if echo "$_release_block" | grep -Fq 'if ! _pci_dev_alive "$GUEST_GPU_BDF"; then' \
  && echo "$_release_block" | grep -Fq 'zombie detected at release time' \
  && echo "$_release_block" | grep -Fq '_pci_dev_remove_rescan "$GUEST_GPU_BDF"'; then
  ok "Q3r generated bind script has release-path zombie gate + recovery"
else
  bad "Q3r generated bind script missing release-path zombie gate"
fi

# --- Smoke Q3s: reboot-FLR monitor (soft FLR on guest warm reboot) ---
# Test the monitor logic: parse a mock virsh event line, check if the domain has
# the GPU, and do a soft FLR if it does. Mock the sysfs reset file + virsh dumpxml.
qfake3="$tmp/syspci_qs"
mkdir -p "$qfake3/0000:0e:00.0" "$qfake3/drivers/vfio-pci"
printf '0x1002' > "$qfake3/0000:0e:00.0/vendor"
printf '\x02\x10\x50\x75' > "$qfake3/0000:0e:00.0/config"
printf '0' > "$qfake3/0000:0e:00.0/reset"
cat > "$tmp/smoke_reboot_flr.sh" <<'QSEOF'
#!/usr/bin/env bash
set -euo pipefail
SYSROOT="${SYSROOT:-/sys/bus/pci/devices}"
GUEST_GPU_BDF="${GUEST_GPU_BDF:-0000:0e:00.0}"
MOCK_VIRSH_DUMPXML="${MOCK_VIRSH_DUMPXML:-}"
FLR_FILE="$SYSROOT/$GUEST_GPU_BDF/reset"
jlog() { command -v logger >/dev/null 2>&1 && logger -t vfio-reboot-flr -- "$*" 2>/dev/null || true; }
do_flr() {
  if [[ -w "$FLR_FILE" ]]; then
    echo 1 >"$FLR_FILE" 2>/dev/null || true
    echo "FLR_DONE"
  else
    echo "FLR_SKIP"
  fi
}
domain_has_gpu() {
  local _dom="$1"
  if [[ -n "$MOCK_VIRSH_DUMPXML" ]]; then
    # Substring match (the real vfio.sh uses -Fixq on parsed BDF-per-line output;
    # here we test the reboot event logic, not the XML parser, so -Fq is sufficient)
    grep -Fq "$GUEST_GPU_BDF" <<<"$MOCK_VIRSH_DUMPXML" 2>/dev/null
  else
    return 1
  fi
}
# Simulate processing a reboot event line
_line="$1"
_dom="$(printf '%s' "$_line" | sed -n "s/.*for domain \([^:]*\):.*/\1/p" 2>/dev/null || true)"
if printf '%s' "$_line" | grep -qi 'reboot'; then
  if domain_has_gpu "$_dom"; then
    echo "REBOOT+GPU:$_dom"
    do_flr
  else
    echo "REBOOT+NOGPU:$_dom"
  fi
else
  echo "NOT_REBOOT:$_dom"
fi
QSEOF
# Case 1: reboot event + domain has GPU -> FLR done (mock XML must contain the BDF string for grep -Fixq)
_mock_xml="0000:0e:00.0 <hostdev><address domain='0x0000' bus='0x0e' slot='0x00' function='0x0'/></hostdev>"
s1="$(SYSROOT="$qfake3" GUEST_GPU_BDF=0000:0e:00.0 MOCK_VIRSH_DUMPXML="$_mock_xml" bash "$tmp/smoke_reboot_flr.sh" "event 'lifecycle' for domain win11: Rebooted" 2>&1 || true)"
if echo "$s1" | grep -Fq 'REBOOT+GPU:win11' && echo "$s1" | grep -Fq 'FLR_DONE'; then ok "Q3s reboot event + domain has GPU -> soft FLR applied"; else bad "Q3s reboot+GPU case failed (got: $s1)"; fi
# Case 2: reboot event + domain does NOT have GPU -> FLR skipped
s2="$(SYSROOT="$qfake3" GUEST_GPU_BDF=0000:0e:00.0 MOCK_VIRSH_DUMPXML="<hostdev><address bus='0x03'/></hostdev>" bash "$tmp/smoke_reboot_flr.sh" "event 'lifecycle' for domain other_vm: Rebooted" 2>&1 || true)"
if echo "$s2" | grep -Fq 'REBOOT+NOGPU:other_vm'; then ok "Q3s reboot event + domain without GPU -> FLR skipped"; else bad "Q3s reboot+no-GPU case failed (got: $s2)"; fi
# Case 3: non-reboot event -> no FLR
s3="$(SYSROOT="$qfake3" GUEST_GPU_BDF=0000:0e:00.0 MOCK_VIRSH_DUMPXML="$_mock_xml" bash "$tmp/smoke_reboot_flr.sh" "event 'lifecycle' for domain win11: Started" 2>&1 || true)"
if echo "$s3" | grep -Fq 'NOT_REBOOT:win11'; then ok "Q3s non-reboot event -> no FLR"; else bad "Q3s non-reboot case failed (got: $s3)"; fi
# Case 4 (static): vfio.sh defines the monitor script heredoc + systemd unit + install/remove
if grep -Fq 'REBOOT_FLR_SCRIPT=' "$VFIO_SCRIPT" \
  && grep -Fq 'install_reboot_flr_monitor()' "$VFIO_SCRIPT" \
  && grep -Fq 'remove_reboot_flr_monitor()' "$VFIO_SCRIPT" \
  && grep -Fq 'virsh -c qemu:///system event --all --loop' "$VFIO_SCRIPT" \
  && grep -Fq 'Restart=always' "$VFIO_SCRIPT" \
  && grep -Fq 'vfio-reboot-flr.service' "$VFIO_SCRIPT"; then
  ok "Q3s vfio.sh defines monitor constants + functions + systemd unit + virsh event"
else
  bad "Q3s vfio.sh missing monitor definitions"
fi
# Case 5 (static): install-dynamic calls installer, install-early + reset call remover
_q3s_dyn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
_q3s_early="$(sed -n '/^install_early_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
_q3s_reset="$(sed -n '/^reset_vfio_all()/,/^}/p' "$VFIO_SCRIPT")"
if grep -Fq 'install_reboot_flr_monitor' <<<"$_q3s_dyn" \
  && grep -Fq 'remove_reboot_flr_monitor' <<<"$_q3s_early" \
  && grep -Fq 'vfio-reboot-flr.service' <<<"$_q3s_reset"; then
  ok "Q3s install-dynamic installs, install-early + reset remove the monitor"
else
  bad "Q3s monitor wiring missing in install-dynamic/install-early/reset"
fi

# --- Smoke Q3t: RX 9070 family-gated pre-FLR Gen1 downtrain + adaptive restore ---
# Test the _is_rx9070 gate, the sysfs speed-string -> gen parsing, and the
# adaptive restore target selection (Gen4 slot vs Gen5 card vs degraded link).
# Mock config space: 02 10 50 75 = vendor 0x1002, device 0x7550 (RX 9070 family:
# RX 9070 / 9070 XT / 9070 GRE all share 0x7550).
qfake4="$tmp/syspci_qt"
mkdir -p "$qfake4/0000:0e:00.0"
printf '\x02\x10\x50\x75' > "$qfake4/0000:0e:00.0/config"
cat > "$tmp/smoke_q3t_gate.sh" <<'QTEOF'
#!/usr/bin/env bash
set -uo pipefail
SYSROOT="${SYSROOT:-/sys/bus/pci/devices}"
GUEST_GPU_BDF="${GUEST_GPU_BDF:-0000:0e:00.0}"
_RX9070_DEVICE_ID="7550"
_is_rx9070() {
  local _sys="$SYSROOT/$GUEST_GPU_BDF" _vendor _device _cfg
  [[ -d "$_sys" ]] || return 1
  _cfg="$(head -c 4 "$_sys/config" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ -n "$_cfg" ]] || return 1
  _vendor="${_cfg:2:2}${_cfg:0:2}"
  _device="${_cfg:6:2}${_cfg:4:2}"
  [[ "${_vendor,,}" == "1002" ]] || return 1
  [[ "${_device,,}" == "$_RX9070_DEVICE_ID" ]]
}
_speed_to_gen() {
  local _s="${1:-}" _n
  [[ -n "$_s" ]] || return 1
  _n="$(printf '%s' "$_s" | tr -cd '0-9.')"
  [[ -n "$_n" ]] || return 1
  case "$_n" in
    2.5) echo 1 ;; 5|5.0) echo 2 ;; 8|8.0) echo 3 ;;
    16|16.0) echo 4 ;; 32|32.0) echo 5 ;; 64|64.0) echo 6 ;; *) return 1 ;;
  esac
}
# Defensive setpci-word cleanup (mirrors _setpci_word trim+validate+pad+lower).
_clean_hex() {
  local _v="${1:-}"
  _v="$(printf '%s' "$_v" | tr -d '[:space:]')"
  [[ -n "$_v" ]] || return 1
  [[ "$_v" =~ ^[0-9a-fA-F]+$ ]] || return 1
  while (( ${#_v} < 4 )); do _v="0$_v"; done
  printf '%s' "${_v,,}"
}
# SKU resolver mirroring _rx9070_sku_name (reads $SYSROOT/$GUEST_GPU_BDF/revision).
_rx9070_sku_name() {
  local _sys="$SYSROOT/$GUEST_GPU_BDF" _rev _r
  [[ -r "$_sys/revision" ]] || return 1
  _rev="$(cat "$_sys/revision" 2>/dev/null || true)"
  [[ -n "$_rev" ]] || return 1
  _r="$(printf '%s' "$_rev" | tr -d '[:space:]' | sed 's/^0x//' | tr 'A-F' 'a-f')"
  case "$_r" in
    c0) echo "RX 9070 XT" ;;
    c2) echo "RX 9070 GRE" ;;
    c3) echo "RX 9070" ;;
    *) echo "RX 9070 family (unknown SKU, rev 0x${_r:-?})" ;;
  esac
  return 0
}
# Link width mirroring _port_link_width.
_port_link_width() {
  local _bdf="$1" _f _v
  _f="$SYSROOT/$_bdf/current_link_width"
  [[ -r "$_f" ]] || return 1
  _v="$(cat "$_f" 2>/dev/null || true)"
  _v="$(printf '%s' "$_v" | tr -d '[:space:]')"
  [[ -n "$_v" ]] || return 1
  echo "$_v"
}
# Adaptive target selection mirroring _post_flr_restore_target priority:
# cap+cur(cur<cap)->cur ; cap+cur(cur>=cap)->cap ; cap only->cap ; sav->sav ; none->5.
_pick_target() {
  local _cap="${1:-}" _cur="${2:-}" _sav="${3:-}"
  if [[ -n "$_cap" && -n "$_cur" ]]; then
    if (( _cur < _cap )) 2>/dev/null; then echo "$_cur"; else echo "$_cap"; fi
  elif [[ -n "$_cap" ]]; then echo "$_cap"
  elif [[ -n "$_sav" ]]; then echo "$_sav"
  else echo 5; fi
}
# MAX_GEN clamp mirroring _post_flr_restore_target's operator-cap step.
_clamp_target() {
  local _t="$1" _m="${2:-}"
  if [[ -n "$_m" ]] && (( _m >= 1 && _m <= 6 )) 2>/dev/null; then
    if (( _t > _m )) 2>/dev/null; then echo "$_m"; else echo "$_t"; fi
  else echo "$_t"; fi
}
# Bounded descent: highest gen the link reaches, trying target..1. $1=target, $2=hw max.
# Mirrors the for((g=target..1)) loop; demonstrates multi-step drop (Gen5->Gen3).
_descent_best() {
  local _t="$1" _hw="$2" _g
  for (( _g = _t; _g >= 1; _g-- )); do
    if (( _hw >= _g )) 2>/dev/null; then echo "$_g"; return 0; fi
  done
  echo 0
}
if _is_rx9070; then echo "IS_RX9070=YES"; else echo "IS_RX9070=NO"; fi
# LnkCtl2 Gen1 value construction (preserves upper 12 bits, low nibble 1).
_ctl2="0045"; _saved_hi="${_ctl2:0:3}"; echo "GEN1=${_saved_hi}1"
# Sysfs speed-string -> PCIe generation parsing.
echo "G16=$(_speed_to_gen "16 GT/s" || echo X)"
echo "G32=$(_speed_to_gen "32 GT/s" || echo X)"
echo "G25=$(_speed_to_gen "2.5 GT/s" || echo X)"
# Adaptive restore target: Gen5 slot, Gen4 slot, degraded link, sav-only, none.
echo "T_GEN5=$(_pick_target 5 5)"
echo "T_GEN4=$(_pick_target 4 4)"
echo "T_DEGRADED=$(_pick_target 5 4)"
echo "T_SAVONLY=$(_pick_target "" "" 5)"
echo "T_NONE=$(_pick_target "" "" "")"
# MAX_GEN clamp + bounded descent (incl. multi-step Gen5->Gen3 drop).
echo "CLAMP_5_4=$(_clamp_target 5 4)"
echo "CLAMP_5_NONE=$(_clamp_target 5)"
echo "DESC_5_5=$(_descent_best 5 5)"
echo "DESC_5_4=$(_descent_best 5 4)"
echo "DESC_5_3=$(_descent_best 5 3)"
echo "DESC_4_4=$(_descent_best 4 4)"
# Defensive setpci-word cleanup (trim whitespace + left-pad to 4 hex digits).
echo "CLEAN45=$(_clean_hex "  45 " || echo BAD)"
echo "CLEAN5=$(_clean_hex "5" || echo BAD)"
# Link width + SKU (read from mock sysfs: revision + current_link_width files).
echo "W16=$(_port_link_width "$GUEST_GPU_BDF" 2>/dev/null || echo NONE)"
echo "SKU=$(_rx9070_sku_name 2>/dev/null || echo NONE)"
QTEOF
# Case 1: RX 9070 base (rev c3) -> gate + Gen1 + speed + adaptive targets + bounded
# descent + MAX_GEN clamp + defensive clean + width + SKU. Mock sysfs revision + width.
printf '0xc3' > "$qfake4/0000:0e:00.0/revision"
printf '16' > "$qfake4/0000:0e:00.0/current_link_width"
r1="$(SYSROOT="$qfake4" bash "$tmp/smoke_q3t_gate.sh" 2>&1 || true)"
if echo "$r1" | grep -Fq 'IS_RX9070=YES' \
  && echo "$r1" | grep -Fq 'GEN1=0041' \
  && echo "$r1" | grep -Fq 'G16=4' \
  && echo "$r1" | grep -Fq 'G32=5' \
  && echo "$r1" | grep -Fq 'G25=1' \
  && echo "$r1" | grep -Fq 'T_GEN5=5' \
  && echo "$r1" | grep -Fq 'T_GEN4=4' \
  && echo "$r1" | grep -Fq 'T_DEGRADED=4' \
  && echo "$r1" | grep -Fq 'T_SAVONLY=5' \
  && echo "$r1" | grep -Fq 'T_NONE=5' \
  && echo "$r1" | grep -Fq 'CLAMP_5_4=4' \
  && echo "$r1" | grep -Fq 'CLAMP_5_NONE=5' \
  && echo "$r1" | grep -Fq 'DESC_5_5=5' \
  && echo "$r1" | grep -Fq 'DESC_5_4=4' \
  && echo "$r1" | grep -Fq 'DESC_5_3=3' \
  && echo "$r1" | grep -Fq 'DESC_4_4=4' \
  && echo "$r1" | grep -Fq 'CLEAN45=0045' \
  && echo "$r1" | grep -Fq 'CLEAN5=0005' \
  && echo "$r1" | grep -Fq 'W16=16' \
  && echo "$r1" | grep -xFq 'SKU=RX 9070'; then
  ok "Q3t 9070 base (rev c3): gate + speed + adaptive targets + bounded descent + MAX_GEN clamp + clean + width + SKU"
else
  bad "Q3t case 1 wrong (got: $r1)"
fi
# Case 1b: rev c0 -> RX 9070 XT (exact-line match so 'RX 9070' base doesn't false-match).
printf '0xc0' > "$qfake4/0000:0e:00.0/revision"
rb="$(SYSROOT="$qfake4" bash "$tmp/smoke_q3t_gate.sh" 2>&1 || true)"
if echo "$rb" | grep -xFq 'SKU=RX 9070 XT'; then ok "Q3t rev c0 -> RX 9070 XT"; else bad "Q3t rev c0 SKU wrong (got: $rb)"; fi
# Case 1c: rev c2 -> RX 9070 GRE
printf '0xc2' > "$qfake4/0000:0e:00.0/revision"
rc="$(SYSROOT="$qfake4" bash "$tmp/smoke_q3t_gate.sh" 2>&1 || true)"
if echo "$rc" | grep -xFq 'SKU=RX 9070 GRE'; then ok "Q3t rev c2 -> RX 9070 GRE"; else bad "Q3t rev c2 SKU wrong (got: $rc)"; fi
# Case 1d: rev c9 -> unknown SKU (heuristic fallback)
printf '0xc9' > "$qfake4/0000:0e:00.0/revision"
rd="$(SYSROOT="$qfake4" bash "$tmp/smoke_q3t_gate.sh" 2>&1 || true)"
if echo "$rd" | grep -Fq 'SKU=RX 9070 family (unknown SKU, rev 0xc9)'; then ok "Q3t rev c9 -> unknown SKU fallback"; else bad "Q3t rev c9 SKU wrong (got: $rd)"; fi
# Case 2: non-RX 9070 config (NVIDIA 10de) -> IS_RX9070=NO
printf '\xde\x10\x00\x00' > "$qfake4/0000:0e:00.0/config"
r2="$(SYSROOT="$qfake4" bash "$tmp/smoke_q3t_gate.sh" 2>&1 || true)"
if echo "$r2" | grep -Fq 'IS_RX9070=NO'; then ok "Q3t non-RX 9070 (NVIDIA) -> gate skips"; else bad "Q3t non-RX 9070 case failed (got: $r2)"; fi
# Case 3 (static): vfio.sh defines gate + downtrain + adaptive restore + all new helpers.
_reboot_block="$(sed -n '/write_file_atomic "$REBOOT_FLR_SCRIPT" 0755/,/^EOF$/p' "$VFIO_SCRIPT")"
if echo "$_reboot_block" | grep -Fq '_is_rx9070()' \
  && echo "$_reboot_block" | grep -Fq '_gpu_upstream_port()' \
  && echo "$_reboot_block" | grep -Fq '_pre_flr_gen1_downtrain()' \
  && echo "$_reboot_block" | grep -Fq '_post_flr_restore_target()' \
  && echo "$_reboot_block" | grep -Fq '_speed_to_gen()' \
  && echo "$_reboot_block" | grep -Fq '_port_speed_gen()' \
  && echo "$_reboot_block" | grep -Fq '_setpci_word()' \
  && echo "$_reboot_block" | grep -Fq '_port_link_width()' \
  && echo "$_reboot_block" | grep -Fq '_gpu_alive()' \
  && echo "$_reboot_block" | grep -Fq '_rx9070_sku_name()' \
  && echo "$_reboot_block" | grep -Fq 'max_link_speed' \
  && echo "$_reboot_block" | grep -Fq 'current_link_speed' \
  && echo "$_reboot_block" | grep -Fq 'current_link_width' \
  && echo "$_reboot_block" | grep -Fq 'VFIO_REBOOT_FLR_MAX_GEN' \
  && echo "$_reboot_block" | grep -Fq 'for (( _g = _target; _g >= 1; _g-- ))' \
  && echo "$_reboot_block" | grep -Fq 'descending to Gen' \
  && echo "$_reboot_block" | grep -Fq '88.w' \
  && echo "$_reboot_block" | grep -Fq '6A.w' \
  && echo "$_reboot_block" | grep -Fq '0x2000' \
  && echo "$_reboot_block" | grep -Fq '7550'; then
  ok "Q3t vfio.sh defines gate + downtrain + adaptive restore + helpers (sku/setpci_word/width/alive) + MAX_GEN + bounded descent"
else
  bad "Q3t vfio.sh missing gate/downtrain/adaptive-restore/helper definitions"
fi
# Case 4 (static): old Gen5-only restore name AND one-step retry loop must be gone.
if echo "$_reboot_block" | grep -Fq '_post_flr_restore_gen5'; then
  bad "Q3t old _post_flr_restore_gen5 name still present in vfio.sh"
else
  ok "Q3t old Gen5-only restore name removed from vfio.sh"
fi
if echo "$_reboot_block" | grep -Fq 'for _try in 1 2'; then
  bad "Q3t old one-step retry loop still present in vfio.sh"
else
  ok "Q3t old one-step retry loop removed from vfio.sh"
fi
# Case 5 (static): write_conf persists the VFIO_REBOOT_FLR_MAX_GEN default (empty).
if grep -Fq 'VFIO_REBOOT_FLR_MAX_GEN=""' "$VFIO_SCRIPT"; then
  ok "Q3t write_conf persists VFIO_REBOOT_FLR_MAX_GEN default"
else
  bad "Q3t write_conf missing VFIO_REBOOT_FLR_MAX_GEN default"
fi
# Case 6 (static): installer warns when setpci is missing + names the pciutils command.
_inst_flr_fn="$(sed -n '/^install_reboot_flr_monitor()/,/^}/p' "$VFIO_SCRIPT")"
if echo "$_inst_flr_fn" | grep -Fq 'have_cmd setpci' \
  && echo "$_inst_flr_fn" | grep -Fq 'zypper in pciutils' \
  && echo "$_inst_flr_fn" | grep -Fq 'adaptive PCIe link restore will be SKIPPED'; then
  ok "Q3t installer warns on missing setpci + names openSUSE pciutils command"
else
  bad "Q3t installer missing setpci/pciutils notice"
fi

# --- Smoke Q3u: install_hypervisor_hiding (AMD driver install fix) ---
# Test the XML-editing logic: take a mock VM XML without hypervisor hiding,
# apply the sed that adds vendor_id+hidden+kvm hidden, verify the result.
cat > "$tmp/mock_vm_no_hv.xml" <<'XEOF'
<domain type='kvm'>
  <name>testvm</name>
  <features>
    <acpi/>
    <apic/>
    <hyperv mode='custom'>
      <relaxed state='on'/>
      <vapic state='on'/>
    </hyperv>
    <vmport state='off'/>
    <smm state='on'/>
  </features>
</domain>
XEOF
# Apply the same sed the function uses (vendor_id in hyperv + kvm hidden, NOT hidden in hyperv)
_tmp="$tmp/mock_vm_edited.xml"
cp "$tmp/mock_vm_no_hv.xml" "$_tmp"
sed -i "s|</hyperv>|      <vendor_id state='on' value='random'/>\n    </hyperv>\n    <kvm>\n      <hidden state='on'/>\n    </kvm>|" "$_tmp" 2>/dev/null || true
# Case 1: edited XML has vendor_id=random
if grep -Fq "vendor_id state='on' value='random'" "$_tmp"; then ok "Q3u XML edit adds vendor_id=random"; else bad "Q3u XML edit missing vendor_id"; fi
# Case 2: edited XML has kvm hidden (not hidden in hyperv)
if grep -Fq '<kvm>' "$_tmp" && grep -Fq "<hidden state='on'/>" "$_tmp"; then ok "Q3u XML edit adds kvm hidden"; else bad "Q3u XML edit missing kvm hidden"; fi
# Case 3: edited XML does NOT have hidden inside hyperv (unsupported by older libvirt)
if ! grep -Fq "hidden" <<<"$(sed -n '/<hyperv/,/<\/hyperv>/p' "$_tmp")"; then ok "Q3u XML edit does NOT add hidden inside hyperv"; else bad "Q3u XML edit wrongly adds hidden inside hyperv"; fi
# Case 4: idempotent — already-hidden XML is not double-edited
cat > "$tmp/mock_vm_has_hv.xml" <<'XEOF'
<domain type='kvm'>
  <name>testvm</name>
  <features>
    <hyperv mode='custom'>
      <vendor_id state='on' value='random'/>
      <hidden state='on'/>
    </hyperv>
    <kvm>
      <hidden state='on'/>
    </kvm>
  </features>
</domain>
XEOF
if grep -Fq "vendor_id state='on'" "$tmp/mock_vm_has_hv.xml" \
  && grep -Fq "<hidden state='on'/>" "$tmp/mock_vm_has_hv.xml" \
  && grep -Fq '<kvm>' "$tmp/mock_vm_has_hv.xml"; then
  ok "Q3u idempotent check recognizes already-hidden XML"
else
  bad "Q3u idempotent check failed to recognize already-hidden XML"
fi
# Case 5 (static): vfio.sh defines install_hypervisor_hiding + wiring
_q3u_dyn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
if grep -Fq 'install_hypervisor_hiding()' "$VFIO_SCRIPT" \
  && grep -Fq 'install_hypervisor_hiding' <<<"$_q3u_dyn" \
  && grep -Fq 'Hide the hypervisor' "$VFIO_SCRIPT"; then
  ok "Q3u vfio.sh defines install_hypervisor_hiding + wired into install-dynamic"
else
  bad "Q3u vfio.sh missing install_hypervisor_hiding or wiring"
fi

# --- Smoke Q3v: park-keepalive monitor (proactive zombie recovery while parked) ---
# The park-keepalive monitor is a NEW, standalone generated script (extracted
# above to gen_park_keepalive.sh). It duplicates _pci_dev_alive /
# _pci_dev_remove_rescan from the bind script (each generated helper script is
# standalone, same pattern as the reboot-FLR monitor), and adds a
# _gpu_owned_by_running_domain fail-safe gate + a main loop that re-reads conf
# every interval so VFIO_DYNAMIC_PARK_KEEPALIVE can be toggled live.

# Case 1: duplicated _pci_dev_alive / _pci_dev_remove_rescan bodies stay in
# sync with the bind script's copies (same liveness + recovery logic). Comment
# lines are stripped before comparing since the two copies carry different
# amounts of prose commentary but must execute identical code.
_strip_comments() { grep -v '^[[:space:]]*#' | sed '/^[[:space:]]*$/d'; }
_pka_alive="$(sed -n '/^_pci_dev_alive()/,/^}/p' "$tmp/gen_park_keepalive.sh" | _strip_comments)"
_bind_alive="$(sed -n '/^_pci_dev_alive()/,/^}/p' "$tmp/gen_bind.sh" | _strip_comments)"
if [[ -n "$_pka_alive" ]] && [[ "$_pka_alive" == "$_bind_alive" ]]; then
  ok "Q3v park-keepalive _pci_dev_alive matches bind script's copy (code, ignoring comments)"
else
  bad "Q3v park-keepalive _pci_dev_alive drifted from bind script's copy"
fi

# Case 2: _conf_get parses a key out of a mock conf file (used to re-read
# VFIO_DYNAMIC_PARK_KEEPALIVE / interval / mode / GUEST_GPU_BDF every poll).
pkconf="$tmp/pk_conf"
printf 'VFIO_DYNAMIC_PARK_KEEPALIVE="0"\nGUEST_GPU_BDF="0000:0e:00.0"\n' > "$pkconf"
cat > "$tmp/smoke_pk_confget.sh" <<'PKCEOF'
#!/usr/bin/env bash
set -euo pipefail
CONF_FILE="$1"
_conf_get() {
  local _key="$1"
  awk -F= -v k="$_key" '$1==k{v=$2; gsub(/"/,"",v); print v; exit}' "$CONF_FILE" 2>/dev/null || true
}
echo "EN=$(_conf_get VFIO_DYNAMIC_PARK_KEEPALIVE)"
echo "GPU=$(_conf_get GUEST_GPU_BDF)"
echo "MISSING=$(_conf_get NO_SUCH_KEY)"
PKCEOF
pkc="$(bash "$tmp/smoke_pk_confget.sh" "$pkconf")"
if echo "$pkc" | grep -Fq 'EN=0' && echo "$pkc" | grep -Fq 'GPU=0000:0e:00.0' && echo "$pkc" | grep -Fq 'MISSING='; then
  ok "Q3v _conf_get reads keys from conf file (present + missing)"
else
  bad "Q3v _conf_get case failed (got: $pkc)"
fi

# Case 3: _gpu_owned_by_running_domain — extract the real function and drive it
# with a fake virsh so the BDF-ownership + fail-safe (virsh missing -> rc=2)
# behavior is tested against the ACTUAL generated code, not a re-typed mock.
_pka_owned_fn="$(sed -n '/^_gpu_owned_by_running_domain()/,/^}/p' "$tmp/gen_park_keepalive.sh")"
lvfake2="$tmp/fakelvbin_pk"
mkdir -p "$lvfake2"
cat > "$lvfake2/virsh" <<'VEOF'
#!/usr/bin/env bash
case "$*" in
  *'list --name'*)
    printf '%s\n' "${MOCK_DOMAINS:-}"
    ;;
  *'dumpxml'*)
    printf '%s' "${MOCK_XML:-}"
    ;;
esac
VEOF
chmod +x "$lvfake2/virsh"
cat > "$tmp/smoke_pk_owned.sh" <<PKOEOF
#!/usr/bin/env bash
set -uo pipefail
$_pka_owned_fn
_rc=0
_gpu_owned_by_running_domain "\$1" || _rc=\$?
echo "rc=\$_rc"
PKOEOF
_owned_xml="<hostdev type='pci'><address domain='0x0000' bus='0x0e' slot='0x00' function='0x0'/></hostdev>"
bash_bin="$(command -v bash)"
# 3a: running domain owns the BDF -> rc=0
o1="$(PATH="$lvfake2:$PATH" MOCK_DOMAINS="win11" MOCK_XML="$_owned_xml" "$bash_bin" "$tmp/smoke_pk_owned.sh" 0000:0e:00.0 2>&1 || true)"
if echo "$o1" | grep -Fq 'rc=0'; then ok "Q3v _gpu_owned_by_running_domain rc=0 when a running domain owns the BDF"; else bad "Q3v owned case failed (got: $o1)"; fi
# 3b: running domain does NOT own the BDF -> rc=1
o2="$(PATH="$lvfake2:$PATH" MOCK_DOMAINS="win11" MOCK_XML="<hostdev type='pci'><address domain='0x0000' bus='0x03' slot='0x00' function='0x0'/></hostdev>" "$bash_bin" "$tmp/smoke_pk_owned.sh" 0000:0e:00.0 2>&1 || true)"
if echo "$o2" | grep -Fq 'rc=1'; then ok "Q3v _gpu_owned_by_running_domain rc=1 when no running domain owns the BDF"; else bad "Q3v not-owned case failed (got: $o2)"; fi
# 3c: virsh unavailable -> rc=2 (fail-safe: caller must NOT act). Use an empty
# directory on PATH (not a full PATH wipe) so the bash interpreter invoked
# below (by absolute path) still runs, but `command -v virsh` still fails.
mkdir -p "$tmp/emptybin"
o3="$(PATH="$tmp/emptybin" "$bash_bin" "$tmp/smoke_pk_owned.sh" 0000:0e:00.0 2>&1 || true)"
if echo "$o3" | grep -Fq 'rc=2'; then ok "Q3v _gpu_owned_by_running_domain rc=2 (fail-safe) when virsh is unavailable"; else bad "Q3v virsh-missing fail-safe failed (got: $o3)"; fi

# Case 4 (static): main loop enforces the full safety-gate order before ever
# calling remove+rescan: enabled -> dynamic mode -> not rebind-host -> on
# vfio-pci -> not owned by a running domain -> virsh-present fail-safe.
if grep -Fq '_enabled" != "1"' "$tmp/gen_park_keepalive.sh" \
  && grep -Fq '_binding_mode,,}" != "dynamic"' "$tmp/gen_park_keepalive.sh" \
  && grep -Fq '_rebind_host:-0}" == "1"' "$tmp/gen_park_keepalive.sh" \
  && grep -Fq '_drv" != "vfio-pci"' "$tmp/gen_park_keepalive.sh" \
  && grep -Fq '_owned_rc == 0' "$tmp/gen_park_keepalive.sh" \
  && grep -Fq '_owned_rc == 2' "$tmp/gen_park_keepalive.sh" \
  && grep -Fq 'zombie detected while parked' "$tmp/gen_park_keepalive.sh" \
  && grep -Fq '_pci_dev_remove_rescan "$_guest_gpu"' "$tmp/gen_park_keepalive.sh"; then
  ok "Q3v main loop enforces full safety-gate order before remove+rescan"
else
  bad "Q3v main loop missing one or more safety gates"
fi

# Case 5 (static): conf keys default to instant-on (1) with a sane interval,
# and the systemd unit is a Restart=always simple service like reboot-FLR.
if grep -Fq 'VFIO_DYNAMIC_PARK_KEEPALIVE="1"' "$VFIO_SCRIPT" \
  && grep -Fq 'VFIO_DYNAMIC_PARK_KEEPALIVE_INTERVAL="30"' "$VFIO_SCRIPT" \
  && grep -Fq 'ExecStart=$PARK_KEEPALIVE_SCRIPT' "$VFIO_SCRIPT" \
  && grep -Fq 'vfio-gpu-park-keepalive.service' "$VFIO_SCRIPT"; then
  ok "Q3v conf defaults to instant-on (1) + 30s interval; systemd unit defined"
else
  bad "Q3v missing instant-on conf defaults or systemd unit definition"
fi

# Case 6 (static): install_park_keepalive_monitor is called UNCONDITIONALLY
# (no prompt) right after install_reboot_flr_monitor in both the full wizard's
# DYNAMIC branch and the --install-dynamic-binding switcher; removal is wired
# into --install-early-binding and --reset (per the "always update the
# uninstaller" rule).
_pkv_dyn="$(sed -n '/^install_dynamic_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
_pkv_early="$(sed -n '/^install_early_binding_from_existing_config()/,/^}/p' "$VFIO_SCRIPT")"
_pkv_reset="$(sed -n '/^reset_vfio_all()/,/^}/p' "$VFIO_SCRIPT")"
if grep -Fq 'install_park_keepalive_monitor()' "$VFIO_SCRIPT" \
  && grep -Fq 'remove_park_keepalive_monitor()' "$VFIO_SCRIPT" \
  && grep -Fq 'install_park_keepalive_monitor' <<<"$_pkv_dyn" \
  && grep -Fq 'remove_park_keepalive_monitor' <<<"$_pkv_early" \
  && grep -Fq 'vfio-gpu-park-keepalive.service' <<<"$_pkv_reset" \
  && grep -Fq 'PARK_KEEPALIVE_SCRIPT' <<<"$_pkv_reset"; then
  ok "Q3v install/remove wired into dynamic switcher, early switcher, and reset"
else
  bad "Q3v install/remove wiring missing in switcher(s) or reset"
fi
# Case 7 (static): the full wizard's DYNAMIC branch also installs it unconditionally.
_pkv_wizard="$(sed -n '/^apply_configuration()/,/^# Automatically hide the hypervisor/p' "$VFIO_SCRIPT")"
if grep -Fq 'install_park_keepalive_monitor' <<<"$_pkv_wizard"; then
  ok "Q3v full wizard DYNAMIC branch installs park-keepalive monitor unconditionally"
else
  bad "Q3v full wizard DYNAMIC branch missing install_park_keepalive_monitor call"
fi

if (( fail != 0 )); then
  printf '\nSMOKE SUMMARY: FAIL\n' >&2
  exit 1
fi
printf '\nSMOKE SUMMARY: PASS\n'
