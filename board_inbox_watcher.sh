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
#                                  automatic retry (stops iMessage spam). A *new* set of board
#                                  basenames (true new upload) clears the cooldown; size-only
#                                  changes / rollback of the same boards do not.
#   PRICE_INBOX_FAIL_NOTIFY_MIN_SEC default 3600 — min seconds between Steve failure iMessages
#                                  (retries still happen; texts are rate-limited).
#   PRICE_INBOX_NOT_READY_RETRY_SEC default 120 — after exit 75 (0-byte / iCloud stub boards),
#                                  quiet retry delay; no iMessage.
#   PRICING_FAIL_NOTIFY_HANDLES — Steve-only failure texts (space-separated). Empty = no failure texts.
#                                  Start/success still use PRICING_NOTIFY_HANDLES (Lexi + Steve).
#   PIN_PRICING_USE_RFDETR   default 1 — RF-DETR (Core ML). Set 0 to use Roboflow API for this watcher.
#   PIN_PRICING_STUDY_MVP    defaults to PinPricingStudyMVP_RFDETR_TEST when RF-DETR; else PinPricingStudyMVP.
#   PIN_PRICING_RFDETR_MIN_CONF — optional; default 0.25 (matches Click To Collect app).
#   LOCAL_WATCHER_BIN     if set, directory with copies of this script, price_boards_from_inbox.sh,
#                           and lexi_send_imessage.py (launchd cannot run scripts from iCloud paths).
#   BOARDS_TO_PRICE_DROP_ZONE  Lexi's iCloud BoardsToPrice drop zone (canonical).
#                              Default in launchd launcher: iCloud PreparingInventory/BoardsToPrice.
#                              Required when PREP is the App Support publish clone.
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
FAIL_NOTIFY_MIN_SEC="${PRICE_INBOX_FAIL_NOTIFY_MIN_SEC:-3600}"
NOT_READY_RETRY_SEC="${PRICE_INBOX_NOT_READY_RETRY_SEC:-120}"
RFDETR_MODEL_MIN_WEIGHT_BYTES="${RFDETR_MODEL_MIN_WEIGHT_BYTES:-1000000}"

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

send_msg_to() {
  local handles="$1"
  local body="$2"
  local label="${3:-LEXI_NOTIFY}"
  local attach="${4:-}"
  if [[ -z "$handles" ]]; then
    echo "[$(date -Iseconds)] ${label}: skip (no handles)"
    return 0
  fi
  if [[ ! -f "$SEND_PY" ]]; then
    echo "[$(date -Iseconds)] ${label}: skip (no $SEND_PY)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[$(date -Iseconds)] ${label}: skip (no python3)"
    return 0
  fi
  # Override recipients for this send only (start/success → Lexi+Steve; failures → Steve).
  # Optional IMESSAGE_ATTACH = image path (success pricing texts); sender falls back to text-only.
  if printf '%s' "$body" | PRICING_NOTIFY_HANDLES="$handles" LEXI_IMESSAGE_HANDLE="" \
      IMESSAGE_ATTACH="${attach}" python3 "$SEND_PY"; then
    if [[ -n "$attach" ]]; then
      echo "[$(date -Iseconds)] ${label}: sent (${#body} chars + thumb)"
    else
      echo "[$(date -Iseconds)] ${label}: sent (${#body} chars)"
    fi
  else
    echo "[$(date -Iseconds)] ${label}: send failed (see stderr above)"
  fi
}

