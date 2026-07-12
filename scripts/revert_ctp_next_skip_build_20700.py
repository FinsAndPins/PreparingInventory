#!/usr/bin/env python3
"""Revert pins wrongly flipped no_match→match by CTP v2 Next-skip (build_20700).

Compare export-3 (before bug) vs export-4 (after). Restores export-3 pin rows in
test RTDB for PriceCollection_20260712_1423 / visual_baseline.

Usage:
  python3 revert_ctp_next_skip_build_20700.py --dry-run
  python3 revert_ctp_next_skip_build_20700.py --apply
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

TEST_RUN_ID = "test_PriceCollection_20260712_1423__build_20700_visual_baseline"
APPROACH_ID = "visual_baseline"
DB_BASE = "https://fins-and-pins-click-to-claim-default-rtdb.firebaseio.com"

EXPORT_3 = Path(
    "/Users/steve/Downloads/"
    "fins-and-pins-click-to-claim-default-rtdb-test_PriceCollection_20260712_1423"
    "__build_20700_visual_baseline-export-3.json"
)
EXPORT_4 = Path(
    "/Users/steve/Downloads/"
    "fins-and-pins-click-to-claim-default-rtdb-test_PriceCollection_20260712_1423"
    "__build_20700_visual_baseline-export-4.json"
)

FIELDS_TO_CLEAR = (
    "display_price",
    "selected_candidate",
    "selected_candidate_idx",
    "listing_title",
    "ladder_preserve_zero",
    "board_num",
    "crop_filename",
    "pin_n",
)


def rtdb_key(pin_key: str) -> str:
    return pin_key.replace("/", "_").replace(".", "_").replace(" ", "_")


def rtdb_path(pin_key: str) -> str:
    safe = "".join(c if c.isalnum() or c in "_-" else "_" for c in pin_key)
    return f"pin_pricing_tests/{TEST_RUN_ID}/{APPROACH_ID}/pins/{safe}"


def find_flipped_pins(export3: dict, export4: dict) -> list[tuple[str, dict, dict]]:
    pins3 = export3.get("visual_baseline", {}).get("pins", {})
    pins4 = export4.get("visual_baseline", {}).get("pins", {})
    flipped = []
    for pk, v3 in pins3.items():
        if v3.get("match_status") != "no_match":
            continue
        v4 = pins4.get(pk)
        if v4 and v4.get("match_status") != "no_match":
            flipped.append((pk, v3, v4))
    return flipped


def build_revert_patch(export3_row: dict) -> dict:
    """Restore export-3 no_match row; null out pricing fields added by Next-skip."""
    patch = {
        "pin_key": export3_row.get("pin_key"),
        "match_status": "no_match",
    }
    for field in ("matched_at", "reviewed_by"):
        if field in export3_row:
            patch[field] = export3_row[field]
    for field in FIELDS_TO_CLEAR:
        patch[field] = None
    return patch


def patch_rtdb(path: str, body: dict) -> None:
    url = f"{DB_BASE}/{path}.json"
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, method="PATCH", headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status >= 400:
            raise RuntimeError(f"PATCH {path} failed: HTTP {resp.status}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Write patches to test RTDB")
    parser.add_argument("--dry-run", action="store_true", help="Print patches only (default)")
    args = parser.parse_args()
    apply = args.apply and not args.dry_run
    if not args.apply and not args.dry_run:
        args.dry_run = True

    if not EXPORT_3.is_file() or not EXPORT_4.is_file():
        print("ERROR: export-3 and export-4 JSON files must exist at expected Downloads paths.")
        return 1

    with EXPORT_3.open() as f:
        export3 = json.load(f)
    with EXPORT_4.open() as f:
        export4 = json.load(f)

    flipped = find_flipped_pins(export3, export4)
    print(f"Pins to revert (no_match in export-3, match in export-4): {len(flipped)}")
    if not flipped:
        return 0

    for pk, v3, v4 in flipped:
        patch = build_revert_patch(v3)
        path = rtdb_path(pk)
        print(f"\n{pk}")
        print(f"  board={v4.get('board_num')} pin_n={v4.get('pin_n')} wrong_price={v4.get('display_price')}")
        print(f"  RTDB: {path}")
        if apply:
            patch_rtdb(path, patch)
            print("  -> PATCHED")
        else:
            print(f"  patch: {json.dumps(patch, indent=2)}")

    if not apply:
        print("\nDry run only. Re-run with --apply to write to test RTDB.")
    else:
        print(f"\nApplied {len(flipped)} reverts to test RTDB.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
