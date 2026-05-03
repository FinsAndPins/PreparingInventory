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
#   PIN_PRICING_STUDY_MVP   same as price_boards_from_inbox.sh
#   LOCAL_WATCHER_BIN     if set, directory with copies of this script, price_boards_from_inbox.sh,
#                           and lexi_send_imessage.py (launchd cannot run scripts from iCloud paths).
#
set -uo pipefail
set +H

if [[ -n "${PREP:-}" ]] && [[ -d "${PREP}" ]]; then
  :
else
  PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi
INBOX="${PREP}/BoardsToPrice"
# Binaries/logs: same as repo when run from Terminal; local copies when LOCAL_WATCHER_BIN is set (launchd + iCloud).
BIN="${LOCAL_WATCHER_BIN:-$PREP}"
LOG="${BIN}/_logs/boards_watcher.log"
LOCKDIR="${BIN}/_logs/boards_watcher_active.lockdir"
PRICE_SCRIPT="${BIN}/price_boards_from_inbox.sh"
SEND_PY="${BIN}/lexi_send_imessage.py"
LAST_PRICE_LOG="${PREP}/_logs/price_inbox_last.log"

QUIET_SEC="${PRICE_INBOX_QUIET_SEC:-120}"
POLL_SEC="${PRICE_INBOX_POLL_SEC:-10}"

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

inbox_has_boards() {
  shopt -s nullglob
  local p
  for p in "${INBOX}"/*.jpg "${INBOX}"/*.jpeg "${INBOX}"/*.JPG "${INBOX}"/*.JPEG \
           "${INBOX}"/*.heic "${INBOX}"/*.HEIC "${INBOX}"/*.heif "${INBOX}"/*.HEIF; do
    [[ -f "$p" ]] || continue
    [[ "$(dirname "$p")" == "$INBOX" ]] || continue
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

inbox_snapshot() {
  # Hash names + sizes + mtimes of non-gitkeep files at inbox top level.
  find "$INBOX" -maxdepth 1 -type f ! -name '.gitkeep' -print0 2>/dev/null \
    | sort -z \
    | xargs -0 stat -f '%N %z %m' 2>/dev/null \
    | md5 || echo "empty"
}

acquire_lock() {
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    sleep 2
  done
}

release_lock() {
  rmdir "$LOCKDIR" 2>/dev/null || true
}

last_snap=""
last_change_epoch=""

while true; do
  now=$(date +%s)
  snap=$(inbox_snapshot)

  if [[ "$snap" != "$last_snap" ]]; then
    last_snap=$snap
    last_change_epoch=$now
    echo "[$(date -Iseconds)] inbox snapshot changed"
  fi

  if inbox_has_boards && [[ -n "${last_change_epoch:-}" ]]; then
    idle=$((now - last_change_epoch))
    if [[ "$idle" -ge "$QUIET_SEC" ]]; then
      echo "[$(date -Iseconds)] quiet for ${idle}s with boards present — acquiring lock"
      acquire_lock
      echo "[$(date -Iseconds)] lock acquired; starting price_boards_from_inbox.sh (caffeinate)"
      send_msg "Fins & Pins pricing: started on Steve's Mac (boards detected in BoardsToPrice). You'll get another message when the run finishes and has been pushed to GitHub."

      set +e
      # Best-effort: keep the Mac awake while the long pricing pipeline runs (lid may be closed).
      PREP="$PREP" caffeinate -dimsu -- bash "$PRICE_SCRIPT"
      rc=$?
      set -e

      release_lock
      echo "[$(date -Iseconds)] lock released (exit ${rc})"

      if [[ "$rc" -eq 0 ]]; then
        url=""
        if [[ -f "$LAST_PRICE_LOG" ]]; then
          url=$(grep 'Harness:' "$LAST_PRICE_LOG" | tail -1 | sed 's/.*Harness: //' || true)
        fi
        send_msg "$(printf '%s\n\n%s\n\n%s' \
          "Fins & Pins pricing: finished and pushed to GitHub." \
          "${url:-Harness URL not found in log - open the PreparingInventory Lexi index on GitHub Pages.}" \
          "The harness link often works within ~10-15 minutes on finsandpins.github.io.")"
      else
        send_msg "$(printf '%s\n\n%s\n\n%s' \
          "Fins & Pins pricing: FAILED (automation exit ${rc})." \
          "You don't need to debug anything. Wait a few minutes, then upload the board photos to BoardsToPrice again - that will start a fresh run." \
          "Steve can check _logs/price_inbox_last.log on the Mac when he's up.")"
      fi

      # Reset debounce so we only react to the next upload wave.
      last_snap=$(inbox_snapshot)
      if inbox_has_boards; then
        last_change_epoch=$(date +%s)
      else
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
