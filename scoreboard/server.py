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
from typing import Any

from flask import Flask, Response, jsonify, request, send_from_directory

app = Flask(__name__, static_folder="static", static_url_path="/static")

SECRET = os.environ.get("HARDENING_SECRET", "dcig-hardening-2026").encode()
ADMIN = os.environ.get("HARDENING_ADMIN", "dcig-admin-2026")
HOST = os.environ.get("HARDENING_HOST", "0.0.0.0")
PORT = int(os.environ.get("HARDENING_PORT", "8080"))
TEAM_COUNT = max(1, int(os.environ.get("HARDENING_TEAM_COUNT", "30")))
TEAM_PREFIX = os.environ.get("HARDENING_TEAM_PREFIX", "dcig")

# Broad public hints only — category-level, no paths/ports/usernames/commands.
FINDING_CATALOG: dict[str, dict[str, dict[str, Any]]] = {
    "linux": {
        "L2-02": {"points": 10, "hint": "Removed an unused leftover account"},
        "L2-09": {"points": 10, "hint": "Removed a non-business user account"},
        "L2-06": {"points": 10, "hint": "Removed suspicious local software"},
        "L2-10": {"points": 10, "hint": "Removed unauthorized third-party software"},
        "L2-11": {"points": 10, "hint": "Cleared plaintext credentials left in user files"},
        "L2-01": {"points": 15, "hint": "Reduced privileged access for a local account"},
        "L2-07": {"points": 10, "hint": "Locked down or removed an exposed credential file"},
        "L2-03": {"points": 15, "hint": "Cleared a scheduled maintenance script and its job"},
        "L2-05": {"points": 15, "hint": "Closed an unexpected network listener"},
        "L2-08": {"points": 15, "hint": "Enabled the host firewall"},
        "L2-12": {"points": 20, "hint": "Removed a risky admin privilege exception"},
        "L2-13": {"points": 15, "hint": "Hardened remote login settings"},
        "L2-04": {"points": 20, "hint": "Stopped and disabled an unnecessary service"},
        "L2-14": {"points": 15, "hint": "Cleaned a privileged scheduled job"},
        "L2-15": {"points": 15, "hint": "Removed boot-time persistence"},
        "L2-16": {"points": 20, "hint": "Removed an unauthorized remote-trust entry"},
        "L2-17": {"points": 20, "hint": "Fixed a dangerous permission on a local tool"},
        "L2-18": {"points": 20, "hint": "Closed another unexpected network listener"},
        "L2-19": {"points": 15, "hint": "Tightened permissions on a secrets location"},
    },
    "windows": {
        "W2-02": {"points": 10, "hint": "Removed an unused leftover account"},
        "W2-09": {"points": 10, "hint": "Disabled or removed a built-in weak account"},
        "W2-07": {"points": 10, "hint": "Removed suspicious installed software"},
        "W2-10": {"points": 10, "hint": "Removed unauthorized third-party software"},
        "W2-11": {"points": 10, "hint": "Cleared plaintext credentials left on the desktop"},
        "W2-01": {"points": 15, "hint": "Reduced privileged access for a local account"},
        "W2-03": {"points": 15, "hint": "Removed a suspicious scheduled task"},
        "W2-05": {"points": 15, "hint": "Closed a risky firewall exception"},
        "W2-06": {"points": 15, "hint": "Re-enabled real-time malware protection"},
        "W2-08": {"points": 10, "hint": "Locked down or removed an exposed credential file"},
        "W2-12": {"points": 20, "hint": "Disabled automatic interactive logon with stored secrets"},
        "W2-13": {"points": 15, "hint": "Closed another risky firewall exception"},
        "W2-14": {"points": 15, "hint": "Removed excess admin rights from a support account"},
        "W2-04": {"points": 20, "hint": "Cleared a suspicious startup Run entry"},
        "W2-15": {"points": 15, "hint": "Removed a Startup-folder persistence item"},
        "W2-16": {"points": 15, "hint": "Cleared a one-time startup registry entry"},
        "W2-17": {"points": 20, "hint": "Removed a stealth scheduled task"},
        "W2-18": {"points": 25, "hint": "Stopped and disabled an unauthorized service"},
        "W2-19": {"points": 15, "hint": "Tightened permissions on an app secrets file"},
    },
}

