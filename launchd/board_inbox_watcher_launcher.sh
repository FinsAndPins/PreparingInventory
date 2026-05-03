#!/usr/bin/env bash
# Installed under ~/Library/Application Support/ (not iCloud). launchd runs this file;
# it cannot execute scripts stored under Mobile Documents, so we run copies from LOCAL_WATCHER_BIN.
set -euo pipefail
export PREP="FULL_PATH_TO_PREPARING_INVENTORY"
export LOCAL_WATCHER_BIN="FULL_PATH_TO_LOCAL_WATCHER_BIN"
export BOARD_INBOX_DIR="FULL_PATH_TO_BOARD_INBOX_DIR"
# Set to 1 to log inbox stats ~every 60s while troubleshooting.
export PRICE_INBOX_DEBUG=0
cd "${HOME}" || exit 1
exec /bin/bash "${LOCAL_WATCHER_BIN}/board_inbox_watcher.sh"
