#!/usr/bin/env bash
# Watch BoardsToPrice/ for new board photos; after QUIET_SEC with no changes,
# run price_boards_from_inbox.sh (under caffeinate) and notify Lexi via iMessage.
#
# Lexi can drop JPEG/HEIC in the shared iCloud BoardsToPrice folder; when uploads
# go quiet, this runs the same pipeline as RunBoardsPricing.command (without the
# interactive "press Return" at the end).
#
# Setup:
#   1) Copy LEXI_NOTIFY.example.env → LEXI_NOTIFY.env (gitignored); set LEXI_IMESSAGE_HANDLE
#      or PRICING_NOTIFY_HANDLES (space-separated — same texts to each).
#   2) Grant Messages automation for the parent process (Terminal or launchd).
#   3) Load launchd/com.finsandpins.BoardsInboxWatcher.plist (see README + install script).
#
# Env (optional):
#   PRICE_INBOX_QUIET_SEC   default 120 — folder must be unchanged this long
#   PRICE_INBOX_POLL_SEC    default 10  — how often to rescan
#   PRICE_INBOX_FAIL_COOLDOWN_SEC  default 3600 — after a failed pricing run, wait this long before
#                                  trying again (stops iMessage spam while boards stay in the inbox).
#   PIN_PRICING_STUDY_MVP   same as price_boards_from_inbox.sh
#   LOCAL_WATCHER_BIN     if set, directory with copies of this script, price_boards_from_inbox.sh,
#                           and lexi_send_imessage.py (launchd cannot run scripts from iCloud paths).
#   BOARD_INBOX_DIR       optional local folder mirroring BoardsToPrice (set by LaunchAgent launcher);
#                           rsync from iCloud via osascript so launchd can see files; pricing still runs on PREP.
#
set -uo pipefail
set +H

if [[ -n "${PREP:-}" ]] && [[ -d "${PREP}" ]]; then
  :
else
  PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi
SCAN_INBOX="${BOARD_INBOX_DIR:-${PREP}/BoardsToPrice}"
# Binaries/logs: same as repo when run from Terminal; local copies when LOCAL_WATCHER_BIN is set (launchd + iCloud).
BIN="${LOCAL_WATCHER_BIN:-$PREP}"
LOG="${BIN}/_logs/boards_watcher.log"
LOCKDIR="${BIN}/_logs/boards_watcher_active.lockdir"
PRICE_SCRIPT="${BIN}/price_boards_from_inbox.sh"
SEND_PY="${BIN}/lexi_send_imessage.py"
# Writable log when scripts run from ~/Library/... (launchd + osascript cannot tee into iCloud _logs).
if [[ "$BIN" != "$PREP" ]]; then
  export PRICE_LOG_DIR="${BIN}/_logs"
fi
LAST_PRICE_LOG="${PRICE_LOG_DIR:-${PREP}/_logs}/price_inbox_last.log"

QUIET_SEC="${PRICE_INBOX_QUIET_SEC:-120}"
POLL_SEC="${PRICE_INBOX_POLL_SEC:-10}"
FAIL_COOLDOWN_SEC="${PRICE_INBOX_FAIL_COOLDOWN_SEC:-3600}"

mkdir -p "${BIN}/_logs" "${PREP}/_logs"
exec >>"$LOG" 2>&1

echo "[$(date -Iseconds)] board_inbox_watcher starting (quiet=${QUIET_SEC}s poll=${POLL_SEC}s)"

NOTIFY_ENV=""
if [[ -f "${BIN}/LEXI_NOTIFY.env" ]]; then
  NOTIFY_ENV="${BIN}/LEXI_NOTIFY.env"
elif [[ -f "${PREP}/LEXI_NOTIFY.env" ]]; then
  NOTIFY_ENV="${PREP}/LEXI_NOTIFY.env"
