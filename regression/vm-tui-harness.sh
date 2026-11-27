#!/usr/bin/env bash
# vm-tui-harness.sh — the consolidated R82-R95 validation suite for the
# built-in VM manager, the Looking Glass integration, and the debug
# windows (relocated into the repo at R95 after /tmp wiped the scratch
# harness TWICE in one arc; the scratch dir is now a per-run mktemp).
# Blocks:
#   1-6. (R82) the debug window: dual-log tail, dedup, no-emulator note,
#      option-9 wiring, the stale-diagnosis latch, target-user writability.
#   7-9. (R83) per-source windows: the hotplug journal window, both sources
#      side by side, and the option-9 sub-choice wiring.
#   7u-7w, 10. (R84) the hotplug window follows ALL VFIO_JOURNAL_TAGS — the
#      printer emits the FULL journalctl command, the dedup pattern matches
#      it, the failure notifies name both relevant tags — plus the all-events
#      dbg sweep (session / agent-wait / host-app / connection / liveness /
#      mru) and the all-component-tags option-9 label.
#   11. (R86) the transient action infobox is per-action: a hinted VM/LG
#      action shows ITS hint; a hint-less action makes no VM/LG claim.
#   12. (R87) the launch-log redirect can never kill the client: the ROOT
#      redirect moved to the target-user side of the launch (child bash -c)
#      with an in-child /dev/null fallback; both gates probe the REAL open
#      (fs.protected_regular denies O_CREAT appends on foreign-owned /tmp
#      files even for root — test -w cannot see it); chown after touch.
#   13. (R88) --install-self is drift-proof + session-safe: the revision
#      from->to printout, the ATOMIC install (temp + rename — a running
#      session keeps its own code), and the anchored running-instance guard.
#   14. (R89) the agent-wait timeout WARN self-diagnoses: one final
#      locale-stable guest-ping distinguishes "just answered" / "channel
#      exists, not connected" / "no channel" / "no answer".
#   15. (R90) the MANAGER window opens with the same 200-line backlog as
#      the journal window (all 3 branches + both fallback notes + the
#      dedup pattern updated in lockstep).
#   16. (R91) the windows SAY what they carry: backlog-aware titles +
#      option-9 sub-menu labels + the plain-mode prompt.
#   17. (R92) the option-9 debug-log viewer shows the last 200 lines (was
#      40) + the live-follow hint carries the same backlog.
#   18. (R93) every host-app readiness check accepts BOTH magics — legacy
#      KVMFR and the B7 LGMP session header (the watcher + hoststate) —
#      including an end-to-end watcher-fires-on-LGMP run.
#   19. (R94) the LG setup ensures the SPICE USB redirector (idempotent,
#      both apply paths) + ends with the Windows-host-app final step.
#   20. (R95) zombie forensics in the libvirt hook: the per-domain session
#      start stamp + the stop-reason/session log at every actual VM stop.
# Scratch: a per-run mktemp dir (cleaned on exit); zero host side effects.
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
H="$(mktemp -d /tmp/vm-tui-harness.XXXXXX)"
trap 'rm -rf "$H"' EXIT
PASS=0; FAIL=0; FAILED=()
ck_grep() {
  if grep -Fq -- "$2" "$3" 2>/dev/null; then printf 'PASS: %s\n' "$1"; PASS=$((PASS+1))
  else printf 'FAIL: %s (pattern: %s, file: %s)\n' "$1" "$2" "$3" >&2; FAIL=$((FAIL+1)); FAILED+=("$1"); fi
}
ck_not_grep() {
  if grep -Fq -- "$2" "$3" 2>/dev/null; then printf 'FAIL: %s (unexpected: %s)\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); FAILED+=("$1")
  else printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); fi
}

mkdir -p "$H/bin" "$H/out" "$H/state"
echo "scratch: $H (repo: $REPO)"

# --- farm: a fake konsole that logs its argv (and stays alive so the pgrep
# dedup path can be exercised via the alive-marker file the fake pgrep reads).
cat > "$H/bin/konsole" <<'EOF'
#!/usr/bin/env bash
H="${R82_H:?}"
printf 'konsole-args: %s\n' "$*" >> "$H/out/konsole-calls"
sleep 30
EOF
# fake pgrep: "window already tailing" iff the marker file is non-empty.
cat > "$H/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
H="${R82_H:?}"
[[ "$*" == *vm-tui-debug.log* ]] || exit 1
[[ -s "$H/out/window-alive" ]] && exit 0 || exit 1
EOF
chmod +x "$H/bin/konsole" "$H/bin/pgrep"
export R82_H="$H"

# --- extract vmtui_debug_window VERBATIM -----------------------------------
sed -n '/^vmtui_debug_window()/,/^}/p' "$REPO/vfio.sh" > "$H/fn.sh"
if ! grep -q "runuser" "$H/fn.sh"; then
  echo "FAIL: extraction missing the R82 root-safe spawn" >&2
  exit 1
fi
printf 'PASS: vmtui_debug_window extracted (%s lines, contains the root-safe spawn)\n' "$(wc -l < "$H/fn.sh" | tr -d ' ')"
PASS=$((PASS+1))

# --- a fake journalctl so the hotplug source can be exercised --------------
cat > "$H/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
H="${R82_H:?}"
printf 'journalctl-args: %s\n' "$*" >> "$H/out/journalctl-calls"
if [[ "${R82_JOURNALCTL_RC:-0}" != "0" ]]; then exit "${R82_JOURNALCTL_RC}"; fi
sleep 30
EOF
chmod +x "$H/bin/journalctl"

DBG="$H/out/vm-tui-debug.log"
LGLOG="$H/out/vm-tui.log"

# 1: non-root, debug on -> ONE window tailing BOTH logs
rm -f "$H/out/konsole-calls" "$H/out/window-alive" "$H/out/notes"
cat > "$H/out/run1.sh" <<RUNEOF
#!/usr/bin/env bash
set -uo pipefail
export R82_H="$H"
export VM_TUI_DEBUG=1
export VM_TUI_DEBUG_LOG="$DBG"
export VM_TUI_LOG_FILE="$LGLOG"
note() { printf '%s\n' "\$*" >> "$H/out/notes"; }
source "$H/fn.sh"
vmtui_debug_window
RUNEOF
PATH="$H/bin:/usr/bin:/bin" bash "$H/out/run1.sh" >/dev/null 2>&1 || true
sleep 1   # settle: the spawned konsole is setsid-detached + async
ck_grep "1 the window tails BOTH logs with backlog (debug + launch)" "tail -n 200 -F $DBG $LGLOG" "$H/out/konsole-calls"
ck_grep "1b the note announces the dual-log window" "tailing $DBG + $LGLOG" "$H/out/notes"
pkill -f "$H/bin/konsol[e]" 2>/dev/null || true

