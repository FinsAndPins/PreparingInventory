#!/usr/bin/env bash
# Run visual pricing + harness for CollectionToPrice2 then CollectionToPrice3 in PreparingInventory.
# Logs to _logs/pricing_background.log — safe to nohup this file.
#
# Usage:
#   cd "/path/to/PreparingInventory"
#   chmod +x run_lexi_pricing_background.sh
#   nohup ./run_lexi_pricing_background.sh >> _logs/pricing_background.log 2>&1 &
#   echo $!
#   tail -f _logs/pricing_background.log
#
set -euo pipefail

PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PIN="${PIN_PRICING_STUDY_MVP:-${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Cursor Projects/PinPricingStudyMVP}"
PY="${PIN}/.venv/bin/python"
PL="${PIN}/run_visual_baseline_pipeline.py"
mkdir -p "${PREP}/_logs"

if [[ ! -x "$PY" ]] || [[ ! -f "$PL" ]]; then
  echo "ERROR: PinPricingStudyMVP not found. Set PIN_PRICING_STUDY_MVP or install venv at:" >&2
  echo "  $PIN" >&2
  exit 1
fi

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
      echo "$(date -Iseconds) HEIC → $(basename "$out") (removed $(basename "$h"))"
    else
      echo "ERROR: could not convert HEIC/HEIF (need macOS sips): $h" >&2
      exit 1
    fi
  done
  shopt -u nullglob
}

run_one() {
  local COL="$1"
  local col_dir="${PREP}/${COL}"
  local stage="${col_dir}/_staged_boards"
  if [[ ! -d "$col_dir" ]]; then
    echo "ERROR: missing $col_dir" >&2
    exit 1
  fi

  heic_to_jpeg_in_dir "$col_dir"

  mkdir -p "$stage"
  rm -f "${stage}"/IMG_*.JPG 2>/dev/null || true
  local i=1
  shopt -s nullglob
  for p in "${col_dir}"/*.jpg "${col_dir}"/*.jpeg "${col_dir}"/*.JPG "${col_dir}"/*.JPEG; do
    [[ -f "$p" ]] || continue
    [[ "$(dirname "$p")" == "$col_dir" ]] || continue
    cp "$p" "${stage}/IMG_${i}.JPG"
    i=$((i + 1))
  done
  shopt -u nullglob
  local n=$((i - 1))
  echo "$(date -Iseconds) ${COL}: staged ${n} boards → ${stage}"
  if [[ "$n" -lt 1 ]]; then
    echo "ERROR: no board JPG/HEIC in top level of ${col_dir}" >&2
    exit 1
  fi

  rm -rf "${col_dir}/crops" "${col_dir}/roboflow" "${col_dir}/testing_ui_visual_baseline" 2>/dev/null || true
  rm -f "${col_dir}/candidates.json" "${col_dir}/run_timing.json" 2>/dev/null || true

  local tmp="${COL}__pricing_tmp_${RANDOM}"
  while [[ -e "${PREP}/${tmp}" ]]; do tmp="${COL}__pricing_tmp_${RANDOM}"; done

  echo "$(date -Iseconds) ${COL}: pipeline start run-id=${tmp}"
  ( cd "$PIN" && "$PY" "$PL" \
      --board-photos-dir "$stage" \
      --out-dir "$PREP" \
      --run-id "$tmp" \
      --pool-n "${POOL_N:-20}" \
      --gate-t "${GATE_T:-10}" \
      --build-harness --harness-firebase-collab )

  local src="${PREP}/${tmp}"
  local dst="$col_dir"
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
  echo "$(date -Iseconds) ${COL}: done → ${dst}/candidates.json"
}

run_one CollectionToPrice2
run_one CollectionToPrice3
echo "$(date -Iseconds) ALL DONE"