MAX_LINUX = sum(v["points"] for v in FINDING_CATALOG["linux"].values())
MAX_WINDOWS = sum(v["points"] for v in FINDING_CATALOG["windows"].values())
MAX_TOTAL = MAX_LINUX + MAX_WINDOWS

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


def _finding_list(os_name: str, bucket: dict[str, int]) -> list[dict[str, Any]]:
    catalog = FINDING_CATALOG.get(os_name, {})
    items = []
    for fid, pts in bucket.items():
        meta = catalog.get(fid, {})
        items.append(
            {
                "id": fid,
                "points": pts,
                "hint": meta.get("hint", "Fixed a hardening issue"),
            }
        )
    items.sort(key=lambda x: x["id"])
    return items


def _display_name(team: str) -> str:
    if team.isdigit():
        return f"{TEAM_PREFIX}{int(team):02d}"
    return f"{TEAM_PREFIX}{team}"


def _team_row(team: str, data: dict[str, Any] | None) -> dict[str, Any]:
    data = data or {}
    lin_bucket = data.get("linux", {}) or {}
    win_bucket = data.get("windows", {}) or {}
    lin = sum(lin_bucket.values())
    win = sum(win_bucket.values())
    return {
        "team": team,
        "name": _display_name(team),
        "linux": lin,
        "windows": win,
        "total": lin + win,
        "linux_findings": _finding_list("linux", lin_bucket),
        "windows_findings": _finding_list("windows", win_bucket),
        "ready_linux": bool(data.get("ready", {}).get("linux")),
        "ready_windows": bool(data.get("ready", {}).get("windows")),
        "updated": data.get("updated", 0),
    }


def _team_totals() -> list[dict[str, Any]]:
    """Fixed dcig01..dcigNN rows (team order), plus any unexpected team ids."""
    known = set()
    rows = []
    for n in range(1, TEAM_COUNT + 1):
        team = f"{n:02d}"
        known.add(team)
        rows.append(_team_row(team, _state["teams"].get(team)))

    extras = []
    for team, data in _state["teams"].items():
        if team in known:
            continue
        extras.append(_team_row(team, data))
    extras.sort(key=lambda r: r["team"])
    rows.extend(extras)

    ranked = sorted(rows, key=lambda r: (-r["total"], r["team"]))
    rank_map = {r["team"]: i for i, r in enumerate(ranked, 1)}
    for r in rows:
        r["rank"] = rank_map[r["team"]]
    return rows


def _bump(kind: str, payload: dict[str, Any]) -> None:
    _state["seq"] += 1
    _state["events"].append(
        {"seq": _state["seq"], "kind": kind, "ts": time.time(), **payload}
    )
    _state["events"] = _state["events"][-200:]


def _snapshot() -> dict[str, Any]:
    return {
        "phase2_open": _state["phase2_open"],
        "frozen": _state["frozen"],
        "teams": _team_totals(),
        "seq": _state["seq"],
        "max_points": MAX_TOTAL,
        "max_linux": MAX_LINUX,
        "max_windows": MAX_WINDOWS,
        "team_prefix": TEAM_PREFIX,
        "team_count": TEAM_COUNT,
    }


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
        return jsonify(_snapshot())


@app.get("/api/stream")
def stream():
    def gen():
        last = 0
        while True:
            with _lock:
                payload = _snapshot()
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
    print(
        f"[hardening-scoreboard] http://{HOST}:{PORT}/  "
        f"max={MAX_TOTAL} (L{MAX_LINUX}+W{MAX_WINDOWS}) teams={TEAM_COUNT} secret set={bool(SECRET)}"
    )
    app.run(host=HOST, port=PORT, threaded=True, debug=False)
