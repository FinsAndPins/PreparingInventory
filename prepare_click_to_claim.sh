#!/usr/bin/env bash
# Prepare ClickToClaim from exactly one dated folder under ClickToRequest/.
#
# Flow: discover input → bootstrap show template → RF-DETR detect → validate →
#       update shows_index.json → path-limited git commit/push → delete input folder.
#
# Optional env:
#   DRY_RUN=1           — print plan only; no file changes, detect, git, or delete
#   SKIP_GIT=1          — run detect/validate but skip commit/push and input cleanup
#   SKIP_DELETE=1       — skip deleting ClickToRequest folder after success
#   CTR_TEMPLATE_ID     — force bootstrap template show (YYYYMMDD only). Launchd pins
#                         20260903 (user-include filter on reports + Fix boxes / Board Box Editor).
#   CTR_PRICING_RUN_ID  — Firebase test_run_id for the matching pricing harness
#                         (test_PriceCollection_…_visual_baseline). When set, price overlay
#                         points at that run. When unset, inherited template pricing ids are
#                         cleared to a per-show unset sentinel (never keep an old collection).
#   CTR_PRICE_COLLECTION — optional path to a PriceCollection_* dir; ui_data.json test_run_id
#                         is used (overrides CTR_PRICING_RUN_ID when both are set).
#   PIN_PRICING_RFDETR_DIR — RF-DETR venv root (PinPricingStudyMVP_RFDETR_TEST)
#   RFDETR_COREML_MODEL_PATH — Core ML model .mlpackage (prefer Application Support local copy)
#   PIN_PRICING_RFDETR_MIN_CONF — min confidence (default 0.25)
#
set -euo pipefail
set +H

PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Canonical Lexi/Steve drop zone (iCloud). Prefer env from launchd launcher when set.
CTR_REQUEST_ROOT="${CTR_REQUEST_ROOT:-${HOME}/Library/Mobile Documents/com~apple~CloudDocs/ClickToRequest}"
# Optional local mirror / explicit input (launchd-safe RF-DETR reads).
CTR_MIRROR_DIR="${CTR_MIRROR_DIR:-}"
CTR_INPUT_DIR="${CTR_INPUT_DIR:-}"
CTR_REPO="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/GitHub Repository/ClickToClaim"
FINS_LOCAL="${HOME}/Library/Application Support/FinsAndPins"
PIN_DIR_ICLOUD="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Cursor Projects/PinPricingStudyMVP_RFDETR_TEST"
PIN_DIR_LOCAL="${FINS_LOCAL}/PinPricingStudyMVP_RFDETR_TEST"
# Prefer Application Support under launchd — iCloud .rfdetr_py39 often fails numpy mmap (errno 11).
if [[ -n "${PIN_PRICING_RFDETR_DIR:-}" ]]; then
  PIN_DIR="${PIN_PRICING_RFDETR_DIR}"
elif [[ -x "${PIN_DIR_LOCAL}/.rfdetr_py39/bin/python" ]] && [[ -f "${PIN_DIR_LOCAL}/rfdetr_coreml_detector.py" ]]; then
  PIN_DIR="${PIN_DIR_LOCAL}"
else
  PIN_DIR="${PIN_DIR_ICLOUD}"
fi
LOG_DIR="${HOME}/Library/Logs/show-automation"
LIVE_BASE="https://finsandpins.github.io/ClickToClaim"

DETECT_PY="${PREP}/detect_boards_rfdetr_for_ctr.py"
VALIDATE_PY="${PREP}/validate_ctr_boards.py"
PATCH_PY="${PREP}/patch_ctr_show_slug.py"
UPDATE_INDEX_PY="${CTR_REPO}/update_shows_index.py"

mkdir -p "$LOG_DIR"

