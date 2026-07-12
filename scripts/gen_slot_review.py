#!/usr/bin/env python3
"""Generate nts_review.html — Slot Review for matched pins at slot > 0 only.

Loads Firebase export (match_status + selected_candidate_idx) and includes only
pins where the user matched a non-slot-0 candidate. Excludes no_match, not_a_pin,
unreviewed, and matches at slot 0.
"""
from __future__ import annotations

import json
import pathlib
import sys

SCRIPTS = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))


def _load_firebase_pins(run_folder: pathlib.Path, export_path: pathlib.Path | None) -> dict:
    """Return pin_key → Firebase entry from an export file."""
    candidates: list[pathlib.Path] = []
    if export_path:
        candidates.append(export_path)
    run_name = run_folder.name
    downloads = pathlib.Path.home() / "Downloads"
    candidates.extend(sorted(downloads.glob(f"*_{run_name}__*_export*.json"), reverse=True))
    candidates.extend(sorted(downloads.glob(f"*_{run_name}*_export*.json"), reverse=True))

    for path in candidates:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"  WARN: could not read {path.name}: {exc}")
            continue
        for approach in data.values():
            if isinstance(approach, dict) and isinstance(approach.get("pins"), dict):
                by_pk = {}
                for entry in approach["pins"].values():
                    pk = entry.get("pin_key")
                    if pk:
                        by_pk[pk] = entry
                if by_pk:
                    print(f"  Firebase export: {path.name} ({len(by_pk)} pins)")
                    return by_pk
    print("  WARN: no Firebase export found — slot review queue will be empty")
    return {}


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <PriceCollection_dir> [firebase_export.json]", file=sys.stderr)
        sys.exit(1)

    import generate_review_pages_enhanced as g

    run_folder = pathlib.Path(sys.argv[1]).expanduser().resolve()
    export_path = pathlib.Path(sys.argv[2]).expanduser().resolve() if len(sys.argv) > 2 else None
    ui_dir = run_folder / "testing_ui_visual_baseline"
    ui_reranked = ui_dir / "ui_data_reranked.json"
    ui_orig = ui_dir / "ui_data.json"
    ui_path = ui_reranked if ui_reranked.exists() else ui_orig
    idx_path = ui_dir / "index.html"
    scores_path = run_folder / "dinov2_scores.json"

    data = json.loads(ui_path.read_text(encoding="utf-8"))
    firebase_cfg, test_run_id, approach_id = g._extract_firebase(idx_path)

    scores: dict = {}
    if scores_path.exists():
        for r in json.loads(scores_path.read_text(encoding="utf-8")):
            scores[r["pin_key"]] = r

    pins = g._build_pins(data, scores)
    for p in pins:
        p["auto_slot"] = p.get("best_slot")
        p["auto_sim"] = p.get("best_sim")

    fb_pins_by_pk = _load_firebase_pins(run_folder, export_path)
    for p in pins:
        fb = fb_pins_by_pk.get(p["pk"])
        if fb and fb.get("match_status"):
            p["ms"] = fb["match_status"]

    g._embed_thumbnails(pins, run_folder / "crops")
    ctx = {"fb": firebase_cfg, "tri": test_run_id, "api": approach_id, "rn": run_folder.name}
    g._gen_nts_review(pins, ctx, ui_dir, fb_pins_by_pk=fb_pins_by_pk)
    nts_count = len(g._slot_review_queue(pins, fb_pins_by_pk))
    print(f"Slot review queue: {nts_count} pins (matched at slot > 0)")


if __name__ == "__main__":
    main()
