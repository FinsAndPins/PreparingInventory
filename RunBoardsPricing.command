#!/bin/bash
# Double-click in Finder to price boards from BoardsToPrice/ and push to GitHub.
# First run: System Settings → Privacy & Security → allow Terminal/scripts if macOS asks.
#
# Lexi harness (PinPricingStudyMVP/build_testing_ui.py): whole-dollar eBay list prices, no show/Whatnot ladder
# on stored values. Pin overlay badges omit “$”; global (top-left) and per-board (top-right) totals include “$”.

set +H
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO" || exit 1

chmod +x ./price_boards_from_inbox.sh 2>/dev/null || true
./price_boards_from_inbox.sh

echo ""
echo "If something failed, check: $REPO/_logs/price_inbox_last.log"
echo "Press Return to close this window."
read -r _
