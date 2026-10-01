#!/usr/bin/env python3
"""
Sidecar: regenerate pricing_runs_index.json for Lexi's pricing runs table.

Discovers successful published PriceCollection_* runs (git-tracked harness on disk),
pulls live pin prices from Firebase RTDB, and writes a light JSON index.

Does NOT touch BoardsToPrice / CollectionsToPrice watchers, price_boards_from_inbox,
inbox LaunchAgents, or PinPricingStudyMVP pipeline entrypoints.

Run from PreparingInventory repo root:
  python3 update_pricing_runs_index.py

Or:
  PREP_REPO_ROOT=/path/to/PreparingInventory python3 update_pricing_runs_index.py
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

BASE_URL = "https://finsandpins.github.io/PreparingInventory"
FB_PINS_URL = (
    "https://fins-and-pins-click-to-claim-default-rtdb.firebaseio.com"
    "/pin_pricing_tests/{run_id}/{approach}/pins.json"
)
FOLDER_RE = re.compile(r"^PriceCollection_(\d{8})_(\d{4,6})(?:__(.+))?$")
OVERLAY_URL_RE = re.compile(
    r"https://finsandpins\.github\.io/PreparingInventory/"
    r"PriceCollection_[^\s]+/testing_ui_visual_baseline/index\.html"
)
GENERIC_NAMES = {
    "untitled",
    "untitled_folder",
    "untitled folder",
    "folder",
    "new_folder",
    "new folder",
    "tmp",
    "temp",
    "test",
}


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def git_tracked_harness_folders(root: Path) -> set[str]:
    try:
        out = subprocess.check_output(
            [
                "git",
                "-C",
                str(root),
                "ls-files",
                "--",
                "PriceCollection_*/testing_ui_visual_baseline/index.html",
            ],
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
        if FOLDER_RE.match(top):
            names.add(top)
    return names


def parse_run_dt(folder: str) -> datetime | None:
    m = FOLDER_RE.match(folder)
    if not m:
        return None
    day = m.group(1)
    tod = m.group(2)
    if len(tod) == 4:
        fmt = "%Y%m%d%H%M"
        stamp = day + tod
    elif len(tod) == 6:
        fmt = "%Y%m%d%H%M%S"
        stamp = day + tod
    else:
        return None
    try:
        # Folder stamps are local Eastern wall time in practice; treat as naive local.
        return datetime.strptime(stamp, fmt)
    except ValueError:
        return None


def timestamp_label(folder: str) -> str:
    """BoardsToPrice / no-person fallback: always YYYYMMDD_HHMM."""
    m = FOLDER_RE.match(folder)
    if not m:
        return folder
    day, tod = m.group(1), m.group(2)
    hhmm = (tod + "0000")[:4]
    return f"{day}_{hhmm}"

def humanize_name(raw: str) -> str:
    s = (raw or "").strip()
    if not s:
        return ""
    # Prefer spaces already present; else underscores → spaces.
    if "_" in s and " " not in s:
        s = s.replace("_", " ")
    return re.sub(r"\s+", " ", s).strip()


def is_generic_name(name: str) -> bool:
    key = humanize_name(name).lower()
    return (not key) or key in GENERIC_NAMES


def folder_label(root: Path, folder: str) -> str:
    named_path = root / folder / "NAMED_FOLDER_ORIGINAL.txt"
    original = humanize_name(_read_text(named_path))
    if original and not is_generic_name(original):
        return original

    m = FOLDER_RE.match(folder)
    slug = humanize_name(m.group(3) if m and m.group(3) else "")
    if slug and not is_generic_name(slug):
        return slug

    return timestamp_label(folder)


def overlay_url(root: Path, folder: str) -> str:
    share = _read_text(root / folder / "SHARE_LEXI_URL.txt")
    if share:
        # Prefer explicit Overlay: URL block when present.
        lines = share.splitlines()
        for i, line in enumerate(lines):
            if line.strip().lower().startswith("overlay"):
                for nxt in lines[i + 1 : i + 4]:
                    m = OVERLAY_URL_RE.search(nxt)
                    if m:
                        return m.group(0)
        # Any Overlay index.html URL in the file.
        m = OVERLAY_URL_RE.search(share)
        if m:
            return m.group(0)
    return f"{BASE_URL}/{folder}/testing_ui_visual_baseline/index.html"


def first_board_thumb_url(folder: str, ui: dict[str, Any] | None) -> str | None:
    """Public Pages URL for the first board photo in the pricing harness."""
    if not isinstance(ui, dict):
        return None
    boards = ui.get("boards")
    if not isinstance(boards, list) or not boards:
        return None
    image_rel = boards[0].get("image_rel") if isinstance(boards[0], dict) else None
    if not image_rel or not isinstance(image_rel, str):
        return None
    rel = image_rel.strip().lstrip("./")
    if not rel:
        return None
    return f"{BASE_URL}/{folder}/testing_ui_visual_baseline/{rel}"


def load_ui_meta(root: Path, folder: str) -> tuple[str | None, str, str | None]:
    path = root / folder / "testing_ui_visual_baseline" / "ui_data.json"
    if not path.is_file():
        return None, "visual_baseline", None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None, "visual_baseline", None
    if not isinstance(data, dict):
        return None, "visual_baseline", None
    run_id = data.get("test_run_id")
    approach = str(data.get("approach_id") or "visual_baseline")
    thumb = first_board_thumb_url(folder, data)
    return (str(run_id) if run_id else None), approach, thumb


def fetch_pins(run_id: str, approach: str) -> dict[str, Any] | None:
    url = FB_PINS_URL.format(run_id=run_id, approach=approach)
    try:
        with urllib.request.urlopen(url, timeout=90) as resp:
            raw = resp.read().decode("utf-8")
    except (urllib.error.URLError, TimeoutError, ValueError):
        return None
    if not raw or raw == "null":
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else {}


def _positive_float(val: Any) -> float | None:
    if val is None:
        return None
    try:
        n = float(val)
    except (TypeError, ValueError):
        return None
    if n > 0 and n == n:  # finite-ish; reject NaN
        return n
    return None


def pin_included_price(pin: Any) -> float | None:
    """
    Include pins with a real price:
      CTM Match, OR CTP clicked listing (priced), OR manual price.
    Exclude NaP.
    Exclude CTM no-match with no CTP click and no manual price.
    """
    if not isinstance(pin, dict):
        return None
    if pin.get("not_a_pin") is True or pin.get("match_status") == "not_a_pin":
        return None

    status = str(pin.get("match_status") or "").strip().lower()
    display = _positive_float(pin.get("display_price"))
    manual = _positive_float(pin.get("manual_price"))

    sc = pin.get("selected_candidate")
    sc_price = None
    if isinstance(sc, dict):
        sc_price = _positive_float(sc.get("price", sc.get("total_price")))

    # CTM Match or CTP/manual "priced" with display_price.
    if status in ("match", "priced") and display is not None:
        return display

    # Explicit manual price even if status is odd.
    if manual is not None:
        return manual

    # Selected listing price without status yet.
    if isinstance(sc, dict) and display is not None:
        return display
    if sc_price is not None:
        return sc_price

    return None


def summarize_pins(pins: dict[str, Any] | None) -> dict[str, Any]:
    if pins is None:
        return {
            "value_usd": None,
            "pin_count": None,
            "per_pin_usd": None,
            "half_value_usd": None,
            "pct_complete": None,
            "pins_total": None,
            "pins_match": None,
            "pins_priced": None,
            "pins_nap": None,
            "price_source": "firebase_error",
        }
    prices: list[float] = []
    pins_total = 0
    pins_match = 0
    pins_priced = 0
    pins_nap = 0
    for pin in pins.values():
        if not isinstance(pin, dict):
            continue
        pins_total += 1
        status = str(pin.get("match_status") or "").strip().lower()
        is_nap = pin.get("not_a_pin") is True or status == "not_a_pin"
        if is_nap:
            pins_nap += 1
        elif status == "match":
            pins_match += 1
        elif status == "priced":
            pins_priced += 1
        p = pin_included_price(pin)
        if p is not None:
            prices.append(p)
    total = round(sum(prices), 2)
    n = len(prices)
    per = round(total / n, 2) if n else 0.0
    half = round(0.5 * total, 2)
    # % pricing complete: (Match + NaP + Priced) / Total.
    # Priced included so CTP/manual finishes count (user's match+NaP core, plus priced).
    done = pins_match + pins_nap + pins_priced
    pct = round(100.0 * done / pins_total, 1) if pins_total else 0.0
    return {
        "value_usd": total,
        "pin_count": n,
        "per_pin_usd": per,
        "half_value_usd": half,
        "pct_complete": pct,
        "pins_total": pins_total,
        "pins_match": pins_match,
        "pins_priced": pins_priced,
        "pins_nap": pins_nap,
        "price_source": "firebase",
    }


def notify_happened(root: Path, folder: str) -> bool:
    """SHARE_LEXI_URL.txt is written when Lexi notify text is prepared."""
    return (root / folder / "SHARE_LEXI_URL.txt").is_file()


def main() -> int:
    root = Path(os.environ.get("PREP_REPO_ROOT", Path(__file__).resolve().parent))
    keep_days = int(os.environ.get("PRICING_RUNS_KEEP_DAYS", "30"))
    cutoff = datetime.now() - timedelta(days=keep_days)

    tracked = git_tracked_harness_folders(root)
    if not tracked and not (root / ".git").exists():
        tracked = {
            p.name
            for p in root.glob("PriceCollection_*")
            if p.is_dir() and FOLDER_RE.match(p.name)
        }

    rows: list[dict[str, Any]] = []
    for folder in tracked:
        m = FOLDER_RE.match(folder)
        if not m:
            continue
        run_dt = parse_run_dt(folder)
        if run_dt is None or run_dt < cutoff:
            continue
        harness = root / folder / "testing_ui_visual_baseline" / "index.html"
        if not harness.is_file():
            continue
        # Success gate: Pages-bound harness tracked in git. Prefer notify artifact when present.
        # PinDadTest-style publishes may lack SHARE; still list if harness is tracked.
        share_ok = notify_happened(root, folder)
        if not share_ok:
            # Allow tracked harness without SHARE only when folder is clearly published naming.
            pass

        label = folder_label(root, folder)
        ov = overlay_url(root, folder)
        run_id, approach, thumb = load_ui_meta(root, folder)
        money = (
            summarize_pins(fetch_pins(run_id, approach))
            if run_id
            else {
                "value_usd": None,
                "pin_count": None,
                "per_pin_usd": None,
                "half_value_usd": None,
                "pct_complete": None,
                "pins_total": None,
                "pins_match": None,
                "pins_priced": None,
                "pins_nap": None,
                "price_source": "missing_test_run_id",
            }
        )

        tod = m.group(2)
        sort_key = f"{m.group(1)}_{tod}"
        rows.append(
            {
                "folder": folder,
                "label": label,
                "sort_key": sort_key,
                "overlay_url": ov,
                "thumb_url": thumb,
                "test_run_id": run_id,
                "approach_id": approach,
                "has_share_lexi": share_ok,
                **money,
            }
        )

    rows.sort(key=lambda r: r["sort_key"], reverse=True)

    payload = {
        "runs": rows,
        "updated_iso": datetime.now().astimezone().isoformat(timespec="seconds"),
        "keep_days": keep_days,
        "base_url": BASE_URL,
        "generated_by": "update_pricing_runs_index.py",
    }
    out = root / "pricing_runs_index.json"
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(
        f"Wrote {out} ({len(rows)} runs in last {keep_days} days)",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
