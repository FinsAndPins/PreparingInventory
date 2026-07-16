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
#   PIN_PRICING_RFDETR_DIR — RF-DETR venv root (PinPricingStudyMVP_RFDETR_TEST)
#   RFDETR_COREML_MODEL_PATH — Core ML model .mlpackage override
#   PIN_PRICING_RFDETR_MIN_CONF — min confidence (default 0.25)
#
set -euo pipefail
set +H

PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CTR_REQUEST_ROOT="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/ClickToRequest"
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
  local best=""
  local best_num=0
  local name d num
  shopt -s nullglob
  for d in "${CTR_REPO}"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    is_yyyymmdd "$name" || continue
    [[ -f "${d}index.html" ]] || continue
    num=$((10#$name))
    if (( num > best_num )); then
      best_num=$num
      best="$name"
    fi
  done
  shopt -u nullglob
  if [[ -z "$best" ]]; then
    die "No dated show template with index.html found under ${CTR_REPO}/"
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

count_input_photos() {
  find "$1" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l | tr -d ' '
}

ensure_collection_detection_promo_asset() {
  local target_dir="$1"
  local template_dir="${2:-}"
  local dest="${target_dir}/collection-detection-app-square.png"
  local src=""
  if [[ -f "${CTR_REPO}/_show_static/collection-detection-app-square.png" ]]; then
    src="${CTR_REPO}/_show_static/collection-detection-app-square.png"
  elif [[ -n "$template_dir" && -f "${template_dir}/collection-detection-app-square.png" ]]; then
    src="${template_dir}/collection-detection-app-square.png"
  elif [[ -f "$dest" ]]; then
    return 0
  fi
  if [[ -z "$src" ]]; then
    log "WARN: collection-detection-app-square.png missing (no _show_static or template source)"
    return 1
  fi
  cp -f "$src" "$dest"
  log "Ensured collection-detection-app-square.png in show folder"
}

bootstrap_show() {
  local template_id="$1"
  local show_id="$2"
  local template_dir="${CTR_REPO}/${template_id}"
  local target_dir="${CTR_REPO}/${show_id}"

  log "Bootstrapping ${show_id} from template ${template_id}"
  mkdir -p "${target_dir}/icons"
  cp "${template_dir}/index.html" "${target_dir}/"
  cp "${template_dir}/reports.html" "${target_dir}/"
  if [[ -d "${template_dir}/icons" ]]; then
    rsync -a "${template_dir}/icons/" "${target_dir}/icons/"
  fi
  ensure_collection_detection_promo_asset "$target_dir" "$template_dir"
  python3 "$PATCH_PY" "$target_dir" "$show_id"
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
  local model_path
  model_path="${RFDETR_COREML_MODEL_PATH:-${HOME}/Desktop/ClickToCollectApp/ClickToCollect/ClickToCollect/RfDetrPinDetector.mlpackage}"
  model_path="${model_path/#\~/$HOME}"
  if [[ ! -e "$model_path" ]]; then
    die "RF-DETR Core ML model not found: ${model_path} (set RFDETR_COREML_MODEL_PATH)"
  fi
  log "RF-DETR PIN_DIR=${PIN_DIR}"
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
  if [[ -f shows_index.json ]]; then
    git add shows_index.json
  fi

  local allowed_re="^(${show_id}/|shows_index\.json\$)"
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

  git commit -m "Add ClickToClaim show ${show_id} (RF-DETR boards from ClickToRequest)."
  log "Committed. Pushing origin main…"
  git push origin main
  log "Push complete."
}

# --- main ---

SHOW_ID="$(discover_input_show)"
INPUT_DIR="${CTR_REQUEST_ROOT}/${SHOW_ID}"
TARGET_DIR="${CTR_REPO}/${SHOW_ID}"
BOARDS_DIR="${TARGET_DIR}/boards"
LOG_FILE="${LOG_DIR}/${SHOW_ID}-ctr.log"

log "=== PrepareClickToClaim show ${SHOW_ID} ==="
log "Input:  ${INPUT_DIR}"
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

if has_board_outputs "$TARGET_DIR"; then
  die "Refusing to overwrite existing board outputs in ${BOARDS_DIR}"
fi

TEMPLATE_ID="$(find_highest_template_show)"
log "Template show: ${TEMPLATE_ID}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  log "DRY_RUN=1 — would bootstrap from ${TEMPLATE_ID}, detect ${PHOTO_COUNT} photos, commit ${SHOW_ID}/ + shows_index.json"
  log "Live URL would be: ${LIVE_BASE}/${SHOW_ID}/"
  exit 0
fi

preflight_rfdetr

if [[ ! -f "${TARGET_DIR}/index.html" ]] || [[ ! -f "${TARGET_DIR}/reports.html" ]]; then
  bootstrap_show "$TEMPLATE_ID" "$SHOW_ID"
else
  log "Show folder exists without board outputs — patching Firebase slug and ensuring promo asset"
  ensure_collection_detection_promo_asset "$TARGET_DIR" "${CTR_REPO}/${TEMPLATE_ID}"
  python3 "$PATCH_PY" "$TARGET_DIR" "$SHOW_ID"
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

LIVE_URL="${LIVE_BASE}/${SHOW_ID}/"
log "Boards ready. Live URL (after push): ${LIVE_URL}"

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
