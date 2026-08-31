#!/usr/bin/env python3
"""
Send a single iMessage via the Messages app (osascript).

Reads message body from stdin (UTF-8). Sends the same text to one or more buddies.

Recipients (first that applies):
  PRICING_NOTIFY_HANDLES — space-separated buddy handles (phone +E.164, Apple ID
    email, or how Messages shows each contact). Everyone gets the same message.
  else LEXI_IMESSAGE_HANDLE — single buddy (backward compatible).

Optional attachment:
  IMESSAGE_ATTACH — path to an image/file to send before the text body.
  On macOS 15+, Messages sandbox only reliably reads files staged under
  ~/Library/Messages/, so attachments are copied there first.
  If the attachment send fails, the text message is still sent (never breaks notify).

The watcher overrides PRICING_NOTIFY_HANDLES per send:
  start/success → PRICING_NOTIFY_HANDLES (Lexi + Steve)
  failures → PRICING_FAIL_NOTIFY_HANDLES (Steve only; empty = silence)

Requires macOS automation permission for whatever runs this script (Terminal,
bash from launchd, etc.) to control Messages — one-time prompt in System Settings.

If no handle is configured, exits 0 without sending (silent skip).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path


def applescript_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _buddy_handles() -> list[str]:
    multi = (os.environ.get("PRICING_NOTIFY_HANDLES") or "").strip()
    if multi:
        return [h for h in multi.split() if h]
    one = (os.environ.get("LEXI_IMESSAGE_HANDLE") or "").strip()
    return [one] if one else []


def _stage_attachment(src: Path) -> Path | None:
    """Copy into a Messages-readable staging dir. Returns staged path or None.

    macOS 15+ Messages sandbox often blocks sends from arbitrary paths; stage under
    ~/Library/Messages first, then fall back to ~/Pictures (known-working on Sequoia).
    """
    if not src.is_file() or src.stat().st_size < 32:
        return None
    candidates = [
        Path.home() / "Library/Messages/.finsandpins-send-staging",
        Path.home() / "Library/Messages/Attachments/finsandpins-staging",
        Path.home() / "Pictures/.finsandpins-send-staging",
    ]
    name = f"{int(time.time())}_{uuid.uuid4().hex[:8]}_{src.name}"
    last_err: Exception | None = None
    for staging in candidates:
        try:
            staging.mkdir(parents=True, exist_ok=True)
            dest = staging / name
            shutil.copy2(src, dest)
            if dest.is_file() and dest.stat().st_size >= 32:
                return dest
        except OSError as e:
            last_err = e
            continue
    if last_err is not None:
        print(f"lexi_send_imessage: staging failed: {last_err}", file=sys.stderr)
    return None


def _send_file_to_buddy(handle: str, file_path: Path) -> int:
    h = applescript_escape(handle)
    p = applescript_escape(str(file_path))
    script = f'''with timeout of 120 seconds
  tell application "Messages"
    set svc to first service whose service type is iMessage
    set b to buddy "{h}" of svc
    send (POSIX file "{p}") to b
  end tell
end timeout'''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr or r.stdout, file=sys.stderr)
        return r.returncode
    return 0


def _send_text_to_buddy(handle: str, body: str) -> int:
    h = applescript_escape(handle)
    b = applescript_escape(body)
    script = f'''with timeout of 120 seconds
  tell application "Messages"
    set svc to first service whose service type is iMessage
    set b to buddy "{h}" of svc
    send "{b}" to b
  end tell
end timeout'''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr or r.stdout, file=sys.stderr)
        return r.returncode
    return 0


def _send_to_buddy(handle: str, body: str, attach: Path | None) -> int:
    # Image first (thumbnail), then text with the harness URL — matches Lexi's ask.
    if attach is not None:
        rc = _send_file_to_buddy(handle, attach)
        if rc != 0:
            print(
                f"lexi_send_imessage: attachment send failed for {handle}; sending text only",
                file=sys.stderr,
            )
        else:
            # Brief pause so Messages finishes the image before the URL text.
            time.sleep(0.6)
    return _send_text_to_buddy(handle, body)


def main() -> int:
    handles = _buddy_handles()
    if not handles:
        print("lexi_send_imessage: no PRICING_NOTIFY_HANDLES or LEXI_IMESSAGE_HANDLE; skip", file=sys.stderr)
        return 0
    body = sys.stdin.read()
    if not body.strip():
        return 0

    attach_env = (os.environ.get("IMESSAGE_ATTACH") or "").strip()
    staged: Path | None = None
    if attach_env:
        staged = _stage_attachment(Path(attach_env).expanduser())
        if staged is None:
            print(
                f"lexi_send_imessage: could not stage attachment ({attach_env}); text-only",
                file=sys.stderr,
            )

    last = 0
    for handle in handles:
        last = _send_to_buddy(handle, body, staged)
        if last != 0:
            return last
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
