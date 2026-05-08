#!/bin/bash
# Double-click in Finder to price boards from BoardsToPrice/ and push to GitHub.
# Uses the Roboflow API for pin detection (original pipeline).
# Automatic inbox watcher uses RF-DETR instead — see board_inbox_watcher.sh / run_price_pipeline.
# For RF-DETR manually: RunBoardsPricing_RFDETR.command
# First run: System Settings → Privacy & Security → allow Terminal/scripts if macOS asks.
#
# Lexi harness (PinPricingStudyMVP/build_testing_ui.py): whole-dollar eBay list prices, no show/Whatnot ladder
# on stored values. Pin overlay badges omit “$”; global (top-left) and per-board (top-right) totals include “$”.

set +H
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO" || exit 1

# Explicit Roboflow path (same defaults as price_boards_from_inbox.sh before watcher switched automatic runs to RF-DETR).
export PIN_PRICING_USE_RFDETR=0
export PIN_PRICING_STUDY_MVP="${PIN_PRICING_STUDY_MVP:-${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Cursor Projects/PinPricingStudyMVP}"

chmod +x ./price_boards_from_inbox.sh 2>/dev/null || true
./price_boards_from_inbox.sh

echo ""
echo "If something failed, check: $REPO/_logs/price_inbox_last.log"
echo "Press Return to close this window."
read -r _
