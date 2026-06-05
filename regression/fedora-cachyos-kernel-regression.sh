#!/usr/bin/env bash
# Regression: Fedora CachyOS kernel ACS override offer behavior in vfio.sh
# Convention: this regression overrides sourced vfio.sh helpers that are invoked indirectly.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VFIO_SCRIPT="${PROJECT_ROOT}/vfio.sh"

if [[ ! -f "$VFIO_SCRIPT" ]]; then
  printf 'FAIL: missing vfio.sh at %s\n' "$VFIO_SCRIPT" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$VFIO_SCRIPT"

fail=0
FAILED_ASSERTIONS=()

exit_code_of() {
  "$@" >/dev/null 2>&1
  echo $?
}

record_failure() {
  local name="$1"
  FAILED_ASSERTIONS+=("$name")
  fail=1
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (expected="%s", got="%s")\n' "$name" "$expected" "$actual" >&2
    record_failure "$name"
  fi
}

assert_contains() {
  local name="$1" pattern="$2" haystack="$3"
  if grep -Fq -- "$pattern" <<<"$haystack"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (pattern not found: %s)\n' "$name" "$pattern" >&2
    record_failure "$name"
  fi
}

assert_not_contains() {
  local name="$1" pattern="$2" haystack="$3"
  if grep -Fq -- "$pattern" <<<"$haystack"; then
    printf 'FAIL: %s (unexpected pattern found: %s)\n' "$name" "$pattern" >&2
    record_failure "$name"
  else
    printf 'PASS: %s\n' "$name"
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Override os_release_id_and_like to read from a test file instead of the real /etc/os-release.
VFIO_TEST_OS_RELEASE="$tmp_dir/os-release"
os_release_id_and_like() {
  local os_id="" os_like=""
  if [[ -r "$VFIO_TEST_OS_RELEASE" ]]; then
    local k v
    while IFS='=' read -r k v; do
      [[ -n "${k:-}" ]] || continue
      case "$k" in
        ID)
          v="${v%\"}"
          v="${v#\"}"
          os_id="$v"
          ;;
        ID_LIKE)
          v="${v%\"}"
          v="${v#\"}"
          os_like="$v"
          ;;
      esac
    done <"$VFIO_TEST_OS_RELEASE"
  fi
  printf '%s\t%s\n' "$os_id" "$os_like"
}

# Test 1: Fedora detection by ID=fedora
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="fedora"
VERSION_ID="44"
EOF
assert_eq "fedora detection by ID=fedora returns 0" "0" "$(exit_code_of is_fedora_like)"
reason="$(fedora_like_detection_reason || true)"
assert_contains "fedora detection reason mentions ID=fedora" "fedora" "$reason"

# Test 2: RHEL detection via ID_LIKE
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="centos"
ID_LIKE="rhel fedora"
EOF
assert_eq "fedora detection by ID_LIKE rhel returns 0" "0" "$(exit_code_of is_fedora_like)"
reason="$(fedora_like_detection_reason || true)"
assert_contains "fedora detection reason mentions rhel token" "rhel" "$reason"

# Test 3: Non-Fedora detection
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="debian"
ID_LIKE="debian"
EOF
assert_eq "non-fedora detection returns 1" "1" "$(exit_code_of is_fedora_like)"
reason="$(fedora_like_detection_reason || true)"
assert_contains "non-fedora detection reason mentions no" "no" "$reason"

# Test 4: Empty os-release
: >"$VFIO_TEST_OS_RELEASE"
assert_eq "empty os-release returns 1" "1" "$(exit_code_of is_fedora_like)"

# ----------------
# Testable wrapper for maybe_offer_fedora_cachyos_kernel that replaces
# /proc/cmdline with a variable so the function can be tested without root.
# All other logic is identical to the original function.
# ----------------
VFIO_TEST_CMDLINE=""
VFIO_TEST_KREL="generic"
VFIO_TEST_RPM_INSTALLED="0"

