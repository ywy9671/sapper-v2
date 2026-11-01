#!/usr/bin/env bash
# entrypoint.sh — commander-architecture container start (unit 4).
#
# Brings up tmux session 'sapper-cmd' (window 0 = 'commander'), starts the
# watchdog guardian in the background, boots the claude commander TUI and
# injects its bootstrap prompt, then stays in the foreground so the container
# lives exactly as long as the campaign does.
#
# Failure modes handled:
#   - missing platform/gateway env               -> fail loud (FATAL) before anything starts
#   - platform unreachable                       -> fail loud (no silent hang: logs are not viewable)
#   - model gateway dead / wrong key             -> smoke test warns (loops rotate keys later)
#   - first-boot claude trust dialogs            -> global + per-cwd preset, Down+Enter auto-accept
#   - commander TUI dies                         -> pane ends with DRIVE_PANE_EXITED; watchdog relaunches
#   - watchdog process crash                     -> entrypoint supervises + respawns (<=3) until deadline
#   - post-deadline resurrection                 -> once now >= END_AT a dead watchdog is NOT respawned
#                                                   (a fresh watchdog would restart a full new budget)
#   - invisible logs                             -> drive.log is tailed to stdout (docker logs)
set -uo pipefail

log() { printf '[sapper-cmd] %s\n' "$*"; }
die() { printf '[sapper-cmd] FATAL: %s\n' "$*" >&2; exit 1; }

ROOT="${SAPPER_ROOT:-/work/runs}"
MODE="${SAPPER_MODE:-platform}"
if [[ "$MODE" == general ]]; then
  export SAPPER_STATE_ROOT="${SAPPER_STATE_ROOT:-$ROOT/.general}"
else
  export SAPPER_STATE_ROOT="${SAPPER_STATE_ROOT:-$ROOT}"
fi
mkdir -p "$SAPPER_STATE_ROOT"
[[ "$MODE" == general ]] || die "Pi adapter supports general mode only"
export SAPPER_BIN="/opt/sapper/docker/commander/pi-agent.py sapper"
LOG="$SAPPER_STATE_ROOT/drive.log"
MODEL="${SAPPER_MODEL:-glm-5.3[1m]}"   # commander brain: SMART tier
TOTAL_MIN="${SAPPER_TOTAL_MINUTES:-470}"
SESSION=sapper-cmd
CMD_HOME="$SAPPER_STATE_ROOT/commander-home"
WATCHDOG=/opt/sapper/docker/commander/watchdog.sh

# ---- 1. required env (platform + model gateway) ----------------------------
if [[ "$MODE" != general ]]; then
  [[ -n "${BENCHMARK_BASE_URL:-}" ]] || die "BENCHMARK_BASE_URL is not set"
  [[ -n "${BENCHMARK_TOKEN:-}" ]] || die "BENCHMARK_TOKEN is not set"
fi
: "${ANTHROPIC_BASE_URL:?set ANTHROPIC_BASE_URL}"
: "${ANTHROPIC_AUTH_TOKEN:?set ANTHROPIC_AUTH_TOKEN}"
export ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 \
       DISABLE_ERROR_REPORTING=1 DISABLE_AUTOUPDATER=1 IS_SANDBOX=1

mkdir -p "$ROOT" "$CMD_HOME"

# ---- pane primitives (verbatim from tmux-drive.sh) -------------------------
pane_text() { tmux capture-pane -pt "$SESSION:$1" 2>/dev/null; }

send_literal() {  # send_literal <window> <text> [enter]
  tmux send-keys -t "$SESSION:$1" -l -- "$2"
  sleep 0.5
  [[ "${3:-enter}" == "enter" ]] && tmux send-keys -t "$SESSION:$1" Enter
}

accept_dialogs() {  # accept_dialogs <window> <pane> -> 0 if a dialog was dismissed
  local win="$1" pane="$2"
  if printf '%s' "$pane" | grep -q 'Enter to confirm'; then
    tmux send-keys -t "$SESSION:$win" Down; sleep 0.4
    tmux send-keys -t "$SESSION:$win" Enter; sleep 1.5
    return 0
  fi
  return 1
}

# ---- 5. tmux session: window 0 = 'commander' -------------------------------
CMDER_CMD="cd '$CMD_HOME' && /opt/sapper/docker/commander/pi-agent.py tui commander '$MODEL' 2>&1; echo DRIVE_PANE_EXITED; exec sleep infinity"
adopted=0
if tmux has-session -t "$SESSION" 2>/dev/null; then
  if [[ "$MODE" == general ]] && tmux list-windows -t "$SESSION" -F "#W" | grep -qx commander; then
    adopted=1
    log "adopting existing commander session"
  else
    tmux kill-window -t "$SESSION:commander" 2>/dev/null || true
    tmux new-window -d -t "$SESSION" -n commander "$CMDER_CMD"
  fi
else
  tmux new-session -d -s "$SESSION" -n commander "$CMDER_CMD"
fi
log "tmux session '$SESSION' up (window 0 = commander, cwd $CMD_HOME)"

log "Pi commander ready; task instructions are supplied as system context"

# ---- 8. watchdog in the background, drive.log in the foreground ------------
[[ -x "$WATCHDOG" ]] || die "watchdog missing: $WATCHDOG (image build broken?)"
touch "$LOG"

start_watchdog() {
  nohup bash "$WATCHDOG" >>"$LOG" 2>&1 &
  WATCHDOG_PID=$!
  log "watchdog started (pid $WATCHDOG_PID)"
}

END_AT=$(( $(date +%s) + TOTAL_MIN * 60 ))
if (( adopted )) && [[ "$MODE" == general && -s "$SAPPER_STATE_ROOT/.deadline" ]]; then
  read -r saved_deadline < "$SAPPER_STATE_ROOT/.deadline"
  [[ "$saved_deadline" =~ ^[0-9]+$ ]] && END_AT=$saved_deadline
fi
printf '%s\n' "$END_AT" > "$SAPPER_STATE_ROOT/.deadline"   # single source of truth for the war clock
MAX_WDG_RESPAWNS=3
wdg_respawns=0

start_watchdog
tail -F -n0 "$LOG" &
TAIL_PID=$!

# Foreground supervisor: the watchdog is the guardian, this is its safety net.
# The watchdog itself re-creates the tmux session at startup, so respawning it
# also covers a vanished session. After the deadline a dead watchdog stays
# dead — otherwise a respawn would hand itself a fresh full budget and never
# let the container finish.
while true; do
  sleep 15
  kill -0 "$WATCHDOG_PID" 2>/dev/null && continue
  if (( $(date +%s) >= END_AT )); then
    log "watchdog finished at deadline — campaign wrapped, container done"
    break
  fi
  if (( wdg_respawns >= MAX_WDG_RESPAWNS )); then
    log "FATAL: watchdog died $wdg_respawns times before the deadline — giving up"
    break
  fi
  wdg_respawns=$((wdg_respawns+1))
  log "WATCHDOG: process died unexpectedly — respawning ($wdg_respawns/$MAX_WDG_RESPAWNS)"
  start_watchdog
done
kill "$TAIL_PID" 2>/dev/null || true
