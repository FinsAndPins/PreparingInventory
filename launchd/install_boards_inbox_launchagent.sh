#!/usr/bin/env bash
# Install LaunchAgent for board_inbox_watcher when the repo lives under iCloud (Mobile Documents).
# Copies helper scripts to ~/Library/Application Support/ so launchd can execute them.
set -euo pipefail
set +H

PREP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
BIN="${HOME}/Library/Application Support/FinsAndPins/PreparingInventoryWatcherBin"
BOARD_INBOX="${HOME}/Library/Application Support/FinsAndPins/PreparingInventoryBoardsInbox"
LAUNCHER="${HOME}/Library/Application Support/FinsAndPins/board_inbox_watcher_launcher.sh"
AGENT="${HOME}/Library/LaunchAgents/com.finsandpins.BoardsInboxWatcher.plist"

mkdir -p "${PREP}/_logs" "${BIN}/_logs" "${BOARD_INBOX}" "$(dirname "$LAUNCHER")"

PIN_LOCAL="${HOME}/Library/Application Support/FinsAndPins/PinPricingStudyMVP_RFDETR_TEST"
PIN_SRC="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Cursor Projects/PinPricingStudyMVP_RFDETR_TEST"
if [[ -d "$PIN_SRC" ]]; then
  echo "Syncing PinPricingStudyMVP_RFDETR_TEST to Application Support (launchd-safe, no iCloud .venv)…"
  mkdir -p "$PIN_LOCAL"
  /usr/bin/rsync -a \
    --exclude '.git/' \
    --exclude '.venv/' \
    --exclude '__pycache__/' \
    --exclude '.pytest_cache/' \
    --exclude 'crops/' \
    --exclude 'roboflow/' \
    "$PIN_SRC/" "$PIN_LOCAL/" \
    || echo "WARN: PinPricing code rsync failed — re-run install after iCloud sync completes."
  _pin_local_venv_ready() {
    [[ -x "${PIN_LOCAL}/.venv/bin/python" ]] \
      && "${PIN_LOCAL}/.venv/bin/python" -c "import imagehash; from PIL import Image" >/dev/null 2>&1
  }
  if ! _pin_local_venv_ready; then
    echo "Building launchd-safe .venv from iCloud pip freeze (ditto .venv often leaves broken Pillow stubs)…"
    rm -rf "${PIN_LOCAL}/.venv"
    if [[ -x "${PIN_SRC}/.venv/bin/pip" ]]; then
      python3 -m venv "${PIN_LOCAL}/.venv"
      "${PIN_SRC}/.venv/bin/pip" freeze >"${PIN_LOCAL}/_venv_freeze.txt"
      "${PIN_LOCAL}/.venv/bin/pip" install --upgrade pip wheel
      "${PIN_LOCAL}/.venv/bin/pip" install -r "${PIN_LOCAL}/_venv_freeze.txt" \
        || echo "WARN: pip install from freeze failed — launchd pipeline may exit on import errors."
      if _pin_local_venv_ready; then
        echo "Local .venv bootstrapped from iCloud pip freeze."
      else
        echo "WARN: local .venv still not import-ready after pip freeze — re-run install after iCloud sync."
      fi
    else
      echo "WARN: iCloud PinPricing .venv missing — open PinPricing in Finder to download, then re-run install."
    fi
  else
    echo "Local .venv ready under Application Support."
  fi
else
  echo "WARN: PinPricing source not found at: $PIN_SRC"
fi

cp -f "${PREP}/board_inbox_watcher.sh" "${PREP}/price_boards_from_inbox.sh" "${PREP}/lexi_send_imessage.py" "$BIN/"
if [[ -f "${PREP}/patch_harness_ctp_scroll.py" ]]; then
  cp -f "${PREP}/patch_harness_ctp_scroll.py" "$BIN/"
fi
chmod +x "${BIN}/board_inbox_watcher.sh" "${BIN}/price_boards_from_inbox.sh" "${BIN}/lexi_send_imessage.py"
# Do not use --delete here: if iCloud BoardsToPrice is unreadable, rsync could treat the
# source as empty and wipe the mirror. The watcher pulls without --delete as well.
echo "Seeding mirror from BoardsToPrice (rsync -a, no --delete)…"
/usr/bin/rsync -a "${PREP}/BoardsToPrice/" "${BOARD_INBOX}/" || echo "WARN: seed rsync failed (iCloud busy or permissions). The watcher will retry each poll."
if [[ -f "${PREP}/LEXI_NOTIFY.env" ]]; then
  cp -f "${PREP}/LEXI_NOTIFY.env" "$BIN/"
  echo "Copied LEXI_NOTIFY.env to watcher bin (launchd cannot read env from iCloud)."
fi

sed -e "s|FULL_PATH_TO_PREPARING_INVENTORY|${PREP}|g" \
    -e "s|FULL_PATH_TO_LOCAL_WATCHER_BIN|${BIN}|g" \
    -e "s|FULL_PATH_TO_BOARD_INBOX_DIR|${BOARD_INBOX}|g" \
  "${PREP}/launchd/board_inbox_watcher_launcher.sh" > "$LAUNCHER"
chmod +x "$LAUNCHER"

sed -e "s|FULL_PATH_TO_PREPARING_INVENTORY|${PREP}|g" \
    -e "s|FULL_PATH_TO_LOCAL_WATCHER_BIN|${BIN}|g" \
    -e "s|FULL_PATH_TO_USER_HOME|${HOME}|g" \
    -e "s|FULL_PATH_TO_LAUNCHER_SCRIPT|${LAUNCHER}|g" \
  "${PREP}/launchd/com.finsandpins.BoardsInboxWatcher.plist" > "$AGENT"

plutil -lint "$AGENT"

launchctl bootout "gui/$(id -u)/com.finsandpins.BoardsInboxWatcher" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl kickstart -k "gui/$(id -u)/com.finsandpins.BoardsInboxWatcher"

echo "Installed."
echo "  Bin copies: $BIN"
echo "  Launcher:   $LAUNCHER"
echo "  Agent plist: $AGENT"
echo "Re-run this script after changing board_inbox_watcher.sh, price_boards_from_inbox.sh, patch_harness_ctp_scroll.py, or lexi_send_imessage.py."
