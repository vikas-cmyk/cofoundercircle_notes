#!/usr/bin/env python3
"""Forward completed Vexa transcripts to Cofounder Circle.

Vexa's native webhook is a meeting.completed ping (no segments). The backend
hook expects the GET /transcripts JSON plus X-API-Key. This process polls the
local gateway and POSTs that shape to FORWARD_URL.

  VEXA_API_URL          default http://127.0.0.1:8056
  VEXA_API_KEY          required
  FORWARD_URL           required (e.g. https://….ngrok-free.app/hooks/vexa)
  FORWARD_API_KEY       default = VEXA_API_KEY (X-API-Key on the outbound POST)
  POLL_SECONDS          default 10
  STATE_PATH            default /tmp/vexa-cofounder-relay-state.json
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("VEXA_API_URL", "http://127.0.0.1:8056").rstrip("/")
KEY = os.environ.get("VEXA_API_KEY", "")
FORWARD = os.environ.get("FORWARD_URL", "")
FORWARD_KEY = os.environ.get("FORWARD_API_KEY", "") or KEY
POLL = float(os.environ.get("POLL_SECONDS", "10"))
STATE_PATH = os.environ.get("STATE_PATH", "/tmp/vexa-cofounder-relay-state.json")


def log(msg: str) -> None:
    print(msg, flush=True)


def load_state() -> set[str]:
    try:
        with open(STATE_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return set(data.get("sent") or [])
    except (OSError, json.JSONDecodeError):
        return set()


def save_state(sent: set[str]) -> None:
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"sent": sorted(sent)}, f)
    os.replace(tmp, STATE_PATH)


def req(method: str, url: str, *, headers: dict | None = None, body: bytes | None = None) -> tuple[int, bytes]:
    h = headers or {}
    request = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(request, timeout=60) as resp:
            return resp.getcode(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def vexa_get(path: str) -> tuple[int, object]:
    code, raw = req(
        "GET",
        API + path,
        headers={"X-API-Key": KEY, "Accept": "application/json"},
    )
    try:
        return code, json.loads(raw.decode() or "null")
    except json.JSONDecodeError:
        return code, raw.decode(errors="replace")


def list_meetings() -> list[dict]:
    code, data = vexa_get("/meetings?limit=100&exclude_planned=true")
    if code != 200:
        log(f"list meetings HTTP {code}: {data!r:.400}")
        return []
    if isinstance(data, dict):
        rows = data.get("meetings") or data.get("items") or []
    elif isinstance(data, list):
        rows = data
    else:
        rows = []
    return [r for r in rows if isinstance(r, dict)]


def transcript_payload(row: dict) -> dict | None:
    native = row.get("native_meeting_id") or ""
    platform = row.get("platform") or "google_meet"
    mid = row.get("id")
    if native:
        path = f"/transcripts/{platform}/{native}"
    elif mid is not None:
        path = f"/transcripts/by-id/{mid}"
    else:
        return None
    code, data = vexa_get(path)
    if code != 200 or not isinstance(data, dict):
        log(f"transcript {path} HTTP {code}: {data!r:.400}")
        return None
    return data


def forward(payload: dict) -> bool:
    body = json.dumps(payload).encode()
    headers = {
        "Content-Type": "application/json",
        "X-API-Key": FORWARD_KEY,
        "ngrok-skip-browser-warning": "1",
    }
    code, raw = req("POST", FORWARD, headers=headers, body=body)
    text = raw.decode(errors="replace")
    if 200 <= code < 300:
        log(f"forwarded {payload.get('native_meeting_id') or payload.get('id')} HTTP {code}")
        return True
    log(f"forward FAILED HTTP {code}: {text[:800]}")
    return False


def stamp(row: dict) -> str:
    return f"{row.get('platform')}:{row.get('native_meeting_id')}:{row.get('id')}"


def tick(sent: set[str]) -> None:
    for row in list_meetings():
        if row.get("status") != "completed":
            continue
        key = stamp(row)
        if key in sent:
            continue
        payload = transcript_payload(row)
        if payload is None:
            continue
        if not payload.get("native_meeting_id"):
            payload["native_meeting_id"] = row.get("native_meeting_id")
        if not payload.get("platform"):
            payload["platform"] = row.get("platform")
        if payload.get("id") is None:
            payload["id"] = row.get("id")
        payload["status"] = payload.get("status") or "completed"
        if forward(payload):
            sent.add(key)
            save_state(sent)


def main() -> int:
    if not KEY or not FORWARD:
        log("set VEXA_API_KEY and FORWARD_URL")
        return 2
    sent = load_state()
    log(f"relay → {FORWARD} polling {API} every {POLL}s (already sent {len(sent)})")
    while True:
        try:
            tick(sent)
        except Exception as exc:
            log(f"tick error: {exc!r}")
        time.sleep(POLL)


if __name__ == "__main__":
    sys.exit(main())
