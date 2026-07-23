#!/usr/bin/env bash
# Installed under ~/Library/Application Support/ (not iCloud). launchd runs this file;
# it cannot execute scripts stored under Mobile Documents, so we run copies from LOCAL_WATCHER_BIN.
#
# Hybrid pricing layout (permanent):
#   Lexi upload  → iCloud PREP/BoardsToPrice (drop zone only)
#   Watcher pull → BOARD_INBOX_DIR (local mirror)
#   RF-DETR/eBay → PRICE_PIPELINE_WORK (local PricingWork)
#   API keys     → PIN_PRICING_KEYS_DIR (+ .backup)
#   Publish      → PRICE_PUBLISH_REPO → GitHub Pages (Lexi review)
set -euo pipefail
export PREP="FULL_PATH_TO_PREPARING_INVENTORY"
export LOCAL_WATCHER_BIN="FULL_PATH_TO_LOCAL_WATCHER_BIN"
export BOARD_INBOX_DIR="FULL_PATH_TO_BOARD_INBOX_DIR"
export PRICE_PIPELINE_WORK="${HOME}/Library/Application Support/FinsAndPins/PricingWork"
export PIN_PRICING_KEYS_DIR="${HOME}/Library/Application Support/FinsAndPins/keys"
export PRICE_PUBLISH_REPO="${HOME}/Library/Application Support/FinsAndPins/PreparingInventoryGit"
# Best-effort rsync of finished runs back into iCloud PREP (off by default — Pages is Lexi's UI).
export PRICE_MIRROR_ICLOUD_PREP=0
# Set to 1 to log inbox stats ~every 60s while troubleshooting.
export PRICE_INBOX_DEBUG=0
cd "${HOME}" || exit 1
exec /bin/bash "${LOCAL_WATCHER_BIN}/board_inbox_watcher.sh"
