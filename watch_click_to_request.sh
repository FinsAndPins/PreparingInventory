#!/usr/bin/env bash
# Watch ClickToRequest/ for exactly one YYYYMMDD/ show folder with board photos;
# after QUIET_SEC with no changes, run prepare_click_to_claim.sh (under caffeinate).
#
# Steve drops board photos into:
#   ~/Library/Mobile Documents/com~apple~CloudDocs/ClickToRequest/YYYYMMDD/
# When uploads go quiet, this runs prepare_click_to_claim.sh (no interactive prompt).
#
# Setup:
#   1) Copy LEXI_NOTIFY.example.env → LEXI_NOTIFY.env (gitignored) for iMessage handles.
#   2) Grant Messages automation for Terminal or launchd.
#   3) Run launchd/install_click_to_request_launchagent.sh (or InstallClickToRequestWatcher.command).
#
# Env (optional):
#   CTR_QUIET_SEC            default 120 — show folder must be unchanged this long
#   CTR_POLL_SEC             default 10  — how often to rescan
#   CTR_FAIL_COOLDOWN_SEC    default 3600 — after a failed run, wait before auto-retry
#   CTR_MIN_BYTES            default 1024 — ignore iCloud placeholder stubs smaller than this
#   LOCAL_CTR_WATCHER_BIN    local copies of scripts (launchd cannot execute under iCloud)
#   CTR_MIRROR_DIR           local mirror of ClickToRequest (set by LaunchAgent launcher)
#   CTR_REQUEST_ROOT         override ClickToRequest root (default: iCloud path below)
#
set -uo pipefail
set +H

if [[ -n "${PREP:-}" ]] && [[ -d "${PREP}" ]]; then
  :
else
  PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi

CTR_REQUEST_ROOT="${CTR_REQUEST_ROOT:-${HOME}/Library/Mobile Documents/com~apple~CloudDocs/ClickToRequest}"
SCAN_ROOT="${CTR_MIRROR_DIR:-${CTR_REQUEST_ROOT}}"
BIN="${LOCAL_CTR_WATCHER_BIN:-$PREP}"
LOG="${BIN}/_logs/ctr_watcher.log"
PROCESSED_STATE="${BIN}/_logs/ctr_watcher_processed.state"
LOCKDIR="${BIN}/_logs/ctr_watcher_active.lockdir"
CTR_SCRIPT="${BIN}/prepare_click_to_claim.sh"
SEND_PY="${BIN}/lexi_send_imessage.py"
SHOW_LOG_DIR="${HOME}/Library/Logs/show-automation"

QUIET_SEC="${CTR_QUIET_SEC:-120}"
POLL_SEC="${CTR_POLL_SEC:-10}"
FAIL_COOLDOWN_SEC="${CTR_FAIL_COOLDOWN_SEC:-3600}"
PHOTO_MIN_BYTES="${CTR_MIN_BYTES:-1024}"

mkdir -p "${BIN}/_logs" "${SHOW_LOG_DIR}" "${CTR_REQUEST_ROOT}"
exec >>"$LOG" 2>&1

echo "[$(date -Iseconds)] watch_click_to_request starting (quiet=${QUIET_SEC}s poll=${POLL_SEC}s)"
echo "[$(date -Iseconds)] CTR_REQUEST_ROOT=${CTR_REQUEST_ROOT} SCAN_ROOT=${SCAN_ROOT}"

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

if [[ ! -x "$CTR_SCRIPT" ]]; then
  echo "[$(date -Iseconds)] ERROR: missing or not executable: $CTR_SCRIPT"
  exit 1
fi

send_msg() {
  local body="$1"
  if [[ ! -f "$SEND_PY" ]]; then
    echo "[$(date -Iseconds)] CTR_NOTIFY: skip (no $SEND_PY)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[$(date -Iseconds)] CTR_NOTIFY: skip (no python3)"
    return 0
  fi
  if printf '%s' "$body" | python3 "$SEND_PY"; then
    echo "[$(date -Iseconds)] CTR_NOTIFY: sent (${#body} chars)"
  else
    echo "[$(date -Iseconds)] CTR_NOTIFY: send failed (see stderr above)"
  fi
}

