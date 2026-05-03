#!/usr/bin/env python3
"""
Regenerate pricing_index.json for the GitHub Pages Lexi index (root index.html).

Scans sibling folders PriceCollection_* that contain testing_ui_visual_baseline/index.html,
sorted newest-first by embedded date in the folder name.

Run from repo root:
  python3 update_pricing_index.py

Or set PREP_REPO_ROOT to the PreparingInventory repo root.
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

BASE_URL = "https://finsandpins.github.io/PreparingInventory"
NAME_RE = re.compile(r"^PriceCollection_(\d{8})_(\d{4})$")


def format_label(folder: str) -> str:
    m = NAME_RE.match(folder)
    if not m:
        return folder
    day = datetime.strptime(m.group(1), "%Y%m%d")
    hhmm = m.group(2)
    h, mi = int(hhmm[:2]), int(hhmm[2:])
    return f"{day.strftime('%b')} {day.day}, {day.year} · {h:02d}:{mi:02d}"


def main() -> int:
    root = Path(os.environ.get("PREP_REPO_ROOT", Path(__file__).resolve().parent))
    rows: list[dict[str, str]] = []
    for p in sorted(root.glob("PriceCollection_*"), key=lambda x: x.name, reverse=True):
        if not p.is_dir():
            continue
        harness = p / "testing_ui_visual_baseline" / "index.html"
        if not harness.is_file():
            continue
        folder = p.name
        rows.append(
            {
                "folder": folder,
                "label": format_label(folder),
                "sort_key": folder.replace("PriceCollection_", "", 1),
                "harness_url": f"{BASE_URL}/{folder}/testing_ui_visual_baseline/index.html",
            }
        )

    payload = {
        "collections": rows,
        "updated_iso": datetime.now().astimezone().isoformat(timespec="seconds"),
        "base_url": BASE_URL,
    }
    out = root / "pricing_index.json"
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {out} ({len(rows)} PriceCollection folders with harness)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
