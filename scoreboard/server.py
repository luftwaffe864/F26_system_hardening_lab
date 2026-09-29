#!/usr/bin/env python3
"""
DCIG System Hardening — live CyberPatriot-style team scoreboard.

  export HARDENING_SECRET='change-me'
  export HARDENING_ADMIN='change-me-admin'
  pip install -r requirements.txt
  python server.py

Projector: http://<host>:8080/
Agents POST signed finding updates to /api/score
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import threading
import time
from collections import defaultdict
from typing import Any

from flask import Flask, Response, jsonify, request, send_from_directory

app = Flask(__name__, static_folder="static", static_url_path="/static")

SECRET = os.environ.get("HARDENING_SECRET", "dcig-hardening-2026").encode()
ADMIN = os.environ.get("HARDENING_ADMIN", "dcig-admin-2026")
HOST = os.environ.get("HARDENING_HOST", "0.0.0.0")
PORT = int(os.environ.get("HARDENING_PORT", "8080"))

_lock = threading.Lock()
_state: dict[str, Any] = {
    "phase2_open": False,
    "frozen": False,
    "teams": {},  # team -> {linux: {finding_id: pts}, windows: {...}, ready: {linux, windows}}
    "events": [],
    "seq": 0,
}


def _sign(team: str, os_name: str, finding_id: str, points: int) -> str:
    msg = f"{team}|{os_name}|{finding_id}|{points}".encode()
    return hmac.new(SECRET, msg, hashlib.sha256).hexdigest()


def _team_totals() -> list[dict[str, Any]]:
    rows = []
    for team, data in _state["teams"].items():
        lin = sum(data.get("linux", {}).values())
        win = sum(data.get("windows", {}).values())
        rows.append(
            {
                "team": team,
                "linux": lin,
                "windows": win,
                "total": lin + win,
                "ready_linux": bool(data.get("ready", {}).get("linux")),
                "ready_windows": bool(data.get("ready", {}).get("windows")),
                "updated": data.get("updated", 0),
            }
        )
    rows.sort(key=lambda r: (-r["total"], r["team"]))
    for i, r in enumerate(rows, 1):
        r["rank"] = i
    return rows


def _bump(kind: str, payload: dict[str, Any]) -> None:
    _state["seq"] += 1
    _state["events"].append(
        {"seq": _state["seq"], "kind": kind, "ts": time.time(), **payload}
    )
    _state["events"] = _state["events"][-200:]


def _require_admin() -> Response | None:
    token = request.headers.get("X-Admin-Token") or request.json.get("admin") if request.is_json else None
    if token != ADMIN:
        return jsonify({"ok": False, "error": "unauthorized"}), 401
    return None


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/status")
def status():
    with _lock:
        return jsonify(
            {
                "phase2_open": _state["phase2_open"],
                "frozen": _state["frozen"],
                "teams": _team_totals(),
                "seq": _state["seq"],
            }
        )


@app.get("/api/stream")
def stream():
    def gen():
        last = 0
        while True:
            with _lock:
                payload = {
                    "phase2_open": _state["phase2_open"],
                    "frozen": _state["frozen"],
                    "teams": _team_totals(),
                    "seq": _state["seq"],
                }
                seq = _state["seq"]
            if seq != last:
                last = seq
                yield f"data: {json.dumps(payload)}\n\n"
            else:
                yield ": ping\n\n"
            time.sleep(1)

    return Response(gen(), mimetype="text/event-stream")


@app.post("/api/ready")
def ready():
    """Mark a team's OS as Phase-2 prepared (prep scripts call this)."""
    data = request.get_json(force=True, silent=True) or {}
    team_raw = str(data.get("team", "")).strip()
    team = f"{int(team_raw):02d}" if team_raw.isdigit() else team_raw
    os_name = str(data.get("os", "")).lower().strip()
    sig = str(data.get("sig", ""))
    if os_name not in ("linux", "windows") or not team:
        return jsonify({"ok": False, "error": "bad team/os"}), 400
    expect = hmac.new(SECRET, f"ready|{team}|{os_name}".encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expect):
        return jsonify({"ok": False, "error": "bad signature"}), 403
    with _lock:
        t = _state["teams"].setdefault(team, {"linux": {}, "windows": {}, "ready": {}, "updated": 0})
        t.setdefault("ready", {})[os_name] = True
        t["updated"] = time.time()
        _bump("ready", {"team": team, "os": os_name})
    return jsonify({"ok": True})


@app.post("/api/score")
def score():
    data = request.get_json(force=True, silent=True) or {}
    team_raw = str(data.get("team", "")).strip()
    team = f"{int(team_raw):02d}" if team_raw.isdigit() else team_raw
    os_name = str(data.get("os", "")).lower().strip()
    finding_id = str(data.get("finding_id", "")).strip()
    try:
        points = int(data.get("points", 0))
    except (TypeError, ValueError):
        return jsonify({"ok": False, "error": "bad points"}), 400
    sig = str(data.get("sig", ""))

    if os_name not in ("linux", "windows") or not team or not finding_id or points <= 0:
        return jsonify({"ok": False, "error": "bad payload"}), 400
    expect = _sign(team, os_name, finding_id, points)
    if not hmac.compare_digest(sig, expect):
        return jsonify({"ok": False, "error": "bad signature"}), 403

    with _lock:
        if _state["frozen"]:
            return jsonify({"ok": False, "error": "board frozen"}), 423
        if not _state["phase2_open"]:
            return jsonify({"ok": False, "error": "phase2 closed"}), 423
        t = _state["teams"].setdefault(team, {"linux": {}, "windows": {}, "ready": {}, "updated": 0})
        bucket = t.setdefault(os_name, {})
        if finding_id in bucket:
            return jsonify({"ok": True, "duplicate": True, "total": sum(t["linux"].values()) + sum(t["windows"].values())})
        bucket[finding_id] = points
        t["updated"] = time.time()
        total = sum(t["linux"].values()) + sum(t["windows"].values())
        _bump("score", {"team": team, "os": os_name, "finding_id": finding_id, "points": points, "total": total})
    return jsonify({"ok": True, "total": total})


@app.post("/api/admin/open")
def admin_open():
    err = _require_admin()
    if err:
        return err
    with _lock:
        _state["phase2_open"] = True
        _state["frozen"] = False
        _bump("open", {})
    return jsonify({"ok": True, "phase2_open": True})


@app.post("/api/admin/freeze")
def admin_freeze():
    err = _require_admin()
    if err:
        return err
    with _lock:
        _state["frozen"] = True
        _bump("freeze", {})
    return jsonify({"ok": True, "frozen": True})


@app.post("/api/admin/reset")
def admin_reset():
    err = _require_admin()
    if err:
        return err
    with _lock:
        _state["phase2_open"] = False
        _state["frozen"] = False
        _state["teams"] = {}
        _state["events"] = []
        _state["seq"] += 1
        _bump("reset", {})
    return jsonify({"ok": True})


if __name__ == "__main__":
    print(f"[hardening-scoreboard] http://{HOST}:{PORT}/  secret set={bool(SECRET)}")
    app.run(host=HOST, port=PORT, threaded=True, debug=False)
