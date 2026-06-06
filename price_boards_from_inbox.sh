#!/usr/bin/env bash
# Drop board photos into BoardsToPrice/ (JPEG, PNG, WebP, TIFF, or HEIC), then run this (or double-click RunBoardsPricing.command).
# HEIC/HEIF in the inbox top level are converted to .JPG with macOS sips, then originals are removed.
# Renames inbox → PriceCollection_YYYYMMDD_HHMM, runs pin detection + eBay + Lexi harness, recreates empty inbox,
# then commits and pushes only the new collection + BoardsToPrice (aborts if other staged changes exist).
# When BOARD_INBOX_DIR (mirror) is used, canonical iCloud BoardsToPrice still holds duplicate uploads until we clear it here.
#
# Optional env:
#   PIN_PRICING_STUDY_MVP  — PinPricingStudyMVP path (default: iCloud Cursor Projects → PinPricingStudyMVP)
#   PIN_PRICING_USE_RFDETR — set 1 with PinPricingStudyMVP_RFDETR_TEST for local RF-DETR (Core ML).
#                            Board inbox watcher sets this to 1 by default; RunBoardsPricing.command sets 0 (Roboflow API).
#   POOL_N, GATE_T        — passed to run_visual_baseline_pipeline.py
#   SKIP_GIT=1            — skip commit and push
#   eBay Browse resilience (optional overrides for run_visual_baseline_pipeline.py):
#     EBAY_BROWSE_MIN_INTERVAL_SEC  EBAY_LARGE_RUN_THRESHOLD  EBAY_LARGE_RUN_MIN_INTERVAL_SEC
#     EBAY_MAX_RETRIES  EBAY_BACKOFF_CAP_SEC  EBAY_CIRCUIT_429_THRESHOLD  EBAY_CIRCUIT_COOLDOWN_SEC
#     EBAY_NO_AUTO_LARGE_RUN=1  — disable auto pacing for large crop counts
#   EBAY_CHECKPOINT_EVERY  — write candidates.checkpoint.json every N crops (default 50; 0=off)
#   BOARD_INBOX_DIR      — optional absolute path to local mirror inbox (launchd); default is ${PREP}/BoardsToPrice
#                        — after a successful pipeline, canonical ${PREP}/BoardsToPrice/ is cleared of board images
#                          so iCloud drop zone is empty for the next Lexi upload.
#
set -euo pipefail
set +H

# Parent may set PREP (e.g. board_inbox_watcher runs this as bash -s < file for iCloud + launchd).
if [[ -n "${PREP:-}" ]] && [[ -d "${PREP}" ]]; then
  :
else
  PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi
# LaunchAgent sets BOARD_INBOX_DIR to a local mirror; rsync into iCloud BoardsToPrice is often blocked.
INBOX="${BOARD_INBOX_DIR:-${PREP}/BoardsToPrice}"
PIN="${PIN_PRICING_STUDY_MVP:-${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Cursor Projects/PinPricingStudyMVP}"
PY="${PIN}/.venv/bin/python"
PL="${PIN}/run_visual_baseline_pipeline.py"
# launchd + osascript often cannot append logs under iCloud; watcher sets PRICE_LOG_DIR to local _logs.
LOG_DIR="${PRICE_LOG_DIR:-${PREP}/_logs}"
LOG_FILE="${LOG_DIR}/price_inbox_last.log"

mkdir -p "$LOG_DIR" "$INBOX"
if [[ "$INBOX" != "${PREP}/BoardsToPrice" ]]; then
  mkdir -p "${PREP}/BoardsToPrice"
fi

