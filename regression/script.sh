#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

exit_code=0
REGRESSION_SCRIPTS=()
REGRESSION_SHELL_SCRIPTS=()

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
run_with_elevated_privileges() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return $?
  fi
  return 1
}

install_shellcheck_if_missing() {
  command -v shellcheck >/dev/null 2>&1 && return 0

  printf '\n[INFO] shellcheck is missing; attempting distro-aware install...\n'
  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    printf '[WARN] Not root and sudo is unavailable; cannot auto-install shellcheck.\n'
    return 1
  fi

  # Debian/Ubuntu and derivatives
  if command -v apt-get >/dev/null 2>&1; then
    if run_with_elevated_privileges apt-get -y install shellcheck; then
      command -v shellcheck >/dev/null 2>&1 && return 0
    fi
    if run_with_elevated_privileges apt-get update && run_with_elevated_privileges apt-get -y install shellcheck; then
      command -v shellcheck >/dev/null 2>&1 && return 0
    fi
  fi

  # Fedora/RHEL and derivatives
  if command -v dnf >/dev/null 2>&1; then
    if run_with_elevated_privileges dnf -y install ShellCheck || run_with_elevated_privileges dnf -y install shellcheck; then
      command -v shellcheck >/dev/null 2>&1 && return 0
    fi
  fi
  if command -v yum >/dev/null 2>&1; then
    if run_with_elevated_privileges yum -y install ShellCheck || run_with_elevated_privileges yum -y install shellcheck; then
      command -v shellcheck >/dev/null 2>&1 && return 0
    fi
  fi

  # openSUSE and derivatives
  if command -v zypper >/dev/null 2>&1; then
    if run_with_elevated_privileges zypper --non-interactive in ShellCheck || run_with_elevated_privileges zypper --non-interactive in shellcheck; then
      command -v shellcheck >/dev/null 2>&1 && return 0
    fi
  fi

  # Arch and derivatives
  if command -v pacman >/dev/null 2>&1; then
    if run_with_elevated_privileges pacman --noconfirm -S shellcheck; then
      command -v shellcheck >/dev/null 2>&1 && return 0
    fi
  fi

  # Alpine
  if command -v apk >/dev/null 2>&1; then
    if run_with_elevated_privileges apk add --no-cache shellcheck; then
      command -v shellcheck >/dev/null 2>&1 && return 0
    fi
  fi

  # Void Linux
  if command -v xbps-install >/dev/null 2>&1; then
    if run_with_elevated_privileges xbps-install -Sy shellcheck; then
      command -v shellcheck >/dev/null 2>&1 && return 0
    fi
  fi

  printf '[WARN] Automatic shellcheck installation failed.\n'
  printf '[WARN] Install manually using your package manager, then re-run regression/script.sh.\n'
  return 1
}

auto_chmod_scripts() {
  local script
  while IFS= read -r -d '' script; do
    chmod +x "$script" 2>/dev/null || true
  done < <(find "$PROJECT_ROOT/regression" -type f -name '*.sh' -print0)
  chmod +x "$PROJECT_ROOT/vfio.sh" 2>/dev/null || true
}

discover_regression_scripts() {
  mapfile -d '' -t REGRESSION_SCRIPTS < <(
    find "$PROJECT_ROOT/regression" -type f -name '*-regression.sh' \
      ! -path "$PROJECT_ROOT/regression/new-regression.sh" \
      -print0 | sort -z
  )
}

discover_regression_shell_scripts() {
  mapfile -d '' -t REGRESSION_SHELL_SCRIPTS < <(
    find "$PROJECT_ROOT/regression" -type f -name '*.sh' ! -path "$PROJECT_ROOT/regression/script.sh" -print0 | sort -z
  )
}

printf 'Regression runner root: %s\n' "$PROJECT_ROOT"
auto_chmod_scripts
discover_regression_scripts
discover_regression_shell_scripts

run_step "Bash syntax check (vfio.sh)" bash -n "$PROJECT_ROOT/vfio.sh"
run_step "Bash syntax check (regression/script.sh)" bash -n "$PROJECT_ROOT/regression/script.sh"
if (( ${#REGRESSION_SHELL_SCRIPTS[@]} > 0 )); then
  run_step "Bash syntax check (all regression shell scripts)" bash -n "${REGRESSION_SHELL_SCRIPTS[@]}"
else
  printf '\n[WARN] No additional shell scripts found under regression/.\n'
fi
if (( ${#REGRESSION_SCRIPTS[@]} > 0 )); then
  run_step "Bash syntax check (discovered regression scripts)" bash -n "${REGRESSION_SCRIPTS[@]}"
else
  printf '\n[WARN] No *-regression.sh scripts found under regression/.\n'
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  install_shellcheck_if_missing || true
fi
if command -v shellcheck >/dev/null 2>&1; then
  if (( ${#REGRESSION_SHELL_SCRIPTS[@]} > 0 )); then
    run_step "Shellcheck (vfio.sh + regression scripts)" \
      shellcheck "$PROJECT_ROOT/vfio.sh" "$PROJECT_ROOT/regression/script.sh" "${REGRESSION_SHELL_SCRIPTS[@]}"
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
