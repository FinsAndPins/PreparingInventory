#!/usr/bin/env python3
"""Validate ClickToClaim boards/ outputs after RF-DETR detect."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from io import BytesIO
from pathlib import Path

from PIL import Image

SUPPORTED_SUFFIXES = {".jpg", ".jpeg", ".png"}

# iCloud CloudDocs can return errno 11 (Resource deadlock avoided) under launchd.
_ICLOUD_READ_ERRNO = 11


def _icloud_download(path: Path) -> None:
    if not path.exists():
        return
    try:
        subprocess.run(
            ["brctl", "download", str(path)],
            check=False,
            capture_output=True,
            timeout=30,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass


def read_bytes_with_retry(path: Path, *, max_attempts: int = 12) -> bytes:
    last_exc: OSError | None = None
    for attempt in range(1, max_attempts + 1):
        _icloud_download(path)
        try:
            data = path.read_bytes()
            if data:
                return data
        except OSError as exc:
            last_exc = exc
            if exc.errno != _ICLOUD_READ_ERRNO:
                raise
        if attempt < max_attempts:
            time.sleep(min(attempt * 2, 30))
    if last_exc is not None:
        raise last_exc
    raise OSError(f"empty read: {path}")


def read_text_with_retry(path: Path, *, encoding: str = "utf-8") -> str:
    return read_bytes_with_retry(path).decode(encoding)


def open_image_with_retry(path: Path, *, max_attempts: int = 12) -> Image.Image:
    last_exc: OSError | None = None
    for attempt in range(1, max_attempts + 1):
        _icloud_download(path)
        try:
            data = path.read_bytes()
            if data:
                return Image.open(BytesIO(data))
        except OSError as exc:
            last_exc = exc
            if exc.errno != _ICLOUD_READ_ERRNO:
                raise
        if attempt < max_attempts:
            time.sleep(min(attempt * 2, 30))
    if last_exc is not None:
        raise last_exc
    raise OSError(f"empty read: {path}")


def count_input_photos(input_dir: Path) -> int:
    return sum(
        1
        for p in input_dir.iterdir()
        if p.is_file() and p.suffix.lower() in SUPPORTED_SUFFIXES
    )


def validate_boards(boards_dir: Path, expected_photo_count: int | None) -> list[str]:
    errors: list[str] = []
    warnings: list[str] = []

    manifest_path = boards_dir / "manifest.json"
    if not manifest_path.is_file():
        errors.append(f"Missing manifest.json in {boards_dir}")
        return errors

    try:
        manifest = json.loads(read_text_with_retry(manifest_path))
    except json.JSONDecodeError as exc:
        errors.append(f"Invalid manifest.json: {exc}")
        return errors
    except OSError as exc:
        errors.append(f"Cannot read manifest.json: {exc}")
        return errors

    if not isinstance(manifest, list):
        errors.append("manifest.json must be a JSON array of board stems")
        return errors

    if expected_photo_count is not None and len(manifest) != expected_photo_count:
        errors.append(
            f"manifest has {len(manifest)} boards but input folder has {expected_photo_count} photos"
        )

    for stem in manifest:
        jpg = boards_dir / f"{stem}.JPG"
        js = boards_dir / f"{stem}.json"
        if not jpg.is_file():
            errors.append(f"Missing board JPG: {jpg.name}")
            continue
        if not js.is_file():
            errors.append(f"Missing board JSON: {js.name}")
            continue

        try:
            data = json.loads(read_text_with_retry(js))
        except json.JSONDecodeError as exc:
            errors.append(f"Invalid JSON for {stem}: {exc}")
            continue
        except OSError as exc:
            errors.append(f"Cannot read {js.name}: {exc}")
            continue

        if not isinstance(data, dict):
            errors.append(f"{stem}.json must be an object")
            continue
        if "predictions" not in data:
            errors.append(f"{stem}.json missing predictions key")
            continue
        preds = data.get("predictions")
        if not isinstance(preds, list):
            errors.append(f"{stem}.json predictions must be a list")
            continue
        if len(preds) == 0:
            warnings.append(f"{stem}: zero pin predictions (verify photo)")

        image_meta = data.get("image")
        if not isinstance(image_meta, dict):
            errors.append(f"{stem}.json missing image dimensions")
            continue

        try:
            with open_image_with_retry(jpg) as im:
                actual_w, actual_h = im.size
        except OSError as exc:
            errors.append(f"Cannot read {jpg.name}: {exc}")
            continue

        json_w = int(image_meta.get("width", 0) or 0)
        json_h = int(image_meta.get("height", 0) or 0)
        if json_w != actual_w or json_h != actual_h:
            errors.append(
                f"{stem}: JSON image {json_w}x{json_h} != JPG {actual_w}x{actual_h}"
            )

    for w in warnings:
        print(f"WARN: {w}", file=sys.stderr)

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate CTR boards/ folder.")
    parser.add_argument("--boards-dir", type=Path, required=True)
    parser.add_argument("--input-dir", type=Path, help="Original photo folder for count check.")
    args = parser.parse_args()

    boards_dir = args.boards_dir.expanduser().resolve()
    expected = None
    if args.input_dir:
        expected = count_input_photos(args.input_dir.expanduser().resolve())

    errors = validate_boards(boards_dir, expected)
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    print(f"Validation OK: {boards_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
