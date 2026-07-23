#!/usr/bin/env bash
# Watch BoardsToPrice/ for new board photos; after QUIET_SEC with no changes,
# run price_boards_from_inbox.sh (under caffeinate) and notify Lexi via iMessage.
#
# Lexi can drop JPEG/HEIC in the shared iCloud BoardsToPrice folder; when uploads
# go quiet, this runs price_boards_from_inbox.sh (without the interactive "press Return"
# at the end). Detection defaults to local RF-DETR (Core ML); see run_price_pipeline.
# Double-click RunBoardsPricing.command still uses the Roboflow API unless you change env.
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
#                                  automatic retry (stops iMessage spam). Adding/removing/changing a
#                                  board file clears the cooldown immediately (stable snapshot changes).
#   PIN_PRICING_USE_RFDETR   default 1 — RF-DETR (Core ML). Set 0 to use Roboflow API for this watcher.
#   PIN_PRICING_STUDY_MVP    defaults to PinPricingStudyMVP_RFDETR_TEST when RF-DETR; else PinPricingStudyMVP.
#   PIN_PRICING_RFDETR_MIN_CONF — optional; default 0.25 (matches Click To Collect app).
#   LOCAL_WATCHER_BIN     if set, directory with copies of this script, price_boards_from_inbox.sh,
#                           and lexi_send_imessage.py (launchd cannot run scripts from iCloud paths).
#   BOARD_INBOX_DIR       local mirror of iCloud BoardsToPrice (LaunchAgent). Hybrid model:
#                           Lexi drops in iCloud BoardsToPrice → watcher materializes into this local
#                           folder → price_boards runs RF-DETR/eBay on local PricingWork (not iCloud).
#                           Results publish from PreparingInventoryGit → Lexi reviews on GitHub Pages.
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
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
    -o -iname '*.heic' -o -iname '*.heif' \
    -o -iname '*.webp' -o -iname '*.tif' -o -iname '*.tiff' \) \
    ! -name '.gitkeep' ! -name '.DS_Store' 2>/dev/null "$@"
}

BOARD_MIN_BYTES="${BOARD_MIN_BYTES:-1024}"
FINS_LOCAL="${HOME}/Library/Application Support/FinsAndPins"

_board_file_bytes_ok() {
  local f="${1:?}"
  local sz
  sz=$(stat -f %z "$f" 2>/dev/null || echo 0)
  [[ "$sz" -ge "${BOARD_MIN_BYTES}" ]]
}

_icloud_request_download() {
  local f="${1:?}"
  if command -v brctl >/dev/null 2>&1; then
    brctl download "$f" 2>/dev/null || true
  fi
}

# Copy one board photo from iCloud → local mirror via Python read/write (forces materialize).
# Avoid /bin/cp and ditto here: under launchd they often create 0-byte stubs or errno 11.
_pull_single_board_file() {
  local src="${1:?}" dest="${2:?}"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    _icloud_request_download "$src"
    if BRIDGE_SRC="$src" BRIDGE_DEST="$dest" BRIDGE_MIN="${BOARD_MIN_BYTES}" /usr/bin/python3 - <<'PY' 2>/dev/null
import os, sys
from pathlib import Path
src, dest = Path(os.environ["BRIDGE_SRC"]), Path(os.environ["BRIDGE_DEST"])
min_b = int(os.environ.get("BRIDGE_MIN", "1024"))
try:
    data = src.read_bytes()
except OSError:
    sys.exit(1)
if len(data) < min_b:
    sys.exit(1)
dest.parent.mkdir(parents=True, exist_ok=True)
tmp = dest.with_suffix(dest.suffix + ".tmp")
tmp.write_bytes(data)
tmp.replace(dest)
sys.exit(0)
PY
    then
      if _board_file_bytes_ok "$dest"; then
        return 0
      fi
    fi
    sleep 2
  done
  echo "[$(date -Iseconds)] WARN bridge_pull: could not materialize $(basename "$src") (still < ${BOARD_MIN_BYTES} bytes after retries)"
  return 1
}