# 2: dedup — with a window already alive, a second call spawns NOTHING new
printf '%s\n' alive > "$H/out/window-alive"
n_before="$(grep -c "konsole-args" "$H/out/konsole-calls" 2>/dev/null || echo 0)"
PATH="$H/bin:/usr/bin:/bin" bash "$H/out/run1.sh" >/dev/null 2>&1 || true
n_after="$(grep -c "konsole-args" "$H/out/konsole-calls" 2>/dev/null || echo 0)"
if [[ "$n_before" == "$n_after" ]]; then printf 'PASS: 2 dedup: no second window spawned\n'; PASS=$((PASS+1))
else printf 'FAIL: 2 dedup: spawned another window (%s -> %s)\n' "$n_before" "$n_after" >&2; FAIL=$((FAIL+1)); FAILED+=("2 dedup"); fi
ck_grep "2b the dedup note says the window is already open" "already open" "$H/out/notes"
rm -f "$H/out/window-alive"

# 3: no terminal emulator anywhere -> the honest fallback note.
mkdir -p "$H/emptybin"
ln -sf /usr/bin/bash "$H/emptybin/bash"   # env must find bash; konsole must NOT be findable
rm -f "$H/out/konsole-calls" "$H/out/notes"
cat > "$H/out/run3.sh" <<RUNEOF
#!/usr/bin/env bash
set -uo pipefail
export R82_H="$H"
export VM_TUI_DEBUG=1
export VM_TUI_DEBUG_LOG="$DBG"
export VM_TUI_LOG_FILE="$LGLOG"
note() { printf '%s\n' "\$*" >> "$H/out/notes"; }
source "$H/fn.sh"
vmtui_debug_window
RUNEOF
env -i HOME="$H" PATH="$H/emptybin" bash "$H/out/run3.sh" >/dev/null 2>&1 || true
ck_grep "3 no emulator: the honest tail-command note (both files, with backlog)" "tail -n 200 -F $DBG $LGLOG" "$H/out/notes"

# 4: static wiring — option 9's ENABLE branch calls vmtui_debug_window
ck_grep "4 option 9 opens the window immediately on enable (static)" "vmtui_ok \"Debug logging ENABLED (live — no restart needed).\"" "$REPO/vfio.sh"
n_calls="$(grep -c "vmtui_debug_window" "$REPO/vfio.sh")"
if [[ "$n_calls" =~ ^[0-9]+$ ]] && (( n_calls >= 3 )); then
  printf 'PASS: 4b vmtui_debug_window wired in >=3 places (def + start + toggle: %s)\n' "$n_calls"; PASS=$((PASS+1))
else
  printf 'FAIL: 4b expected >=3 call sites, saw %s\n' "${n_calls:-0}" >&2; FAIL=$((FAIL+1)); FAILED+=("4b window call sites")
fi

# 5: the stale-log diagnosis fix — VMTUI_LG_LOG_FALLBACK=1 must SKIP the
# tail and print the disabled-log explanation instead (static + unit).
ck_grep "5a the fallback branch explains the disabled log (static)" "The launch log is DISABLED for this session" "$REPO/vfio.sh"
ck_grep "5b the writable-log branch still tails (static)" "Last log lines (\$VM_TUI_LOG_FILE):" "$REPO/vfio.sh"
sed -n '/note "WARN: the Looking Glass client exited within/,/fi$/p' "$REPO/vfio.sh" > "$H/diag.snip" 2>/dev/null || true
if grep -q "VMTUI_LG_LOG_FALLBACK" "$H/diag.snip" 2>/dev/null; then
  printf 'PASS: 5c the diagnosis branch is conditional on the latch\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 5c the extracted diagnosis has no latch condition\n' >&2; FAIL=$((FAIL+1)); FAILED+=("5c diagnosis latch")
fi

# 6: the target-user writability check (static): runuser test -w when root
ck_grep "6 the writability check runs AS the target user (runuser test -w)" 'runuser -u "$_vmtui_lg_user" -- test -w "$VM_TUI_LOG_FILE"' "$REPO/vfio.sh"

# 7 (R83/R84/R85): the HOTPLUG source — ONE window following ALL the script's
# journal tags. The follow command is built from VFIO_JOURNAL_TAGS via the
# _vmtui_journal_follow_cmd printer, so: extract the constant + the printer,
# source both in the run script, and assert the FULL journalctl command
# (journalctl -n 200 -f + every -t pair) arrives in the spawned konsole argv.
rm -f "$H/out/konsole-calls" "$H/out/journalctl-calls" "$H/out/notes" "$H/out/window-alive"
sed -n '/^VFIO_JOURNAL_TAGS=/p' "$REPO/vfio.sh" > "$H/tags.env"
sed -n '/^_vmtui_journal_follow_cmd()/,/^}/p' "$REPO/vfio.sh" > "$H/jfn.sh"
cat > "$H/out/run7.sh" <<RUNEOF
#!/usr/bin/env bash
set -uo pipefail
export R82_H="$H"
export VM_TUI_DEBUG=1
export VM_TUI_DEBUG_LOG="$DBG"
export VM_TUI_LOG_FILE="$LGLOG"
note() { printf '%s\n' "\$*" >> "$H/out/notes"; }
source "$H/tags.env"
source "$H/jfn.sh"
source "$H/fn.sh"
vmtui_debug_window hotplug
RUNEOF
PATH="$H/bin:/usr/bin:/bin" bash "$H/out/run7.sh" >/dev/null 2>&1 || true
sleep 1   # settle: the spawned konsole is setsid-detached + async
ck_grep "7 hotplug window follows ALL journal tags with backlog (full journalctl command)" "journalctl -n 200 -f -t vfio-dynamic -t vfio-live-attach -t vfio-reboot-flr -t vfio-park-keepalive" "$H/out/konsole-calls"
ck_grep "7b the hotplug window note announces all tags" "following ALL the script's journal tags live" "$H/out/notes"
ck_grep "7c the note lists the exact tag set" "(vfio-dynamic vfio-live-attach vfio-reboot-flr vfio-park-keepalive)" "$H/out/notes"
# 7u (R84/R85 unit): the printer's output IS the exact follow command — the
# journalctl word included (the first draft printed only the flags, which
# would have made konsole run "-f" as the command), and since R85 with the
# -n 200 BACKLOG before the live follow.
{
  cat "$H/tags.env"
  cat "$H/jfn.sh"
  echo '_vmtui_journal_follow_cmd'
} > "$H/out/junit7.sh"
_jout="$(bash "$H/out/junit7.sh" 2>/dev/null || true)"
if [[ "$_jout" == "journalctl -n 200 -f -t vfio-dynamic -t vfio-live-attach -t vfio-reboot-flr -t vfio-park-keepalive" ]]; then
  printf 'PASS: 7u the journal printer emits the FULL all-tags command (with backlog)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 7u printer output wrong: %s\n' "${_jout:-<empty>}" >&2; FAIL=$((FAIL+1)); FAILED+=("7u printer output")
