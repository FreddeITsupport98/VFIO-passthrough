#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

exit_code=0

run_step() {
  local name="$1"
  shift
  printf '\n[RUN] %s\n' "$name"
  if "$@"; then
    printf '[PASS] %s\n' "$name"
  else
    printf '[FAIL] %s\n' "$name" >&2
    exit_code=1
  fi
}

auto_chmod_scripts() {
  local script
  while IFS= read -r -d '' script; do
    chmod +x "$script" 2>/dev/null || true
  done < <(find "$PROJECT_ROOT/regression" -maxdepth 1 -type f -name '*.sh' -print0)
  chmod +x "$PROJECT_ROOT/vfio.sh" 2>/dev/null || true
}

printf 'Regression runner root: %s\n' "$PROJECT_ROOT"
auto_chmod_scripts

run_step "Bash syntax check (vfio.sh)" bash -n "$PROJECT_ROOT/vfio.sh"

if command -v shellcheck >/dev/null 2>&1; then
  run_step "Shellcheck (vfio.sh)" shellcheck "$PROJECT_ROOT/vfio.sh"
else
  printf '\n[WARN] shellcheck is not installed; skipping shellcheck step.\n'
fi

run_step "Openbox monitor regression" bash "$PROJECT_ROOT/regression/openbox-monitor-regression.sh"

if (( exit_code == 0 )); then
  printf '\nAll regression checks passed.\n'
else
  printf '\nOne or more regression checks failed.\n' >&2
fi
exit "$exit_code"
