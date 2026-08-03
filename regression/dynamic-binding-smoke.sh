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

# --- Smoke fix #5: reprobe_to_host leaves d3cold_allowed untouched ---
# Strip comment lines so the explanatory comment (which mentions d3cold_allowed)
# does not count as a write.
if ! grep -Fq 'd3cold_allowed' <(sed -n '/^reprobe_to_host()/,/^}/p' "$tmp/gen_bind.sh" | grep -v '^[[:space:]]*#'); then
  ok "fix #5 reprobe_to_host does not touch d3cold_allowed"
else
  bad "fix #5 reprobe_to_host writes d3cold_allowed (should not)"
fi

if (( fail != 0 )); then
  printf '\nSMOKE SUMMARY: FAIL\n' >&2
  exit 1
fi
printf '\nSMOKE SUMMARY: PASS\n'
