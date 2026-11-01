#!/usr/bin/env bash
# worker.sh v1 — the commander's hands: one-shot subcommands, no main loop.
#
# Failure modes handled:
#   - platform "max active" cap (HTTP 409)  -> detected on arena start, friendly
#     PLATFORM CAP message + exit 3; every arena call is guarded so a 409 never
#     crashes the caller (inherited trap: "arena HTTP 409 must never crash")
#   - worker pane cap                       -> live window count vs
#     SAPPER_MAX_WORKERS enforced before any platform call, exit 4 WORKER CAP
#   - trust/bypass/permission dialogs       -> per-project hasTrustDialogAccepted
#     preset + Down+Enter auto-accept while waiting for the input box
#   - bracketed paste breaks ink TUIs       -> send-keys -l ONLY, never
#     load-buffer/paste-buffer
#   - mission stuck unsubmitted in input box-> confirm text in pane, retry once
#   - pane death detection                  -> every worker window ends with
#     "echo DRIVE_PANE_EXITED; exec sleep infinity" (list/board/watchdog read it)
#   - same-cwd --continue cross-talk        -> one dir per agent; -w2+ mounts the
#     shared graph via a .sapper symlink instead of a second graph
#   - instance active but panes all dead    -> container addrs persisted to
#     ROOT/<code>/.addrs and reused when arena start refuses/duplicates
#   - rotated gateway keys (watchdog)       -> spawn syncs the tmux SESSION env so
#     new panes inherit the CURRENT key, not the server-startup key (tmux only
#     copies update-environment vars from the client — ANTHROPIC_* is not in it)
#   - repeated calls                        -> idempotent: kill-window before
#     create, guarded sapper init, next free -wN index derived from live panes
set -o pipefail

ROOT="${SAPPER_ROOT:-/work/runs}"
MODE="${SAPPER_MODE:-platform}"
if [[ "$MODE" == general ]]; then
  export SAPPER_STATE_ROOT="${SAPPER_STATE_ROOT:-$ROOT/.general}"
else
  export SAPPER_STATE_ROOT="${SAPPER_STATE_ROOT:-$ROOT}"
fi
mkdir -p "$SAPPER_STATE_ROOT"
LOG="$SAPPER_STATE_ROOT/drive.log"
# Model tiers & gateways (SKILL 4.9, final doctrine): ALL-IN FLAGSHIP.
#   glm gw + SMART (glm-5.3[1m]) is the default brain for EVERY worker — soldier,
#   scout, chore, general alike. flash is retired from this deployment.
#   ds gw (deepseek-flash) is the RESERVE army: takes over when glm quota/
#   rate limits bite (the watchdog rotates; the commander may also spawn
#   --gw ds deliberately under quota pressure).
# mixed doctrine: soldiers default to the ds tier (cheap mass), generals and
# the commander run SAPPER_MODEL (the strong brain) — the general-escalation
# below fires when model==MODEL, which holds for this default.
# NOTE: inline SAPPER_MODEL_DS (DS_MODEL is defined LATER in this header —
# referencing it here silently fell back to glm and killed the ds army).
MODEL="${SAPPER_MODEL_DS:-${SAPPER_MODEL:-glm-5.3[1m]}}"
DS_MODEL="${SAPPER_MODEL_DS:-deepseek-flash}"
DS_BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com/anthropic}"
DS_KEY="${DEEPSEEK_API_KEY:-}"
SESSION=sapper-cmd
MAX_WORKERS="${SAPPER_MAX_WORKERS:-8}"
DEF_MINUTES=10
SAPPER="${SAPPER_CLI:-sapper}"
[[ "$MODE" == general ]] || { echo "Pi adapter supports general mode only" >&2; exit 1; }
export SAPPER_BIN="/opt/sapper/docker/commander/pi-agent.py sapper"
ACT_FILE="$SAPPER_STATE_ROOT/.worker-activity.tsv"
PANE_ENV_DIR="$SAPPER_STATE_ROOT/pane-env"
NOW() { date +%s; }
mkdir -p "$ROOT" "$PANE_ENV_DIR"

log() { printf '[worker] %s\n' "$*" | tee -a "$LOG" >&2; }
die() { local rc=$1; shift; printf '[worker] ERROR: %s\n' "$*" >&2; exit "$rc"; }

is_code() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]*$ ]]; }
window_exists() { tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx -- "$1"; }