fi
# 7v (R84 static): all THREE terminal variants append the printer via $()
# (10-space-indented code form only — the helper's comment quotes the same
# literal, which must NOT count as a call site.)
_njf="$(grep -cF '          _cmd+=($(_vmtui_journal_follow_cmd))' "$REPO/vfio.sh" || true)"
if [[ "$_njf" == "3" ]]; then
  printf 'PASS: 7v all 3 terminal variants use the printer via command substitution\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 7v expected 3 printer appends, saw %s\n' "${_njf:-0}" >&2; FAIL=$((FAIL+1)); FAILED+=("7v printer append count")
fi
# 7w (R84 static): the hotplug dedup pattern IS the printer output (the old
# single-tag literal would never match the all-tags command line -> the
# guard would never fire and repeated toggles would stack windows).
ck_grep "7w hotplug dedup pattern = the printer output" '_tail_pat="$(_vmtui_journal_follow_cmd)"' "$REPO/vfio.sh"
pkill -f "$H/bin/konsol[e]" 2>/dev/null || true

# 8 (R83): BOTH sources — two windows, one per source
rm -f "$H/out/konsole-calls" "$H/out/journalctl-calls" "$H/out/notes" "$H/out/window-alive"
cat > "$H/out/run8.sh" <<RUNEOF
#!/usr/bin/env bash
set -uo pipefail
export R82_H="$H"
export VM_TUI_DEBUG=1
export VM_TUI_DEBUG_LOG="$DBG"
export VM_TUI_LOG_FILE="$LGLOG"
note() { printf '%s\n' "\$*" >> "$H/out/notes"; }
source "$H/tags.env"
source "$H/jfn.sh"
source "$H/fn.sh"
vmtui_debug_window manager
vmtui_debug_window hotplug
RUNEOF
PATH="$H/bin:/usr/bin:/bin" bash "$H/out/run8.sh" >/dev/null 2>&1 || true
sleep 1
ck_grep "8 both sources: the manager window (tail -n 200 -F) opens" "tail -n 200 -F $DBG $LGLOG" "$H/out/konsole-calls"
ck_grep "8b both sources: the hotplug window (all-tags journalctl + backlog) opens too" "journalctl -n 200 -f -t vfio-dynamic -t vfio-live-attach -t vfio-reboot-flr -t vfio-park-keepalive" "$H/out/konsole-calls"
pkill -f "$H/bin/konsol[e]" 2>/dev/null || true

# 9 (R83): option 9's enable flow asks WHICH windows (static wiring)
ck_grep "9 option 9 asks which windows to open (static)" "Which log windows to open?" "$REPO/vfio.sh"
ck_grep "9b the sub-choice dispatches both sources (static)" '3) vmtui_debug_window manager; vmtui_debug_window hotplug ;;' "$REPO/vfio.sh"

# 10 (R84): the all-events debug sweep — every remaining decision point in
# the manager flow is now a vmtui_dbg event (static coverage greps).
ck_grep "10a session refusal is a dbg event" 'vmtui_dbg "session: REFUSED' "$REPO/vfio.sh"
ck_grep "10b resolved session env is a dbg event" 'vmtui_dbg "session: user=' "$REPO/vfio.sh"
ck_grep "10c agent-wait outcome is a dbg event" 'vmtui_dbg "agent-wait: rc=' "$REPO/vfio.sh"
ck_grep "10d pre-launch KVMFR host-app state is a dbg event" 'vmtui_dbg "host-app: state=' "$REPO/vfio.sh"
ck_grep "10e post-launch connection verdict is a dbg event" 'vmtui_dbg "connection: pid=' "$REPO/vfio.sh"
ck_grep "10f post-launch host-app state is a dbg event" 'vmtui_dbg "post-launch host-app: state=' "$REPO/vfio.sh"
ck_grep "10g liveness verdicts are dbg events" 'vmtui_dbg "liveness: pid ' "$REPO/vfio.sh"
ck_grep "10h the MRU remember is a dbg event" 'vmtui_dbg "mru: remembered ' "$REPO/vfio.sh"
ck_grep "10i the MRU prune is a dbg event" 'vmtui_dbg "mru: pruned' "$REPO/vfio.sh"
# 10j: the generated live-attach helper's failure notifications point at
# BOTH relevant journal tags (the helper's own + the bind script's).
_nh="$(grep -cF 'Check: journalctl -t vfio-live-attach -t vfio-dynamic' "$REPO/vfio.sh" || true)"
if [[ "$_nh" == "2" ]]; then
  printf 'PASS: 10j both failure notifies point at live-attach + dynamic tags\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 10j expected 2 all-tags failure hints, saw %s\n' "${_nh:-0}" >&2; FAIL=$((FAIL+1)); FAILED+=("10j failure-notify hints")
fi
# 10k: the option-9 sub-menu label no longer claims a single tag
ck_grep "10k option-9 label says all component tags + the backlog" 'GPU hotplug journal (all component tags — last 200 lines + live)' "$REPO/vfio.sh"

# 11 (R86): the transient action infobox is PER-ACTION — the old fixed
# "(the VM / Looking Glass may need a moment)" boilerplate claimed VM
# involvement for every action (the live report read Debug log's box as
# "does a VM need to start?"). Extract vmtui_menu_action, drive it with a
# fake TUI backend + stubs, and assert: a hint-less action's infobox makes
# NO VM/LG claim, a hinted action carries ITS own hint, and every call
# site passes the new hint argument.
sed -n '/^vmtui_menu_action()/,/^}/p' "$REPO/vfio.sh" > "$H/mfn.sh"
cat > "$H/bin/fake-tui" <<'EOF'
#!/usr/bin/env bash
H="${R82_H:?}"
printf 'tui-call: %s\n' "$*" >> "$H/out/tui-calls"
exit 0
EOF
chmod +x "$H/bin/fake-tui"
cat > "$H/out/run11.sh" <<RUNEOF
#!/usr/bin/env bash
set -uo pipefail
export R82_H="$H"
export TUI_BIN="$H/bin/fake-tui"
export VM_TUI_DEBUG=1
export VM_TUI_DEBUG_LOG="$DBG"
vmtui_dbg() { :; }
vmtui_tui_active() { return 0; }
_ansi_strip() { cat; }
vmtui_msgbox() { printf 'msgbox: %s\n' "\$*" >> "\$R82_H/out/tui-calls"; }
myact() { echo "did-the-thing"; }
source "$H/mfn.sh"
vmtui_menu_action "Debug log" pause "" myact
vmtui_menu_action "Start VM + Looking Glass" nopause "the VM + Windows boot waits can take a few minutes" myact
RUNEOF
rm -f "$H/out/tui-calls"
bash "$H/out/run11.sh" >/dev/null 2>&1 || true
ck_grep "11a a hint-less action's infobox is a plain Running line" "Running: Debug log ..." "$H/out/tui-calls"
if grep -q "Looking Glass may need a moment" "$H/out/tui-calls" 2>/dev/null; then
  printf 'FAIL: 11b the old fixed boilerplate clause is still emitted\n' >&2; FAIL=$((FAIL+1)); FAILED+=("11b old boilerplate gone")
