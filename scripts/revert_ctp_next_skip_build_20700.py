#!/usr/bin/env python3
"""Revert pins wrongly flipped no_match→match by CTP v2 Next-skip (build_20700).

Compare a baseline export (before bug, typically export-3) vs a later export.
Restores baseline no_match pin rows in test RTDB for PriceCollection_20260712_1423.

Usage:
  python3 revert_ctp_next_skip_build_20700.py --dry-run
  python3 revert_ctp_next_skip_build_20700.py --apply
  python3 revert_ctp_next_skip_build_20700.py --current export-5.json --apply
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

EXPORT_DIR = Path("/Users/steve/Downloads")
EXPORT_PREFIX = (
    "fins-and-pins-click-to-claim-default-rtdb-test_PriceCollection_20260712_1423"
    "__build_20700_visual_baseline"
)
DEFAULT_BASELINE = EXPORT_DIR / f"{EXPORT_PREFIX}-export-3.json"
DEFAULT_CURRENT = EXPORT_DIR / f"{EXPORT_PREFIX}-export-4.json"

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


def find_flipped_pins(baseline: dict, current: dict) -> list[tuple[str, dict, dict]]:
    pins_base = baseline.get("visual_baseline", {}).get("pins", {})
    pins_cur = current.get("visual_baseline", {}).get("pins", {})
    flipped = []
    for pk, v_base in pins_base.items():
        if v_base.get("match_status") != "no_match":
            continue
        v_cur = pins_cur.get(pk)
        if v_cur and v_cur.get("match_status") not in (None, "no_match"):
            flipped.append((pk, v_base, v_cur))
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


def resolve_export(path_arg: str | None, default: Path) -> Path:
    if not path_arg:
        return default
    p = Path(path_arg).expanduser()
    if p.is_file():
        return p
    candidate = EXPORT_DIR / f"{EXPORT_PREFIX}-{path_arg}"
    if candidate.is_file():
        return candidate
    candidate = EXPORT_DIR / path_arg
    if candidate.is_file():
        return candidate
    raise FileNotFoundError(path_arg)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Write patches to test RTDB")
    parser.add_argument("--dry-run", action="store_true", help="Print patches only (default)")
    parser.add_argument(
        "--baseline",
        metavar="PATH",
        help="Baseline export JSON (default: export-3 in Downloads)",
    )
    parser.add_argument(
        "--current",
        metavar="PATH",
        help="Current export JSON to diff against baseline (default: export-4)",
    )
    args = parser.parse_args()
    apply = args.apply and not args.dry_run
    if not args.apply and not args.dry_run:
        args.dry_run = True

    try:
        baseline_path = resolve_export(args.baseline, DEFAULT_BASELINE)
        current_path = resolve_export(args.current, DEFAULT_CURRENT)
    except FileNotFoundError as e:
        print(f"ERROR: export file not found: {e}")
        return 1

    with baseline_path.open() as f:
        baseline = json.load(f)
    with current_path.open() as f:
        current = json.load(f)

    flipped = find_flipped_pins(baseline, current)
    print(
        f"Pins to revert (no_match in {baseline_path.name}, "
        f"non-no_match in {current_path.name}): {len(flipped)}"
    )
    if not flipped:
        return 0

    for pk, v_base, v_cur in flipped:
        patch = build_revert_patch(v_base)
        path = rtdb_path(pk)
        print(f"\n{pk}")
        print(
            f"  board={v_cur.get('board_num')} pin_n={v_cur.get('pin_n')} "
            f"wrong_status={v_cur.get('match_status')} wrong_price={v_cur.get('display_price')}"
        )
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