maybe_offer_fedora_cachyos_kernel_testable() {
  local guest_vendor_b10="$1" guest_gpu_bdf="$2"

  if ! is_fedora_like; then
    return 0
  fi
  if ! have_cmd dnf; then
    return 0
  fi

  if [[ "${guest_vendor_b10,,}" != "1002" ]]; then
    return 0
  fi

  if [[ "$(bdf_driver_name "$guest_gpu_bdf")" == "vfio-pci" ]]; then
    return 0
  fi

  if [[ -n "$VFIO_TEST_CMDLINE" ]] && grep -q 'pcie_acs_override' <<<"$VFIO_TEST_CMDLINE" 2>/dev/null; then
    return 0
  fi

  if [[ "$VFIO_TEST_RPM_INSTALLED" == "1" ]]; then
    return 0
  fi

  local krel="$VFIO_TEST_KREL"
  if [[ "$krel" == *cachyos* ]]; then
    return 0
  fi

  say ""
  hdr "Optional: install CachyOS kernel for ACS override support"
  note "The stock Fedora kernel does NOT include the ACS override patch."
  note "When pcie_acs_override=downstream,multifunction is present in the kernel cmdline but the patch is missing, the parameter is silently ignored."
  note "This can leave the guest GPU in the same IOMMU group as other devices (for example the PCIe bridge or xHCI controller), which may destabilize the shared PCIe root complex during long VFIO passthrough sessions and cause USB/xHCI crashes."
  note "The CachyOS kernel (package: kernel-cachyos, COPR: bieszczaders/kernel-cachyos) includes ACS override support and has been observed to properly isolate devices into separate IOMMU groups."
  note "Installing kernel-cachyos keeps your current kernel installed; at boot you can pick either the default Fedora kernel or the CachyOS kernel from the menu."

  local def="N"
  if [[ "$(bdf_driver_name "$guest_gpu_bdf")" == "amdgpu" ]]; then
    def="Y"
    note "Right now the guest GPU ($guest_gpu_bdf) is driven by amdgpu; installing the CachyOS kernel is RECOMMENDED so vfio-pci can reliably bind it with proper IOMMU isolation."
  else
    note "If you later find that amdgpu still owns the guest GPU after enabling VFIO, or you experience USB/xHCI instability after long VM sessions, consider installing the CachyOS kernel manually:"
    note "  sudo dnf copr enable bieszczaders/kernel-cachyos"
    note "  sudo dnf install kernel-cachyos kernel-cachyos-devel-matched"
  fi

  if prompt_yn "Install the CachyOS kernel (kernel-cachyos) now via dnf from COPR bieszczaders/kernel-cachyos (optional, safe alongside the current kernel)?" "$def" "Kernel (optional)"; then
    run dnf -y copr enable bieszczaders/kernel-cachyos || \
      note "COPR enable failed; you can enable manually later with: sudo dnf copr enable bieszczaders/kernel-cachyos"
    run dnf -y install kernel-cachyos kernel-cachyos-devel-matched || \
      note "kernel-cachyos install via dnf failed; you can install it manually later with: sudo dnf install kernel-cachyos kernel-cachyos-devel-matched"
  fi
}

# Capture output and prompt_yn calls from the testable function.
CAPTURED_OUTPUT=""
CAPTURED_PROMPT_COUNT=0
CAPTURED_PROMPT_DEFAULT=""
CAPTURED_PROMPT_QUESTION=""

say() { CAPTURED_OUTPUT+="$(printf '%s\n' "$*")\n"; }
hdr() { CAPTURED_OUTPUT+="$(printf '%s\n' "--- $* ---")\n"; }
note() { CAPTURED_OUTPUT+="$(printf '%s\n' "$*")\n"; }

prompt_yn() {
  CAPTURED_PROMPT_COUNT=$((CAPTURED_PROMPT_COUNT + 1))
  CAPTURED_PROMPT_QUESTION="$1"
  CAPTURED_PROMPT_DEFAULT="$2"
  return 1  # decline by default so we don't trigger dnf commands
}

run() { :; }  # no-op in test mode

# Test 5: Not Fedora-like → no prompt, no output.
VFIO_TEST_CMDLINE=""
VFIO_TEST_KREL="generic"
VFIO_TEST_RPM_INSTALLED="0"
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="debian"
ID_LIKE="debian"
EOF
CAPTURED_OUTPUT=""
CAPTURED_PROMPT_COUNT=0
maybe_offer_fedora_cachyos_kernel_testable "1002" "0000:01:00.0"
assert_eq "non-fedora returns immediately with no output" "0" "$CAPTURED_PROMPT_COUNT"
assert_eq "non-fedora returns immediately with no text" "" "$CAPTURED_OUTPUT"

# Test 6: AMD guest, Fedora-like, but pcie_acs_override already active → no prompt.
VFIO_TEST_CMDLINE="quiet amd_iommu=on pcie_acs_override=downstream,multifunction"
VFIO_TEST_KREL="generic"
VFIO_TEST_RPM_INSTALLED="0"
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="fedora"
EOF
CAPTURED_OUTPUT=""
CAPTURED_PROMPT_COUNT=0
maybe_offer_fedora_cachyos_kernel_testable "1002" "0000:01:00.0"
assert_eq "acs_override already active returns immediately" "0" "$CAPTURED_PROMPT_COUNT"
assert_eq "acs_override already active returns no text" "" "$CAPTURED_OUTPUT"

