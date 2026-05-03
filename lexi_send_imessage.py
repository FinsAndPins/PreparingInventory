#!/usr/bin/env python3
"""
Send a single iMessage via the Messages app (osascript).

Reads message body from stdin (UTF-8). Expects env LEXI_IMESSAGE_HANDLE to the
buddy handle (phone +E.164, Apple ID email, or how Messages shows the contact).

Requires macOS automation permission for whatever runs this script (Terminal,
bash from launchd, etc.) to control Messages — one-time prompt in System Settings.

If LEXI_IMESSAGE_HANDLE is unset, exits 0 without sending (silent skip).
"""
from __future__ import annotations

import os
import subprocess
import sys


def applescript_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main() -> int:
    handle = (os.environ.get("LEXI_IMESSAGE_HANDLE") or "").strip()
    if not handle:
        print("lexi_send_imessage: LEXI_IMESSAGE_HANDLE unset; skip", file=sys.stderr)
        return 0
    body = sys.stdin.read()
    if not body.strip():
        return 0
    h = applescript_escape(handle)
    b = applescript_escape(body)
    script = f'''tell application "Messages"
  set svc to first service whose service type is iMessage
  set b to buddy "{h}" of svc
  send "{b}" to b
end tell'''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr or r.stdout, file=sys.stderr)
        return r.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
