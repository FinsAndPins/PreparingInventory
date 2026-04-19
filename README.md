# PreparingInventory

Static bundles for **GitHub Pages** (inventory / pricing / validation UIs). The repo root is the Pages site; **`.nojekyll`** is present so paths with underscores work.

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
