#!/usr/bin/env python3
"""Patch CTR show slug + pricing Firebase run id after template bootstrap.

Always rewrites the price-overlay run id so a bootstrap from an older template
cannot leave a stale PriceCollection Firebase path (wrong or missing prices).

Also rewrites companion pages copied from the template (mark_pending.html, etc.).

Usage:
  patch_ctr_show_slug.py SHOW_DIR SHOW_ID
      → slug/manifest + pricing unset sentinel for this show
  patch_ctr_show_slug.py SHOW_DIR SHOW_ID --pricing-run-id test_PriceCollection_…_visual_baseline
  patch_ctr_show_slug.py SHOW_DIR SHOW_ID --from-collection /path/to/PriceCollection_…
  patch_ctr_show_slug.py SHOW_DIR SHOW_ID --pricing-unset
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SLUG_RE = re.compile(r'(const SHOW_DATE_SLUG_FALLBACK = ")(\d{8})(";)')
MANIFEST_RE = re.compile(r'(const BOARDS_MANIFEST_VERSION = ")([^"]+)(";)')
# index.html price overlay (primary collection only — leftover id is show-specific)
PO_TR_RE = re.compile(
    r"(const _PO_TR = ')([^']*)(';)"
)
# reports.html dollar-value support
PRICING_RUN_RE = re.compile(
    r"(const PRICING_RUN_ID = ')([^']*)(';)"
)
# mark_pending.html dual pricing
RUN_PRIMARY_RE = re.compile(
    r'(const RUN_PRIMARY = ")([^"]*)(";)'
)

RUN_ID_RE = re.compile(
    r"^test_PriceCollection_\d{8}_\d{4}(?:_\d+)?(?:__build_\d+)?_visual_baseline$"
)
UNSET_RE = re.compile(r"^test_CTR_\d{8}_pricing_unset$")

COMPANION_HTML = (
    "mark_pending.html",
    "mark_leftover_sold.html",
    "leftover_sheet.html",
)


def unset_pricing_run_id(show_id: str) -> str:
    return f"test_CTR_{show_id}_pricing_unset"


def collection_name_from_run(run_id: str) -> str | None:
    match = re.search(r"(PriceCollection_\d{8}_\d{4})", run_id)
    return match.group(1) if match else None


def retarget_show_data(text: str, show_id: str, pricing_run_id: str) -> str:
    """Point copied template pages at this show only.

    Clears the previous show's sold-stem list, price run, crop folder, and
    Firebase sold/pending paths (including an old shared leftover bucket).
    """
    text = re.sub(
        r'(const slug = m \? m\[1\] : ")(\d{8})(";)',
        rf"\g<1>{show_id}\g<3>",
        text,
    )
    text = re.sub(
        r"const _SOLD_STEMS_BOOTSTRAP = \{.*?\};",
        "const _SOLD_STEMS_BOOTSTRAP = {};",
        text,
        count=1,
        flags=re.S,
    )
    text = re.sub(
        r"""((?:const|let)\s+(?:TEST_RUN_ID|RUN_PRIMARY|RUN_LEFTOVER)\s*=\s*["'])([^"']+)(["'])""",
        rf"\g<1>{pricing_run_id}\g<3>",
        text,
    )
    text = re.sub(
        r"showConfig/[A-Za-z0-9_]+/soldStems",
        f"showConfig/{show_id}/soldStems",
        text,
    )
    text = re.sub(
        r"showConfig/[A-Za-z0-9_]+/pendingStems",
        f"showConfig/{show_id}/pendingStems",
        text,
    )
    text = re.sub(
        r"""(const MANIFEST_VER = ["'])[^"']+(["'])""",
        r"\g<1>1\g<2>",
        text,
    )
    collection = collection_name_from_run(pricing_run_id)
    if collection:
        text = re.sub(r"PriceCollection_\d{8}_\d{4}", collection, text)
    else:
        text = re.sub(
            r"PriceCollection_\d{8}_\d{4}",
            f"PriceCollection_UNSET_{show_id}",
            text,
        )
    text = re.sub(
        r"Mark leftover sold · \d{8}(?: → \d{8})?",
        f"Mark leftover sold · {show_id}",
        text,
    )
    text = re.sub(
        r"\d{8} claims",
        f"{show_id} claims",
        text,
    )
    return text


def validate_pricing_run_id(run_id: str, *, allow_unset: bool = False) -> str:
    run_id = run_id.strip()
    if not run_id:
        raise ValueError("pricing run id is empty")
    if allow_unset and UNSET_RE.fullmatch(run_id):
        return run_id
    if RUN_ID_RE.fullmatch(run_id):
        return run_id
    # Allow exact ui_data test_run_id shapes we have seen (build suffix optional variants)
    if run_id.startswith("test_PriceCollection_") and run_id.endswith("_visual_baseline"):
        return run_id
    raise ValueError(
        f"pricing run id looks unexpected: {run_id!r} "
        "(expected test_PriceCollection_YYYYMMDD_HHMM[__build_N]_visual_baseline)"
    )


def pricing_run_id_from_collection(collection_dir: Path) -> str:
    ui = collection_dir / "testing_ui_visual_baseline" / "ui_data.json"
    if not ui.is_file():
        raise FileNotFoundError(f"missing {ui}")
    data = json.loads(ui.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{ui} is not a JSON object")
    run_id = str(data.get("test_run_id") or "").strip()
    return validate_pricing_run_id(run_id)


def patch_core_file(path: Path, show_id: str, pricing_run_id: str) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text
    text = SLUG_RE.sub(rf"\g<1>{show_id}\g<3>", text)
    text = MANIFEST_RE.sub(r"\g<1>1\g<3>", text)
    text = PO_TR_RE.sub(rf"\g<1>{pricing_run_id}\g<3>", text)
    text = PRICING_RUN_RE.sub(rf"\g<1>{pricing_run_id}\g<3>", text)
    # Dual / leftover pricing ids (keep in sync with primary when bootstrapping)
    text = re.sub(
        r"(const _PO_TR_LEFTOVER = ')[^']*(')",
        rf"\g<1>{pricing_run_id}\g<2>",
        text,
    )
    text = re.sub(
        r"(const PRICING_RUN_ID_LEFTOVER = ')[^']*(')",
        rf"\g<1>{pricing_run_id}\g<2>",
        text,
    )
    # Board Box Editor hrefs (Reports → ../BoardBoxEditor/YYYYMMDD/)
    text = re.sub(r"(BoardBoxEditor/)\d{8}(/?)", rf"\g<1>{show_id}\g<2>", text)
    # Price-mode localStorage key + sold/pending stems under showConfig
    text = re.sub(r"(_ctcPriceMode_)\d{8}", rf"\g<1>{show_id}", text)
    text = re.sub(r"(ctc_price_mode_)\d{8}", rf"\g<1>{show_id}", text)
    text = re.sub(
        r"(showConfig/)\d{8}(/soldStems)",
        rf"\g<1>{show_id}\g<2>",
        text,
    )
    text = re.sub(
        r"(showConfig/)\d{8}(/pendingStems)",
        rf"\g<1>{show_id}\g<2>",
        text,
    )
    # _PO_SHOW_ID ternary fallback literal
    text = re.sub(
        r"(const _PO_SHOW_ID = \(typeof fbName !== 'undefined' && fbName\) \? fbName\n"
        r"  : \(typeof showDateSlug !== 'undefined' && showDateSlug\) \? showDateSlug\n"
        r"  : ')(\d{8})(';)",
        rf"\g<1>{show_id}\g<3>",
        text,
    )
    # Meta cache-bust fragment in <head> (suffix varies by show, e.g. -fix-boxes, -search-clear).
    text = re.sub(
        r'(content="closes-to-end-v\d+-)\d{8}(-[^"]*")',
        rf"\g<1>{show_id}\g<2>",
        text,
    )
    text = retarget_show_data(text, show_id, pricing_run_id)
    if text == original:
        print(f"WARN: no changes in {path}", file=sys.stderr)
        return False
    path.write_text(text, encoding="utf-8")
    return True


def patch_companion_file(path: Path, show_id: str, pricing_run_id: str) -> bool:
    """Retarget show-id labels / pendingStems path; wire primary pricing run id."""
    text = path.read_text(encoding="utf-8")
    original = text
    name = path.name

    # showConfig/{date}/pendingStems → this show
    text = re.sub(
        r"(showConfig/)\d{8}(/pendingStems)",
        rf"\g<1>{show_id}\g<2>",
        text,
    )
    # Visible CTR show labels. Firebase paths for this show are retargeted below,
    # including an older shared leftover bucket (showConfig/YYYYMMDD_leftover/soldStems).
    text = re.sub(r"(Open CTR )\d{8}", rf"\g<1>{show_id}", text)
    text = re.sub(r"(>CTR )\d{8}(<)", rf"\g<1>{show_id}\g<2>", text)
    text = re.sub(
        r"(Mark pending auth · )\d{8}",
        rf"\g<1>{show_id}",
        text,
    )
    text = re.sub(
        r'(<title>Mark pending auth · )\d{8}(</title>)',
        rf"\g<1>{show_id}\g<2>",
        text,
    )
    text = re.sub(
        r'(<span class="sub">)\d{8}( · )',
        rf"\g<1>{show_id}\g<2>",
        text,
    )
    # Leftover sold tool: keep Monday id, retarget this show's date
    text = re.sub(r"(→ )\d{8}", rf"\g<1>{show_id}", text)
    text = re.sub(r"(on )\d{8}( Boards)", rf"\g<1>{show_id}\g<2>", text)
    text = re.sub(
        r"(Mark leftover sold · \d{8} → )\d{8}",
        rf"\g<1>{show_id}",
        text,
    )
    text = re.sub(
        r"(<title>Mark leftover sold · \d{8} → )\d{8}(</title>)",
        rf"\g<1>{show_id}\g<2>",
        text,
    )

    if name == "mark_pending.html":
        text = RUN_PRIMARY_RE.sub(rf"\g<1>{pricing_run_id}\g<3>", text)

    text = retarget_show_data(text, show_id, pricing_run_id)

    if text == original:
        return False
    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Patch CTR show Firebase slug + pricing overlay run id."
    )
    parser.add_argument("show_dir", type=Path, help="ClickToClaim/YYYYMMDD folder")
    parser.add_argument("show_id", help="YYYYMMDD show id")
    src = parser.add_mutually_exclusive_group()
    src.add_argument(
        "--pricing-run-id",
        default=None,
        help="Firebase test_run_id for pin_pricing_tests/.../pins",
    )
    src.add_argument(
        "--from-collection",
        type=Path,
        default=None,
        help="PriceCollection dir; read testing_ui_visual_baseline/ui_data.json test_run_id",
    )
    src.add_argument(
        "--pricing-unset",
        action="store_true",
        help="Clear inherited template pricing id (safe sentinel for this show)",
    )
    args = parser.parse_args()

    show_id = args.show_id.strip()
    if not re.fullmatch(r"\d{8}", show_id):
        print(f"ERROR: show_id must be YYYYMMDD, got {show_id!r}", file=sys.stderr)
        return 1

    try:
        if args.pricing_run_id is not None:
            pricing_run_id = validate_pricing_run_id(args.pricing_run_id)
        elif args.from_collection is not None:
            pricing_run_id = pricing_run_id_from_collection(
                args.from_collection.expanduser().resolve()
            )
        else:
            # Default: never keep a template's old PriceCollection id.
            pricing_run_id = unset_pricing_run_id(show_id)
            if not args.pricing_unset:
                print(
                    f"NOTE: no --pricing-run-id/--from-collection; "
                    f"setting overlay to unset sentinel {pricing_run_id}",
                    file=sys.stderr,
                )
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    show_dir = args.show_dir.expanduser().resolve()
    changed = 0
    saw_po = False
    for name in ("index.html", "reports.html"):
        path = show_dir / name
        if not path.is_file():
            print(f"ERROR: missing {path}", file=sys.stderr)
            return 1
        raw = path.read_text(encoding="utf-8")
        if "_PO_TR" in raw or "PRICING_RUN_ID" in raw:
            saw_po = True
        if patch_core_file(path, show_id, pricing_run_id):
            changed += 1
            print(f"Patched {path}")

    for name in COMPANION_HTML:
        path = show_dir / name
        if not path.is_file():
            continue
        if patch_companion_file(path, show_id, pricing_run_id):
            changed += 1
            print(f"Patched {path}")

    if not saw_po:
        print(
            "WARN: no _PO_TR / PRICING_RUN_ID markers found — slug may be patched but overlay id was not",
            file=sys.stderr,
        )
    if changed == 0:
        return 1
    print(f"Pricing overlay run id → {pricing_run_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