# Pull canonical iCloud BoardsToPrice → local mirror (hybrid: iCloud = Lexi drop only).
# Per-file Python materialize only — no folder-level ditto/rsync (those spam errno 11 under launchd).
# Never --delete the mirror on a partial iCloud read.
bridge_pull_icloud_inbox_to_scan_dir() {
  [[ -n "${BOARD_INBOX_DIR:-}" ]] || return 0
  mkdir -p "${BOARD_INBOX_DIR}"
  local src="${PREP}/BoardsToPrice"
  if [[ ! -d "$src" ]]; then
    return 0
  fi
  local f dest n_ok=0 n_fail=0
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue
    dest="${BOARD_INBOX_DIR}/$(basename "$f")"
    if [[ -f "$dest" ]] && _board_file_bytes_ok "$dest"; then
      # Same basename+size already local — skip re-copy.
      local src_sz dest_sz
      src_sz=$(stat -f %z "$f" 2>/dev/null || echo 0)
      dest_sz=$(stat -f %z "$dest" 2>/dev/null || echo 0)
      if [[ "$src_sz" -gt 0 && "$src_sz" == "$dest_sz" ]]; then
        n_ok=$((n_ok + 1))
        continue
      fi
    fi
    if _pull_single_board_file "$f" "$dest"; then
      n_ok=$((n_ok + 1))
    else
      n_fail=$((n_fail + 1))
    fi
  done < <(find "$src" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
    -o -iname '*.heic' -o -iname '*.heif' \
    -o -iname '*.webp' -o -iname '*.tif' -o -iname '*.tiff' \) \
    ! -name '.gitkeep' ! -name '.DS_Store' -print0 2>/dev/null)
  if [[ "$n_fail" -gt 0 ]]; then
    echo "[$(date -Iseconds)] WARN bridge_pull: materialized ${n_ok} board(s), ${n_fail} still unavailable from iCloud"
  fi
}

_pin_venv_ready() {
  local pin="$1"
  [[ -x "${pin}/.venv/bin/python" ]] || return 1
  "${pin}/.venv/bin/python" -c "import imagehash; from PIL import Image" >/dev/null 2>&1
}

# Prefer Application Support copy under launchd (iCloud .venv often fails imports).
_resolve_pin_pricing_study_mvp() {
  local icloud_cursor="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Cursor Projects"
  local pin_rfdetr_icloud="${icloud_cursor}/PinPricingStudyMVP_RFDETR_TEST"
  local pin_robo_icloud="${icloud_cursor}/PinPricingStudyMVP"
  local pin_rfdetr_local="${FINS_LOCAL}/PinPricingStudyMVP_RFDETR_TEST"
  local pin_robo_local="${FINS_LOCAL}/PinPricingStudyMVP"
  local use_rfdetr=1
  if [[ "${PIN_PRICING_USE_RFDETR:-1}" == "0" ]] || [[ "${PIN_PRICING_USE_RFDETR:-1}" == "false" ]] || [[ "${PIN_PRICING_USE_RFDETR:-1}" == "False" ]]; then
    use_rfdetr=0
  fi
  if [[ "$use_rfdetr" -eq 0 ]]; then
    if [[ -n "${LOCAL_WATCHER_BIN:-}" ]] && _pin_venv_ready "$pin_robo_local"; then
      printf '%s' "$pin_robo_local"
    else
      printf '%s' "${PIN_PRICING_STUDY_MVP:-$pin_robo_icloud}"
    fi
    return
  fi
  if [[ -n "${LOCAL_WATCHER_BIN:-}" ]] && _pin_venv_ready "$pin_rfdetr_local"; then
    printf '%s' "$pin_rfdetr_local"
  else
    if [[ -n "${LOCAL_WATCHER_BIN:-}" ]]; then
      echo "[$(date -Iseconds)] WARN: local PinPricing .venv not ready (${pin_rfdetr_local}); run launchd/install_boards_inbox_launchagent.sh to copy .venv off iCloud" >&2
    fi
    printf '%s' "${PIN_PRICING_STUDY_MVP:-$pin_rfdetr_icloud}"
  fi
}

