#!/usr/bin/env python3
"""Detect show board photos with RF-DETR (Core ML) for ClickToClaim CTR pages."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps

SUPPORTED_SUFFIXES = {".jpg", ".jpeg", ".png"}
_FINS_LOCAL = Path.home() / "Library/Application Support/FinsAndPins/PinPricingStudyMVP_RFDETR_TEST"
_ICLOUD = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Cursor Projects/PinPricingStudyMVP_RFDETR_TEST"
PIN_PRICING_RFDETR_DEFAULT = (
    _FINS_LOCAL
    if (_FINS_LOCAL / ".rfdetr_py39/bin/python").exists() and (_FINS_LOCAL / "rfdetr_coreml_detector.py").exists()
    else _ICLOUD
)


def board_numeric_id(board_path: Path, board_index: int) -> str:
    matches = list(re.finditer(r"\d+", board_path.stem))
    if not matches:
        return f"{board_index + 1:04d}"
    return max(matches, key=lambda m: len(m.group(0))).group(0)


def sort_predictions_reading_order(predictions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(predictions, key=lambda p: (float(p.get("y", 0.0)), float(p.get("x", 0.0))))


def list_input_images(input_dir: Path, only_stems: set[str] | None = None) -> list[Path]:
    if not input_dir.is_dir():
        raise FileNotFoundError(f"Input directory does not exist: {input_dir}")
    files = [
        p
        for p in sorted(input_dir.iterdir(), key=lambda x: x.name)
        if p.is_file() and p.suffix.lower() in SUPPORTED_SUFFIXES
    ]
    if only_stems is not None:
        only = {s.upper() for s in only_stems}
        files = [p for p in files if p.stem.upper() in only]
    return files


def read_manifest_stems(out_dir: Path) -> list[str]:
    manifest_path = out_dir / "manifest.json"
    if not manifest_path.is_file():
        return []
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        return []
    return [str(s) for s in data]


def merge_manifest_stems(existing: list[str], processed: list[str]) -> list[str]:
    processed_set = {s.upper(): s for s in processed}
    merged = [processed_set.get(s.upper(), s) for s in existing]
    existing_upper = {s.upper() for s in existing}
    new_stems = sorted(
        (processed_set[s] for s in processed_set if s not in existing_upper),
        key=lambda name: name.upper(),
    )
    return merged + new_stems


def prepare_output_jpg(src: Path, dest_jpg: Path, max_dim: int = 1280) -> tuple[int, int]:
    dest_jpg.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(src) as im:
        rgb = ImageOps.exif_transpose(im).convert("RGB")
        rgb.thumbnail((max_dim, max_dim), Image.Resampling.LANCZOS)
        rgb.save(dest_jpg, format="JPEG", quality=85)
        return rgb.size


def load_dedupe_helpers(pin_pricing_dir: Path):
    sys.path.insert(0, str(pin_pricing_dir))
    try:
        from prediction_dedupe import (  # type: ignore
            DEFAULT_IOU_THRESHOLD,
            DEFAULT_SECONDARY_IOU,
            dedupe_predictions_two_pass,
        )
    finally:
        sys.path.pop(0)
    return dedupe_predictions_two_pass, DEFAULT_IOU_THRESHOLD, DEFAULT_SECONDARY_IOU


def detect_predictions(image_path: Path, pin_pricing_dir: Path, min_conf: float) -> dict[str, Any]:
    detector_python = pin_pricing_dir / ".rfdetr_py39" / "bin" / "python"
    detector_script = pin_pricing_dir / "rfdetr_coreml_detector.py"
    if not detector_python.is_file():
        raise FileNotFoundError(f"Missing RF-DETR venv python: {detector_python}")
    if not detector_script.is_file():
        raise FileNotFoundError(f"Missing detector script: {detector_script}")

    with tempfile.TemporaryDirectory(prefix="ctr_detect_") as tmp_dir:
        json_out = Path(tmp_dir) / "predictions.json"
        cmd = [
            str(detector_python),
            str(detector_script),
            "--image",
            str(image_path),
            "--model",
            str(
                Path(
                    os.environ.get(
                        "RFDETR_COREML_MODEL_PATH",
                        "~/Desktop/ClickToCollectApp/ClickToCollect/ClickToCollect/RfDetrPinDetector.mlpackage",
                    )
                ).expanduser()
            ),
            "--min-conf",
            str(min_conf),
            "--json-out",
            str(json_out),
        ]
        subprocess.run(cmd, check=True)
        return json.loads(json_out.read_text(encoding="utf-8"))


def write_manifest(stems: list[str], out_dir: Path) -> Path:
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(stems, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Detect show boards with RF-DETR for ClickToClaim CTR.")
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--pin-pricing-rfdetr-dir",
        type=Path,
        default=PIN_PRICING_RFDETR_DEFAULT,
        help="Path to PinPricingStudyMVP_RFDETR_TEST clone.",
    )
    parser.add_argument("--min-conf", type=float, default=0.25)
    parser.add_argument(
        "--only-stems",
        nargs="+",
        help="Process only these board stems (case-insensitive).",
    )
    parser.add_argument(
        "--merge-manifest",
        action="store_true",
        help="Merge processed stems into existing manifest.json instead of replacing it.",
    )
    parser.add_argument(
        "--no-dedupe",
        action="store_true",
        help="Skip IoU dedupe (not recommended for show night).",
    )
    args = parser.parse_args()

    input_dir = args.input_dir.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    pin_pricing_dir = args.pin_pricing_rfdetr_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    dedupe_fn = None
    primary_iou = secondary_iou = None
    if not args.no_dedupe:
        dedupe_fn, primary_iou, secondary_iou = load_dedupe_helpers(pin_pricing_dir)

    only_stems = {s.upper() for s in args.only_stems} if args.only_stems else None
    images = list_input_images(input_dir, only_stems=only_stems)
    if not images:
        manifest = write_manifest([], output_dir)
        print(f"No input images found in {input_dir}. Wrote empty manifest: {manifest}")
        return 0

    processed_stems = [p.stem for p in images]
    for index, image_path in enumerate(images):
        stem = image_path.stem
        print(f"[{index + 1}/{len(images)}] {image_path.name}")

        output_jpg = output_dir / f"{stem}.JPG"
        prepared_w, prepared_h = prepare_output_jpg(image_path, output_jpg)

        raw = detect_predictions(output_jpg, pin_pricing_dir, min_conf=float(args.min_conf))
        predictions = raw.get("predictions") if isinstance(raw, dict) else []
        if not isinstance(predictions, list):
            predictions = []

        if dedupe_fn is not None and primary_iou is not None:
            predictions, _dedupe_meta = dedupe_fn(
                predictions,
                primary_iou=float(primary_iou),
                secondary_iou=float(secondary_iou) if secondary_iou is not None else None,
            )

        predictions = sort_predictions_reading_order(predictions)

        numeric_id = board_numeric_id(image_path, index)
        for pin_i, pred in enumerate(predictions, start=1):
            pred["crop_stem"] = f"img{numeric_id}_pin{pin_i:02d}"

        image_meta = raw.get("image") if isinstance(raw, dict) else None
        if not isinstance(image_meta, dict):
            image_meta = {}
        width = int(image_meta.get("width", 0) or 0)
        height = int(image_meta.get("height", 0) or 0)
        if width <= 0 or height <= 0:
            with Image.open(output_jpg) as im:
                width, height = im.size
        if width <= 0 or height <= 0:
            width, height = prepared_w, prepared_h

        payload = {
            "predictions": predictions,
            "image": {
                "width": width,
                "height": height,
            },
        }

        (output_dir / f"{stem}.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    if args.merge_manifest:
        existing = read_manifest_stems(output_dir)
        stems = merge_manifest_stems(existing, processed_stems)
    else:
        stems = processed_stems

    manifest_path = write_manifest(stems, output_dir)
    print(f"Wrote {len(images)} boards to {output_dir}")
    print(f"Manifest boards: {len(stems)}")
    print(f"Wrote manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