else
  printf 'PASS: 11b the old fixed boilerplate clause is gone\n'; PASS=$((PASS+1))
fi
ck_grep "11c a VM/LG action's infobox carries ITS own hint" "Running: Start VM + Looking Glass ... (the VM + Windows boot waits can take a few minutes)" "$H/out/tui-calls"
# 11d (static): every menu call site passes the hint argument (a quoted
# 3rd arg right after the pause flag — the old 2-arg form would not match)
_nma="$(grep -cE 'vmtui_menu_action "[^"]*" (pause|nopause) "' "$REPO/vfio.sh" || true)"
if [[ "$_nma" == "9" ]]; then
  printf 'PASS: 11d all 9 menu call sites pass the per-action hint arg\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 11d expected 9 hinted call sites, saw %s\n' "${_nma:-0}" >&2; FAIL=$((FAIL+1)); FAILED+=("11d hinted call sites")
fi

# 12 (R87): the launch-log redirect can never kill the client. Root cause
# (live on this host): fs.protected_regular=2 denies >> opens (O_CREAT) on
# foreign-owned files in sticky /tmp EVEN FOR ROOT — after the R75 chown the
# log is fb-owned, so the ROOT manager's own parent-side redirect was
# EACCES-denied and the failed redirect aborted the launch ("retry
# exhausted" on a healthy file both gates called writable). Statics: the
# child-side redirect form, the in-child guarded fallback, both real-open
# probes, the chown-after-touch order. Functional: the EXTRACTED child
# payload — a writable log gets the header + client output; an unwritable
# log still runs the client (output to /dev/null, never killed).
sed -n "/bash -c 'if ( exec/,/^fi' &/p" "$REPO/vfio.sh" | sed -e "1s/^.*bash -c '//" -e "\$s/' &\$//" > "$H/child87.sh"
ck_grep "12a the ROOT launch redirects on the TARGET-USER side (child bash -c)" "bash -c 'if ( exec >>\"\$VMTUI_LAUNCH_LOG\" ) 2>/dev/null; then" "$REPO/vfio.sh"
ck_grep "12b the child re-probes + falls back to /dev/null internally" "exec setsid \"\$VMTUI_LAUNCH_BIN\" \$VMTUI_LAUNCH_ARGS </dev/null >/dev/null 2>&1" "$REPO/vfio.sh"
ck_grep "12c the non-root gate probes the REAL open (not test -w)" "if ( exec >>\"\$_lg_out\" ) 2>/dev/null; then" "$REPO/vfio.sh"
ck_grep "12d the root gate adds the runuser'd real-open probe" "runuser -u \"\$_vmtui_lg_user\" -- bash -c 'exec >>\"\$1\"' _ \"\$_lg_out\"" "$REPO/vfio.sh"
# 12e: the chown now runs AFTER the touch (a missing log was created
# root-owned by the old order — no logging on fresh boots)
_lgf="$(sed -n '/^vmtui_lg_launch()/,/^}/p' "$REPO/vfio.sh")"
_tl="$(printf '%s\n' "$_lgf" | grep -nF 'touch "$VM_TUI_LOG_FILE"' | head -n 1 | cut -d: -f1)"
_cl="$(printf '%s\n' "$_lgf" | grep -nF 'chown "$_vmtui_lg_user" "$VM_TUI_LOG_FILE"' | head -n 1 | cut -d: -f1)"
if [[ -n "${_tl:-}" && -n "${_cl:-}" && "$_cl" -gt "$_tl" ]]; then
  printf 'PASS: 12e the chown runs after the touch (fresh-boot logs are fb-owned immediately)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 12e chown-after-touch order wrong (touch=%s chown=%s)\n' "${_tl:-?}" "${_cl:-?}" >&2; FAIL=$((FAIL+1)); FAILED+=("12e chown order")
fi
# functional: drive the EXTRACTED child payload (as the harness user, with
# a fake client — the child's own logic is what must never kill the client).
cat > "$H/bin/fake-client87" <<'EOF'
#!/usr/bin/env bash
H="${R82_H:?}"
printf 'CLIENT-RAN %s\n' "$*"
touch "$H/out/client87-ran"
EOF
chmod +x "$H/bin/fake-client87"
rm -f "$H/out/client87-ran" "$H/out/lg87.log"
R82_H="$H" VMTUI_LAUNCH_DOM=TESTDOM VMTUI_LAUNCH_BIN="$H/bin/fake-client87" \
  VMTUI_LAUNCH_ARGS="-o x=y" VMTUI_LAUNCH_ENVS="XDG_RUNTIME_DIR=/run/user/1000" \
  VMTUI_LAUNCH_LOG="$H/out/lg87.log" bash "$H/child87.sh" >/dev/null 2>&1 || true
sleep 1
ck_grep "12f writable log: the child wrote the launch header" "launch: domain=TESTDOM" "$H/out/lg87.log"
ck_grep "12g writable log: the client ran with its output in the log" "CLIENT-RAN -o x=y" "$H/out/lg87.log"
# 12h/12i: an UNWRITABLE log must never kill the client (the R87 guarantee)
rm -f "$H/out/client87-ran" "$H/out/lg87b.log"
printf 'stale\n' > "$H/out/lg87b.log"
chmod 444 "$H/out/lg87b.log"
R82_H="$H" VMTUI_LAUNCH_DOM=TESTDOM VMTUI_LAUNCH_BIN="$H/bin/fake-client87" \
  VMTUI_LAUNCH_ARGS="" VMTUI_LAUNCH_ENVS="x" \
  VMTUI_LAUNCH_LOG="$H/out/lg87b.log" bash "$H/child87.sh" >/dev/null 2>&1 || true
sleep 1
if [[ -e "$H/out/client87-ran" ]]; then
  printf 'PASS: 12h unwritable log: the client still ran (a log problem can never kill it)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 12h the unwritable log killed the client\n' >&2; FAIL=$((FAIL+1)); FAILED+=("12h unwritable log client survived")
fi
if grep -q CLIENT-RAN "$H/out/lg87b.log" 2>/dev/null; then
  printf 'FAIL: 12i the unwritable log was written anyway\n' >&2; FAIL=$((FAIL+1)); FAILED+=("12i unwritable log untouched")
else
  printf 'PASS: 12i the unwritable log stayed untouched (output went to /dev/null)\n'; PASS=$((PASS+1))
fi

# 13 (R88): --install-self is drift-proof + session-safe: the revision
# from->to printout, the ATOMIC install (write_file_atomic = temp + rename
# = a NEW inode — a running session keeps its own code), and the anchored
# running-instance guard (the watcher/tray paths merely CONTAIN the prefix
# and must never match).
ck_grep "13a the install is ATOMIC (write_file_atomic, new inode)" 'write_file_atomic "$SELF_INSTALL_BIN" 0755 "root:root" <"$src"' "$REPO/vfio.sh"
ck_not_grep "13b no in-place cp of the script onto the deployed path" 'cp -a "$src" "$SELF_INSTALL_BIN"' "$REPO/vfio.sh"
ck_grep "13c the deployed revision is read BEFORE the update (drift printout)" "grep -m1 'SCRIPT_REVISION=' \"\$SELF_INSTALL_BIN\"" "$REPO/vfio.sh"
ck_grep "13d the from->to drift line" "Deployed revision updated:" "$REPO/vfio.sh"
ck_grep "13e the running-instance warning says restart" "code until restarted. Exit and re-open it to pick up" "$REPO/vfio.sh"
ck_grep "13f the guard pattern is anchored (space-or-EOL; the watcher prefix never matches)" 'pgrep -f "$SELF_INSTALL_BIN( |\$)"' "$REPO/vfio.sh"
# 13u unit: the anchored pattern matches a deployed-binary-shaped process
# but NOT the watcher-shaped prefix name (vfio-lg-autostart merely
# CONTAINS the path as a prefix).
cat > "$H/bin/fake-deployed88" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
cat > "$H/bin/fake-deployed88-watcher" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
chmod +x "$H/bin/fake-deployed88" "$H/bin/fake-deployed88-watcher"
"$H/bin/fake-deployed88" --vm-tui & _p88a=$!
"$H/bin/fake-deployed88-watcher" GAMING & _p88b=$!
sleep 1
_hits88="$(pgrep -f "$H/bin/fake-deployed88( |\$)" 2>/dev/null | grep -vx "$$" || true)"
kill "$_p88a" "$_p88b" 2>/dev/null || true
if [[ "$_hits88" == "$_p88a" ]]; then
  printf 'PASS: 13u the anchored guard matches the deployed-shaped process ONLY (not the watcher prefix)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 13u anchored guard hits wrong (wanted %s, got %s)\n' "$_p88a" "${_hits88:-<none>}" >&2; FAIL=$((FAIL+1)); FAILED+=("13u anchored pgrep pattern")
fi
# 13v unit: the drift extraction pipeline (the exact grep|cut the code uses)
printf 'x\nSCRIPT_REVISION="R86"\ny\n' > "$H/out/fake-deployed88-old"
_dr88="$(grep -m1 'SCRIPT_REVISION=' "$H/out/fake-deployed88-old" 2>/dev/null | cut -d'"' -f2 || true)"
if [[ "$_dr88" == "R86" ]]; then
  printf 'PASS: 13v the drift extraction pipeline reads the deployed revision\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 13v drift extraction got %s (wanted R86)\n' "${_dr88:-<empty>}" >&2; FAIL=$((FAIL+1)); FAILED+=("13v drift extraction")
fi

# 14 (R89): the agent-wait timeout WARN self-diagnoses — one final
# guest-ping (LC_ALL=C, locale-stable) whose verdict distinguishes "Windows
# still booting" from "the agent dropped". Statics + a functional unit of
# the extracted diagnose helper against a fake virsh with canned outcomes.
ck_grep "14a the diagnose helper is defined" 'vmtui_agent_wait_diagnose()' "$REPO/vfio.sh"
ck_grep "14b the final ping is locale-stable (LC_ALL=C — the R77 lesson)" 'LC_ALL=C timeout 8 virsh -c qemu:///system qemu-agent-command' "$REPO/vfio.sh"
ck_grep "14c the just-answered case reports Windows UP, not a WARN" "Windows is up (the guest agent answered right after the wait)" "$REPO/vfio.sh"
ck_grep "14d the verdict is appended to the WARN" 'note "      Final check: $_awd."' "$REPO/vfio.sh"
ck_grep "14e the verdict is mirrored into the dbg event" 'vmtui_dbg "agent-wait: timeout self-diagnosis: $_awd"' "$REPO/vfio.sh"
# 14f-14i functional: the extracted helper vs a fake virsh returning each
# canned outcome (up / not-configured / not-connected / silent; plus a
# 'running' mode for block 18 and a 'reason' mode for block 20).
sed -n '/^vmtui_agent_wait_diagnose()/,/^}/p' "$REPO/vfio.sh" > "$H/awdfn.sh"
cat > "$H/bin/virsh" <<'EOF'
#!/usr/bin/env bash
H="${R82_H:?}"
printf 'virsh-call: %s\n' "$*" >> "$H/out/virsh-calls"
case "${R82_VIRSH_MODE:-}" in
  up) printf '{"return":{}}\n' ;;
  nochan) printf 'error: guest agent is not configured\n' >&2; exit 1 ;;
  notconn) printf 'error: guest agent is not responding: QEMU guest agent is not connected\n' >&2; exit 1 ;;
  silent) exit 1 ;;
  running) printf 'running\n' ;;
  reason) printf 'shut off (destroyed)\n' ;;