is_yyyymmdd() {
  [[ "$1" =~ ^[0-9]{8}$ ]]
}

# Use find (not shell globs): launchd + iCloud paths often fail glob expansion while find works.
_find_dated_show_dirs_in() {
  local root="${1:?}"
  find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    is_yyyymmdd "$(basename "$d")" && printf '%s\n' "$d"
  done
}

_find_photo_files_in() {
  local dir="${1:?}"
  find "$dir" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) \
    ! -name '.DS_Store' 2>/dev/null "${@:2}"
}

_photo_bytes_ok() {
  local f="${1:?}"
  local sz
  sz=$(stat -f %z "$f" 2>/dev/null || echo 0)
  [[ "$sz" -ge "${PHOTO_MIN_BYTES}" ]]
}

_find_ready_photos_in() {
  local dir="${1:?}" f
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue
    _photo_bytes_ok "$f" && printf '%s\0' "$f"
  done < <(_find_photo_files_in "$dir" -print0)
}

_icloud_request_download() {
  local target="${1:?}"
  if command -v brctl >/dev/null 2>&1; then
    brctl download "$target" 2>/dev/null || true
  fi
}

_pull_single_photo() {
  local src="${1:?}" dest="${2:?}"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    _icloud_request_download "$src"
    rm -f "$dest" 2>/dev/null || true
    if /bin/cp -f "$src" "$dest" 2>/dev/null || /usr/bin/ditto "$src" "$dest" 2>/dev/null; then
      if _photo_bytes_ok "$dest"; then
        return 0
      fi
    fi
    sleep 2
  done
  echo "[$(date -Iseconds)] WARN bridge_pull: could not materialize $(basename "$src") (still < ${PHOTO_MIN_BYTES} bytes after retries)"
  return 1
}

# Mirror iCloud ClickToRequest → local CTR_MIRROR_DIR so launchd can see uploads.
bridge_pull_icloud_to_mirror() {
  [[ -n "${CTR_MIRROR_DIR:-}" ]] || return 0
  mkdir -p "${CTR_MIRROR_DIR}"
  if [[ ! -d "${CTR_REQUEST_ROOT}" ]]; then
    return 0
  fi
  local show_dir name src dest ec=0 attempt out
  while IFS= read -r show_dir; do
    [[ -n "$show_dir" ]] || continue
    name="$(basename "$show_dir")"
    dest="${CTR_MIRROR_DIR}/${name}"
    mkdir -p "$dest"
    src="${CTR_REQUEST_ROOT}/${name}"
    for attempt in 1 2 3 4 5; do
      ec=0
      out=$(/usr/bin/ditto "$src/" "${dest}/" 2>&1) || ec=$?
      if [[ "$ec" -eq 0 ]]; then
        break
      fi
      if [[ "$attempt" -lt 5 ]]; then
        echo "[$(date -Iseconds)] WARN bridge_pull: ditto ${name} exit ${ec} (attempt ${attempt}/5): ${out}"
        sleep 2
      else
        echo "[$(date -Iseconds)] WARN bridge_pull: ditto ${name} exit ${ec} after 5 tries: ${out}; per-file fallback"
      fi
    done
    local f
    while IFS= read -r -d '' f; do
      _pull_single_photo "$f" "${dest}/$(basename "$f")" || true
    done < <(_find_photo_files_in "$src" -print0)
  done < <(_find_dated_show_dirs_in "${CTR_REQUEST_ROOT}")
  prune_stale_mirror_show_dirs
}

# Mirror dirs left behind after prepare_click_to_claim deletes iCloud ClickToRequest/YYYYMMDD/.
prune_stale_mirror_show_dirs() {
  [[ -n "${CTR_MIRROR_DIR:-}" ]] || return 0
  [[ -d "${CTR_MIRROR_DIR}" ]] || return 0
  local d name
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    name="$(basename "$d")"
    if [[ ! -d "${CTR_REQUEST_ROOT}/${name}" ]]; then
      echo "[$(date -Iseconds)] prune mirror: removing stale show folder ${name} (absent from iCloud ClickToRequest)"
      rm -rf "$d"
    fi
  done < <(_find_dated_show_dirs_in "${CTR_MIRROR_DIR}")
}

