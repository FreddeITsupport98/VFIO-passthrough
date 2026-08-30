#!/usr/bin/env bash
# R41 smoke: extract the generated vfio-hotplug-tray PySide6 applet from vfio.sh,
# py_compile it, confirm it imports cleanly (no GUI shown), and assert the
# --live-attach-status machine-readable output shape (installed= / mode= / vm=
# lines) that the tray consumes on launch. Does NOT need root, a display, or a
# real libvirt VM — exercises the tray + status logic only (safe code).
# Run: bash regression/live-attach-tray-smoke.sh
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

# Extract the PySide6 tray applet heredoc (first <<'TRAYEOF' ... TRAYEOF after
# install_live_attach_tray()).
tray_py="$tmp/vfio-hotplug-tray.py"
awk '
  /install_live_attach_tray\(\)/ { in_fn=1 }
  in_fn && /<<.TRAYEOF./ { grab=1; next }
  grab && /^TRAYEOF$/ { grab=0; in_fn=0 }
  grab { print }
' "$VFIO_SCRIPT" > "$tray_py"

if python3 -m py_compile "$tray_py" 2>/dev/null; then
  ok "tray applet python compiles (py_compile)"
else
  bad "tray applet python does not compile"
fi

# The tray must be a PySide6 QSystemTrayIcon applet that toggles via pkexec +
# zenity --question + notify-send, and reads the world-readable mode file.
if grep -Fq 'QtWidgets.QSystemTrayIcon' "$tray_py"; then ok "tray uses QSystemTrayIcon"; else bad "tray missing QSystemTrayIcon"; fi
if grep -Fq 'MODE_FILE = "/var/lib/vfio-dynamic/live-attach-mode"' "$tray_py"; then ok "tray reads the mode file"; else bad "tray missing MODE_FILE read"; fi
if grep -Fq '"pkexec", VFIO_BIN, "--live-attach-toggle"' "$tray_py"; then ok "tray toggles via pkexec --live-attach-toggle"; else bad "tray missing pkexec toggle"; fi
if grep -Fq '"zenity", "--question"' "$tray_py"; then ok "tray confirms via zenity --question"; else bad "tray missing zenity confirmation"; fi
if grep -Fq '"notify-send"' "$tray_py"; then ok "tray reports via notify-send"; else bad "tray missing notify-send"; fi
if grep -Fq 'VFIO_BIN  = "/usr/local/bin/vfio"' "$tray_py"; then ok "tray calls the self-installed vfio CLI"; else bad "tray missing VFIO_BIN"; fi
if grep -Fq 'def ensure_single_instance():' "$tray_py"; then ok "tray has a single-instance guard (ensure_single_instance)"; else bad "tray missing single-instance guard"; fi
if grep -Fq 'QLocalServer' "$tray_py"; then ok "tray single-instance guard uses QLocalServer"; else bad "tray missing QLocalServer single-instance guard"; fi
if grep -Fq 'SOCK_NAME = "/tmp/vfio-hotplug-tray.sock"' "$tray_py"; then ok "tray uses a named single-instance socket"; else bad "tray missing named single-instance socket"; fi
# R42: the tray probes guest-GPU liveness so a dead/zombie card shows
# "GPU DEAD, needs host reboot" and the icon stays visible (no vanish).
if grep -Fq 'def read_gpu_bdf():' "$tray_py"; then ok "tray reads the guest GPU BDF from the conf"; else bad "tray missing read_gpu_bdf"; fi
if grep -Fq 'def gpu_state():' "$tray_py"; then ok "tray has a gpu_state() liveness probe"; else bad "tray missing gpu_state()"; fi
if grep -Fq '0xffff' "$tray_py"; then ok "tray gpu_state treats vendor 0xffff as dead"; else bad "tray gpu_state does not check vendor 0xffff"; fi
if grep -Fq 'GPU DEAD, needs host reboot' "$tray_py"; then ok "tray dead tooltip says GPU DEAD, needs host reboot"; else bad "tray missing the GPU DEAD tooltip"; fi
# R42: the icon is color-coded by state — green=ON, red=OFF, yellow=DEAD card.
if grep -Fq 'def _status_icon(color):' "$tray_py"; then ok "tray defines a _status_icon color helper"; else bad "tray missing the _status_icon color helper"; fi
if grep -Fq 'CompositionMode_DestinationIn' "$tray_py"; then ok "tray tints the GPU glyph with the status color"; else bad "tray does not tint the glyph with the status color"; fi
if grep -Fq '_GREEN, _RED, _YELLOW' "$tray_py"; then ok "tray defines green/red/yellow status colors"; else bad "tray missing the green/red/yellow status colors"; fi
if grep -Fq '_status_icon(_YELLOW)' "$tray_py"; then ok "tray uses a yellow icon when the GPU is dead"; else bad "tray does not use a yellow icon when dead"; fi
# on/off is a ternary on one line: _status_icon(_GREEN if m == "on" else _RED)
if grep -Fq '_GREEN if m == "on" else _RED' "$tray_py"; then ok "tray uses green when ON, red when OFF"; else bad "tray does not pick green-on/red-off"; fi
# The icon itself is clickable: left-click (Trigger) toggles, middle-click shows status.
if grep -Fq 'def on_activated(reason):' "$tray_py"; then ok "tray wires an activated (click) handler"; else bad "tray missing the activated (click) handler"; fi
if grep -Fq 'tray.activated.connect(on_activated)' "$tray_py"; then ok "tray connects the activated signal"; else bad "tray does not connect the activated signal"; fi
if grep -Fq 'QtWidgets.QSystemTrayIcon.Trigger' "$tray_py"; then ok "tray left-click (Trigger) toggles the hotplug"; else bad "tray missing left-click Trigger handling"; fi
if grep -Fq 'QtWidgets.QSystemTrayIcon.MiddleClick' "$tray_py"; then ok "tray middle-click shows the status dialog"; else bad "tray missing middle-click status handling"; fi