# First-board preview JPEG written by price_boards_from_inbox.sh (lexi_preview.jpg).
pricing_success_preview_thumb() {
  local thumb="" col work
  if [[ -f "$LAST_PRICE_LOG" ]]; then
    thumb=$(grep 'Preview thumb:' "$LAST_PRICE_LOG" | tail -1 | sed 's/.*Preview thumb: //' || true)
  fi
  if [[ -n "$thumb" && -f "$thumb" ]]; then
    printf '%s' "$thumb"
    return 0
  fi
  # Fallback: derive collection from harness URL → PricingWork/.../lexi_preview.jpg
  local url=""
  if [[ -f "$LAST_PRICE_LOG" ]]; then
    url=$(grep 'Harness:' "$LAST_PRICE_LOG" | tail -1 | sed 's/.*Harness: //' || true)
  fi
  col=$(printf '%s' "$url" | sed -n 's|.*/\(PriceCollection_[0-9]\{8\}_[0-9]\{4\}\)/.*|\1|p')
  work="${PRICE_PIPELINE_WORK:-${HOME}/Library/Application Support/FinsAndPins/PricingWork}"
  if [[ -n "$col" && -f "${work}/${col}/lexi_preview.jpg" ]]; then
    printf '%s' "${work}/${col}/lexi_preview.jpg"
    return 0
  fi
  return 1
}

# Start / success — everyone in PRICING_NOTIFY_HANDLES (or LEXI_IMESSAGE_HANDLE fallback).
# Optional 2nd arg: image path to attach (pricing success preview thumb).
send_msg() {
  local body="$1"
  local attach="${2:-}"
  local handles="${PRICING_NOTIFY_HANDLES:-${LEXI_IMESSAGE_HANDLE:-}}"
  send_msg_to "$handles" "$body" "LEXI_NOTIFY" "$attach"
}

# Failures — Steve only. Empty PRICING_FAIL_NOTIFY_HANDLES = silence (no Lexi spam).
send_fail_msg() {
  local body="$1"
  local handles="${PRICING_FAIL_NOTIFY_HANDLES:-}"
  if [[ -z "$handles" ]]; then
    echo "[$(date -Iseconds)] FAIL_NOTIFY: suppressed (PRICING_FAIL_NOTIFY_HANDLES unset — Lexi not texted)"
    return 0
  fi
  send_msg_to "$handles" "$body" "FAIL_NOTIFY"
}

_local_rfdetr_model_ok() {
  local pkg="${RFDETR_COREML_MODEL_PATH:-${HOME}/Library/Application Support/FinsAndPins/models/RfDetrPinDetector.mlpackage}"
  local weight="${pkg}/Data/com.apple.CoreML/weights/weight.bin"
  local sz
  [[ -d "$pkg" ]] || return 1
  [[ -f "$weight" ]] || return 1
  sz=$(stat -f %z "$weight" 2>/dev/null || echo 0)
  [[ "$sz" -gt "${RFDETR_MODEL_MIN_WEIGHT_BYTES}" ]]
}

# Fail-fast at watcher start when RF-DETR is enabled: missing local model must not start runs.
model_preflight_notified=0
if [[ "${PIN_PRICING_USE_RFDETR:-1}" != "0" ]] && [[ "${PIN_PRICING_USE_RFDETR:-1}" != "false" ]] && [[ "${PIN_PRICING_USE_RFDETR:-1}" != "False" ]]; then
  if _local_rfdetr_model_ok; then
    echo "[$(date -Iseconds)] RF-DETR local model OK: ${RFDETR_COREML_MODEL_PATH:-${HOME}/Library/Application Support/FinsAndPins/models/RfDetrPinDetector.mlpackage}"
  else
    echo "[$(date -Iseconds)] ERROR: local RF-DETR model missing/tiny — refusing pricing runs until install syncs Application Support/FinsAndPins/models/"
    send_fail_msg "Fins & Pins pricing: watcher will not start runs — local RF-DETR Core ML model is missing. Re-run launchd/install_boards_inbox_launchagent.sh on Steve's Mac."
    model_preflight_notified=1
  fi
fi

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
  # Lexi drops in the iCloud BoardsToPrice folder. PREP may be the App Support
  # publish clone (empty BoardsToPrice) — do not pull from there.
  local src="${BOARDS_TO_PRICE_DROP_ZONE:-${PREP}/BoardsToPrice}"
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
  # LOCAL_WATCHER_BIN lets price_boards prefer launchd-safe copies of review-page scripts.
  PREP="$PREP" BOARD_INBOX_DIR="${BOARD_INBOX_DIR:-}" LOCAL_WATCHER_BIN="${LOCAL_WATCHER_BIN:-$BIN}" \
    /usr/bin/caffeinate -dimsu -- /bin/bash "$PRICE_SCRIPT"
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