remove_mirror_show_dir() {
  local show_id="${1:?}"
  [[ -n "${CTR_MIRROR_DIR:-}" ]] || return 0
  if [[ -d "${CTR_MIRROR_DIR}/${show_id}" ]]; then
    echo "[$(date -Iseconds)] clearing mirror show folder ${show_id} after pipeline"
    rm -rf "${CTR_MIRROR_DIR}/${show_id}"
  fi
}

mark_show_processed() {
  local show_id="${1:?}" snap="${2:?}"
  local tmp="${PROCESSED_STATE}.$$"
  mkdir -p "$(dirname "$PROCESSED_STATE")"
  if [[ -f "$PROCESSED_STATE" ]]; then
    grep -v "^${show_id}:" "$PROCESSED_STATE" >"$tmp" 2>/dev/null || : >"$tmp"
  else
    : >"$tmp"
  fi
  printf '%s:%s\n' "$show_id" "$snap" >>"$tmp"
  mv "$tmp" "$PROCESSED_STATE"
}

is_show_snap_processed() {
  local show_id="${1:?}" snap="${2:?}"
  [[ -f "$PROCESSED_STATE" ]] && grep -qxF "${show_id}:${snap}" "$PROCESSED_STATE"
}

_effective_scan_roots() {
  printf '%s\n' "$SCAN_ROOT"
  if [[ -n "${CTR_MIRROR_DIR:-}" ]] && [[ -d "${CTR_REQUEST_ROOT}" ]]; then
    printf '%s\n' "${CTR_REQUEST_ROOT}"
  fi
}

# Returns 0 with exactly one show id on stdout; 1 if none; 2 if multiple.
discover_single_show_id() {
  local unique="" id count=0 root
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    count=$((count + 1))
    unique="$id"
    if (( count > 1 )); then
      echo "[$(date -Iseconds)] skip: multiple dated folders in ClickToRequest (expected exactly one)" >&2
      return 2
    fi
  done < <(
    while IFS= read -r root; do
      [[ -n "$root" ]] || continue
      _find_dated_show_dirs_in "$root" | while IFS= read -r d; do
        [[ -n "$d" ]] && basename "$d"
      done
    done < <(_effective_scan_roots) | LC_ALL=C sort -u
  )
  if (( count == 0 )); then
    return 1
  fi
  printf '%s' "$unique"
  return 0
}

show_folder_for_id() {
  local show_id="${1:?}"
  local root
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    if [[ -d "${root}/${show_id}" ]]; then
      printf '%s' "${root}/${show_id}"
      return 0
    fi
  done < <(_effective_scan_roots)
  return 1
}

show_has_ready_photos() {
  local show_id="${1:?}"
  local folder
  folder="$(show_folder_for_id "$show_id")" || return 1
  _find_ready_photos_in "$folder" | grep -q .
}

show_snapshot() {
  local show_id="${1:?}"
  local folder lines="" f sz
  folder="$(show_folder_for_id "$show_id")" || {
    printf '%s' "missing"
    return
  }
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue
    _photo_bytes_ok "$f" || continue
    sz=$(stat -f %z "$f" 2>/dev/null) || continue
    lines+=$(printf '%s\t%s\n' "$(basename "$f")" "$sz")
  done < <(_find_ready_photos_in "$folder" | sort -z)
  if [[ -z "$lines" ]]; then
    printf '%s' "empty"
    return
  fi
  printf '%s' "$lines" | LC_ALL=C sort -u | md5 -q 2>/dev/null || printf '%s' "empty"
}

ctr_pipeline_busy() {
  pgrep -f "prepare_click_to_claim\\.sh" >/dev/null 2>&1 \
    || pgrep -f "detect_boards_rfdetr_for_ctr\\.py" >/dev/null 2>&1
}