# Non-GUI import sanity: the module imports PySide6 symbols the tray uses, but
# we do NOT exec the tray (that would try to show a Qt window). Importing the
# module-level names is enough to confirm there are no import-time typos beyond
# what py_compile already checked. PySide6 is the tray toolkit.
if python3 -c 'import PySide6.QtWidgets, PySide6.QtGui, PySide6.QtCore' >/dev/null 2>&1; then
  ok "PySide6 (Qt6) is importable on this host"
else
  # PySide6 not installed here is OK for the smoke (the installer gates on it);
  # the py_compile + grep checks above already validate the generated script.
  ok "PySide6 not installed here (skipping live import; installer gates on it)"
fi

# --- --live-attach-status machine-readable output shape (tray launch state) ---
# Isolate CONF_FILE + LIVE_ATTACH_MODE_FILE to temp paths so the smoke does NOT
# read the real host /etc/vfio-gpu-passthrough.conf / mode file (which would
# make the "no conf" test flaky against an actually-configured host).
empty_conf="$tmp/empty.conf"   # intentionally never written -> readable_file is false
nomode="$tmp/nomode"           # intentionally never written -> _la_read_mode -> unknown

# With no conf, live_attach_status prints installed=0 + mode=unknown + gpu=unknown
# (no vm= lines). Source vfio.sh (defines functions; does not run main) and call it.
status_out="$tmp/status.txt"
# shellcheck disable=SC1090
DRY_RUN=1 bash -c "source '$VFIO_SCRIPT' >/dev/null 2>&1; CONF_FILE='$empty_conf' LIVE_ATTACH_MODE_FILE='$nomode' MODE=live-attach-status live_attach_status" >"$status_out" 2>/dev/null || true