esac
EOF
chmod +x "$H/bin/virsh"
rm -f "$H/out/virsh-calls"
_awd_test() {
  local _mode="$1" _want_rc="$2" _want_pat="$3" _name="$4" _rc=0 _v
  _v="$(R82_H="$H" R82_VIRSH_MODE="$_mode" PATH="$H/bin:/usr/bin:/bin" bash -c "source '$H/awdfn.sh'; vmtui_agent_wait_diagnose GAMING" 2>/dev/null)" || _rc=$?
  if [[ "$_rc" == "$_want_rc" ]] && grep -Fq "$_want_pat" <<<"$_v"; then
    printf 'PASS: %s\n' "$_name"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (rc=%s wanted=%s out=%s)\n' "$_name" "$_rc" "$_want_rc" "${_v:-<empty>}" >&2; FAIL=$((FAIL+1)); FAILED+=("$_name")
  fi
}
_awd_test up       0 "JUST answered" "14f diagnose: agent JUST answered -> rc 0 + the Windows-is-up verdict"
_awd_test nochan   1 "NO agent channel" "14g diagnose: not-configured -> rc 1 + the no-channel verdict"
_awd_test notconn  1 "has NOT connected" "14h diagnose: not-connected -> rc 1 + the still-booting-or-dropped verdict"
_awd_test silent   1 "no answer within 8s" "14i diagnose: silent virsh -> rc 1 + the no-answer verdict"
ck_grep "14j the diagnose ping actually ran through the fake virsh" "qemu-agent-command GAMING" "$H/out/virsh-calls"

