#!/usr/bin/env bash
# Drop board JPGs into BoardsToPrice/, then run this (or double-click RunBoardsPricing.command).
# Renames inbox → PriceCollection_YYYYMMDD_HHMM, runs Roboflow + eBay + Lexi harness, recreates empty BoardsToPrice,
# then commits and pushes only the new collection + BoardsToPrice (aborts if other staged changes exist).
#
# Optional env:
#   PIN_PRICING_STUDY_MVP  — PinPricingStudyMVP path (default: iCloud Cursor Projects)
#   POOL_N, GATE_T        — passed to run_visual_baseline_pipeline.py
#   SKIP_GIT=1            — skip commit and push
#   eBay Browse resilience (optional overrides for run_visual_baseline_pipeline.py):
#     EBAY_BROWSE_MIN_INTERVAL_SEC  EBAY_LARGE_RUN_THRESHOLD  EBAY_LARGE_RUN_MIN_INTERVAL_SEC
#     EBAY_MAX_RETRIES  EBAY_BACKOFF_CAP_SEC  EBAY_CIRCUIT_429_THRESHOLD  EBAY_CIRCUIT_COOLDOWN_SEC
#     EBAY_NO_AUTO_LARGE_RUN=1  — disable auto pacing for large crop counts
#
set -euo pipefail
set +H

PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INBOX="${PREP}/BoardsToPrice"
PIN="${PIN_PRICING_STUDY_MVP:-${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Cursor Projects/PinPricingStudyMVP}"
PY="${PIN}/.venv/bin/python"
PL="${PIN}/run_visual_baseline_pipeline.py"
LOG_DIR="${PREP}/_logs"
LOG_FILE="${LOG_DIR}/price_inbox_last.log"

mkdir -p "$LOG_DIR" "$INBOX"

log() {
  local msg="[$(date -Iseconds)] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

if [[ ! -x "$PY" ]] || [[ ! -f "$PL" ]]; then
  log "ERROR: PinPricingStudyMVP not found. Set PIN_PRICING_STUDY_MVP. Expected: $PIN"
  exit 1
fi

shopt -s nullglob
board_count=0
for p in "${INBOX}"/*.jpg "${INBOX}"/*.jpeg "${INBOX}"/*.JPG "${INBOX}"/*.JPEG; do
  [[ -f "$p" ]] || continue
  [[ "$(dirname "$p")" == "$INBOX" ]] || continue
  board_count=$((board_count + 1))
done
shopt -u nullglob

if [[ "$board_count" -lt 1 ]]; then
  log "ERROR: Put at least one board photo (jpg/jpeg) in: $INBOX"
  exit 1
fi

base="PriceCollection_$(date +%Y%m%d_%H%M)"
NEWNAME="$base"
suffix=1
while [[ -e "${PREP}/${NEWNAME}" ]]; do
  NEWNAME="${base}_${suffix}"
  suffix=$((suffix + 1))
done

log "Renaming BoardsToPrice → ${NEWNAME} (${board_count} boards)"
mv "$INBOX" "${PREP}/${NEWNAME}"
mkdir -p "$INBOX"
touch "${INBOX}/.gitkeep"

COL_DIR="${PREP}/${NEWNAME}"
STAGE="${COL_DIR}/_staged_boards"
mkdir -p "$STAGE"
rm -f "${STAGE}"/IMG_*.JPG 2>/dev/null || true

i=1
shopt -s nullglob
for p in "${COL_DIR}"/*.jpg "${COL_DIR}"/*.jpeg "${COL_DIR}"/*.JPG "${COL_DIR}"/*.JPEG; do
  [[ -f "$p" ]] || continue
  [[ "$(dirname "$p")" == "$COL_DIR" ]] || continue
  cp "$p" "${STAGE}/IMG_${i}.JPG"
  i=$((i + 1))
done
shopt -u nullglob
staged=$((i - 1))
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

PAGES_URL="https://finsandpins.github.io/PreparingInventory/${NEWNAME}/testing_ui_visual_baseline/index.html"
cat > "${dst}/SHARE_LEXI_URL.txt" << EOF
Lexi harness (GitHub Pages):
${PAGES_URL}

Open this file after push; Pages can take a minute to refresh.
EOF
log "Wrote ${dst}/SHARE_LEXI_URL.txt"
log "Harness: ${PAGES_URL}"

if [[ "${SKIP_GIT:-0}" == "1" ]]; then
  log "SKIP_GIT=1 — not committing. Run: cd \"$PREP\" && git add \"$NEWNAME\" BoardsToPrice && git commit && git push"
  exit 0
fi

cd "$PREP"
if [[ ! -d .git ]]; then
  log "No .git here — skipping commit/push."
  exit 0
fi

git add "$NEWNAME" BoardsToPrice

BAD=$(git diff --cached --name-only | grep -Ev "^(BoardsToPrice/|${NEWNAME}/)" || true)
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