# Returns 0 when pipeline can run; 2 defer (iCloud download pending); 3 stale mirror-only.
ctr_preflight() {
  local show_id="${1:?}"
  local icloud_folder="${CTR_REQUEST_ROOT}/${show_id}"
  if [[ -n "${CTR_MIRROR_DIR:-}" ]] && [[ ! -d "${icloud_folder}" ]]; then
    if [[ -d "${CTR_MIRROR_DIR}/${show_id}" ]] && _find_ready_photos_in "${CTR_MIRROR_DIR}/${show_id}" | grep -q .; then
      echo "[$(date -Iseconds)] skip CTR: stale mirror only (${show_id} gone from iCloud ClickToRequest)"
      return 3
    fi
    echo "[$(date -Iseconds)] defer CTR: show folder not in iCloud yet"
    return 2
  fi
  if [[ -n "${CTR_MIRROR_DIR:-}" ]] && [[ -d "${icloud_folder}" ]]; then
    local f dest
    while IFS= read -r -d '' f; do
      dest="${icloud_folder}/$(basename "$f")"
      if [[ -f "$dest" ]] && _photo_bytes_ok "$dest"; then
        continue
      fi
      _pull_single_photo "${CTR_MIRROR_DIR}/${show_id}/$(basename "$f")" "$dest" 2>/dev/null || true
      _icloud_request_download "$dest"
      if [[ -f "$dest" ]] && ! _photo_bytes_ok "$dest"; then
        _pull_single_photo "$f" "$dest" || true
      fi
    done < <(_find_photo_files_in "${CTR_MIRROR_DIR}/${show_id}" -print0 2>/dev/null)
    if _find_ready_photos_in "$icloud_folder" | grep -q .; then
      return 0
    elif _find_ready_photos_in "${CTR_MIRROR_DIR}/${show_id}" | grep -q .; then
      echo "[$(date -Iseconds)] defer CTR: photos in mirror but not materialized in iCloud yet"
      return 2
    fi
    echo "[$(date -Iseconds)] defer CTR: photos present but not downloaded yet (< ${PHOTO_MIN_BYTES} bytes)"
    return 2
  fi
  if ! _find_ready_photos_in "$icloud_folder" | grep -q .; then
    echo "[$(date -Iseconds)] defer CTR: photos present but not downloaded yet (< ${PHOTO_MIN_BYTES} bytes)"
    return 2
  fi
  return 0
}