# 15 (R90): the MANAGER debug window opens with the same 200-line BACKLOG
# as the journal window — all three terminal variants + both manual
# fallback notes print "tail -n 200 -F <logs>", and the manager dedup
# pattern matches the new command line (the R84 lesson).
ck_grep "15a the manager dedup pattern matches the new backlog command" '_tail_pat="tail -n 200 -F $VM_TUI_DEBUG_LOG"' "$REPO/vfio.sh"
_n200="$(grep -cF 'tail -n 200 -F "$VM_TUI_DEBUG_LOG" "$VM_TUI_LOG_FILE"' "$REPO/vfio.sh" || true)"
if [[ "$_n200" == "2" ]]; then
  printf 'PASS: 15b both direct branches (konsole + xterm) use tail -n 200 -F\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 15b expected 2 direct backlog tails, saw %s\n' "${_n200:-0}" >&2; FAIL=$((FAIL+1)); FAILED+=("15b direct branch count")
fi
ck_grep "15c the gnome-terminal branch uses the backlog form" 'bash -c "tail -n 200 -F $VM_TUI_DEBUG_LOG $VM_TUI_LOG_FILE"' "$REPO/vfio.sh"
ck_grep "15d the root-fallback note prints the backlog command" 'note "  tail -n 200 -F $VM_TUI_DEBUG_LOG $VM_TUI_LOG_FILE"' "$REPO/vfio.sh"
ck_grep "15e the no-emulator note prints the backlog command" 'note "Debug log (no terminal emulator found): tail -n 200 -F $VM_TUI_DEBUG_LOG $VM_TUI_LOG_FILE in another terminal"' "$REPO/vfio.sh"
ck_not_grep "15f no old 10-line-default tail form remains (quoted)" 'tail -F "$VM_TUI_DEBUG_LOG"' "$REPO/vfio.sh"
ck_not_grep "15g no old 10-line-default tail form remains (unquoted)" 'tail -F $VM_TUI_DEBUG_LOG' "$REPO/vfio.sh"

# 16 (R91): the debug windows SAY what they carry — backlog-aware titles,
# option-9 sub-menu labels, and the plain-mode prompt all name the
# last-200-lines + live behavior.
ck_grep "16a the manager window title names the backlog" '_win_title="VFIO manager logs (last 200 + live)"' "$REPO/vfio.sh"
ck_grep "16b the journal window title names the backlog" '_win_title="VFIO journal (all tags — last 200 + live)"' "$REPO/vfio.sh"
ck_grep "16c the manager sub-menu label names the backlog" '"1" "Manager logs (debug events + Looking Glass client — last 200 lines + live)"' "$REPO/vfio.sh"
ck_grep "16d the plain-mode prompt names the backlog" 'Open log windows (each shows the last 200 lines, then live)' "$REPO/vfio.sh"

# 17 (R92): the option-9 debug-log viewer (shown when debug is ON and the
# disable prompt is declined) is aligned with the windows' 200-line
# standard — the header, the tail, and the live-follow hint.
ck_grep "17a the viewer header says last 200" 'say "Debug log: $VM_TUI_DEBUG_LOG (${_n:-0} lines) — last 200:"' "$REPO/vfio.sh"
ck_grep "17b the viewer tails 200 lines" 'tail -n 200 "$VM_TUI_DEBUG_LOG" 2>/dev/null || true' "$REPO/vfio.sh"
ck_grep "17c the live-follow hint carries the backlog" 'say "Live-follow in another terminal: tail -n 200 -f $VM_TUI_DEBUG_LOG"' "$REPO/vfio.sh"
ck_not_grep "17d no 40-line viewer header remains" '— last 40:' "$REPO/vfio.sh"
ck_not_grep "17e no 40-line debug-log tail remains" 'tail -n 40 "$VM_TUI_DEBUG_LOG"' "$REPO/vfio.sh"

# 18 (R93): every host-app readiness check accepts BOTH IVSHMEM magics —
# the legacy KVMFR header (4b564d4652) and the B7 host app's LGMP session
# header (4c474d50 + version; verified LIVE on this host after the user
# installed the Windows host app). Statics + functional units of the
# extracted hoststate chain AND the watcher's standalone twin, plus an
# end-to-end watcher-fires-on-LGMP drive.
ck_grep "18a the dual-magic helper is defined (vm-tui block)" 'vmtui_lg_magic_ok()' "$REPO/vfio.sh"
_nlgmp="$(grep -cF '"${1:0:8}" == "4c474d50"' "$REPO/vfio.sh" || true)"
if [[ "$_nlgmp" == "2" ]]; then
  printf 'PASS: 18b BOTH the vm-tui helper AND the watcher twin accept the LGMP magic\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 18b expected 2 LGMP acceptors (helper + watcher twin), saw %s\n' "${_nlgmp:-0}" >&2; FAIL=$((FAIL+1)); FAILED+=("18b LGMP acceptor count")
fi
ck_grep "18c the vm-tui hoststate delegates to the dual-magic helper" 'if vmtui_lg_magic_ok "$_hex"; then' "$REPO/vfio.sh"
ck_grep "18d the watcher's standalone twin is defined" 'magic_ok()' "$REPO/vfio.sh"
# 18e-18g functional: the extracted hoststate chain (magic_ok + shm_file +
# hoststate) against KVMFR / LGMP / zeroed fake shms via the VM_TUI_LG_SHM pin.
sed -n '/^vmtui_lg_magic_ok()/,/^}/p; /^vmtui_lg_shm_file()/,/^}/p; /^vmtui_lg_hoststate()/,/^}/p' "$REPO/vfio.sh" > "$H/magfn.sh"
printf 'KVMFR' > "$H/out/shm-kvmfr"
printf 'LGMP\x06' > "$H/out/shm-lgmp"
printf '\x00\x00\x00\x00\x00' > "$H/out/shm-zero"
_hs_test() {
  local _shm="$1" _want="$2" _name="$3" _rc=0
  VM_TUI_LG_SHM="$_shm" bash -c "source '$H/magfn.sh'; vmtui_lg_hoststate" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" == "$_want" ]]; then
    printf 'PASS: %s\n' "$_name"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (rc=%s wanted=%s)\n' "$_name" "$_rc" "$_want" >&2; FAIL=$((FAIL+1)); FAILED+=("$_name")
  fi
}
_hs_test "$H/out/shm-kvmfr" 0 "18e hoststate: the legacy KVMFR magic -> ready"
_hs_test "$H/out/shm-lgmp"  0 "18f hoststate: the B7 LGMP session magic -> ready (the live R93 case)"
_hs_test "$H/out/shm-zero"  1 "18g hoststate: a zeroed shm -> not initialized"
# 18h-18i functional: the WATCHER's standalone twin against LGMP / zeros.
sed -n '/write_file_atomic "$LG_AUTOSTART_WATCHER" 0755 "root:root" <<.WATCHEREOF./,/^WATCHEREOF$/p' "$REPO/vfio.sh" | sed '1d;$d' > "$H/watcher93.sh"
sed -n '/^magic_ok()/,/^}/p; /^shm_file()/,/^}/p; /^host_app_ready()/,/^}/p' "$H/watcher93.sh" > "$H/wfn93.sh"
if VM_TUI_LG_SHM="$H/out/shm-lgmp" bash -c "source '$H/wfn93.sh'; host_app_ready" >/dev/null 2>&1; then
  printf 'PASS: 18h the watcher twin: LGMP shm -> host app ready\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 18h the watcher twin did not accept the LGMP magic\n' >&2; FAIL=$((FAIL+1)); FAILED+=("18h watcher LGMP ready")
