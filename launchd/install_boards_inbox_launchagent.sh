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

cp -f "${PREP}/board_inbox_watcher.sh" "${PREP}/price_boards_from_inbox.sh" "${PREP}/lexi_send_imessage.py" "$BIN/"
chmod +x "${BIN}/board_inbox_watcher.sh" "${BIN}/price_boards_from_inbox.sh" "${BIN}/lexi_send_imessage.py"
/usr/bin/rsync -a --delete "${PREP}/BoardsToPrice/" "${BOARD_INBOX}/" 2>/dev/null || true
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
echo "Re-run this script after changing board_inbox_watcher.sh, price_boards_from_inbox.sh, or lexi_send_imessage.py."
