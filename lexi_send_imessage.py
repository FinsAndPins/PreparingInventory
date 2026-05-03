#!/usr/bin/env python3
"""
Send a single iMessage via the Messages app (osascript).

Reads message body from stdin (UTF-8). Sends the same text to one or more buddies.

Recipients (first that applies):
  PRICING_NOTIFY_HANDLES — space-separated buddy handles (phone +E.164, Apple ID
    email, or how Messages shows each contact). Everyone gets the same message.
  else LEXI_IMESSAGE_HANDLE — single buddy (backward compatible).

Requires macOS automation permission for whatever runs this script (Terminal,
bash from launchd, etc.) to control Messages — one-time prompt in System Settings.

If no handle is configured, exits 0 without sending (silent skip).
"""
from __future__ import annotations

import os
import subprocess
import sys


def applescript_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _buddy_handles() -> list[str]:
    multi = (os.environ.get("PRICING_NOTIFY_HANDLES") or "").strip()
    if multi:
        return [h for h in multi.split() if h]
    one = (os.environ.get("LEXI_IMESSAGE_HANDLE") or "").strip()
    return [one] if one else []


def _send_to_buddy(handle: str, body: str) -> int:
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


def main() -> int:
    handles = _buddy_handles()
    if not handles:
        print("lexi_send_imessage: no PRICING_NOTIFY_HANDLES or LEXI_IMESSAGE_HANDLE; skip", file=sys.stderr)
        return 0
    body = sys.stdin.read()
    if not body.strip():
        return 0
    last = 0
    for handle in handles:
        last = _send_to_buddy(handle, body)
        if last != 0:
            return last
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