fi
if VM_TUI_LG_SHM="$H/out/shm-zero" bash -c "source '$H/wfn93.sh'; host_app_ready" >/dev/null 2>&1; then
  printf 'FAIL: 18i the watcher twin accepted a zeroed shm as ready\n' >&2; FAIL=$((FAIL+1)); FAILED+=("18i watcher zero not-ready")
else
  printf 'PASS: 18i the watcher twin: zeroed shm -> not ready\n'; PASS=$((PASS+1))
fi
# 18j: the extracted watcher is valid bash
if bash -n "$H/watcher93.sh"; then
  printf 'PASS: 18j the extracted watcher is valid bash\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 18j the extracted watcher failed bash -n\n' >&2; FAIL=$((FAIL+1)); FAILED+=("18j watcher syntax")
fi
# 18k-18l end-to-end: the watcher FIRES on an LGMP shm (fake virsh=running,
# fake client via VM_TUI_LG_BIN, fake notify-send, isolated log, poll=1s).
cat > "$H/bin/looking-glass-client" <<'EOF'
#!/usr/bin/env bash
H="${R82_H:?}"
printf 'client93-argv: %s\n' "$*" >> "$H/out/e2e93"
touch "$H/out/client93-ran"
sleep 2
EOF
cat > "$H/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
H="${R82_H:?}"
printf 'notify93: %s\n' "$*" >> "$H/out/e2e93"
exit 0
EOF
chmod +x "$H/bin/looking-glass-client" "$H/bin/notify-send"
rm -f "$H/out/e2e93" "$H/out/client93-ran" "$H/out/lg93e2e.log"
env R82_H="$H" R82_VIRSH_MODE=running \
  VM_TUI_LG_SHM="$H/out/shm-lgmp" VM_TUI_LG_BIN="$H/bin/looking-glass-client" \
  VM_TUI_LOG="$H/out/lg93e2e.log" VFIO_LG_AUTOSTART_POLL=1 \
  PATH="$H/bin:/usr/bin:/bin" bash "$H/watcher93.sh" GAMING >/dev/null 2>&1 &
_w93=$!
sleep 3
kill "$_w93" 2>/dev/null || true
if [[ -e "$H/out/client93-ran" ]]; then
  printf 'PASS: 18k end-to-end: the watcher LAUNCHED the client on the LGMP magic (the R93 fix)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 18k end-to-end: the watcher did not fire on the LGMP shm\n' >&2; FAIL=$((FAIL+1)); FAILED+=("18k watcher fires on LGMP")
fi
ck_grep "18l end-to-end: the launch + the readiness line are logged" "client launched detached" "$H/out/lg93e2e.log"

# 19 (R94): the Modify-VM "Set up Looking Glass" path makes the whole chain
# seamless — the SPICE USB redirector is ensured in every VM (idempotent,
# both apply paths), and the setup ENDS with the install-the-Windows-host-
# app final step.
ck_grep "19a the USB-redirector patcher is defined" '_lg_ensure_usb_redir_to_vm()' "$REPO/vfio.sh"
_nur="$(grep -cF '_lg_ensure_usb_redir_to_vm "$_' "$REPO/vfio.sh" || true)"
if [[ "$_nur" == "2" ]]; then
  printf 'PASS: 19b both LG apply paths call the patcher (install_looking_glass + _lg_apply_to_vm)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 19b expected 2 patcher call sites, saw %s\n' "${_nur:-0}" >&2; FAIL=$((FAIL+1)); FAILED+=("19b patcher call sites")
fi
ck_grep "19c the final step tells the user to install the Windows host app" 'looking-glass-host-setup.exe' "$REPO/vfio.sh"
ck_grep "19d the USB-audio sound setting is named" 'Looking Glass USB Audio' "$REPO/vfio.sh"
ck_grep "19e the hotplug defaults path got the host-app one-liner too" 'without it the display stays black' "$REPO/vfio.sh"
# 19f-19g functional: the extracted patcher against a fake VM XML —
# without a redirdev it ADDS one; on the patched XML it exits 3 (idempotent).
sed -n '/^_lg_ensure_usb_redir_to_vm()/,/^}/p' "$REPO/vfio.sh" > "$H/urfn.sh"
cat > "$H/out/vm94.xml" <<'EOF'
<domain type='kvm'>
  <name>testvm</name>
  <devices>
    <graphics type='spice'/>
  </devices>
</domain>
EOF
_ur94=0
bash -c "source '$H/urfn.sh'; _lg_ensure_usb_redir_to_vm '$H/out/vm94.xml'" >/dev/null 2>&1 || _ur94=$?
if [[ "$_ur94" == "0" ]] && grep -q "redirdev" "$H/out/vm94.xml" && grep -q "spicevmc" "$H/out/vm94.xml"; then
  printf 'PASS: 19f the patcher added a spicevmc USB redirector to a VM without one\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 19f patcher run rc=%s, redirdev lines: %s\n' "$_ur94" "$(grep -c redirdev "$H/out/vm94.xml" 2>/dev/null || echo 0)" >&2; FAIL=$((FAIL+1)); FAILED+=("19f patcher adds redirector")
fi
_ur94b=0
bash -c "source '$H/urfn.sh'; _lg_ensure_usb_redir_to_vm '$H/out/vm94.xml'" >/dev/null 2>&1 || _ur94b=$?
if [[ "$_ur94b" == "3" ]]; then
  printf 'PASS: 19g the patcher is idempotent (exit 3 when a redirector exists)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 19g idempotent re-run got rc=%s (wanted 3)\n' "$_ur94b" >&2; FAIL=$((FAIL+1)); FAILED+=("19g patcher idempotent")
fi

# 20 (R95): zombie forensics in the generated libvirt hook — the per-domain
# session-start stamp at prepare + the stop reason/session log at every
# actual stop. Statics + a functional unit of the extracted forensics
# function (fake virsh reason + a planted start-stamp; NO real release path).
ck_grep "20a the forensics logger is defined in the hook" '_log_vm_stop_forensics()' "$REPO/vfio.sh"
ck_grep "20b the prepare phase stamps the per-domain session start" 'vm-start.$DOMAIN.ts' "$REPO/vfio.sh"
ck_grep "20c the stop log names the reason + session" "action=vm-stopped domain=\$_dom reason=" "$REPO/vfio.sh"
ck_grep "20d the stopped phase calls the logger (gated to real stops)" '_log_vm_stop_forensics "$DOMAIN"' "$REPO/vfio.sh"
sed -n '/write_file_atomic "$LIBVIRT_HOOK_SCRIPT" 0755 "root:root" <<.EOF./,/^EOF$/p' "$REPO/vfio.sh" | sed '1d;$d' > "$H/hook95.sh"
sed -n '/^_log_vm_stop_forensics()/,/^}/p' "$H/hook95.sh" > "$H/forensics95.sh"
# 20e: the extracted hook is valid bash
if bash -n "$H/hook95.sh"; then
  printf 'PASS: 20e the extracted hook is valid bash\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 20e the extracted hook failed bash -n\n' >&2; FAIL=$((FAIL+1)); FAILED+=("20e hook syntax")
