# PreparingInventory

Static bundles for **GitHub Pages** (inventory / pricing / validation UIs). The repo root is the Pages site; **`.nojekyll`** is present so paths with underscores work.

## Lexi — all pricing collections (bookmark this)

One stable URL lists every **`PriceCollection_*`** folder that has a harness (**`testing_ui_visual_baseline/index.html`**), **newest first**:

- **Open:** [PreparingInventory index](https://finsandpins.github.io/PreparingInventory/) (root **`index.html`** loads **`pricing_index.json`**).

After each successful **`price_boards_from_inbox.sh`** run, the script runs **`update_pricing_index.py`** so **`pricing_index.json`** stays current when you commit and push.

## BoardsToPrice inbox (`RunBoardsPricing.command`)

Put board photos in **`BoardsToPrice/`** (repo root). **JPEG** and **HEIC/HEIF** (iPhone) in that folder’s **top level** are accepted: HEIC is converted to **`.JPG`** with **macOS `sips`**, then the HEIC file is removed, before Roboflow/eBay staging. The Python pipeline is unchanged.

### Lexi overnight: `board_inbox_watcher.sh` + iMessage + `launchd`

For **hands-off** runs when Steve is not at the machine: a long-lived watcher polls **`BoardsToPrice/`**, waits **`PRICE_INBOX_QUIET_SEC`** (default **120** seconds) with no file changes, then runs **`price_boards_from_inbox.sh`** under **`caffeinate -dimsu`** (best-effort wakefulness; **no guarantee** if the MacBook lid is closed without clamshell power).

**Queueing:** If Lexi uploads **while** a run is in progress, those files wait on disk. When the run finishes and the watcher **releases its lock**, it starts a **new** quiet window for whatever accumulated, so she does not need to coordinate interleaving.

**iMessage:** Copy **`LEXI_NOTIFY.example.env`** → **`LEXI_NOTIFY.env`** (gitignored). Set **`LEXI_IMESSAGE_HANDLE`** for a single recipient, or **`PRICING_NOTIFY_HANDLES`** with **space-separated** handles (Lexi and you each get the **same** three message templates). First run: grant **Automation** for **Messages** (and **Accessibility** if macOS prompts) for **Terminal** if you start the watcher manually, or for **`launchd`** after you load the plist below.

**Message text (everyone on the list gets the same body):** (1) **Start:** “Fins & Pins pricing: started on Steve's Mac (boards detected in BoardsToPrice). You'll get another message when the run finishes and has been pushed to GitHub.” (2) **Success:** “Fins & Pins pricing: finished and pushed to GitHub.” then a blank line, the harness URL line from the log (or a fallback line if missing), then a blank line and “The harness link often works within ~10-15 minutes on finsandpins.github.io.” (3) **Failure:** “Fins & Pins pricing: FAILED (automation exit *N*).” then guidance to re-upload later, then a line that you can check **`_logs/price_inbox_last.log`** when you are up.

**Install `launchd` (template):** Edit **`launchd/com.finsandpins.BoardsInboxWatcher.plist`** and replace **`FULL_PATH_TO_PREPARING_INVENTORY`** with the absolute path to this repo root (three occurrences: **WorkingDirectory** and both log paths). Copy to a stable location (for example **`~/Library/LaunchAgents/`**), then:

```bash
launchctl unload ~/Library/LaunchAgents/com.finsandpins.BoardsInboxWatcher.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.finsandpins.BoardsInboxWatcher.plist
```

Ensure **`board_inbox_watcher.sh`** is executable (`chmod +x board_inbox_watcher.sh`). Logs: **`_logs/boards_watcher.log`**, **`_logs/launchd_boards_watcher.log`**, **`_logs/launchd_boards_watcher.err.log`**.

**Stale lock:** If a run crashes hard and **`_logs/boards_watcher_active.lockdir`** is left behind with **no** pricing process running, remove that directory once (`rmdir _logs/boards_watcher_active.lockdir`) so the watcher can run again.

**Future / v2 ideas:** **`FUTURE.md`**.

## ClickToPrice — Show 2026-04-16 (shared harness)

- **Open:** [Show20260416/testing_ui_visual_baseline/index.html](https://finsandpins.github.io/PreparingInventory/Show20260416/testing_ui_visual_baseline/index.html)
- **What it is:** 34 boards, embedded payload plus **`assets/boards/`** for overlay images. Built from **`PinPricingStudyMVP/build_testing_ui.py`** with Firebase collaboration.
- **Rebuild:** Edit the template in **`Cursor Projects/PinPricingStudyMVP/build_testing_ui.py`**, run **`build_testing_ui.py --run-dir …`**, replace this folder, commit, push.

Older runs (for example **`20260411_133429/`**) remain for reference.

## RunBoardsPricing baseline (git tag)

The last **double-click inbox → Roboflow → eBay → Lexi harness** flow you verified is pinned in git as:

- **Tag:** `preparing-inventory-pricing-baseline-2026-04-26`
- **Recover only the launcher scripts** (from repo root, this folder):

```bash
git checkout preparing-inventory-pricing-baseline-2026-04-26 -- RunBoardsPricing.command price_boards_from_inbox.sh
```

That tag predates **HEIC inbox support**; use **`main`** for the current launcher, or merge the tag’s scripts with your tree if you need an older baseline plus HEIC.

- **Inspect a file without changing your tree:**

```bash
git show preparing-inventory-pricing-baseline-2026-04-26:RunBoardsPricing.command | less
```

- **List what the tag points at:** `git show preparing-inventory-pricing-baseline-2026-04-26 --stat`

Push the tag when you push this repo so others (and future you) can fetch it:

```bash
git push origin preparing-inventory-pricing-baseline-2026-04-26
```

## Large runs and GitHub

- GitHub **rejects any single file over ~100 MiB**. Big **`candidates.json`** / **`testing_ui_visual_baseline/index.html`** runs can **push-fail** even when total folder size is fine. Mitigations: **`build_testing_ui.py --split-bundle`**, chunking or compression strategies, iCloud share for the full folder, or keep giant artifacts out of git. See **`PinPricingStudyMVP/PIPELINE_DECISIONS.md`** (GitHub / checkpoint notes).

## Optional env (`price_boards_from_inbox.sh`)

See the header comment in **`price_boards_from_inbox.sh`** for **`POOL_N`**, **`GATE_T`**, **`SKIP_GIT`**, **`EBAY_*`**, and **`EBAY_CHECKPOINT_EVERY`** (periodic **`candidates.checkpoint.json`** during long eBay phases).

## Notes

- Session write-up (pipeline, pricing rules, layout, Pages lessons): **`PinPricingStudyMVP/STUDY_LEARNINGS_AND_NEXT_STEPS.md`** → **Session notes — 2026-04-16**.