run_price_pipeline() {
  # Do not wrap price_boards in osascript "do shell script": that environment cannot write under
  # ~/Library/Mobile Documents/... (e.g. mkdir/touch BoardsToPrice, git), so the run dies right after
  # moving the mirror inbox. launchd already runs this watcher as your GUI user — caffeinate + bash is enough.
  export PIN_PRICING_USE_RFDETR="${PIN_PRICING_USE_RFDETR:-1}"
  if [[ "${PIN_PRICING_USE_RFDETR}" == "0" ]] || [[ "${PIN_PRICING_USE_RFDETR}" == "false" ]] || [[ "${PIN_PRICING_USE_RFDETR}" == "False" ]]; then
    :
  else
    export PIN_PRICING_RFDETR_MIN_CONF="${PIN_PRICING_RFDETR_MIN_CONF:-0.25}"
  fi
  export PIN_PRICING_STUDY_MVP="$(_resolve_pin_pricing_study_mvp)"
  echo "[$(date -Iseconds)] PIN_PRICING_STUDY_MVP=${PIN_PRICING_STUDY_MVP}"
  PREP="$PREP" BOARD_INBOX_DIR="${BOARD_INBOX_DIR:-}" /usr/bin/caffeinate -dimsu -- /bin/bash "$PRICE_SCRIPT"
}

inbox_has_boards() {
  _board_find_board_files | grep -q .
}

inbox_snapshot() {
  # Stable fingerprint: basename + size only (omit mtime). ditto from iCloud refreshes mtimes without
  # content changes, which used to look like constant "uploads" and cleared the post-failure cooldown.
  local lines="" f sz
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue
    sz=$(stat -f %z "$f" 2>/dev/null) || continue
    lines+=$(printf '%s\t%s\n' "$(basename "$f")" "$sz")
  done < <(_board_find_board_files -print0 | sort -z)
  if [[ -z "$lines" ]]; then
    printf '%s' "empty"
    return
  fi
  printf '%s' "$lines" | LC_ALL=C sort | md5 -q 2>/dev/null || printf '%s' "empty"
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

  # After a failed run last_change_epoch is cleared; when the failure cooldown ends, restart the
  # quiet debounce so the same boards can retry without Lexi re-uploading.
  if inbox_has_boards && [[ -z "${last_change_epoch:-}" ]] && (( fail_quiet_until > 0 )) && (( now >= fail_quiet_until )); then
    last_change_epoch=$now
    echo "[$(date -Iseconds)] failure cooldown ended (${FAIL_COOLDOWN_SEC}s) — ${QUIET_SEC}s quiet debounce before retry"
  fi

  if [[ "$snap" != "$last_snap" ]]; then
    last_snap=$snap
    last_change_epoch=$now
    fail_quiet_until=0
    echo "[$(date -Iseconds)] inbox snapshot changed (board set)"
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
          "The link usually works within 10-15 minutes.")"
      else
        fail_quiet_until=$((now + FAIL_COOLDOWN_SEC))
        echo "[$(date -Iseconds)] pricing failed (exit ${rc}); automatic retry after $(date -r "$fail_quiet_until" "+%Y-%m-%d %H:%M:%S %z") (${FAIL_COOLDOWN_SEC}s cooldown, or sooner if the board file set in the inbox changes)"
        send_msg "$(printf '%s\n\n%s\n\n%s' \
          "Fins & Pins pricing: FAILED (automation exit ${rc})." \
          "You don't need to debug anything. The Mac will retry automatically after a cooldown, or you can add/remove a board photo in BoardsToPrice to start sooner." \
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