run_ctr_pipeline() {
  local show_id="${1:?}"
  ctr_preflight "$show_id" || return $?
  PREP="$PREP" /usr/bin/caffeinate -dimsu -- /bin/bash "$CTR_SCRIPT"
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

last_show_id=""
last_snap=""
last_change_epoch=""
fail_quiet_until=0
debug_tick=0

while true; do
  now=$(date +%s)
  bridge_pull_icloud_to_mirror

  show_id=""
  discover_rc=0
  show_id="$(discover_single_show_id)" || discover_rc=$?

  if [[ "$discover_rc" -eq 2 ]]; then
    last_show_id=""
    last_snap=""
    last_change_epoch=""
    sleep "$POLL_SEC"
    continue
  fi

  if [[ -z "$show_id" ]]; then
    last_show_id=""
    last_snap=""
    last_change_epoch=""
    sleep "$POLL_SEC"
    continue
  fi

  if [[ "${CTR_WATCHER_DEBUG:-0}" == "1" ]]; then
    debug_tick=$((debug_tick + 1))
    if (( debug_tick % 6 == 1 )); then
      hb=0
      show_has_ready_photos "$show_id" && hb=1
      echo "[$(date -Iseconds)] DEBUG show_id=${show_id} has_photos=${hb} last_change_epoch=${last_change_epoch:-}"
    fi
  fi

  if [[ "$show_id" != "$last_show_id" ]]; then
    last_show_id="$show_id"
    last_snap=""
    last_change_epoch=""
    echo "[$(date -Iseconds)] watching show folder ${show_id}"
  fi

  snap=$(show_snapshot "$show_id")

  if show_has_ready_photos "$show_id" && [[ -z "${last_change_epoch:-}" ]] && (( fail_quiet_until > 0 )) && (( now >= fail_quiet_until )); then
    last_change_epoch=$now
    echo "[$(date -Iseconds)] failure cooldown ended (${FAIL_COOLDOWN_SEC}s) — ${QUIET_SEC}s quiet debounce before retry"
  fi

  if [[ "$snap" != "$last_snap" ]]; then
    last_snap=$snap
    last_change_epoch=$now
    fail_quiet_until=0
    echo "[$(date -Iseconds)] show ${show_id} snapshot changed (photo set)"
  fi

  if show_has_ready_photos "$show_id" && [[ -n "${last_change_epoch:-}" ]] && [[ "$now" -ge "$fail_quiet_until" ]]; then
    idle=$((now - last_change_epoch))
    if [[ "$idle" -ge "$QUIET_SEC" ]]; then
      if ctr_pipeline_busy; then
        echo "[$(date -Iseconds)] skip auto CTR: prepare_click_to_claim already running"
        last_change_epoch=$now
      elif is_show_snap_processed "$show_id" "$snap"; then
        echo "[$(date -Iseconds)] skip auto CTR: show ${show_id} snapshot already processed successfully"
        last_change_epoch=""
      else
        preflight_rc=0
        ctr_preflight "$show_id" || preflight_rc=$?
        if [[ "$preflight_rc" -eq 3 ]]; then
          remove_mirror_show_dir "$show_id"
          last_show_id=""
          last_snap=""
          last_change_epoch=""
          sleep "$POLL_SEC"
          continue
        elif [[ "$preflight_rc" -eq 2 ]]; then
          echo "[$(date -Iseconds)] CTR not ready (iCloud download pending); waiting without notify"
          last_change_epoch=$now
          sleep "$POLL_SEC"
          continue
        fi

        log_path="${SHOW_LOG_DIR}/${show_id}-ctr.log"
        trigger_snap="$snap"
        echo "[$(date -Iseconds)] quiet for ${idle}s with photos in ${show_id} — acquiring lock"
        acquire_lock
        echo "[$(date -Iseconds)] lock acquired; starting prepare_click_to_claim.sh (caffeinate)"
        ( send_msg "ClickToRequest for show ${show_id}: started on Steve's Mac (photos detected in ClickToRequest). You'll get another message when the run finishes and has been pushed to GitHub." ) &

        set +e
        run_ctr_pipeline "$show_id"
        rc=$?
        set -e

        release_lock
        echo "[$(date -Iseconds)] lock released (exit ${rc})"

        if [[ "$rc" -eq 2 ]]; then
          echo "[$(date -Iseconds)] CTR deferred (iCloud download pending); will retry after next quiet period"
          last_change_epoch=$now
          sleep "$POLL_SEC"
          continue
        fi

        if [[ "$rc" -eq 3 ]]; then
          remove_mirror_show_dir "$show_id"
          last_show_id=""
          last_snap=""
          last_change_epoch=""
          sleep "$POLL_SEC"
          continue
        fi

        live_url="https://finsandpins.github.io/ClickToClaim/${show_id}/"

        if [[ "$rc" -eq 0 ]]; then
          fail_quiet_until=0
          mark_show_processed "$show_id" "$trigger_snap"
          remove_mirror_show_dir "$show_id"
          prune_stale_mirror_show_dirs
          send_msg "$(printf '%s\n\n%s\n\n%s\n\n%s' \
            "ClickToRequest for show ${show_id} is ready" \
            "Live site: ${live_url}" \
            "The link usually works within 10-15 minutes." \
            "Log: ${log_path}")"
        else
          fail_quiet_until=$((now + FAIL_COOLDOWN_SEC))
          echo "[$(date -Iseconds)] CTR failed (exit ${rc}); automatic retry after $(date -r "$fail_quiet_until" "+%Y-%m-%d %H:%M:%S %z") (${FAIL_COOLDOWN_SEC}s cooldown, or sooner if the photo set changes)"
          send_msg "$(printf '%s\n\n%s\n\n%s' \
            "ClickToRequest for show ${show_id}: FAILED (automation exit ${rc})." \
            "The Mac will retry automatically after a cooldown, or you can add/remove a photo in the show folder to start sooner." \
            "Log: ${log_path}")"
        fi

        # Reset debounce so we only react to the next upload wave (matches board_inbox_watcher).
        last_snap=$(show_snapshot "$show_id")
        if [[ "$rc" -eq 0 ]]; then
          last_show_id=""
          last_snap=""
          last_change_epoch=""
        else
          last_change_epoch=""
        fi
      fi
    fi
  else
    if ! show_has_ready_photos "$show_id"; then
      last_change_epoch=""
    fi
  fi

  sleep "$POLL_SEC"
done