# Basename-only fingerprint — used so rollback/size flicker of the *same* boards does not
# clear the post-failure cooldown (that was spamming Lexi with start+fail every ~2 min).
inbox_basenames_fp() {
  local lines="" f
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue
    lines+=$(printf '%s\n' "$(basename "$f")")
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
fail_basenames_fp=""
last_fail_notify_epoch=0
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
    names_fp=$(inbox_basenames_fp)
    last_snap=$snap
    last_change_epoch=$now
    # Only clear failure cooldown on a *new basename set* (true new upload / empty→boards).
    # Size-only changes and rollback of the same boards must keep the cooldown.
    if [[ -n "$fail_basenames_fp" && "$names_fp" == "$fail_basenames_fp" && "$now" -lt "$fail_quiet_until" ]]; then
      echo "[$(date -Iseconds)] inbox snapshot changed (same board names; keeping failure cooldown until $(date -r "$fail_quiet_until" "+%H:%M:%S"))"
    else
      fail_quiet_until=0
      fail_basenames_fp=""
      echo "[$(date -Iseconds)] inbox snapshot changed (board set)"
    fi
  fi

  if inbox_has_boards && [[ -n "${last_change_epoch:-}" ]] && [[ "$now" -ge "$fail_quiet_until" ]]; then
    idle=$((now - last_change_epoch))
    if [[ "$idle" -ge "$QUIET_SEC" ]]; then
      # Refuse to start if local RF-DETR model is missing (errno-11 Desktop path under launchd).
      if [[ "${PIN_PRICING_USE_RFDETR:-1}" != "0" ]] && [[ "${PIN_PRICING_USE_RFDETR:-1}" != "false" ]] && [[ "${PIN_PRICING_USE_RFDETR:-1}" != "False" ]] \
        && ! _local_rfdetr_model_ok; then
        echo "[$(date -Iseconds)] ERROR: skipping run — local RF-DETR model missing/tiny"
        fail_quiet_until=$((now + FAIL_COOLDOWN_SEC))
        fail_basenames_fp=$(inbox_basenames_fp)
        last_change_epoch=""
        if [[ "$model_preflight_notified" -eq 0 ]]; then
          send_fail_msg "Fins & Pins pricing: skipped run — local RF-DETR Core ML model is missing. Re-run launchd/install_boards_inbox_launchagent.sh on Steve's Mac."
          model_preflight_notified=1
          last_fail_notify_epoch=$now
        fi
        sleep "$POLL_SEC"
        continue
      fi

      echo "[$(date -Iseconds)] quiet for ${idle}s with boards present — acquiring lock"
      acquire_lock
      echo "[$(date -Iseconds)] lock acquired; starting price_boards_from_inbox.sh (caffeinate)"
      # Do not block the pipeline on Messages (timeouts would delay pricing and log writes).
      # Suppress "started" texts while retrying the same failed board set (avoids Lexi spam).
      names_fp=$(inbox_basenames_fp)
      if [[ -n "$fail_basenames_fp" && "$names_fp" == "$fail_basenames_fp" ]]; then
        echo "[$(date -Iseconds)] LEXI_NOTIFY: suppressed started (retry of same failed board set)"
      else
        ( send_msg "Fins & Pins pricing: started on Steve's Mac (boards detected in BoardsToPrice). You'll get another message when the run finishes and has been pushed to GitHub." ) &
      fi

      set +e
      # Best-effort: keep the Mac awake while the long pricing pipeline runs (lid may be closed).
      PREP="$PREP" run_price_pipeline
      rc=$?
      set -e

      release_lock
      echo "[$(date -Iseconds)] lock released (exit ${rc})"

      if [[ "$rc" -eq 0 ]]; then
        fail_quiet_until=0
        fail_basenames_fp=""
        last_fail_notify_epoch=0
        model_preflight_notified=0
        url=""
        thumb=""
        if [[ -f "$LAST_PRICE_LOG" ]]; then
          url=$(grep 'Harness:' "$LAST_PRICE_LOG" | tail -1 | sed 's/.*Harness: //' || true)
        fi
        thumb=$(pricing_success_preview_thumb || true)
        if [[ -n "$thumb" ]]; then
          echo "[$(date -Iseconds)] LEXI_NOTIFY: attaching preview thumb ${thumb}"
        else
          echo "[$(date -Iseconds)] LEXI_NOTIFY: no preview thumb (text + URL only)"
        fi
        send_msg "$(printf '%s\n\n%s\n\n%s' \
          "Fins & Pins pricing: finished and pushed to GitHub." \
          "${url:-Harness URL not found in log - open the PreparingInventory Lexi index on GitHub Pages.}" \
          "The link usually works within 10-15 minutes.")" "$thumb"
      elif [[ "$rc" -eq 75 ]]; then
        # Boards not ready (0-byte / iCloud stub) — quiet short retry, no iMessage.
        now=$(date +%s)
        fail_basenames_fp=$(inbox_basenames_fp)
        fail_quiet_until=$((now + NOT_READY_RETRY_SEC))
        echo "[$(date -Iseconds)] QUIET_RETRY: boards not ready (exit 75); retry after $(date -r "$fail_quiet_until" "+%Y-%m-%d %H:%M:%S %z") (${NOT_READY_RETRY_SEC}s, no iMessage)"
      elif [[ "$rc" -eq 76 ]]; then
        now=$(date +%s)
        fail_basenames_fp=$(inbox_basenames_fp)
        fail_quiet_until=$((now + FAIL_COOLDOWN_SEC))
        echo "[$(date -Iseconds)] pricing blocked — local RF-DETR model missing (exit 76); retry after $(date -r "$fail_quiet_until" "+%Y-%m-%d %H:%M:%S %z")"
        if (( last_fail_notify_epoch == 0 || now - last_fail_notify_epoch >= FAIL_NOTIFY_MIN_SEC )); then
          last_fail_notify_epoch=$now
          send_fail_msg "Fins & Pins pricing: blocked — local RF-DETR Core ML model missing/unusable (exit 76). Re-run launchd/install_boards_inbox_launchagent.sh. Lexi was not texted."
        else
          echo "[$(date -Iseconds)] FAIL_NOTIFY: suppressed (rate limit ${FAIL_NOTIFY_MIN_SEC}s)"
        fi
      else
        now=$(date +%s)
        fail_basenames_fp=$(inbox_basenames_fp)
        fail_quiet_until=$((now + FAIL_COOLDOWN_SEC))
        echo "[$(date -Iseconds)] pricing failed (exit ${rc}); automatic retry after $(date -r "$fail_quiet_until" "+%Y-%m-%d %H:%M:%S %z") (${FAIL_COOLDOWN_SEC}s cooldown, or sooner if a *new* board file set appears)"
        if (( last_fail_notify_epoch == 0 || now - last_fail_notify_epoch >= FAIL_NOTIFY_MIN_SEC )); then
          last_fail_notify_epoch=$now
          send_fail_msg "$(printf '%s\n\n%s\n\n%s' \
            "Fins & Pins pricing: FAILED (automation exit ${rc}). Lexi was not texted." \
            "The Mac will retry automatically after a cooldown, or add/remove a board photo in BoardsToPrice to start sooner." \
            "Check PreparingInventoryWatcherBin/_logs/price_inbox_last.log")"
        else
          echo "[$(date -Iseconds)] FAIL_NOTIFY: suppressed (rate limit ${FAIL_NOTIFY_MIN_SEC}s; last notify $(date -r "$last_fail_notify_epoch" "+%H:%M:%S"))"
        fi
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