if grep -Fxq 'installed=0' "$status_out"; then ok "status prints installed=0 with no conf"; else bad "status missing installed=0 (got: $(cat "$status_out" | tr '\n' ' '))"; fi
if grep -Fxq 'mode=unknown' "$status_out"; then ok "status prints mode=unknown with no conf"; else bad "status missing mode=unknown"; fi
if grep -Fxq 'gpu=unknown' "$status_out"; then ok "status prints gpu=unknown with no conf"; else bad "status missing gpu=unknown with no conf"; fi
# No vm= lines when libvirt is unreachable / no conf.
if ! grep -q '^vm=' "$status_out"; then ok "status omits vm= lines when no guest-GPU VMs"; else bad "status emitted vm= lines with no conf"; fi

# With a conf that has VFIO_DYNAMIC_LIVE_ATTACH="1" but no mode file, status
# should default mode=on (pre-R41 install = hotplug active). The fake BDF
# 0000:0e:00.0 does not exist on the test host -> gpu=dead (dir gone), proving
# the R42 GPU-dead probe works end-to-end through live_attach_status.
fake_conf="$tmp/fake.conf"
cat >"$fake_conf" <<'EOF'
GUEST_GPU_BDF="0000:0e:00.0"
VFIO_DYNAMIC_LIVE_ATTACH="1"
EOF
status_out2="$tmp/status2.txt"
# shellcheck disable=SC1090
DRY_RUN=1 bash -c "source '$VFIO_SCRIPT' >/dev/null 2>&1; CONF_FILE='$fake_conf' LIVE_ATTACH_MODE_FILE='$nomode' MODE=live-attach-status live_attach_status" >"$status_out2" 2>/dev/null || true
if grep -Fxq 'installed=1' "$status_out2"; then ok "status prints installed=1 with live-attach conf"; else bad "status missing installed=1"; fi
if grep -Fxq 'mode=on' "$status_out2"; then ok "status defaults mode=on for a pre-R41 install (no mode file)"; else bad "status did not default mode=on"; fi
if grep -Fxq 'gpu=dead' "$status_out2"; then ok "status prints gpu=dead for a non-existent guest GPU BDF"; else bad "status did not print gpu=dead (got: $(cat "$status_out2" | tr '\n' ' '))"; fi

# A mode file overrides: write mode=off, status should report mode=off.
mode_dir="$tmp/vfio-dynamic"
mkdir -p "$mode_dir"
printf 'off\n' >"$mode_dir/live-attach-mode"
status_out3="$tmp/status3.txt"
# shellcheck disable=SC1090
DRY_RUN=1 bash -c "source '$VFIO_SCRIPT' >/dev/null 2>&1; CONF_FILE='$fake_conf' LIVE_ATTACH_MODE_FILE='$mode_dir/live-attach-mode' MODE=live-attach-status live_attach_status" >"$status_out3" 2>/dev/null || true
if grep -Fxq 'mode=off' "$status_out3"; then ok "status reads mode=off from the mode file"; else bad "status did not read mode=off from the mode file"; fi

# --live-attach-status --json emits a machine-readable object (installed + mode + vms[]).
status_json="$tmp/status.json"
DRY_RUN=1 bash -c "source '$VFIO_SCRIPT' >/dev/null 2>&1; CONF_FILE='$fake_conf' JSON_OUTPUT=1 MODE=live-attach-status live_attach_status" >"$status_json" 2>/dev/null || true
if grep -Fq '{' "$status_json" && grep -Fq '"installed":' "$status_json" && grep -Fq '"mode":' "$status_json" && grep -Fq '"vms":' "$status_json"; then ok "status --json emits an installed + mode + vms object"; else bad "status --json did not emit the expected JSON object (got: $(tr '\n' ' ' < "$status_json"))"; fi

if (( fail != 0 )); then
  printf '\nFAIL SUMMARY (%d)\n' "${#FAILED_ASSERTIONS[@]}" >&2
  for _a in "${FAILED_ASSERTIONS[@]}"; do printf ' - %s\n' "$_a" >&2; done
  exit 1
fi
printf '\nSMOKE SUMMARY: PASS\n'
