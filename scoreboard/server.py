#!/usr/bin/env python3
"""
DCIG System Hardening — live team scoreboard.

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
import html
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
# 25 per OS: 8 easy (5), 7 medium (10), 5 hard (15), 3 very hard (20), 2 almost impossible (25).
FINDING_CATALOG: dict[str, dict[str, dict[str, Any]]] = {
    "linux": {
        "LE-01": {"points": 5, "hint": "Removed an unused leftover account"},
        "LE-02": {"points": 5, "hint": "Removed a non-business user account"},
        "LE-03": {"points": 5, "hint": "Removed a suspicious tool from a system PATH location"},
        "LE-04": {"points": 5, "hint": "Removed unauthorized software under /opt"},
        "LE-05": {"points": 5, "hint": "Cleared plaintext secrets left in a user home folder"},
        "LE-06": {"points": 5, "hint": "Removed a world-readable password list from a temp directory"},
        "LE-07": {"points": 5, "hint": "Closed an unexpected TCP listener"},
        "LE-08": {"points": 5, "hint": "Enabled the host firewall"},
        "LM-01": {"points": 10, "hint": "Removed sudo-group membership from an extra account"},
        "LM-02": {"points": 10, "hint": "Cleared a cron.d job and the script it runs"},
        "LM-03": {"points": 10, "hint": "Removed a sudoers drop-in that granted full root"},
        "LM-04": {"points": 10, "hint": "Turned off SSH login as root"},
        "LM-05": {"points": 10, "hint": "Locked down or removed an exposed credential file"},
        "LM-06": {"points": 10, "hint": "Stopped and disabled an unnecessary systemd service"},
        "LM-07": {"points": 10, "hint": "Tightened permissions on a secrets directory"},
        "LH-01": {"points": 15, "hint": "Cleaned a privileged root crontab entry"},
        "LH-02": {"points": 15, "hint": "Removed boot-time rc.local persistence"},
        "LH-03": {"points": 15, "hint": "Removed an unauthorized SSH trust key for root"},
        "LH-04": {"points": 15, "hint": "Removed a setuid bit from a local tool"},
        "LH-05": {"points": 15, "hint": "Closed a second unexpected TCP listener"},
        "LV-01": {"points": 20, "hint": "Removed a file capability that allows privilege gain"},
        "LV-02": {"points": 20, "hint": "Disabled a hidden systemd timer"},
        "LV-03": {"points": 20, "hint": "Removed a sudoers rule for an account that is not in the sudo group"},
        "LI-01": {"points": 25, "hint": "Removed a hidden, immutable script from a cron directory"},
        "LI-02": {"points": 25, "hint": "Removed or locked a system-looking account that has a real login shell"},
    },
    "windows": {
        "WE-01": {"points": 5, "hint": "Disabled or removed the built-in Guest account"},
        "WE-02": {"points": 5, "hint": "Removed a temporary vendor account"},
        "WE-03": {"points": 5, "hint": "Removed a program from the all-users Startup folder"},
        "WE-04": {"points": 5, "hint": "Removed or locked down an overly open SMB share"},
        "WE-05": {"points": 5, "hint": "Removed a plaintext password file from a public folder"},
        "WE-06": {"points": 5, "hint": "Removed an extra line from the hosts file"},
        "WE-07": {"points": 5, "hint": "Closed a risky inbound firewall exception"},
        "WE-08": {"points": 5, "hint": "Removed unauthorized software from Program Files"},
        "WM-01": {"points": 10, "hint": "Removed excess Administrators membership"},
        "WM-02": {"points": 10, "hint": "Required Network Level Authentication for Remote Desktop"},
        "WM-03": {"points": 10, "hint": "Turned real-time antivirus protection back on"},
        "WM-04": {"points": 10, "hint": "Cleared a policy that lets any user install as admin"},
        "WM-05": {"points": 10, "hint": "Turned off automatic logon and its stored password"},
        "WM-06": {"points": 10, "hint": "Stopped the Remote Registry service from starting automatically"},
        "WM-07": {"points": 10, "hint": "Tightened permissions on a sensitive shared file"},
        "WH-01": {"points": 15, "hint": "Turned off cleartext credential caching"},
        "WH-02": {"points": 15, "hint": "Restricted anonymous access to account names"},
        "WH-03": {"points": 15, "hint": "Raised the LAN Manager authentication level"},
        "WH-04": {"points": 15, "hint": "Fixed or removed a service with an unquoted path"},
        "WH-05": {"points": 15, "hint": "Stopped and disabled an unauthorized service"},
        "WV-01": {"points": 20, "hint": "Removed a scheduled task disguised as Windows maintenance"},
        "WV-02": {"points": 20, "hint": "Removed an extra program from the Winlogon userinit value"},
        "WV-03": {"points": 20, "hint": "Blocked anonymous null-session access to shares"},
        "WI-01": {"points": 25, "hint": "Cleared a debugger hijack on a second accessibility program"},
        "WI-02": {"points": 25, "hint": "Removed a machine startup script from local Group Policy"},
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


@app.get("/lite")
def lite():
    """Server-rendered board for IE11 (Server 2019 default browser): no JavaScript."""
    with _lock:
        snap = _snapshot()
    if snap["frozen"]:
        state = "FROZEN"
    elif snap["phase2_open"]:
        state = "OPEN"
    else:
        state = "not open yet"
    rows = "".join(
        "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td><b>{}</b></td></tr>".format(
            r["rank"], html.escape(r["name"]), r["linux"], r["windows"], r["total"]
        )
        for r in sorted(snap["teams"], key=lambda r: r["rank"])
    )
    page = (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta http-equiv="X-UA-Compatible" content="IE=edge">'
        '<meta http-equiv="refresh" content="15"><title>DCIG Scoreboard</title>'
        "<style>body{font-family:Segoe UI,Arial,sans-serif;background:#0b1220;color:#e8eefc;margin:24px}"
        "table{border-collapse:collapse}th,td{padding:4px 16px;border-bottom:1px solid #24304a;text-align:left}"
        "th{color:#8b9bb8}</style></head><body>"
        "<h1>DCIG Hardening Scoreboard</h1>"
        f"<p>Phase 2: <b>{state}</b> &middot; max {snap['max_points']} points &middot; refreshes every 15 s</p>"
        "<table><tr><th>#</th><th>Team</th><th>Linux</th><th>Windows</th><th>Total</th></tr>"
        f"{rows}</table></body></html>"
    )
    return Response(page, mimetype="text/html")


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
