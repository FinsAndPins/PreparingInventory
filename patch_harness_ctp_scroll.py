#!/usr/bin/env python3
"""Patch ClickToPrice harness: preserve pin-list scroll when a pin leaves the filter."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

MARKER = "function syncCtpPinIndexToView(viewPins)"

SYNC_FN = """
    function syncCtpPinIndexToView(viewPins) {
      if (!viewPins.length) return;
      const curPin = pins[pinIndex] || null;
      if (curPin && pinByKeyInView(viewPins, curPin.pin_key)) return;
      const departedKey = curPin && curPin.pin_key;
      let pick = viewPins[0];
      if (departedKey) {
        const depIdx = pins.findIndex((p) => p.pin_key === departedKey);
        if (depIdx >= 0) {
          let viewIdx = 0;
          for (let i = 0; i < depIdx; i++) {
            if (pinByKeyInView(viewPins, pins[i].pin_key)) viewIdx++;
          }
          pick = viewPins[Math.min(viewIdx, viewPins.length - 1)];
        }
      }
      const i = pins.findIndex((p) => p.pin_key === pick.pin_key);
      if (i >= 0) pinIndex = i;
    }
"""

OLD_RENDER_PIN_LIST = """    function renderPinList() {
      const list = document.getElementById("pinList");
      list.innerHTML = "";
      const viewPins = getCtpViewPins();
      const curPin = pins[pinIndex] || null;
      if (viewPins.length && (!curPin || !pinByKeyInView(viewPins, curPin.pin_key))) {
        const i = pins.findIndex((p) => p.pin_key === viewPins[0].pin_key);
        if (i >= 0) pinIndex = i;
      }
      let selectedEl = null;
      viewPins.forEach((p) => {
        const i = pins.findIndex((x) => x.pin_key === p.pin_key);
        const d = document.createElement("div");
        d.className = "item" + (i === pinIndex ? " sel" : "");
        d.innerHTML = `<div><b>${esc(pinBoardPinLabel(p))}</b></div><div class="muted">${esc(pinImgAndPinRefLine(p))}</div><div class="muted">${esc(p.crop_filename)}</div><div class="muted">${pinPriceMetaHtml(p)} | Status: ${esc(p.match_status||"unreviewed")}</div>`;
        d.onclick = () => { pinIndex = i; renderPinList(); renderCtpPane(); };
        if (i === pinIndex) selectedEl = d;
        list.appendChild(d);
      });
      if (selectedEl) selectedEl.scrollIntoView({ block: "nearest" });
      updateCtpProgressLine();
    }"""

NEW_RENDER_PIN_LIST = """    function renderPinList() {
      const list = document.getElementById("pinList");
      const prevScrollTop = list.scrollTop;
      const prevPinKey = (pins[pinIndex] || {}).pin_key;
      list.innerHTML = "";
      const viewPins = getCtpViewPins();
      if (viewPins.length) syncCtpPinIndexToView(viewPins);
      let selectedEl = null;
      viewPins.forEach((p) => {
        const i = pins.findIndex((x) => x.pin_key === p.pin_key);
        const d = document.createElement("div");
        d.className = "item" + (i === pinIndex ? " sel" : "");
        d.innerHTML = `<div><b>${esc(pinBoardPinLabel(p))}</b></div><div class="muted">${esc(pinImgAndPinRefLine(p))}</div><div class="muted">${esc(p.crop_filename)}</div><div class="muted">${pinPriceMetaHtml(p)} | Status: ${esc(p.match_status||"unreviewed")}</div>`;
        d.onclick = () => { pinIndex = i; renderPinList(); renderCtpPane(); };
        if (i === pinIndex) selectedEl = d;
        list.appendChild(d);
      });
      if (selectedEl) {
        const samePin = prevPinKey && (pins[pinIndex] || {}).pin_key === prevPinKey;
        if (samePin && pinByKeyInView(viewPins, prevPinKey)) {
          list.scrollTop = prevScrollTop;
        } else {
          selectedEl.scrollIntoView({ block: "nearest" });
        }
      }
      updateCtpProgressLine();
    }"""

OLD_RENDER_CTP_PANE = """      const curPin = pins[pinIndex] || null;
      if (!curPin || !pinByKeyInView(viewPins, curPin.pin_key)) {
        const i = pins.findIndex((x) => x.pin_key === viewPins[0].pin_key);
        if (i >= 0) pinIndex = i;
      }
      if (!pins.length) {"""

NEW_RENDER_CTP_PANE = """      syncCtpPinIndexToView(viewPins);
      if (!pins.length) {"""


def patch_index_html(index_path: Path) -> bool:
    html = index_path.read_text(encoding="utf-8")
    if MARKER in html:
        return False
    if OLD_RENDER_PIN_LIST not in html:
        raise SystemExit(f"{index_path}: renderPinList block not found (harness template changed?)")
    if OLD_RENDER_CTP_PANE not in html:
        raise SystemExit(f"{index_path}: renderCtpPane pin-index block not found (harness template changed?)")
    html = html.replace(
        "      batchIndex = Math.min(fromIdx + s, listLen - 1);\n    }\n\n    function batchMarkAndAdvance",
        "      batchIndex = Math.min(fromIdx + s, listLen - 1);\n    }\n" + SYNC_FN + "\n    function batchMarkAndAdvance",
        1,
    )
    html = html.replace(OLD_RENDER_PIN_LIST, NEW_RENDER_PIN_LIST, 1)
    html = html.replace(OLD_RENDER_CTP_PANE, NEW_RENDER_CTP_PANE, 1)
    index_path.write_text(html, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "harness_dir",
        type=Path,
        nargs="?",
        help="Path to testing_ui_visual_baseline/ (default: stdin path or cwd)",
    )
    args = ap.parse_args()
    harness_dir = args.harness_dir
    if harness_dir is None:
        print("usage: patch_harness_ctp_scroll.py testing_ui_visual_baseline/", file=sys.stderr)
        return 2
    index_path = harness_dir.expanduser().resolve() / "index.html"
    if not index_path.is_file():
        raise SystemExit(f"Missing {index_path}")
    if patch_index_html(index_path):
        print(f"Patched {index_path}")
    else:
        print(f"Already patched {index_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
