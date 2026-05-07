#!/usr/bin/env python3
"""
Prune old published artifacts from the PreparingInventory GitHub repo while keeping them on disk.

Design goals:
- Keep the pricing pipeline working (especially overnight automation).
- Shrink GitHub Pages publish size by untracking old PriceCollection runs.
- Never delete local files: uses `git rm -r --cached ...` (unpublish/untrack only).

Policy (defaults):
- Prune tracked `PriceCollection_YYYYMMDD_HHMM/` older than KEEP_DAYS (default 30),
  but always keep at least KEEP_MIN newest collections (default 10).
- Always prune tracked `PriceCollection_*__build_*/` folders (transient build artifacts).

The script only operates on **git-tracked** top-level folders, because only tracked files affect GitHub size / Pages.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path


@dataclass(frozen=True)
class TrackedDir:
    name: str
    kind: str  # "collection" | "build"
    date: datetime | None


COL_RE = re.compile(r"^PriceCollection_(\d{8})_(\d{4})$")
BUILD_RE = re.compile(r"^PriceCollection_\d{8}_\d{4}__build_\d+$")


def sh(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True).strip()


def git_root() -> Path:
    return Path(sh(["git", "rev-parse", "--show-toplevel"]))


def tracked_top_level_dirs() -> list[str]:
    # `git ls-tree` is stable and only shows tracked items.
    out = sh(["git", "ls-tree", "--name-only", "HEAD"])
    return [line.strip() for line in out.splitlines() if line.strip()]


def parse_tracked_dir(name: str) -> TrackedDir | None:
    if BUILD_RE.match(name):
        return TrackedDir(name=name, kind="build", date=None)
    m = COL_RE.match(name)
    if not m:
        return None
    ds = m.group(1)
    try:
        d = datetime.strptime(ds, "%Y%m%d")
    except ValueError:
        d = None
    return TrackedDir(name=name, kind="collection", date=d)


def append_gitignore(root: Path, rel_dir: str) -> None:
    gi = root / ".gitignore"
    line = f"/{rel_dir}/"
    existing = gi.read_text(encoding="utf-8").splitlines() if gi.exists() else []
    if line in existing:
        return
    with gi.open("a", encoding="utf-8") as f:
        if existing and existing[-1].strip() != "":
            f.write("\n")
        f.write(line + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-days", type=int, default=int(os.environ.get("RETENTION_KEEP_DAYS", "30")))
    ap.add_argument("--keep-min", type=int, default=int(os.environ.get("RETENTION_KEEP_MIN", "10")))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    keep_days = max(0, int(args.keep_days))
    keep_min = max(0, int(args.keep_min))
    cutoff = datetime.now() - timedelta(days=keep_days)

    root = git_root()
    os.chdir(root)

    tracked = [parse_tracked_dir(n) for n in tracked_top_level_dirs()]
    tracked = [t for t in tracked if t is not None]

    builds = [t for t in tracked if t.kind == "build"]
    cols = [t for t in tracked if t.kind == "collection" and t.date is not None]
    # newest first
    cols.sort(key=lambda t: (t.date or datetime.min, t.name), reverse=True)

    keep_names = set(t.name for t in cols[:keep_min])
    prune: list[str] = []

    # Always prune tracked build artifacts
    prune.extend([t.name for t in builds])

    # Prune old collections, respecting keep-min
    for t in cols:
        if t.name in keep_names:
            continue
        if t.date and t.date < cutoff:
            prune.append(t.name)

    prune = sorted(set(prune))

    print(f"[retention] keep_days={keep_days} cutoff={cutoff:%Y-%m-%d} keep_min={keep_min}")
    print(f"[retention] tracked collections={len(cols)} tracked build dirs={len(builds)}")
    print(f"[retention] prune count={len(prune)}")
    for n in prune[:40]:
        print(f"  prune: {n}/")
    if len(prune) > 40:
        print(f"  … +{len(prune)-40} more")

    if args.dry_run or not prune:
        return 0

    # Untrack/unpublish (keep on disk)
    for n in prune:
        subprocess.run(["git", "rm", "-r", "--cached", "--ignore-unmatch", n], check=True)
        append_gitignore(root, n)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