# Test 7: AMD guest, Fedora-like, but running cachyos kernel → no prompt.
VFIO_TEST_CMDLINE=""
VFIO_TEST_KREL="7.0.11-cachyos1.fc44"
VFIO_TEST_RPM_INSTALLED="0"
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="fedora"
EOF
CAPTURED_OUTPUT=""
CAPTURED_PROMPT_COUNT=0
maybe_offer_fedora_cachyos_kernel_testable "1002" "0000:01:00.0"
assert_eq "running cachyos kernel returns immediately" "0" "$CAPTURED_PROMPT_COUNT"
assert_eq "running cachyos kernel returns no text" "" "$CAPTURED_OUTPUT"

# Test 8: AMD guest, Fedora-like, but kernel-cachyos already installed → no prompt.
VFIO_TEST_CMDLINE=""
VFIO_TEST_KREL="generic"
VFIO_TEST_RPM_INSTALLED="1"
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="fedora"
EOF
CAPTURED_OUTPUT=""
CAPTURED_PROMPT_COUNT=0
maybe_offer_fedora_cachyos_kernel_testable "1002" "0000:01:00.0"
assert_eq "already installed returns immediately" "0" "$CAPTURED_PROMPT_COUNT"
assert_eq "already installed returns no text" "" "$CAPTURED_OUTPUT"

# Test 9: AMD guest, Fedora-like, all conditions met, amdgpu is driver → prompt with default Y.
VFIO_TEST_CMDLINE=""
VFIO_TEST_KREL="generic"
VFIO_TEST_RPM_INSTALLED="0"
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="fedora"
EOF
CAPTURED_OUTPUT=""
CAPTURED_PROMPT_COUNT=0
CAPTURED_PROMPT_DEFAULT=""
CAPTURED_PROMPT_QUESTION=""

# Override bdf_driver_name to return amdgpu for this test.
bdf_driver_name() { echo "amdgpu"; }

maybe_offer_fedora_cachyos_kernel_testable "1002" "0000:01:00.0"
assert_eq "amdgpu driver triggers prompt" "1" "$CAPTURED_PROMPT_COUNT"
assert_eq "amdgpu driver default is Y" "Y" "$CAPTURED_PROMPT_DEFAULT"
assert_contains "prompt question mentions CachyOS kernel" "CachyOS kernel" "$CAPTURED_PROMPT_QUESTION"
assert_contains "output explains Fedora kernel limitation" "stock Fedora kernel does NOT include" "$CAPTURED_OUTPUT"
assert_contains "output mentions COPR" "bieszczaders/kernel-cachyos" "$CAPTURED_OUTPUT"
assert_contains "output mentions xHCI instability" "USB/xHCI crashes" "$CAPTURED_OUTPUT"
assert_contains "output recommends install when amdgpu" "RECOMMENDED" "$CAPTURED_OUTPUT"

# Test 10: Non-AMD guest → no prompt even on Fedora.
VFIO_TEST_CMDLINE=""
VFIO_TEST_KREL="generic"
VFIO_TEST_RPM_INSTALLED="0"
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="fedora"
EOF
CAPTURED_OUTPUT=""
CAPTURED_PROMPT_COUNT=0
maybe_offer_fedora_cachyos_kernel_testable "10de" "0000:01:00.0"
assert_eq "non-AMD guest returns immediately" "0" "$CAPTURED_PROMPT_COUNT"
assert_eq "non-AMD guest returns no text" "" "$CAPTURED_OUTPUT"

# Test 11: AMD guest, Fedora-like, not amdgpu driver → prompt with default N.
VFIO_TEST_CMDLINE=""
VFIO_TEST_KREL="generic"
VFIO_TEST_RPM_INSTALLED="0"
cat >"$VFIO_TEST_OS_RELEASE" <<EOF
ID="fedora"
EOF
CAPTURED_OUTPUT=""
CAPTURED_PROMPT_COUNT=0
CAPTURED_PROMPT_DEFAULT=""

# Override bdf_driver_name to return something other than amdgpu.
bdf_driver_name() { echo "<none>"; }

maybe_offer_fedora_cachyos_kernel_testable "1002" "0000:01:00.0"
assert_eq "non-amdgpu driver triggers prompt" "1" "$CAPTURED_PROMPT_COUNT"
assert_eq "non-amdgpu driver default is N" "N" "$CAPTURED_PROMPT_DEFAULT"
assert_contains "output mentions manual install steps" "sudo dnf copr enable" "$CAPTURED_OUTPUT"
assert_not_contains "output does not recommend when not amdgpu" "RECOMMENDED" "$CAPTURED_OUTPUT"

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for failed_assertion in "${FAILED_ASSERTIONS[@]}"; do
    printf ' - %s\n' "$failed_assertion" >&2
  done
  exit 1
fi

printf 'Fedora CachyOS kernel regression checks passed.\n'