fi
if [[ -n "$NOTIFY_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$NOTIFY_ENV"
  set +a
fi

if [[ ! -x "$PRICE_SCRIPT" ]]; then
  echo "[$(date -Iseconds)] ERROR: missing or not executable: $PRICE_SCRIPT"
  exit 1
fi

send_msg() {
  local body="$1"
  if [[ ! -f "$SEND_PY" ]]; then
    echo "[$(date -Iseconds)] LEXI_NOTIFY: skip (no $SEND_PY)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[$(date -Iseconds)] LEXI_NOTIFY: skip (no python3)"
    return 0
  fi
  if printf '%s' "$body" | python3 "$SEND_PY"; then
    echo "[$(date -Iseconds)] LEXI_NOTIFY: sent (${#body} chars)"
  else
    echo "[$(date -Iseconds)] LEXI_NOTIFY: send failed (see stderr above)"
  fi
}

# Use find (not shell globs): launchd + iCloud paths often fail glob expansion while find works.
_board_find_board_files() {
  find "$SCAN_INBOX" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.heif' \) \
    ! -name '.gitkeep' ! -name '.DS_Store' 2>/dev/null "$@"
}

# launchd cannot list ~/Library/Mobile Documents/...; pull from canonical BoardsToPrice via osascript.
bridge_pull_icloud_inbox_to_scan_dir() {
  [[ -n "${BOARD_INBOX_DIR:-}" ]] || return 0
  mkdir -p "${BOARD_INBOX_DIR}"
  /usr/bin/osascript - "${PREP}/BoardsToPrice/" "${BOARD_INBOX_DIR}/" <<'OSA' 2>/dev/null || true
on run argv
  set src to item 1 of argv
  set dst to item 2 of argv
  do shell script "/usr/bin/rsync -a " & quoted form of src & " " & quoted form of dst
end run
OSA
}

run_price_pipeline() {
  if [[ -n "${BOARD_INBOX_DIR:-}" ]]; then
    /usr/bin/osascript - "$PREP" "$PRICE_SCRIPT" <<'OSA'
on run argv
  set p to item 1 of argv
  set s to item 2 of argv
  do shell script "export PREP=" & quoted form of p & " && cd " & quoted form of p & " && /usr/bin/caffeinate -dimsu -- /bin/bash " & quoted form of s
end run
OSA
  else
    PREP="$PREP" /usr/bin/caffeinate -dimsu -- /bin/bash "$PRICE_SCRIPT"
  fi
}

inbox_has_boards() {
  _board_find_board_files | grep -q .
}

inbox_snapshot() {
  # Hash names + sizes + mtimes of board files at inbox top level.
  _board_find_board_files -print0 \
    | sort -z \
    | xargs -0 stat -f '%N %z %m' 2>/dev/null \
    | md5 -q 2>/dev/null || echo "empty"
}

acquire_lock() {
  local waited=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    if (( waited % 60 == 0 )); then
      echo "[$(date -Iseconds)] waiting for lock: $LOCKDIR (${waited}s)"
    fi
    waited=$((waited + 2))
    sleep 2
  done
}

release_lock() {
  rmdir "$LOCKDIR" 2>/dev/null || true
}

last_snap=""
last_change_epoch=""
fail_quiet_until=0
debug_tick=0

while true; do
  now=$(date +%s)
  bridge_pull_icloud_inbox_to_scan_dir
  if [[ "${PRICE_INBOX_DEBUG:-0}" == "1" ]]; then
    debug_tick=$((debug_tick + 1))
    if (( debug_tick % 6 == 1 )); then
      nf=$( (_board_find_board_files | wc -l) | tr -d '[:space:]' )
      hb=0
      inbox_has_boards && hb=1
      echo "[$(date -Iseconds)] DEBUG scan_inbox=${SCAN_INBOX} file_count=${nf} has_boards=${hb} last_change_epoch=${last_change_epoch:-}"
    fi
  fi
  snap=$(inbox_snapshot)

  if [[ "$snap" != "$last_snap" ]]; then
    last_snap=$snap
    last_change_epoch=$now
    fail_quiet_until=0
    echo "[$(date -Iseconds)] inbox snapshot changed"
  fi

  if inbox_has_boards && [[ -n "${last_change_epoch:-}" ]] && [[ "$now" -ge "$fail_quiet_until" ]]; then
    idle=$((now - last_change_epoch))
    if [[ "$idle" -ge "$QUIET_SEC" ]]; then
      echo "[$(date -Iseconds)] quiet for ${idle}s with boards present — acquiring lock"
      acquire_lock
      echo "[$(date -Iseconds)] lock acquired; starting price_boards_from_inbox.sh (caffeinate)"
      # Do not block the pipeline on Messages (timeouts would delay pricing and log writes).
      ( send_msg "Fins & Pins pricing: started on Steve's Mac (boards detected in BoardsToPrice). You'll get another message when the run finishes and has been pushed to GitHub." ) &

      set +e
      # Best-effort: keep the Mac awake while the long pricing pipeline runs (lid may be closed).
      PREP="$PREP" run_price_pipeline
      rc=$?
      set -e

      release_lock
      echo "[$(date -Iseconds)] lock released (exit ${rc})"

      if [[ "$rc" -eq 0 ]]; then
        fail_quiet_until=0
        url=""
        if [[ -f "$LAST_PRICE_LOG" ]]; then
          url=$(grep 'Harness:' "$LAST_PRICE_LOG" | tail -1 | sed 's/.*Harness: //' || true)
        fi
        send_msg "$(printf '%s\n\n%s\n\n%s' \
          "Fins & Pins pricing: finished and pushed to GitHub." \
          "${url:-Harness URL not found in log - open the PreparingInventory Lexi index on GitHub Pages.}" \
          "The harness link often works within ~10-15 minutes on finsandpins.github.io.")"
      else
        fail_quiet_until=$((now + FAIL_COOLDOWN_SEC))
        echo "[$(date -Iseconds)] pricing failed (exit ${rc}); no new runs until $(date -r "$fail_quiet_until" "+%Y-%m-%d %H:%M:%S %z") (${FAIL_COOLDOWN_SEC}s cooldown, or sooner if the inbox snapshot changes)"
        send_msg "$(printf '%s\n\n%s\n\n%s' \
          "Fins & Pins pricing: FAILED (automation exit ${rc})." \
          "You don't need to debug anything. Wait a few minutes, then upload the board photos to BoardsToPrice again - that will start a fresh run." \
          "Steve can check _logs/price_inbox_last.log on the Mac when he's up.")"
      fi

      # Reset debounce so we only react to the next upload wave.
      last_snap=$(inbox_snapshot)
      if [[ "$rc" -eq 0 ]] && inbox_has_boards; then
        last_change_epoch=$(date +%s)
      else
        # After failure (or empty inbox), require a new snapshot change before quiet-timer restarts.
        last_change_epoch=""
      fi
    fi
  else
    if ! inbox_has_boards; then
      last_change_epoch=""
    fi
  fi

  sleep "$POLL_SEC"
done
