#!/usr/bin/env bash
# Installed under ~/Library/Application Support/ (not iCloud). launchd runs this file;
# it cannot execute scripts stored under Mobile Documents, so we run copies from LOCAL_CTR_WATCHER_BIN.
set -euo pipefail
export PREP="FULL_PATH_TO_PREPARING_INVENTORY"
export LOCAL_CTR_WATCHER_BIN="FULL_PATH_TO_LOCAL_CTR_WATCHER_BIN"
export CTR_MIRROR_DIR="FULL_PATH_TO_CTR_MIRROR_DIR"
export CTR_REQUEST_ROOT="FULL_PATH_TO_CTR_REQUEST_ROOT"
# Local-disk ClickToClaim clone for git commit/push (avoids iCloud .git deadlock).
export CTR_PUBLISH_REPO="${CTR_PUBLISH_REPO:-${HOME}/Library/Application Support/FinsAndPins/ClickToClaimGit}"
# Pin bootstrap template (never 2026D23 / special folders). 20260910 = verified CTR chrome
# (no fuel/B-N limits UI, green-only visitor clicks, Connected sync, lite nudge).
export CTR_TEMPLATE_ID="${CTR_TEMPLATE_ID:-20260910}"
# Local Core ML model — Desktop/iCloud hits errno 11 under launchd.
export RFDETR_COREML_MODEL_PATH="${RFDETR_COREML_MODEL_PATH:-${HOME}/Library/Application Support/FinsAndPins/models/RfDetrPinDetector.mlpackage}"
# Set to 1 to log scan stats ~every 60s while troubleshooting.
export CTR_WATCHER_DEBUG=0
cd "${HOME}" || exit 1
exec /bin/bash "${LOCAL_CTR_WATCHER_BIN}/watch_click_to_request.sh"