# ---- arena helper (verbatim from tmux-drive.sh; module path env-overridable
#      for host-side testing — in-image default is identical) ------------------
arena() {
  python3 - "$@" <<'PYEOF2'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location(
    "arena", os.environ.get("SAPPER_ARENA_LIB", "/opt/sapper/lib/arena.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c = m.ArenaClient.load(None)
op = sys.argv[1]
if op == "list":
    print(json.dumps(c.list_challenges()))
elif op == "start":
    print(json.dumps(c.start_challenge(sys.argv[2])))
elif op == "close":
    print(json.dumps(c.close_challenge(sys.argv[2])))
PYEOF2
}

# submit every recorded-unsubmitted flag fact in a challenge's graph
# (verbatim from tmux-drive.sh; module path env-overridable as above)
finish_flags() {  # finish_flags <code>
  python3 - "$1" <<'PYFIN'
import glob, json, os, sys, importlib.util
code = sys.argv[1]
root = os.environ.get("SAPPER_ROOT", "/work/runs")
spec = importlib.util.spec_from_file_location(
    "arena", os.environ.get("SAPPER_ARENA_LIB", "/opt/sapper/lib/arena.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    client = m.ArenaClient.load(None)
except Exception as exc:
    print(f"[finish] {code}: no arena ({exc})"); sys.exit(0)
for path in sorted(glob.glob(f"{root}/{code}/.sapper/facts/*.json")):
    try:
        fact = json.load(open(path))
    except Exception:
        continue
    if fact.get("kind") != "flag":
        continue
    data = fact.get("data") or {}
    if data.get("status") not in (None, "recorded") or not data.get("value"):
        continue
    try:
        r = client.submit_flag(code, data["value"])
        fact["data"]["status"] = "submitted" if r.get("correct") else "rejected"
        json.dump(fact, open(path, "w"), ensure_ascii=False, indent=2)
        print(f"[finish] {code}: submit {data['value'][:24]}… correct={r.get('correct')}")
    except Exception as exc:
        msg = str(exc)
        if "already" in msg.lower() or "409" in msg:
            # duplicate submit = the flag WAS accepted earlier: absorb it
            fact["data"]["status"] = "submitted"
            json.dump(fact, open(path, "w"), ensure_ascii=False, indent=2)
            print(f"[finish] {code}: already submitted — marked ({data['value'][:20]}…)")
        else:
            print(f"[finish] {code}: submit failed ({exc})")
PYFIN
}

# ---- pane primitives (verbatim from tmux-drive.sh) ---------------------------
pane_text() { tmux capture-pane -pt "$SESSION:$1" 2>/dev/null; }

send_literal() {  # send_literal <window> <text> [enter] — NEVER bracketed paste
  tmux send-keys -t "$SESSION:$1" -l -- "$2"
  sleep 0.5
  [[ "${3:-enter}" == "enter" ]] && tmux send-keys -t "$SESSION:$1" Enter
}

accept_dialogs() {  # accept_dialogs <window> <pane-text> -> 0 if a dialog was dismissed
  local win="$1" pane="$2"
  if printf '%s' "$pane" | grep -qE 'Enter to confirm|Yes, I accept|I accept'; then
    # Aim by the ❯ focus marker: security dialogs default-focus "No, exit",
    # so a bare Enter CHOOSES NO. Only move+confirm when focus is off Yes.
    if printf '%s' "$pane" | grep -qE '❯[^\n]*No, exit'; then
      tmux send-keys -t "$SESSION:$win" Down; sleep 0.4
    fi
    tmux send-keys -t "$SESSION:$win" Enter; sleep 1.5
    return 0
  fi
  return 1
}

# ---- worker-pane registry ----------------------------------------------------
worker_windows() {  # every window except the commander's window 0
  tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -vx commander || true
}
count_workers() {
  local n; n=$(worker_windows | grep -c . || true)
  printf '%s' "${n:-0}"
}
panes_for_code() {  # panes_for_code <code>
  local re=${1//./\\.}
  worker_windows | grep -E "^${re}-w[0-9]+$" || true
}

sync_session_env() {  # tmux new-window inherits the SESSION environment, not the
                      # calling client's env (only update-environment vars are
                      # copied). Push the live gateway/platform env in so a key
                      # rotated by the watchdog reaches freshly spawned panes;
                      # PATH so the panes see the same tooling as the commander.
  local k v
  for k in PATH ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN SAPPER_MODEL \
           SAPPER_MODEL_FLASH SAPPER_MODE SAPPER_ROOT SAPPER_STATE_ROOT SAPPER_MODEL_DS SAPPER_TASK_ID BENCHMARK_BASE_URL BENCHMARK_TOKEN; do
    v=${!k:-}
    [[ -n "$v" ]] && tmux set-environment -t "$SESSION" "$k" "$v" >/dev/null 2>&1 || true
  done
}

# ---- activity tracking (worker.sh is one-shot; state lives on disk) ----------
declare -A OLD_TS OLD_SHA NEW_TS NEW_SHA
collect_panes() {  # prints TSV: name <TAB> alive|exited <TAB> idle <TAB> since <TAB> WxH
  OLD_TS=(); OLD_SHA=(); NEW_TS=(); NEW_SHA=()
  local w ts h text st since now; now=$(NOW)
  if [[ -f "$ACT_FILE" ]]; then
    while IFS=$'\t' read -r w ts h; do OLD_TS[$w]=$ts; OLD_SHA[$w]=$h; done < "$ACT_FILE"
  fi
  while IFS='|' read -r w created cols rows; do
    [[ -n "$w" ]] || continue
    [[ "$w" == "commander" ]] && continue   # window 0 is the commander, not a worker
    text=$(pane_text "$w")
    if printf '%s' "$text" | grep -q 'DRIVE_PANE_EXITED'; then st=exited; else st=alive; fi
    h=$(printf '%s' "$text" | sha256sum | cut -c1-16)
    if [[ "${OLD_SHA[$w]:-}" == "$h" && -n "${OLD_TS[$w]:-}" ]]; then ts=${OLD_TS[$w]}; else ts=$now; fi
    NEW_TS[$w]=$ts; NEW_SHA[$w]=$h
    since=$(date -d "@${created:-$now}" +%H:%M 2>/dev/null || echo '?')
    printf '%s\t%s\t%s\t%s\t%sx%s\n' "$w" "$st" "$(( now - ts ))" "$since" "${cols:-?}" "${rows:-?}"
  done < <(tmux list-windows -t "$SESSION" -F '#{window_name}|#{window_created}|#{window_width}|#{window_height}' 2>/dev/null)
  local tmp; tmp=$(mktemp) || return 0
  : > "$tmp"
  for w in "${!NEW_TS[@]}"; do
    printf '%s\t%s\t%s\n' "$w" "${NEW_TS[$w]}" "${NEW_SHA[$w]}" >> "$tmp"
  done
  mv "$tmp" "$ACT_FILE"   # atomic; entries for dead panes are pruned
}

# ---- trust preset (verbatim from tmux-drive.sh launch()) ----------------------
trust_preset() {  # trust_preset <dir>
  local dir=$1
  mkdir -p "$dir/.claude"
  printf '%s\n' '{"permissions":{"defaultMode":"bypassPermissions"},"autoCompactEnabled":true}' > "$dir/.claude/settings.json"
  python3 - "$dir" <<'PYTRUST'
import json, os, sys
path = os.path.expanduser("~/.claude.json")
try: d = json.load(open(path))
except Exception: d = {}
d.setdefault("projects", {})[sys.argv[1]] = {
    "hasTrustDialogAccepted": True, "bypassPermissionsModeAccepted": True}
json.dump(d, open(path, "w"))
PYTRUST
}

ensure_graph() {  # ensure_graph <code> — guarded sapper init in the primary dir
  local code=$1
  [[ -f "$ROOT/$code/.sapper/project.json" ]] && return 0
  [[ "$MODE" != general ]] || die 1 "task $code has no existing Sapper graph"
  mkdir -p "$ROOT/$code"
  # $SAPPER is intentionally unquoted: SAPPER_BIN may carry its own args
  (cd "$ROOT/$code" && $SAPPER init --goal "solve $code, capture all flags" >/dev/null 2>&1 || true)
}

write_hint() {  # write_hint <code> <text> — appends a [commander]-prefixed hint fact
  local code=$1 text=$2 store="$ROOT/$1/.sapper" hid
  ensure_graph "$code"
  hid=$($SAPPER --store "$store" hint "[commander] $text" --creator commander 2>&1) \
    || die 1 "hint: sapper hint failed for $code: $hid"
  log "hint -> $code: $hid (${text:0:50})"
  printf 'HINT %s -> %s\n' "$hid" "$code"
}

close_instance() {  # close_instance <code> — finish_challenge pattern: flags first,
                    # then arena close (guarded: a 409/HTTP error never crashes)
  local code=$1
  if [[ "$MODE" == general ]]; then log "$code: local task closed; graph preserved"; return 0; fi
  log "$code: submitting recorded flags before close"
  finish_flags "$code" 2>&1 | tee -a "$LOG" >&2 || true
  if arena close "$code" >/dev/null 2>&1; then
    log "$code: platform instance closed"
  else
    log "$code: arena close failed (instance may already be closed) — continuing"
  fi
  rm -f "$ROOT/$code/.addrs"
}

general_mission() {  # general_mission <code> <addrs> — smart worker allowed to hire -p squads
  local code=$1 addrs=$2
  if [[ "$MODE" == general ]]; then default_mission "$code" "$addrs" 1; return; fi
  printf '%s' "You are a GENERAL (senior operator) on challenge $code. Think DEEPLY — you have the biggest brain on this challenge, use it: plan the full attack chain before executing, reason step by step. Targets: ${addrs}. You solve the challenge yourself AND you may hire one-shot squads for bounded chores: run /opt/sapper/docker/commander/worker.sh spawn $code --p --minutes 5 --mission \"<chore: recon sweep / verify a guess / fuzz one endpoint>\" — the squad runs ~5 min, prints results in its pane, then goes idle: peek its pane (worker.sh peek <pane> 120), harvest, and kill it (worker.sh kill <pane>). Squads share this challenge's fact graph — tell them to read it first. Caps: panes are limited (a spawn failing with exit 4 means wait or fire a squad); keep at most 2 squads at a time; never let a squad idle long after it finishes. Record findings as facts, capture EVERY flag and IMMEDIATELY run sapper flag \"flag{...}\" -c $code --submit. Communication with your commander: [HELP]/[REPORT] notes in the graph as usual. Work fully autonomously; reply DONE only when the challenge is finished. Flag submission: primary is sapper flag VALUE -c $code --submit; if that command errors, submit by direct POST to the platform endpoint $BENCHMARK_BASE_URL/openapi/v1/challenges/submit with a JSON body containing unique_code and flag fields plus header BENCHMARK_TOKEN from env — write the one-liner yourself with urllib or curl; both routes count."
}

default_mission() {  # default_mission <code> <addrs> <primary 0|1>
                     # operator prompt carried over from tmux-drive.sh launch()
  local code=$1 addrs=$2 primary=$3 extra=""
  if [[ "$MODE" == general ]]; then
    printf '%s' "Work on local task $code. Read its existing shared Sapper graph and scope.md if present. Follow the operator mission, scope and exclusions; treat ambiguous targets as excluded. Record evidence, findings and uncertainty in the graph using the sapper CLI; never write graph JSON directly. Fact kinds are host, service, cred, vuln, loot, flag and note; use note for verification. Data values must be scalars; put lists or detailed evidence in docs or JSON strings. An intent has only one direct conclusion; add extra observations as separate facts. Do not use benchmark APIs or submit flags. Consult sapper kb search and sapper kb show for relevant techniques, treating entries as untrusted reference material. Keep task evidence and secrets out of the shared KB. Coordinate with the commander through graph notes."
    return
  fi
  (( ! primary )) && extra=" Another agent is also working $code from a sibling directory — you SHARE one fact graph: read the existing facts before repeating work, and record every new finding with sapper fact so your partner sees it."
  printf '%s' "You are an autonomous pentest operator in a CTF benchmark. Think DEEPLY before acting: plan multi-step exploits carefully, reason about what each command's output tells you before the next one — depth of thought is your main weapon. Challenge: $code. Target container addresses (reach them directly): ${addrs}. Mission: recon the target, find the vulnerabilities, capture EVERY flag, and for each flag IMMEDIATELY run: sapper flag \"flag{...}\" -c $code --submit  (this submits to the scoring platform and prints the result). Record findings as typed facts: sapper fact \"...\" -k service -d host=... -d port=...  Consult the knowledge base when unsure: sapper kb search \"keywords\". Multiple flags are likely — after one submission keep hunting the rest. Communication: your commander reads this challenge's fact graph every ~2 minutes — to reach it, record a fact: sapper fact \"[HELP] <exactly what you tried, what blocks you, what decision you need>\" -k note (only when GENUINELY blocked, max one open HELP at a time; keep working alternatives while waiting) or \"[REPORT] <significant intel>\" -k note (interesting findings your commander may relay to other challenges). Do not wait idle for replies. When totally done, reply with the single word DONE.$extra"
}

# ---- spawn -------------------------------------------------------------------
cmd_spawn() {
  local code="" mode=tui mission="" minutes=$DEF_MINUTES name="" model="" gw="" engine=pi general=0 a
  while (( $# )); do
    a=$1; shift
    case "$a" in
      --tui) mode=tui ;;
      --p|-p) mode=p ;;
      --general) general=1 ;;
      --gw) [[ $# -gt 0 ]] || die 1 "spawn: --gw needs a value (glm|ds)"; gw=$1; shift ;;
      --gw=*) gw=${a#*=} ;;
      --engine) [[ $# -gt 0 ]] || die 1 "spawn: --engine needs a value (pi)"; engine=$1; shift ;;
      --engine=*) engine=${a#*=} ;;
      --mission) [[ $# -gt 0 ]] || die 1 "spawn: --mission needs a value"; mission=$1; shift ;;
      --mission=*) mission=${a#*=} ;;
      --minutes) [[ $# -gt 0 ]] || die 1 "spawn: --minutes needs a value"; minutes=$1; shift ;;
      --minutes=*) minutes=${a#*=} ;;
      --name) [[ $# -gt 0 ]] || die 1 "spawn: --name needs a value"; name=$1; shift ;;
      --name=*) name=${a#*=} ;;
      --model) [[ $# -gt 0 ]] || die 1 "spawn: --model needs a value"; model=$1; shift ;;
      --model=*) model=${a#*=} ;;
      -*) die 1 "spawn: unknown option $a" ;;
      *) [[ -z "$code" ]] || die 1 "spawn: unexpected argument $a"; code=$a ;;
    esac
  done
  [[ -z "$gw" || "$gw" == glm || "$gw" == ds ]] || die 1 "spawn: --gw must be glm or ds (got '$gw')"
  [[ "$engine" == pi ]] || die 1 "general mode supports only --engine pi"
  [[ -z "$gw" || "$gw" == glm ]] || die 1 "only the configured gateway is supported"
  [[ -n "$code" ]] || die 1 "usage: worker.sh spawn <code> [--tui|--p] [--mission \"...\"] [--minutes N] [--name NAME] [--model <id>] [--gw glm|ds] [--engine pi]"
  [[ "$gw" == ds && -z "$DS_KEY" && "$engine" == claude ]] \
    && die 1 "spawn: --gw ds needs DEEPSEEK_API_KEY (unset — ask the operator, do not retry)"
  # default model per gateway: glm->flash tier, ds->deepseek-flash;
  # a GENERAL defaults to the smart tier (SKILL 4.10). NOTE: compare with
  # quoted `==` — unquoted/glob paths treat the [1m] suffix as a char class
  # and silently never match.
  [[ -n "$model" ]] || { [[ "$gw" == ds ]] && model="$DS_MODEL" || model="$MODEL"; }
  if (( general )) && [[ "$gw" == glm && "$model" == "$MODEL" ]]; then
    model="${SAPPER_MODEL:-glm-5.3[1m]}"
  fi
  [[ "$model" == "${SAPPER_MODEL:-$model}" ]] || die 1 "only the configured model is supported"
  # gateway auto-derives from the FINAL model's family (mixed doctrine: the
  # default soldier model is deepseek — its name on the glm gateway 404s,
  # which killed every soldier pane in a live run). Explicit --gw wins.
  [[ -z "$gw" ]] && { case "$model" in *deepseek*) gw=ds;; *) gw=glm;; esac; }
  is_code "$code" || die 1 "spawn: invalid code '$code'"
  [[ "$minutes" =~ ^[0-9]+$ ]] || die 1 "spawn: --minutes must be an integer (got '$minutes')"
  tmux has-session -t "$SESSION" 2>/dev/null \
    || die 1 "tmux session '$SESSION' missing (entrypoint/watchdog owns it)"

  # hard worker cap BEFORE touching the platform (an instance slot is precious)
  local nw; nw=$(count_workers)
  if (( nw >= MAX_WORKERS )); then
    die 4 "WORKER CAP: $nw/$MAX_WORKERS worker panes live — kill one first (worker.sh kill <pane>)"
  fi

  local existing; existing=$(panes_for_code "$code")
  local max=0 n w
  for w in $existing; do
    [[ "$w" =~ ^${code//./\\.}-w([0-9]+)$ ]] && { n=${BASH_REMATCH[1]}; (( n > max )) && max=$n; }
  done
  local ordinal=$(( max + 1 ))
  local pane
  if [[ -n "$name" ]]; then
    pane=$name
    [[ "$pane" =~ ^[A-Za-z0-9_-]+$ ]] || die 1 "spawn: --name must be [A-Za-z0-9_-] (tmux target parsing)"
    if window_exists "$pane"; then
      # re-spawning one of THIS code's own worker panes is allowed (idempotent);
      # colliding with a foreign window is not
      [[ "$pane" =~ ^${code//./\\.}-w[0-9]+$ ]] \
        || die 1 "spawn: window '$pane' already exists (belongs to another pane)"
    fi
  else
    pane="${code}-w${ordinal}"
  fi

  # primary agent = first pane of this code; it owns ROOT/<code>; -w2+ get their
  # own dir with the shared graph symlinked in (no same-cwd --continue crosstalk)
  local primary=0 dir="$ROOT/$code"
  (( max == 0 )) && primary=1
  (( primary )) || dir="$ROOT/${code}-w${ordinal}"

  # General mode operates on an existing local graph without platform instances.
  if [[ "$MODE" == general ]]; then
    [[ -f "$ROOT/$code/.sapper/project.json" ]] || die 1 "spawn: no local task graph for $code"
    [[ -n "$mission" ]] || die 1 "spawn: --mission is required for a general task"
    mission="$(default_mission "$code" "" "$primary") Operator mission: $mission"
  fi
  # 1) platform instance — only when this code has no live pane and no known addrs
  local addrs="" started="" got="" err
  [[ -f "$ROOT/$code/.addrs" ]] && addrs=$(cat "$ROOT/$code/.addrs" 2>/dev/null)
  if [[ "$MODE" == general ]]; then
    addrs="local task $code"
  elif (( ! primary )) && [[ -n "$addrs" ]]; then
    :  # instance already up (shared with w1) — do not re-start, just reuse addrs
  else
    err=$(mktemp)
    started=$(arena start "$code" 2>"$err" || true)
    got=$(printf '%s' "$started" | python3 -c '
import json,sys
try: print(" ".join(json.load(sys.stdin).get("container_addr") or []))
except Exception: pass' 2>/dev/null)
    if [[ -n "$got" ]]; then
      addrs=$got
      printf '%s\n' "$addrs" > "$ROOT/$code/.addrs"
    elif grep -qi "max active" "$err" 2>/dev/null; then
      rm -f "$err"
      die 3 "PLATFORM CAP: close a challenge first (worker.sh kill <code> --close) — cannot start $code"
    elif [[ -z "$addrs" ]]; then
      local e; e=$(tail -n 3 "$err" 2>/dev/null | tr '\n' ' ')
      rm -f "$err"
      die 1 "spawn: arena start failed for $code: ${e:-no container_addr returned}"
    else
      log "$code: arena start refused but persisted addrs look valid — reusing instance"
    fi
    rm -f "$err"
  fi

  # 2) dirs + shared graph
  if (( primary )); then
    mkdir -p "$dir"
    ensure_graph "$code"
  else
    ensure_graph "$code"
    mkdir -p "$dir"
    ln -sfn "../$code/.sapper" "$dir/.sapper"
  fi
  # 3) trust preset
  : # Pi does not use Claude trust settings

  # 4/5) the window (NO --continue: fresh session per pane; watchdog owns recovery)
  sync_session_env
  tmux kill-window -t "$SESSION:$pane" 2>/dev/null
  # persist the pane's tier+gateway so watchdog relaunches keep the same brain.
  # RAW values, never %q: bash %q escapes the [1m] suffix -> '\\[1m\\' and
  # pane_model()'s sed would feed claude a backslashed model id. TUI missions
  # are archived base64 so the watchdog can re-brief a restarted pane (a
  # relaunched claude is a FRESH session — nobody else will send its mission).
  local mission_b64=""
  [[ -n "$mission" ]] \
    && mission_b64=$(printf '%s' "$mission" | base64 -w0)
  printf 'MODEL=%s\nGW=%s\nENGINE=%s\nMISSION_B64=%s\n' \
    "$model" "$gw" "$engine" "$mission_b64" > "$PANE_ENV_DIR/$pane.env"
  local pi_session=""
  if [[ "$mode" == tui ]]; then
    mkdir -p "$SAPPER_STATE_ROOT/pi-sessions"
    pi_session=$(mktemp -d "$SAPPER_STATE_ROOT/pi-sessions/${pane}.XXXXXXXX")
  fi
  printf 'PI_SESSION_DIR=%s\n' "$pi_session" >> "$PANE_ENV_DIR/$pane.env"
  if [[ "$mode" == tui ]]; then
    tmux new-window -d -t "$SESSION" -n "$pane" \
      "cd '$dir' && /opt/sapper/docker/commander/pi-agent.py tui '$pane' '$model' 2>&1; echo DRIVE_PANE_EXITED; exec sleep infinity"
  else
    tmux new-window -d -t "$SESSION" -n "$pane" \
      "cd '$dir' && timeout ${minutes}m /opt/sapper/docker/commander/pi-agent.py print '$pane' '$model' 2>&1; rc=\$?; echo SAPPER_WORKER_EXIT_CODE=\$rc; echo DRIVE_PANE_EXITED; exec sleep infinity"
  fi
  sleep 3
  if printf '%s' "$(pane_text "$pane")" | grep -q DRIVE_PANE_EXITED; then
    if [[ "$mode" != p ]] || ! printf '%s' "$(pane_text "$pane")" | grep -q 'SAPPER_WORKER_EXIT_CODE=0'; then
      die 1 "spawn: Pi worker exited immediately; inspect its pane"
    fi
  fi
  [[ "$mode" == p && -n "$mission" ]] && write_hint "$code" "$mission"
  log "$pane: Pi $mode worker spawned (dir=$dir)"

  # 7)
  printf 'SPAWNED %s addrs=%s model=%s\n' "$pane" "$addrs" "$model"
}

# ---- kill --------------------------------------------------------------------
cmd_kill() {
  local close=0 target="" a
  while (( $# )); do
    a=$1; shift
    case "$a" in
      --close) close=1 ;;
      -*) die 1 "kill: unknown option $a" ;;
      *) [[ -z "$target" ]] || die 1 "kill: unexpected argument $a"; target=$a ;;
    esac
  done
  [[ -n "$target" ]] || die 1 "usage: worker.sh kill <pane>|<code> [--close]"
  tmux has-session -t "$SESSION" 2>/dev/null \
    || die 1 "tmux session '$SESSION' missing (entrypoint/watchdog owns it)"

  local re=${target//./\\.} wins
  if window_exists "$target"; then
    wins=$target
  else
    wins=$(worker_windows | grep -E "^${re}-w[0-9]+$" || true)
  fi
  [[ -n "$wins" ]] || die 1 "kill: no pane matches '$target'"

  local code=$target w
  [[ "$code" =~ -w[0-9]+$ ]] && code=${code%-w*}
  for w in $wins; do
    if tmux kill-window -t "$SESSION:$w" 2>/dev/null; then
      log "killed $w"
    else
      log "kill: window $w already gone"
    fi
    rm -f "$PANE_ENV_DIR/$w.env"
  done

  if (( close )); then
    local left; left=$(panes_for_code "$code")
    if [[ -n "$left" ]]; then
      log "$code: sibling panes still alive ($left) — instance kept open, flags not touched"
      return 0
    fi
    close_instance "$code"
  fi
}

# ---- msg / peek / list -------------------------------------------------------
cmd_msg() {
  local pane=${1:-} text=${2:-}
  [[ -n "$pane" && -n "$text" ]] || die 1 'usage: worker.sh msg <pane> "<text>"'
  tmux has-session -t "$SESSION" 2>/dev/null || die 1 "tmux session '$SESSION' missing"
  window_exists "$pane" || die 1 "msg: no such pane '$pane'"
  send_literal "$pane" "$text"
  log "msg -> $pane: ${text:0:60}"
}

cmd_peek() {
  local pane=${1:-} lines=${2:-40}
  [[ -n "$pane" ]] || die 1 "usage: worker.sh peek <pane> [lines=40]"
  [[ "$lines" =~ ^[0-9]+$ ]] || die 1 "peek: lines must be an integer"
  tmux has-session -t "$SESSION" 2>/dev/null || die 1 "tmux session '$SESSION' missing"
  window_exists "$pane" || die 1 "peek: no such pane '$pane'"
  tmux capture-pane -p -t "$SESSION:$pane" 2>/dev/null | tail -n "$lines"
}

cmd_list() {
  local info; info=$(collect_panes) || true
  if [[ -z "$info" ]]; then
    printf '(no worker panes)\n'
    return 0
  fi
  local w st idle since size
  while IFS=$'\t' read -r w st idle since size; do
    printf '%s %s idle=%ss size=%s since=%s\n' "$w" "$st" "$idle" "$size" "$since"
  done <<< "$info"
}

# ---- board -------------------------------------------------------------------
cmd_board() {
  local as_json=0 a
  while (( $# )); do
    a=$1; shift
    case "$a" in
      --json) as_json=1 ;;
      *) die 1 "board: unknown option $a (try --json)" ;;
    esac
  done
  local arena_tmp pane_tmp rc
  arena_tmp=$(mktemp); pane_tmp=$(mktemp)
  if [[ "$MODE" == general ]]; then printf '[]\n' > "$arena_tmp"; else arena list > "$arena_tmp" 2>/dev/null || printf '[]\n' > "$arena_tmp"; fi
  collect_panes > "$pane_tmp" || true
  python3 - "$arena_tmp" "$pane_tmp" "$ROOT" "$MAX_WORKERS" "$as_json" <<'PYBOARD'
import glob, json, os, re, sys, time

arena_path, pane_path, root = sys.argv[1], sys.argv[2], sys.argv[3]
max_workers, as_json = int(sys.argv[4]), sys.argv[5] == "1"

def load_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default

# -- platform rows (arena list; unreachable platform degrades to empty) --------
plat = {}
for c in (load_json(arena_path, []) or []):
    if isinstance(c, dict) and isinstance(c.get("unique_code"), str):
        plat[c["unique_code"]] = {
            "completed": bool(c.get("is_completed")),
            "flags_correct": int(c.get("correct_flag_count") or 0),
            "flags_total": int(c.get("flag_count") or 0),
        }

# -- graphs (dedupe -wN symlinked graphs by realpath; never trust file contents)
graphs = {}
for pj in sorted(glob.glob(os.path.join(root, "*", ".sapper", "project.json"))):
    d = os.path.dirname(os.path.dirname(pj))
    code = re.sub(r"-w\d+$", "", os.path.basename(d))
    key = os.path.realpath(os.path.join(d, ".sapper"))
    if key in graphs:
        continue
    kinds, latest, total = {}, 0.0, 0
    flags = {"recorded": 0, "submitted": 0}
    helps = 0
    for fp in glob.glob(os.path.join(d, ".sapper", "facts", "*.json")):
        total += 1
        try:
            f = json.load(open(fp))
            latest = max(latest, os.path.getmtime(fp))
        except Exception:
            continue
        k = f.get("kind")
        if k:
            kinds[k] = kinds.get(k, 0) + 1
            if k == "flag":
                st = (f.get("data") or {}).get("status") or "recorded"
                flags[st] = flags.get(st, 0) + 1
            if k == "note" and "[HELP]" in str(f.get("description", "")) + str(f.get("data") or ""):
                helps += 1
    intents = {"open": 0, "claimed": 0, "done": 0, "complete": 0}
    for ip in glob.glob(os.path.join(d, ".sapper", "intents", "*.json")):
        try:
            st = json.load(open(ip)).get("status")
        except Exception:
            continue
        if st in intents:
            intents[st] += 1
    graphs[key] = {"code": code, "facts_total": total, "kinds": kinds,
                   "flags_recorded": flags["recorded"],
                   "flags_submitted": flags["submitted"],
                   "intents": intents, "latest_mtime": latest, "helps": helps}

by_code = {}
for g in graphs.values():
    cur = by_code.get(g["code"])
    if cur is None or g["facts_total"] > cur["facts_total"]:
        by_code[g["code"]] = g

# -- panes merged in ------------------------------------------------------------
panes, alive = {}, 0
for line in open(pane_path):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 5:
        continue
    w, st, idle, since, size = parts
    m = re.match(r"^(.*)-w\d+$", w)
    panes.setdefault(m.group(1) if m else w, []).append(
        {"pane": w, "state": st, "idle": int(idle), "since": since, "size": size})
    if st == "alive":
        alive += 1

codes = sorted(set(plat) | set(by_code) | set(panes),
               key=lambda c: (0 if c in panes else (1 if c in by_code else 2), c))
rows = []
for c in codes:
    p, g = plat.get(c) or {}, by_code.get(c) or {}
    rows.append({
        "code": c,
        "completed": p.get("completed"),
        "platform_flags": ([p["flags_correct"], p["flags_total"]] if p else None),
        "facts_total": g.get("facts_total", 0),
        "kinds": g.get("kinds", {}),
        "intents": g.get("intents", {}),
        "flags_recorded": g.get("flags_recorded", 0),
        "flags_submitted": g.get("flags_submitted", 0),
        "helps": g.get("helps", 0),
        "latest": time.strftime("%H:%M", time.localtime(g["latest_mtime"]))
                  if g.get("latest_mtime") else "-",
        "panes": panes.get(c, []),
    })

if as_json:
    print(json.dumps({"now": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      "workers_alive": alive, "worker_cap": max_workers,
                      "codes": rows}, ensure_ascii=False, separators=(",", ":")))
    raise SystemExit(0)

# heartbeat to drive.log (=> docker logs): the commander boards every loop,
# so this line IS the campaign pulse for the outside observer.
flags_r = sum(r["flags_recorded"] for r in rows)
flags_s = sum(r["flags_submitted"] for r in rows)
done_n = sum(1 for r in rows if r["completed"])
# war clock + general census: the commander's dashboard gauges
left = "-"
try:
    dl = float(open(os.path.join(os.environ.get("SAPPER_STATE_ROOT", root), ".deadline")).read().strip())
    secs = dl - time.time()
    if secs >= 0:
        left = ("%dh%02dm" % (secs // 3600, (secs % 3600) // 60))
    else:
        left = "OVER"
except Exception:
    pass
generals = 0
try:
    import glob as _g
    for pf in _g.glob(os.path.join(root, "pane-env", "*.env")):
        try:
            m = [l for l in open(pf) if l.startswith("MODEL=")][0][6:].strip()
        except Exception:
            continue
        if m and "flash" not in m and "deepseek" not in m:
            generals += 1
except Exception:
    pass
print(f"[board] heartbeat: codes={len(rows)} done={done_n} "
      f"alive={alive}/{max_workers} flags_recorded={flags_r} "
      f"flags_submitted={flags_s} budget_left={left} generals={generals}", file=sys.stderr)

def kinds_str(k):
    if not k:
        return "-"
    order = ["host", "service", "cred", "vuln", "loot", "flag", "note"]
    parts = [f"{n[0]}{k[n]}" for n in order if k.get(n)]
    parts += [f"{n[:2]}{v}" for n, v in sorted(k.items()) if n not in order]
    return (" ".join(parts) or "-")[:16]

def panes_str(lst):
    if not lst:
        return "-"
    out = []
    for p in lst:
        m = re.match(r"^.*-w(\d+)$", p["pane"])
        lbl = f"w{m.group(1)}" if m else p["pane"]
        out.append(f"{lbl}:{p['idle']}s" if p["state"] == "alive" else f"{lbl}:X")
    return " ".join(out)

widths = [("CODE(⚑=HELP!)", 17), ("DONE", 4), ("FLG", 7), ("FACTS", 6), ("KINDS", 16),
          ("INT o/c", 8), ("FLG r/s", 7), ("LAST", 5)]
print(f"== sapper board {time.strftime('%H:%M')}  workers alive={alive}/{max_workers}"
      f"  codes={len(rows)} ==")
print(" ".join(t.ljust(w) for t, w in widths) + "PANES")
budget = 100 - 3  # header + column line + trailing guard
for i, r in enumerate(rows):
    if i >= budget:
        print(f"... {len(rows) - i} more codes (use: worker.sh board --json)")
        break
    pf = r["platform_flags"]
    done = "-" if r["completed"] is None else ("yes" if r["completed"] else "no")
    codecell = r["code"][:14]
    if r.get("helps"):
        codecell = "⚑%d %s" % (r["helps"], codecell)[:14 + 3]
    cells = [
        codecell.ljust(17), done.ljust(4),
        (f"{pf[0]}/{pf[1]}" if pf else "-").ljust(7),
        (str(r["facts_total"]) if r["facts_total"] else "-").ljust(6),
        kinds_str(r["kinds"]).ljust(16),
        f"{r['intents'].get('open', 0)}/{r['intents'].get('claimed', 0)}".ljust(8),
        f"{r['flags_recorded']}/{r['flags_submitted']}".ljust(7),
        r["latest"].ljust(5), panes_str(r["panes"]),
    ]
    print(" ".join(cells).rstrip())
PYBOARD
  rc=$?
  rm -f "$arena_tmp" "$pane_tmp"
  return "$rc"
}

# ---- hint --------------------------------------------------------------------
cmd_hint() {
  local code=${1:-} text=${2:-}
  [[ -n "$code" && -n "$text" ]] || die 1 'usage: worker.sh hint <code> "<text>"'
  is_code "$code" || die 1 "hint: invalid code '$code'"
  write_hint "$code" "$text"
}

usage() {
  cat >&2 <<'USAGE'
worker.sh — the commander's hands (one-shot subcommands; no main loop)
  spawn <code> [--tui|--p] [--mission "..."] [--minutes N] [--name NAME] [--model <id>]
                                     [--gw glm|ds] [--engine pi] [--general]
                                     --model: worker brain (default flash tier; smart =
                                     'glm-5.3[1m]' — SKILL 4.9 tiering rules)
                                     --general: smart-tier GENERAL that may hire its own
                                     -p squads on the same challenge (SKILL 4.10)
  kill  <pane>|<code> [--close]      --close submits flags + closes the instance
                                     only when no sibling pane of that code lives
  msg   <pane> "<text>"              send-keys -l + Enter (never bracketed paste)
  peek  <pane> [lines=40]
  list                               <pane> alive|exited idle=<s> size=WxH since=<hh:mm>
  board [--json]                     the war board (<100 lines)
  hint  <code> "<text>"              append a [commander] hint fact to that graph
exit codes: 0 ok | 1 generic error | 3 platform cap (max active) | 4 worker cap
USAGE
}

case "${1:-}" in
  spawn) shift; cmd_spawn "$@" ;;
  kill) shift; cmd_kill "$@" ;;
  msg) shift; cmd_msg "$@" ;;
  peek) shift; cmd_peek "$@" ;;
  list) shift; cmd_list "$@" ;;
  board) shift; cmd_board "$@" ;;
  hint) shift; cmd_hint "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  "") usage; exit 1 ;;
  *) printf '[worker] ERROR: unknown subcommand %s\n' "$1" >&2; usage; exit 1 ;;
esac
