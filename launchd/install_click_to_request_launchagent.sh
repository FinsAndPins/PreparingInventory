#!/usr/bin/env bash
# Install LaunchAgent for watch_click_to_request when the repo lives under iCloud (Mobile Documents).
# Copies helper scripts to ~/Library/Application Support/ so launchd can execute them.
set -euo pipefail
set +H

PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
BIN="${HOME}/Library/Application Support/FinsAndPins/ClickToRequestWatcherBin"
CTR_MIRROR="${HOME}/Library/Application Support/FinsAndPins/ClickToRequestMirror"
CTR_REQUEST="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/ClickToRequest"
LAUNCHER="${HOME}/Library/Application Support/FinsAndPins/click_to_request_watcher_launcher.sh"
AGENT="${HOME}/Library/LaunchAgents/com.finsandpins.ClickToRequestWatcher.plist"

mkdir -p "${PREP}/_logs" "${BIN}/_logs" "${CTR_MIRROR}" "$(dirname "$LAUNCHER")" "${CTR_REQUEST}"

# Local-disk publish clone for CTR git commit/push (mirrors PreparingInventoryGit for pricing).
CTR_PUBLISH="${HOME}/Library/Application Support/FinsAndPins/ClickToClaimGit"
if [[ ! -d "${CTR_PUBLISH}/.git" ]]; then
  echo "Cloning ClickToClaim into local publish repo (avoids iCloud .git deadlock)…"
  mkdir -p "$(dirname "$CTR_PUBLISH")"
  git clone https://github.com/FinsAndPins/ClickToClaim.git "$CTR_PUBLISH"
else
  echo "Publish clone OK: $CTR_PUBLISH"
  git -C "$CTR_PUBLISH" fetch origin main >/dev/null 2>&1 || true
  git -C "$CTR_PUBLISH" pull --ff-only origin main >/dev/null 2>&1 || true
fi

CTR_SCRIPTS=(
  watch_click_to_request.sh
  prepare_click_to_claim.sh
  detect_boards_rfdetr_for_ctr.py
  validate_ctr_boards.py
  patch_ctr_show_slug.py
  wire_ctr_pricing_overlay.sh
  lexi_send_imessage.py
)

for f in "${CTR_SCRIPTS[@]}"; do
  if [[ ! -f "${PREP}/${f}" ]]; then
    echo "ERROR: missing ${PREP}/${f}"
    exit 1
  fi
  cp -f "${PREP}/${f}" "$BIN/"
done
chmod +x "${BIN}/watch_click_to_request.sh" "${BIN}/prepare_click_to_claim.sh" "${BIN}/lexi_send_imessage.py"

# Local (non-iCloud) promo asset cache — prepare prefers this over CloudDocs _show_static.
PROMO_SRC=""
CTR_REPO_DEFAULT="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/GitHub Repository/ClickToClaim"
if [[ -s "${CTR_REPO_DEFAULT}/_show_static/collection-detection-app-square.png" ]]; then
  PROMO_SRC="${CTR_REPO_DEFAULT}/_show_static/collection-detection-app-square.png"
elif [[ -s "${CTR_REPO_DEFAULT}/20260806/collection-detection-app-square.png" ]]; then
  PROMO_SRC="${CTR_REPO_DEFAULT}/20260806/collection-detection-app-square.png"
elif [[ -s "${CTR_REPO_DEFAULT}/20260730/collection-detection-app-square.png" ]]; then
  PROMO_SRC="${CTR_REPO_DEFAULT}/20260730/collection-detection-app-square.png"
elif [[ -s "${CTR_REPO_DEFAULT}/20260728/collection-detection-app-square.png" ]]; then
  PROMO_SRC="${CTR_REPO_DEFAULT}/20260728/collection-detection-app-square.png"
fi
if [[ -n "$PROMO_SRC" ]]; then
  cp -f "$PROMO_SRC" "${BIN}/collection-detection-app-square.png"
  echo "Cached collection-detection-app-square.png in watcher bin (avoids iCloud copy deadlocks)."
fi

if [[ -f "${PREP}/LEXI_NOTIFY.env" ]]; then
  cp -f "${PREP}/LEXI_NOTIFY.env" "$BIN/"
  echo "Copied LEXI_NOTIFY.env to watcher bin (launchd cannot read env from iCloud)."
fi

sed -e "s|FULL_PATH_TO_PREPARING_INVENTORY|${PREP}|g" \
    -e "s|FULL_PATH_TO_LOCAL_CTR_WATCHER_BIN|${BIN}|g" \
    -e "s|FULL_PATH_TO_CTR_MIRROR_DIR|${CTR_MIRROR}|g" \
    -e "s|FULL_PATH_TO_CTR_REQUEST_ROOT|${CTR_REQUEST}|g" \
  "${PREP}/launchd/click_to_request_watcher_launcher.sh" > "$LAUNCHER"
chmod +x "$LAUNCHER"

sed -e "s|FULL_PATH_TO_LOCAL_CTR_WATCHER_BIN|${BIN}|g" \
    -e "s|FULL_PATH_TO_USER_HOME|${HOME}|g" \
    -e "s|FULL_PATH_TO_LAUNCHER_SCRIPT|${LAUNCHER}|g" \
  "${PREP}/launchd/com.finsandpins.ClickToRequestWatcher.plist" > "$AGENT"

plutil -lint "$AGENT"

launchctl bootout "gui/$(id -u)/com.finsandpins.ClickToRequestWatcher" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl kickstart -k "gui/$(id -u)/com.finsandpins.ClickToRequestWatcher"

echo "Installed ClickToRequest watcher."
echo "  Bin copies:     $BIN"
echo "  Publish clone:  $CTR_PUBLISH  (git commit/push; not iCloud)"
echo "  iCloud mirror:  $CTR_MIRROR  (poll copy of ClickToRequest/YYYYMMDD/)"
echo "  iCloud inbox:   $CTR_REQUEST  (drop photos here)"
echo "  Launcher:       $LAUNCHER"
echo "  Agent plist:    $AGENT"
echo "  Watcher log:    ${BIN}/_logs/ctr_watcher.log"
echo "  Pipeline logs:  ~/Library/Logs/show-automation/{YYYYMMDD}-ctr.log"
echo ""
echo "Re-run this script after changing watch_click_to_request.sh, prepare_click_to_claim.sh, or CTR helper scripts."
echo "Reload only: launchctl kickstart -k \"gui/\$(id -u)/com.finsandpins.ClickToRequestWatcher\""
echo "Uninstall:     bash \"${PREP}/launchd/uninstall_click_to_request_launchagent.sh\""