log() {
  local msg="[$(date -Iseconds)] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

# Remove board photos from canonical iCloud BoardsToPrice (Lexi drop zone). Mirror mode copies into
# BOARD_INBOX_DIR first, so these files are duplicates once the collection exists — clear so the next wave is obvious.
clear_canonical_boards_to_price_drop_zone() {
  local btp="${PREP}/BoardsToPrice"
  [[ -d "$btp" ]] || return 0
  find "$btp" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.JPG' -o -iname '*.JPEG' \
    -o -iname '*.png' -o -iname '*.PNG' \
    -o -iname '*.heic' -o -iname '*.HEIC' -o -iname '*.heif' -o -iname '*.HEIF' \
    -o -iname '*.webp' -o -iname '*.WEBP' \
    -o -iname '*.tif' -o -iname '*.TIF' -o -iname '*.tiff' -o -iname '*.TIFF' \) \
    ! -name '.gitkeep' -delete 2>/dev/null || true
  rm -f "${btp}/.DS_Store" 2>/dev/null || true
  mkdir -p "$btp"
  touch "${btp}/.gitkeep"
}

if [[ ! -x "$PY" ]] || [[ ! -f "$PL" ]]; then
  log "ERROR: PinPricingStudyMVP not found. Set PIN_PRICING_STUDY_MVP. Expected: $PIN"
  exit 1
fi

# Convert iPhone HEIC/HEIF in inbox root → JPEG (pipeline expects JPG in _staged_boards).
heic_to_jpeg_in_dir() {
  local dir="$1"
  local h out base
  shopt -s nullglob
  for h in "${dir}"/*.heic "${dir}"/*.HEIC "${dir}"/*.heif "${dir}"/*.HEIF; do
    [[ -f "$h" ]] || continue
    [[ "$(dirname "$h")" == "$dir" ]] || continue
    base="${h%.*}"
    out="${base}.JPG"
    if [[ -f "$out" ]]; then
      out="${base}_from_heic.JPG"
    fi
    if command -v sips >/dev/null 2>&1 && sips -s format jpeg "$h" --out "$out" >/dev/null 2>&1; then
      rm -f "$h"
      log "Converted HEIC → $(basename "$out") (removed $(basename "$h"))"
    else
      log "ERROR: could not convert HEIC/HEIF (need macOS sips): $h"
      exit 1
    fi
  done
  shopt -u nullglob
}

heic_to_jpeg_in_dir "$INBOX"

board_count=0
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  board_count=$((board_count + 1))
done < <(
  find "$INBOX" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
    -o -iname '*.heic' -o -iname '*.heif' \
    -o -iname '*.webp' -o -iname '*.tif' -o -iname '*.tiff' \) \
    ! -name '.gitkeep' ! -name '.DS_Store' 2>/dev/null | LC_ALL=C sort
)

if [[ "$board_count" -lt 1 ]]; then
  log "ERROR: Put at least one board photo (jpg/jpeg/png/webp/tiff/heic) in: $INBOX"
  exit 1
fi

base="PriceCollection_$(date +%Y%m%d_%H%M)"
NEWNAME="$base"
suffix=1
while [[ -e "${PREP}/${NEWNAME}" ]]; do
  NEWNAME="${base}_${suffix}"
  suffix=$((suffix + 1))
done

log "Renaming inbox → ${NEWNAME} (${board_count} boards) [inbox=${INBOX}]"
mv "$INBOX" "${PREP}/${NEWNAME}"
mkdir -p "$INBOX"
touch "${INBOX}/.gitkeep"
if [[ "$INBOX" != "${PREP}/BoardsToPrice" ]]; then
  mkdir -p "${PREP}/BoardsToPrice"
  touch "${PREP}/BoardsToPrice/.gitkeep"
fi

COL_DIR="${PREP}/${NEWNAME}"
STAGE="${COL_DIR}/_staged_boards"
mkdir -p "$STAGE"
rm -f "${STAGE}"/IMG_*.* 2>/dev/null || true

heic_to_jpeg_in_dir "$COL_DIR"

i=1
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  [[ -f "$p" ]] || continue
  ext_lower=$(echo "${p##*.}" | tr '[:upper:]' '[:lower:]')
  case "$ext_lower" in
    jpg|jpeg) cp "$p" "${STAGE}/IMG_${i}.JPG" ;;
    png) cp "$p" "${STAGE}/IMG_${i}.PNG" ;;
    webp) cp "$p" "${STAGE}/IMG_${i}.WEBP" ;;
    tif|tiff) cp "$p" "${STAGE}/IMG_${i}.TIF" ;;
    *)
      log "WARN: skipping unsupported extension in collection dir: $p"
      continue
      ;;
  esac
  i=$((i + 1))
done < <(
  find "$COL_DIR" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
    -o -iname '*.heic' -o -iname '*.heif' \
    -o -iname '*.webp' -o -iname '*.tif' -o -iname '*.tiff' \) \
    ! -name '.gitkeep' ! -name '.DS_Store' 2>/dev/null | LC_ALL=C sort
)
staged=$((i - 1))
if [[ "${staged:-0}" -lt 1 ]]; then
  log "ERROR: No board photos were staged to ${STAGE} (supported: jpg/jpeg/png/webp/tif/tiff/heic→jpg)."
  exit 1
fi
log "Staged ${staged} boards → ${STAGE}"

rm -rf "${COL_DIR}/crops" "${COL_DIR}/roboflow" "${COL_DIR}/testing_ui_visual_baseline" 2>/dev/null || true
rm -f "${COL_DIR}/candidates.json" "${COL_DIR}/run_timing.json" 2>/dev/null || true

tmp="${NEWNAME}__build_${RANDOM}"
while [[ -e "${PREP}/${tmp}" ]]; do tmp="${NEWNAME}__build_${RANDOM}"; done

log "Pipeline start run-id=${tmp}"
(
  cd "$PIN" && "$PY" "$PL" \
    --board-photos-dir "$STAGE" \
    --out-dir "$PREP" \
    --run-id "$tmp" \
    --pool-n "${POOL_N:-20}" \
    --gate-t "${GATE_T:-10}" \
    --ebay-checkpoint-every "${EBAY_CHECKPOINT_EVERY:-50}" \
    --build-harness --harness-firebase-collab
)

src="${PREP}/${tmp}"
dst="$COL_DIR"
for d in crops roboflow testing_ui_visual_baseline; do
  rm -rf "${dst}/${d}" 2>/dev/null || true
  if [[ -d "${src}/${d}" ]]; then
    mv "${src}/${d}" "${dst}/"
  fi
done
for f in candidates.json run_timing.json; do
  rm -f "${dst}/${f}" 2>/dev/null || true
  if [[ -f "${src}/${f}" ]]; then
    mv "${src}/${f}" "${dst}/"
  fi
done
rm -rf "$src"

if [[ ! -f "${dst}/candidates.json" ]] || [[ ! -f "${dst}/testing_ui_visual_baseline/index.html" ]]; then
  log "ERROR: pipeline did not produce candidates.json + harness. Restore BoardsToPrice manually from ${NEWNAME} if needed."
  exit 1
fi

if [[ -f "${PREP}/patch_harness_ctp_scroll.py" ]] && command -v python3 >/dev/null 2>&1; then
  python3 "${PREP}/patch_harness_ctp_scroll.py" "${dst}/testing_ui_visual_baseline" 2>&1 | tee -a "$LOG_FILE" \
    || log "WARN: patch_harness_ctp_scroll.py failed — ClickToPrice list may jump to top after Use this"
fi

PAGES_URL="https://finsandpins.github.io/PreparingInventory/${NEWNAME}/testing_ui_visual_baseline/index.html"
cat > "${dst}/SHARE_LEXI_URL.txt" << EOF
Lexi harness (GitHub Pages):
${PAGES_URL}

Open this file after push; Pages can take a minute to refresh.
EOF
log "Wrote ${dst}/SHARE_LEXI_URL.txt"
log "Harness: ${PAGES_URL}"

if [[ -n "${BOARD_INBOX_DIR:-}" ]]; then
  log "Clearing canonical BoardsToPrice (${PREP}/BoardsToPrice) after successful pipeline (mirror inbox — remove duplicate iCloud copies)."
  clear_canonical_boards_to_price_drop_zone
fi

if [[ "${SKIP_GIT:-0}" == "1" ]]; then
  log "SKIP_GIT=1 — not committing. After a successful run: cd \"$PREP\" && PREP_REPO_ROOT=\"$PREP\" python3 update_pricing_index.py && git add \"$NEWNAME\" BoardsToPrice pricing_index.json index.html update_pricing_index.py && git commit && git push"
  exit 0
fi

cd "$PREP"
if [[ ! -d .git ]]; then
  log "No .git here — skipping commit/push."
  exit 0
fi

if [[ -f "${PREP}/update_pricing_index.py" ]] && command -v python3 >/dev/null 2>&1; then
  PREP_REPO_ROOT="$PREP" python3 "${PREP}/update_pricing_index.py" 2>&1 | tee -a "$LOG_FILE" || log "WARN: update_pricing_index.py failed — Lexi landing page list may be stale"
else
  log "WARN: python3 or update_pricing_index.py missing — skipping pricing_index.json refresh"
fi

# Retention policy: keep recent PriceCollection runs on GitHub Pages (untrack older, keep on disk).
# Defaults: keep 30 days, keep at least 10 newest, prune tracked __build__ dirs immediately.
if [[ -f "${PREP}/prune_github_retention.py" ]] && command -v python3 >/dev/null 2>&1; then
  log "Retention prune (GitHub Pages): keep_days=${RETENTION_KEEP_DAYS:-30} keep_min=${RETENTION_KEEP_MIN:-10}"
  python3 "${PREP}/prune_github_retention.py" \
    --keep-days "${RETENTION_KEEP_DAYS:-30}" \
    --keep-min "${RETENTION_KEEP_MIN:-10}" \
    2>&1 | tee -a "$LOG_FILE" || log "WARN: retention prune failed — continuing without pruning"
else
  log "WARN: prune_github_retention.py missing or python3 unavailable — skipping retention prune"
fi

git add "$NEWNAME" BoardsToPrice
for f in pricing_index.json index.html update_pricing_index.py; do
  [[ -f "$f" ]] && git add "$f"
done

# Allow any path under BoardsToPrice/ or the new collection; exact root files only for the rest.
# (A trailing $ on the whole alternation wrongly required lines to be exactly "Collection/", so
# every real file looked "unrelated" and the commit always aborted.)
BAD=$(git diff --cached --name-only | grep -Ev "^(BoardsToPrice/|${NEWNAME}/|pricing_index\.json\$|index\.html\$|update_pricing_index\.py\$|price_boards_from_inbox\.sh\$|RunBoardsPricing\.command\$|run_lexi_pricing_background\.sh\$|board_inbox_watcher\.sh\$|lexi_send_imessage\.py\$|launchd/)" || true)
if [[ -n "$BAD" ]]; then
  log "ERROR: unrelated paths are staged. Aborting commit. Staged:"
  log "$BAD"
  git reset HEAD
  exit 1
fi

if git diff --cached --quiet; then
  log "Nothing staged to commit (unexpected)."
  exit 1
fi

git commit -m "Add pricing run ${NEWNAME} (boards from BoardsToPrice inbox)."
log "Committed. Pushing origin main…"
git push origin main
log "Done. Push complete."

exit 0
