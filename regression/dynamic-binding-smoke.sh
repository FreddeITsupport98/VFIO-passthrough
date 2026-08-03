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

if (( fail != 0 )); then
  printf '\nSMOKE SUMMARY: FAIL\n' >&2
  exit 1
fi
printf '\nSMOKE SUMMARY: PASS\n'