log() {
  local msg="[$(date -Iseconds)] $*"
  echo "$msg"
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

# Exit 4 = boards ready locally; only git commit/push remains (watcher uses short cooldown).
die_commit_pending() {
  log "ERROR: $*"
  exit 4
}

is_yyyymmdd() {
  [[ "$1" =~ ^[0-9]{8}$ ]]
}

discover_input_show() {
  local count=0
  local found=""
  local name d
  shopt -s nullglob
  for d in "${CTR_REQUEST_ROOT}"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    is_yyyymmdd "$name" || continue
    if (( count > 0 )); then
      die "Multiple dated folders in ClickToRequest (expected exactly one): found at least ${found} and ${name}"
    fi
    found="$name"
    count=$((count + 1))
  done
  shopt -u nullglob
  if (( count == 0 )); then
    die "No YYYYMMDD folder found under ${CTR_REQUEST_ROOT}/"
  fi
  echo "$found"
}

find_highest_template_show() {
  # Bootstrap from a normal YYYYMMDD show only — never 2026D23 / Test overlays.
  # Prefer CTR_TEMPLATE_ID when set (launchd pins 20260903 until you change it).
  # Prefer git ls-tree (one call); fall back to disk if iCloud git flakes under launchd.
  local exclude="${SHOW_ID:-}"
  local best="" best_num=0 name num d

  if [[ -n "${CTR_TEMPLATE_ID:-}" ]]; then
    if ! is_yyyymmdd "$CTR_TEMPLATE_ID"; then
      die "CTR_TEMPLATE_ID must be YYYYMMDD (got '${CTR_TEMPLATE_ID}' — refusing non-dated templates like D23)"
    fi
    if [[ ! -f "${CTR_REPO}/${CTR_TEMPLATE_ID}/index.html" ]]; then
      die "CTR_TEMPLATE_ID=${CTR_TEMPLATE_ID} has no index.html under ${CTR_REPO}"
    fi
    echo "$CTR_TEMPLATE_ID"
    return 0
  fi

  # Primary: committed dated shows on HEAD (single ls-tree — less flaky than per-folder cat-file).
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    is_yyyymmdd "$name" || continue
    [[ -n "$exclude" && "$name" == "$exclude" ]] && continue
    num=$((10#$name))
    if (( num > best_num )); then
      best_num=$num
      best="$name"
    fi
  done < <(git -C "$CTR_REPO" ls-tree --name-only -d HEAD 2>/dev/null || true)

  if [[ -n "$best" && -f "${CTR_REPO}/${best}/index.html" ]]; then
    echo "$best"
    return 0
  fi

  # Fallback: highest YYYYMMDD on disk with index.html (launchd + iCloud git errno 11).
  log "WARN: git ls-tree template scan empty/failed — falling back to on-disk YYYYMMDD shows"
  best=""
  best_num=0
  shopt -s nullglob
  for d in "${CTR_REPO}"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    is_yyyymmdd "$name" || continue
    [[ -n "$exclude" && "$name" == "$exclude" ]] && continue
    [[ -f "${d}index.html" ]] || continue
    num=$((10#$name))
    if (( num > best_num )); then
      best_num=$num
      best="$name"
    fi
  done
  shopt -u nullglob

  if [[ -z "$best" ]]; then
    die "No dated YYYYMMDD show template with index.html found under ${CTR_REPO}/ (refusing non-dated folders like 2026D23)"
  fi
  echo "$best"
}

has_board_outputs() {
  local show_dir="$1"
  local boards="${show_dir}/boards"
  [[ -d "$boards" ]] || return 1
  [[ -f "${boards}/manifest.json" ]] && return 0
  find "$boards" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.json' \) -print -quit | grep -q .
}

show_bootstrap_complete() {
  local target_dir="$1"
  [[ -s "${target_dir}/index.html" ]] && [[ -s "${target_dir}/reports.html" ]]
}

# Remove partial bootstrap leftovers (e.g. 0-byte index.html) so retries do not skip bootstrap_show.
scrub_failed_bootstrap() {
  local target_dir="$1"
  [[ -d "$target_dir" ]] || return 0
  if has_board_outputs "$target_dir"; then
    return 0
  fi
  if show_bootstrap_complete "$target_dir"; then
    return 0
  fi
  log "WARN: incomplete bootstrap from prior failed run — removing ${target_dir}"
  rm -rf "$target_dir"
}

count_input_photos() {
  find "$1" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l | tr -d ' '
}

ensure_collection_detection_promo_asset() {
  local target_dir="$1"
  local template_dir="${2:-}"
  local dest="${target_dir}/collection-detection-app-square.png"
  local src=""
  # Prefer a non-iCloud local cache (launchd bin) — CloudDocs fcopyfile often deadlocks.
  if [[ -s "${PREP}/collection-detection-app-square.png" ]]; then
    src="${PREP}/collection-detection-app-square.png"
  elif [[ -s "${CTR_REPO}/_show_static/collection-detection-app-square.png" ]]; then
    src="${CTR_REPO}/_show_static/collection-detection-app-square.png"
  elif [[ -n "$template_dir" && -s "${template_dir}/collection-detection-app-square.png" ]]; then
    src="${template_dir}/collection-detection-app-square.png"
  elif [[ -s "$dest" ]]; then
    return 0
  fi
  if [[ -z "$src" ]]; then
    log "WARN: collection-detection-app-square.png missing (no local cache, _show_static, or template source)"
    return 1
  fi
  # Drop empty/partial stubs left by prior failed copies.
  if [[ -e "$dest" ]] && [[ ! -s "$dest" ]]; then
    rm -f "$dest" || true
  fi
  copy_with_retry "$src" "$dest" || return 1
  [[ -s "$dest" ]] || return 1
  log "Ensured collection-detection-app-square.png in show folder"
}

# iCloud can return EDEADLK on mmap/rsync/cp for files under CloudDocs.
copy_with_retry() {
  local src="$1"
  local dest="$2"
  local attempt=1
  local max_attempts=12
  local err=""
  local tmp=""
  mkdir -p "$(dirname "$dest")"

  # Fast path: read committed blobs from git (bypasses iCloud fcopyfile on template copies).
  if [[ "$src" == "${CTR_REPO}/"* ]]; then
    local rel="${src#${CTR_REPO}/}"
    if git -C "$CTR_REPO" cat-file -e "HEAD:${rel}" 2>/dev/null; then
      tmp="$(mktemp "${TMPDIR:-/tmp}/ctr_git_copy.XXXXXX")"
      if git -C "$CTR_REPO" show "HEAD:${rel}" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        if python3 - "$tmp" "$dest" <<'PY' 2>/dev/null
import sys
from pathlib import Path
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_bytes(src.read_bytes())
PY
        then
          rm -f "$tmp"
          if [[ -s "$dest" ]]; then
            return 0
          fi
        fi
      fi
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi

  while (( attempt <= max_attempts )); do
    rm -f "$dest" 2>/dev/null || true
    if command -v brctl >/dev/null 2>&1; then
      brctl download "$src" 2>/dev/null || true
    fi
    # 1) plain cp
    if err=$(cp -f "$src" "$dest" 2>&1) && [[ -s "$dest" ]]; then
      return 0
    fi
    # 2) Python read from source with brctl + errno-11 retry, byte-write dest (avoids fcopyfile)
    if CTR_COPY_SRC="$src" CTR_COPY_DEST="$dest" python3 - <<'PY' 2>/dev/null
import os, subprocess, sys, time
from pathlib import Path
src = Path(os.environ["CTR_COPY_SRC"])
dest = Path(os.environ["CTR_COPY_DEST"])
for attempt in range(1, 13):
    try:
        subprocess.run(["brctl", "download", str(src)], capture_output=True, timeout=30)
    except Exception:
        pass
    try:
        data = src.read_bytes()
        if data:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            if dest.stat().st_size > 0:
                sys.exit(0)
    except OSError as e:
        if getattr(e, "errno", None) != 11:
            raise
    time.sleep(min(attempt * 2, 30))
sys.exit(1)
PY
    then
      if [[ -s "$dest" ]]; then
        return 0
      fi
    fi
    # 3) stage outside iCloud via tmp, then Python byte-write
    tmp="$(mktemp "${TMPDIR:-/tmp}/ctr_copy.XXXXXX")"
    if cp -f "$src" "$tmp" 2>/dev/null \
      && python3 - "$tmp" "$dest" <<'PY' 2>/dev/null
import sys
from pathlib import Path
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_bytes(src.read_bytes())
PY
    then
      rm -f "$tmp"
      if [[ -s "$dest" ]]; then
        return 0
      fi
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
    if echo "${err:-}" | grep -qiE 'deadlock|Resource deadlock|mmap|fcopyfile' \
      || [[ ! -s "$dest" ]]; then
      log "WARN: copy hit iCloud/fs contention (attempt ${attempt}/${max_attempts}): ${src##*/}: ${err:-empty dest}"
      sleep $(( attempt * 2 ))
      attempt=$((attempt + 1))
      continue
    fi
    log "ERROR: copy failed: ${src} -> ${dest}: ${err}"
    return 1
  done
  log "ERROR: copy failed after ${max_attempts} attempts: ${src} -> ${dest}"
  return 1
}

copy_icons_with_retry() {
  local template_dir="$1"
  local target_dir="$2"
  local f
  mkdir -p "${target_dir}/icons"
  [[ -d "${template_dir}/icons" ]] || return 0
  shopt -s nullglob
  for f in "${template_dir}/icons"/*; do
    [[ -f "$f" ]] || continue
    copy_with_retry "$f" "${target_dir}/icons/$(basename "$f")" || {
      shopt -u nullglob
      return 1
    }
  done
  shopt -u nullglob
  return 0
}

copy_js_with_retry() {
  local template_dir="$1"
  local target_dir="$2"
  local f
  mkdir -p "${target_dir}/js"
  [[ -d "${template_dir}/js" ]] || return 0
  shopt -s nullglob
  for f in "${template_dir}/js"/*; do
    [[ -f "$f" ]] || continue
    copy_with_retry "$f" "${target_dir}/js/$(basename "$f")" || {
      shopt -u nullglob
      return 1
    }
  done
  shopt -u nullglob
  log "Copied js/ assets from template"
  return 0
}

# Patch show slug + pricing overlay Firebase run id (never leave a template's old collection).
patch_show_html() {
  local target_dir="$1"
  local show_id="$2"
  local -a args=(python3 "$PATCH_PY" "$target_dir" "$show_id")
  if [[ -n "${CTR_PRICE_COLLECTION:-}" ]]; then
    args+=(--from-collection "$CTR_PRICE_COLLECTION")
    log "Wiring price overlay from collection: ${CTR_PRICE_COLLECTION}"
  elif [[ -n "${CTR_PRICING_RUN_ID:-}" ]]; then
    args+=(--pricing-run-id "$CTR_PRICING_RUN_ID")
    log "Wiring price overlay run id: ${CTR_PRICING_RUN_ID}"
  else
    args+=(--pricing-unset)
    log "No CTR_PRICING_RUN_ID / CTR_PRICE_COLLECTION — clearing inherited template pricing overlay id"
  fi
  "${args[@]}" || die "patch_ctr_show_slug.py failed for ${show_id}"
}

bootstrap_show() {
  local template_id="$1"
  local show_id="$2"
  local template_dir="${CTR_REPO}/${template_id}"
  local target_dir="${CTR_REPO}/${show_id}"
  local opt

  log "Bootstrapping ${show_id} from template ${template_id}"
  mkdir -p "${target_dir}/icons"
  # Prefer plain cp + retries over rsync: rsync mmap often deadlocks under iCloud.
  copy_with_retry "${template_dir}/index.html" "${target_dir}/index.html" \
    || die "Failed copying index.html from template ${template_id}"
  copy_with_retry "${template_dir}/reports.html" "${target_dir}/reports.html" \
    || die "Failed copying reports.html from template ${template_id}"
  # Optional companion pages from the pinned template (skip if absent on older templates).
  for opt in mark_pending.html mark_leftover_sold.html leftover_sheet.html; do
    if [[ -f "${template_dir}/${opt}" ]]; then
      copy_with_retry "${template_dir}/${opt}" "${target_dir}/${opt}" \
        || die "Failed copying ${opt} from template ${template_id}"
      log "Copied companion page: ${opt}"
    fi
  done
  copy_icons_with_retry "$template_dir" "$target_dir" \
    || die "Failed copying icons from template ${template_id}"
  copy_js_with_retry "$template_dir" "$target_dir" \
    || die "Failed copying js/ from template ${template_id}"
  ensure_collection_detection_promo_asset "$target_dir" "$template_dir" \
    || die "Failed placing collection-detection-app-square.png"
  patch_show_html "$target_dir" "$show_id"
}

# After RF-DETR boards exist: create BoardBoxEditor/<show>/ with that show's boards.
# Reports links use the show slug; editor UI derives SHOW_SLUG from its URL path.
bootstrap_board_box_editor() {
  local show_id="$1"
  local template_id="$2"
  local editor_src=""
  local dest="${CTR_REPO}/BoardBoxEditor/${show_id}"
  local boards_src="${CTR_REPO}/${show_id}/boards"
  local f

  if [[ -f "${CTR_REPO}/BoardBoxEditor/${template_id}/index.html" ]]; then
    editor_src="${CTR_REPO}/BoardBoxEditor/${template_id}"
  elif [[ -f "${CTR_REPO}/BoardBoxEditor/20260903/index.html" ]]; then
    editor_src="${CTR_REPO}/BoardBoxEditor/20260903"
  else
    log "WARN: no BoardBoxEditor UI template — skipping editor bootstrap for ${show_id}"
    return 0
  fi

  if [[ ! -d "$boards_src" ]] || [[ ! -f "${boards_src}/manifest.json" ]]; then
    log "WARN: ${boards_src} missing — skipping Board Box Editor bootstrap"
    return 0
  fi

  log "Bootstrapping BoardBoxEditor/${show_id} (UI from ${editor_src##*/}, boards from ${show_id})"
  mkdir -p "${dest}/boards"
  copy_with_retry "${editor_src}/index.html" "${dest}/index.html" \
    || die "Failed copying BoardBoxEditor index.html for ${show_id}"
  cat > "${dest}/README.md" <<EOF
# Board Box Editor — ${show_id}

Manual pin-box cleanup for Click To Request ${show_id}.

**https://finsandpins.github.io/ClickToClaim/BoardBoxEditor/${show_id}/**

Open from **${show_id} → Reports** (admin) → **Board box editor**.

Save writes to Firebase \`boardBoxEditor/${show_id}/…\`. Ask an agent to sync Firebase edits into \`${show_id}/boards\` (and bump \`BOARDS_MANIFEST_VERSION\`) before relying on CTR clicks/prices.
EOF

  shopt -s nullglob
  for f in "${boards_src}"/*; do
    [[ -f "$f" ]] || continue
    copy_with_retry "$f" "${dest}/boards/$(basename "$f")" \
      || die "Failed copying $(basename "$f") into BoardBoxEditor/${show_id}/boards"
  done
  shopt -u nullglob
  log "Board Box Editor ready: BoardBoxEditor/${show_id}/"
}

preflight_rfdetr() {
  if [[ ! -f "$DETECT_PY" ]]; then
    die "Missing detect script: $DETECT_PY"
  fi
  if [[ ! -d "${PIN_DIR}/.rfdetr_py39/bin" ]]; then
    die "Missing RF-DETR venv under ${PIN_DIR}/.rfdetr_py39 (run PinPricingStudyMVP_RFDETR_TEST setup)"
  fi
  if [[ ! -f "${PIN_DIR}/rfdetr_coreml_detector.py" ]]; then
    die "Missing rfdetr_coreml_detector.py in ${PIN_DIR}"
  fi
  # Smoke-test numpy in this process context (launchd often breaks iCloud .so mmap).
  if ! "${PIN_DIR}/.rfdetr_py39/bin/python" -c "import numpy" >/dev/null 2>&1; then
    if [[ "$PIN_DIR" != "$PIN_DIR_LOCAL" ]] && [[ -x "${PIN_DIR_LOCAL}/.rfdetr_py39/bin/python" ]]; then
      log "WARN: RF-DETR numpy failed at ${PIN_DIR}; falling back to ${PIN_DIR_LOCAL}"
      PIN_DIR="${PIN_DIR_LOCAL}"
    else
      die "RF-DETR numpy import failed under ${PIN_DIR} (iCloud mmap?). Re-run launchd/install_boards_inbox_launchagent.sh to refresh Application Support PinPricingStudyMVP_RFDETR_TEST."
    fi
  fi
  local model_path local_model
  local_model="${HOME}/Library/Application Support/FinsAndPins/models/RfDetrPinDetector.mlpackage"
  if [[ -n "${RFDETR_COREML_MODEL_PATH:-}" ]]; then
    model_path="${RFDETR_COREML_MODEL_PATH/#\~/$HOME}"
  elif [[ -d "$local_model" ]]; then
    model_path="$local_model"
    export RFDETR_COREML_MODEL_PATH="$local_model"
  else
    model_path="${HOME}/Desktop/ClickToCollectApp/ClickToCollect/ClickToCollect/RfDetrPinDetector.mlpackage"
  fi
  if [[ ! -e "$model_path" ]]; then
    die "RF-DETR Core ML model not found: ${model_path} (set RFDETR_COREML_MODEL_PATH to Application Support copy)"
  fi
  if [[ -d "$model_path" ]]; then
    local weight="${model_path}/Data/com.apple.CoreML/weights/weight.bin"
    local wsz
    wsz=$(stat -f %z "$weight" 2>/dev/null || echo 0)
    if [[ ! -f "$weight" ]] || [[ "$wsz" -lt 1000000 ]]; then
      die "RF-DETR model weight.bin missing/tiny at ${model_path} (avoid Desktop/iCloud under launchd)"
    fi
  fi
  log "RF-DETR PIN_DIR=${PIN_DIR}"
  log "RF-DETR model=${model_path}"
}

commit_and_push() {
  local show_id="$1"
  local promo_rel="${show_id}/collection-detection-app-square.png"
  cd "$CTR_REPO"
  if [[ ! -d .git ]]; then
    die "ClickToClaim repo has no .git at ${CTR_REPO}"
  fi

  if [[ -f "$UPDATE_INDEX_PY" ]] && command -v python3 >/dev/null 2>&1; then
    log "Updating shows_index.json"
    CTR_REPO_ROOT="$CTR_REPO" python3 "$UPDATE_INDEX_PY" 2>&1 | tee -a "$LOG_FILE" || log "WARN: update_shows_index.py failed"
  fi

  if [[ ! -f "$promo_rel" ]]; then
    die "Missing ${promo_rel} — refuse to publish show without Collection Detection promo icon"
  fi

  git add "${show_id}/"
  git add "$promo_rel"
  if [[ -d "BoardBoxEditor/${show_id}" ]]; then
    git add "BoardBoxEditor/${show_id}/"
  fi
  if [[ -f shows_index.json ]]; then
    git add shows_index.json
  fi

  local allowed_re="^(${show_id}/|BoardBoxEditor/${show_id}/|shows_index\.json\$)"
  local bad
  bad=$(git diff --cached --name-only | grep -Ev "$allowed_re" || true)
  if [[ -n "$bad" ]]; then
    log "ERROR: unrelated paths staged — aborting commit:"
    log "$bad"
    git reset HEAD
    die "Refusing broad staging in ClickToClaim repo"
  fi

  if git diff --cached --quiet; then
    die "Nothing staged to commit (unexpected after detect)"
  fi

  # ClickToClaim lives under iCloud; git commit can fail with
  # "could not open '.git/COMMIT_EDITMSG': Resource deadlock avoided".
  # Prefer -F with a message file outside iCloud; clear stale COMMIT_EDITMSG between tries.
  local commit_msg="Add ClickToClaim show ${show_id} (RF-DETR boards from ClickToRequest)."
  local msg_file
  msg_file="$(mktemp "${TMPDIR:-/tmp}/ctr_commit_msg.XXXXXX")"
  printf '%s\n' "$commit_msg" >"$msg_file"
  local attempt=1
  local max_attempts=12
  local commit_err=""
  local committed=0
  local sleep_sec=0
  while (( attempt <= max_attempts )); do
    rm -f .git/COMMIT_EDITMSG .git/index.lock 2>/dev/null || true
    if commit_err=$(git commit -F "$msg_file" 2>&1); then
      committed=1
      log "Committed on attempt ${attempt}."
      break
    fi
    if echo "$commit_err" | grep -qiE 'deadlock|Resource deadlock|COMMIT_EDITMSG'; then
      sleep_sec=$(( attempt * 5 ))
      if (( sleep_sec > 60 )); then sleep_sec=60; fi
      log "WARN: git commit hit iCloud/fs contention (attempt ${attempt}/${max_attempts}, sleep ${sleep_sec}s): ${commit_err}"
      sleep "$sleep_sec"
      attempt=$((attempt + 1))
      continue
    fi
    rm -f "$msg_file" 2>/dev/null || true
    log "ERROR: git commit failed: ${commit_err}"
    die "git commit failed"
  done
  rm -f "$msg_file" 2>/dev/null || true
  if (( committed != 1 )); then
    die_commit_pending "git commit failed after ${max_attempts} attempts (iCloud deadlock on .git). Boards are ready under ${show_id}/ — watcher will retry commit/push soon (or re-run prepare)."
  fi

  log "Committed. Pushing origin main…"
  attempt=1
  local push_err=""
  local pushed=0
  while (( attempt <= max_attempts )); do
    if push_err=$(git push origin main 2>&1); then
      pushed=1
      log "Push complete on attempt ${attempt}."
      break
    fi
    # Common when another machine/agent pushed while RF-DETR was running.
    if echo "$push_err" | grep -qiE 'non-fast-forward|fetch first|behind'; then
      log "WARN: push rejected (non-fast-forward). Pulling --rebase then retrying (attempt ${attempt}/${max_attempts})"
      if ! git pull --rebase origin main 2>&1 | tee -a "$LOG_FILE"; then
        log "ERROR: git pull --rebase failed after non-fast-forward push"
        die_commit_pending "git pull --rebase failed; resolve manually then push ${show_id}"
      fi
      attempt=$((attempt + 1))
      continue
    fi
    sleep_sec=$(( attempt * 5 ))
    if (( sleep_sec > 60 )); then sleep_sec=60; fi
    log "WARN: git push failed (attempt ${attempt}/${max_attempts}, sleep ${sleep_sec}s): ${push_err}"
    sleep "$sleep_sec"
    attempt=$((attempt + 1))
  done
  if (( pushed != 1 )); then
    die_commit_pending "git push failed after ${max_attempts} attempts. Commit is local — watcher will retry push, or push manually."
  fi
  log "Push complete."
}

# --- main ---

SHOW_ID="$(discover_input_show)"
# Prefer local mirror / CTR_INPUT_DIR for detection (avoid iCloud errno 11 mid RF-DETR).
if [[ -n "${CTR_INPUT_DIR:-}" ]] && [[ -d "${CTR_INPUT_DIR}" ]]; then
  INPUT_DIR="${CTR_INPUT_DIR}"
elif [[ -n "${CTR_MIRROR_DIR:-}" ]] && [[ -d "${CTR_MIRROR_DIR}/${SHOW_ID}" ]]; then
  INPUT_DIR="${CTR_MIRROR_DIR}/${SHOW_ID}"
else
  INPUT_DIR="${CTR_REQUEST_ROOT}/${SHOW_ID}"
fi
ICLOUD_INPUT_DIR="${CTR_REQUEST_ROOT}/${SHOW_ID}"
TARGET_DIR="${CTR_REPO}/${SHOW_ID}"
BOARDS_DIR="${TARGET_DIR}/boards"
LOG_FILE="${LOG_DIR}/${SHOW_ID}-ctr.log"

log "=== PrepareClickToClaim show ${SHOW_ID} ==="
log "Input:  ${INPUT_DIR}"
if [[ "$INPUT_DIR" != "$ICLOUD_INPUT_DIR" ]]; then
  log "iCloud drop zone: ${ICLOUD_INPUT_DIR}"
fi
log "Output: ${TARGET_DIR}"
log "Log:    ${LOG_FILE}"

if [[ ! -d "$INPUT_DIR" ]]; then
  die "Input folder missing: ${INPUT_DIR}"
fi

PHOTO_COUNT="$(count_input_photos "$INPUT_DIR")"
if [[ "$PHOTO_COUNT" -eq 0 ]]; then
  die "No board photos (.jpg/.jpeg/.png) in ${INPUT_DIR}"
fi
log "Found ${PHOTO_COUNT} input photo(s)"

LIVE_URL="${LIVE_BASE}/${SHOW_ID}/"
RECOVERY_COMMIT_ONLY=0
scrub_failed_bootstrap "$TARGET_DIR"
if has_board_outputs "$TARGET_DIR"; then
  if git -C "$CTR_REPO" cat-file -e "HEAD:${SHOW_ID}/boards/manifest.json" 2>/dev/null; then
    # Boards already published (e.g. manual commit/push after iCloud deadlock).
    # Clean leftover drop-zone folders and exit success so the watcher can mark processed.
    log "Show ${SHOW_ID} already on HEAD with board outputs — treating as success; cleaning leftover input"
    if [[ "${SKIP_DELETE:-0}" != "1" ]]; then
      if [[ -d "$INPUT_DIR" ]]; then
        log "Removing leftover input folder: ${INPUT_DIR}"
        rm -rf "$INPUT_DIR"
      fi
      local_icloud_drop="${CTR_REQUEST_ROOT}/${SHOW_ID}"
      if [[ -n "${CTR_MIRROR_DIR:-}" ]] && [[ -d "$local_icloud_drop" ]] && [[ "$INPUT_DIR" != "$local_icloud_drop" ]]; then
        log "Removing leftover iCloud ClickToRequest drop zone: ${local_icloud_drop}"
        rm -rf "$local_icloud_drop"
      elif [[ -d "$local_icloud_drop" ]] && [[ "$INPUT_DIR" == "$local_icloud_drop" ]]; then
        :
      elif [[ -d "$local_icloud_drop" ]]; then
        rm -rf "$local_icloud_drop"
      fi
    else
      log "SKIP_DELETE=1 — leaving input folders in place"
    fi
    log "=== Success (already published) ==="
    log "ClickToRequest for show ${SHOW_ID} is ready"
    log "Live site: ${LIVE_URL}"
    exit 0
  fi
  # Boards finished previously but commit/push failed (e.g. iCloud deadlock).
  log "Recovering: board outputs exist locally but ${SHOW_ID} is not on HEAD — commit/push only"
  RECOVERY_COMMIT_ONLY=1
fi

TEMPLATE_ID="$(find_highest_template_show)"
log "Template show: ${TEMPLATE_ID}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  if [[ "$RECOVERY_COMMIT_ONLY" == "1" ]]; then
    log "DRY_RUN=1 — would commit/push existing ${SHOW_ID}/ + shows_index.json (recovery)"
  else
    log "DRY_RUN=1 — would bootstrap from ${TEMPLATE_ID}, detect ${PHOTO_COUNT} photos, commit ${SHOW_ID}/ + shows_index.json"
  fi
  log "Live URL would be: ${LIVE_BASE}/${SHOW_ID}/"
  exit 0
fi

if [[ "$RECOVERY_COMMIT_ONLY" != "1" ]]; then
  preflight_rfdetr

  if ! show_bootstrap_complete "$TARGET_DIR"; then
    bootstrap_show "$TEMPLATE_ID" "$SHOW_ID"
  else
    log "Show folder exists without board outputs — finishing bootstrap assets and patching Firebase slug"
    copy_icons_with_retry "${CTR_REPO}/${TEMPLATE_ID}" "$TARGET_DIR" \
      || die "Failed copying icons while finishing incomplete bootstrap"
    ensure_collection_detection_promo_asset "$TARGET_DIR" "${CTR_REPO}/${TEMPLATE_ID}" \
      || die "Failed placing collection-detection-app-square.png"
    patch_show_html "$TARGET_DIR" "$SHOW_ID"
  fi

  mkdir -p "$BOARDS_DIR"

  log "Running RF-DETR detect (${PHOTO_COUNT} photos)…"
  python3 "$DETECT_PY" \
    --input-dir "$INPUT_DIR" \
    --output-dir "$BOARDS_DIR" \
    --pin-pricing-rfdetr-dir "$PIN_DIR" \
    --min-conf "${PIN_PRICING_RFDETR_MIN_CONF:-0.25}"

  log "Validating board outputs…"
  python3 "$VALIDATE_PY" --boards-dir "$BOARDS_DIR" --input-dir "$INPUT_DIR"

  bootstrap_board_box_editor "$SHOW_ID" "$TEMPLATE_ID"

  log "Boards ready. Live URL (after push): ${LIVE_URL}"
else
  log "Skipping detect (recovery). Live URL (after push): ${LIVE_URL}"
  # Recovery may still need the editor folder if boards exist but editor was never created.
  if [[ ! -d "${CTR_REPO}/BoardBoxEditor/${SHOW_ID}" ]]; then
    bootstrap_board_box_editor "$SHOW_ID" "$TEMPLATE_ID"
  fi
fi

if [[ "${SKIP_GIT:-0}" == "1" ]]; then
  ensure_collection_detection_promo_asset "$TARGET_DIR" "${CTR_REPO}/${TEMPLATE_ID}" || true
  log "SKIP_GIT=1 — skipping commit/push and input cleanup"
  log "Done (local only). Open after manual push: ${LIVE_URL}"
  exit 0
fi

ensure_collection_detection_promo_asset "$TARGET_DIR" "${CTR_REPO}/${TEMPLATE_ID}" \
  || die "collection-detection-app-square.png could not be placed in ${TARGET_DIR}"

commit_and_push "$SHOW_ID"

if [[ "${SKIP_DELETE:-0}" != "1" ]]; then
  log "Removing processed input folder: ${INPUT_DIR}"
  rm -rf "$INPUT_DIR"
  log "Deleted ${INPUT_DIR}"
  # Also clear the iCloud drop zone when we ran from the local mirror (otherwise the
  # watcher re-mirrors and can start a duplicate CTR run).
  local_icloud_drop="${CTR_REQUEST_ROOT}/${SHOW_ID}"
  if [[ -n "${CTR_MIRROR_DIR:-}" ]] && [[ -d "$local_icloud_drop" ]] && [[ "$INPUT_DIR" != "$local_icloud_drop" ]]; then
    log "Removing iCloud ClickToRequest drop zone: ${local_icloud_drop}"
    rm -rf "$local_icloud_drop"
    log "Deleted ${local_icloud_drop}"
  fi
else
  log "SKIP_DELETE=1 — leaving ${INPUT_DIR} in place"
fi

log "=== Success ==="
log "ClickToRequest for show ${SHOW_ID} is ready"
log "Live site: ${LIVE_URL}"
echo ""
echo "ClickToRequest for show ${SHOW_ID} is ready"
echo "Live site: ${LIVE_URL}"
echo "Log: ${LOG_FILE}"

exit 0
