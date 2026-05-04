# Future ideas — PreparingInventory / pricing

Exploratory backlog. Not committed to a ship date.

---

## Multiple collections in one overnight drop (v2)

**Today:** `BoardsToPrice/` is a **single flat inbox** → one `PriceCollection_*` per successful `price_boards_from_inbox.sh` run. Lexi can still send several collections back‑to‑back: uploads that arrive **while a run is in progress** land in the **next** empty inbox and are picked up automatically after the first run finishes (see `board_inbox_watcher.sh`).

**Future:** Support **several labeled subfolders** inside `BoardsToPrice` (or parallel drop folders), each becoming its **own** `PriceCollection_*` without waiting between uploads. Needs new discovery rules, ordering, and git staging semantics.

---

## Public “sell us your collection” flow (much later)

**Sketch:** A small website where sellers upload collection photos, your pipeline produces an **estimate**, you generate a **shipping label** to you, and they enter **Venmo / PayPal** so you can pay them.

**Constraints called out early:** minimize **retention of their photos** (privacy, liability, storage cost). Likely needs explicit **TTL deletion**, optional **client-side processing**, or **ephemeral processing** with no long‑term blob store—design TBD before any build.

---

## Run PinPricingStudyMVP from a non-iCloud working copy (ops hardening)

**Context (2026-05-03):** Under **`Mobile Documents/…/CloudDocs/`**, **`prediction_dedupe.py`** and **`ebay_api.py`** briefly existed on disk as **truncated or older** versions while the pipeline scripts expected newer APIs — runs failed with **`ImportError`** / **`AttributeError`** even though the editor sometimes showed the full file. iCloud sync, conflict copies, or interrupted writes are the usual suspects.

**Idea:** Keep the canonical repo under iCloud for Cursor, but **run overnight pricing** against a **local-disk clone** (or a second git worktree on **`~/Projects/…`**) updated with **`git pull`**, with **`PIN_PRICING_STUDY_MVP`** pointing there in **`price_boards_from_inbox.sh`** / env. Reduces “disk ≠ editor” risk for the Python tree the watcher executes.

---

_Add new bullets here as ideas come up._
