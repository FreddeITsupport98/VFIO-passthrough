#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

exit_code=0
REGRESSION_SCRIPTS=()

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

discover_regression_scripts() {
  mapfile -d '' -t REGRESSION_SCRIPTS < <(
    find "$PROJECT_ROOT/regression" -maxdepth 1 -type f -name '*-regression.sh' -print0 | sort -z
  )
}

printf 'Regression runner root: %s\n' "$PROJECT_ROOT"
auto_chmod_scripts
discover_regression_scripts

run_step "Bash syntax check (vfio.sh)" bash -n "$PROJECT_ROOT/vfio.sh"
run_step "Bash syntax check (regression/script.sh)" bash -n "$PROJECT_ROOT/regression/script.sh"

if (( ${#REGRESSION_SCRIPTS[@]} > 0 )); then
  run_step "Bash syntax check (discovered regression scripts)" bash -n "${REGRESSION_SCRIPTS[@]}"
else
  printf '\n[WARN] No *-regression.sh files found under regression/.\n'
fi

if command -v shellcheck >/dev/null 2>&1; then
  if (( ${#REGRESSION_SCRIPTS[@]} > 0 )); then
    run_step "Shellcheck (vfio.sh + regression scripts)" \
      shellcheck "$PROJECT_ROOT/vfio.sh" "$PROJECT_ROOT/regression/script.sh" "${REGRESSION_SCRIPTS[@]}"
  else
    run_step "Shellcheck (vfio.sh + regression/script.sh)" \
      shellcheck "$PROJECT_ROOT/vfio.sh" "$PROJECT_ROOT/regression/script.sh"
  fi
else
  printf '\n[WARN] shellcheck is not installed; skipping shellcheck step.\n'
fi
if (( ${#REGRESSION_SCRIPTS[@]} > 0 )); then
  regression_script=""
  regression_name=""
  for regression_script in "${REGRESSION_SCRIPTS[@]}"; do
    regression_name="$(basename -- "$regression_script" .sh)"
    run_step "Regression (${regression_name})" bash "$regression_script"
  done
else
  printf '\n[WARN] No regression scripts were executed.\n'
fi

if (( exit_code == 0 )); then
  printf '\nAll regression checks passed.\n'
else
  printf '\nOne or more regression checks failed.\n' >&2
fi
exit "$exit_code"
