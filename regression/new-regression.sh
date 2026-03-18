#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/regression-template.sh"

usage() {
  cat <<'EOF'
Usage: regression/new-regression.sh [--force] <name>

Creates regression/<name>-regression.sh from regression/regression-template.sh.

Options:
  -f, --force   Overwrite target file if it already exists.
  -h, --help    Show this help.
EOF
}

fail_msg() {
  printf 'ERROR: %s\n' "$1" >&2
}

normalize_regression_name() {
  local raw="$1"
  local name="$raw"

  name="${name##*/}"
  name="${name%.sh}"
  name="${name%-regression}"

  if [[ -z "$name" ]]; then
    fail_msg "regression name cannot be empty"
    return 1
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail_msg "invalid regression name: '$raw' (allowed: letters, digits, dot, underscore, dash)"
    return 1
  fi

  printf '%s\n' "$name"
}

main() {
  local force=0
  local name_arg=""
  local arg=""
  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      -f|--force)
        force=1
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --*)
        fail_msg "unknown option: $arg"
        usage >&2
        return 1
        ;;
      *)
        if [[ -n "$name_arg" ]]; then
          fail_msg "only one regression name argument is supported"
          usage >&2
          return 1
        fi
        name_arg="$arg"
        ;;
    esac
    shift
  done

  if [[ -z "$name_arg" ]]; then
    usage >&2
    return 1
  fi
  if [[ ! -f "$TEMPLATE_FILE" ]]; then
    fail_msg "template not found: $TEMPLATE_FILE"
    return 1
  fi

  local normalized_name=""
  normalized_name="$(normalize_regression_name "$name_arg")"

  local target_file="${SCRIPT_DIR}/${normalized_name}-regression.sh"
  if [[ "$target_file" == "${SCRIPT_DIR}/new-regression.sh" ]]; then
    fail_msg "name resolves to helper script path; choose a different name"
    return 1
  fi
  if [[ -e "$target_file" && "$force" != "1" ]]; then
    fail_msg "target already exists: $target_file (use --force to overwrite)"
    return 1
  fi

  cp -- "$TEMPLATE_FILE" "$target_file"
  chmod +x "$target_file" 2>/dev/null || true

  printf 'Created regression scaffold: %s\n' "$target_file"
  printf 'Next: edit test logic and run: bash %s/script.sh\n' "$SCRIPT_DIR"
}

main "$@"