fi
# 20f-20h functional: the forensics logger with a fake reason + a planted
# start-stamp (100s ago) -> reason + session logged; without the stamp ->
# session=unknown. VFIO_DYNAMIC_DIR pins the stamp dir to the scratch.
mkdir -p "$H/out/vfdyn95"
printf '%s\n' "$(( $(date +%s) - 100 ))" > "$H/out/vfdyn95/vm-start.GAMING.ts"
rm -f "$H/out/hooklog95"
R82_H="$H" R82_VIRSH_MODE=reason VFIO_DYNAMIC_DIR="$H/out/vfdyn95" \
  PATH="$H/bin:/usr/bin:/bin" \
  bash -c "hook_log() { printf 'hooklog: %s\n' \"\$*\" >>'$H/out/hooklog95'; }; source '$H/forensics95.sh'; _log_vm_stop_forensics GAMING" >/dev/null 2>&1 || true
ck_grep "20f the stop reason is logged from libvirt's classification" "reason='shut off (destroyed)'" "$H/out/hooklog95"
if grep -Eq "session=[0-9]+s" "$H/out/hooklog95" 2>/dev/null; then
  printf 'PASS: 20g the session length is computed from the start stamp\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 20g no session=<n>s in the stop log (%s)\n' "$(cat "$H/out/hooklog95" 2>/dev/null || echo '<empty>')" >&2; FAIL=$((FAIL+1)); FAILED+=("20g session length logged")
fi
rm -f "$H/out/vfdyn95/vm-start.GAMING.ts" "$H/out/hooklog95"
R82_H="$H" R82_VIRSH_MODE=reason VFIO_DYNAMIC_DIR="$H/out/vfdyn95" \
  PATH="$H/bin:/usr/bin:/bin" \
  bash -c "hook_log() { printf 'hooklog: %s\n' \"\$*\" >>'$H/out/hooklog95'; }; source '$H/forensics95.sh'; _log_vm_stop_forensics GAMING" >/dev/null 2>&1 || true
ck_grep "20h a missing start stamp logs session=unknown (never fatal)" "session=unknown" "$H/out/hooklog95"

# 21 (R96): the mode-preserving dead-GPU fallback — the user's hotplug-OFF
# choice SURVIVES the rescue flip (pending-restore flag), the stopped phase
# restores it once the card is healthy (post-reboot), the prepare phase
# notifies "you can use hot-attach now", and a deliberate user toggle
# always clears the flag.
ck_grep "21a the fallback writes the pending-restore flag" 'restore-mode-off.$DOMAIN' "$REPO/vfio.sh"
ck_grep "21b the fallback logs the remembered choice" 'action=fallback-remembers-mode-off domain=$DOMAIN' "$REPO/vfio.sh"
ck_grep "21c the stopped phase restores the user's hotplug-off choice" 'action=mode-restoring domain=$DOMAIN' "$REPO/vfio.sh"
ck_grep "21d the prepare phase notifies 'card is alive again'" 'action=card-alive-again domain=$DOMAIN' "$REPO/vfio.sh"
ck_grep "21e the hook defines the liveness probe for the restore logic" '_gpu_alive_now()' "$REPO/vfio.sh"
_nnd="$(grep -cF '_notify_desktop()' "$REPO/vfio.sh" || true)"
if [[ "$_nnd" == "3" ]]; then
  printf 'PASS: 21f the desktop notifier exists in all 3 generated scripts (hook + live-attach helper + bind script)\n'; PASS=$((PASS+1))
else
  printf 'FAIL: 21f expected 3 _notify_desktop definitions (hook + helper + bind), saw %s\n' "${_nnd:-0}" >&2; FAIL=$((FAIL+1)); FAILED+=("21f notifier definitions")
fi
ck_grep "21g a deliberate user toggle clears the pending-restore flag" 'rm -f "/var/lib/vfio-dynamic/restore-mode-off.$_dom"' "$REPO/vfio.sh"
ck_grep "21h the alive-again message names hot-attach (the requested wording)" 'you can use hot-attach now' "$REPO/vfio.sh"

# 22 (R97): every libvirt call the hook makes is TIMEOUT-BOUNDED — the live
# freeze (qemu died mid-reset on the zombie card, virtqemud in an I/O-error
# loop) hung the R95/R96 hook's unbounded calls, and the two hung "stopped
# end" hook processes blocked libvirt's stop job (virsh destroy + virt-manager
# queued forever). A hook must never deepen a libvirt wedge.
ck_grep "22a the forensics reason call is bounded (timeout 5)" 'timeout 5 virsh -c qemu:///system domstate --reason' "$REPO/vfio.sh"
ck_grep "22b the mode-restore CLI is bounded (timeout 25)" 'timeout 25 /usr/local/bin/vfio --live-attach-off' "$REPO/vfio.sh"
ck_grep "22c the fallback worker's on call is bounded (timeout 30)" 'timeout 30 /usr/local/bin/vfio --live-attach-on' "$REPO/vfio.sh"
ck_grep "22d the fallback worker's start call is bounded (timeout 30)" 'timeout 30 virsh -c qemu:///system start' "$REPO/vfio.sh"
# 22e functional: the bounded forensics still logs the reason (the fake virsh
# returns instantly; the timeout passes through) — re-run the 20f scenario.
rm -f "$H/out/hooklog95"
printf '%s\n' "$(( $(date +%s) - 100 ))" > "$H/out/vfdyn95/vm-start.GAMING.ts"
R82_H="$H" R82_VIRSH_MODE=reason VFIO_DYNAMIC_DIR="$H/out/vfdyn95" \
  PATH="$H/bin:/usr/bin:/bin" \
  bash -c "hook_log() { printf 'hooklog: %s\n' \"\$*\" >>'$H/out/hooklog95'; }; source '$H/forensics95.sh'; _log_vm_stop_forensics GAMING" >/dev/null 2>&1 || true
ck_grep "22e the bounded forensics still logs the reason + session" "reason='shut off (destroyed)'" "$H/out/hooklog95"

echo
echo "PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
  echo "FAIL SUMMARY ($FAIL):"
  for f in "${FAILED[@]}"; do echo " - $f"; done
  exit 1
fi
echo "ALL CHECKS PASSED"
