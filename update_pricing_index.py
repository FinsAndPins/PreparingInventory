#!/usr/bin/env python3
"""
Regenerate pricing_index.json for the GitHub Pages Lexi index (root index.html).

Only lists PriceCollection_* folders that are in the git index (tracked or staged)
and that still have testing_ui_visual_baseline/index.html on disk. This avoids
linking collections that were untracked for retention while kept locally.

Run from repo root:
  python3 update_pricing_index.py

Or set PREP_REPO_ROOT to the PreparingInventory repo root.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
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


def git_indexed_collections(root: Path) -> set[str]:
    """Top-level PriceCollection_* dirs present in the git index (tracked or staged)."""
    try:
        out = subprocess.check_output(
            ["git", "-C", str(root), "ls-files", "--", "PriceCollection_*/testing_ui_visual_baseline/index.html"],
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return set()
    names: set[str] = set()
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        top = line.split("/", 1)[0]
        if NAME_RE.match(top):
            names.add(top)
    return names


def main() -> int:
    root = Path(os.environ.get("PREP_REPO_ROOT", Path(__file__).resolve().parent))
    indexed = git_indexed_collections(root)
    # Fall back to disk scan only when not in a git checkout (manual/offline use).
    if not indexed and not (root / ".git").exists():
        indexed = {
            p.name
            for p in root.glob("PriceCollection_*")
            if p.is_dir() and NAME_RE.match(p.name)
        }

    rows: list[dict[str, str]] = []
    for folder in sorted(indexed, reverse=True):
        harness = root / folder / "testing_ui_visual_baseline" / "index.html"
        if not harness.is_file():
            continue
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
