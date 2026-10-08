#!/usr/bin/env python3
"""
DCIG System Hardening — live team scoreboard.

  export HARDENING_SECRET='change-me'
  export HARDENING_ADMIN='change-me-admin'
  pip install -r requirements.txt
  python server.py

Projector: http://<host>:8080/
Agents POST signed finding updates to /api/score

Phase 2 scoring model (per machine):
  8 Easy (5) + 7 Medium (10) + 5 Hard (15) + 3 Very Hard (20) + 2 Almost
  Impossible (25) = 295 points per machine, 590 points for the pair.
Point values are the single source of truth here; score agents and the
ANSWER_KEY must match these exactly (an agent POST whose points disagree with
the catalog is rejected).
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

# Difficulty tiers (ascending). Point value is fixed per tier so every machine
# lands on 8*5 + 7*10 + 5*15 + 3*20 + 2*25 = 295.
TIER_POINTS: dict[str, int] = {
    "easy": 5,
    "medium": 10,
    "hard": 15,
    "very_hard": 20,
    "almost_impossible": 25,
}
TIER_ORDER = list(TIER_POINTS.keys())
TIER_LABELS: dict[str, str] = {
    "easy": "Easy",
    "medium": "Medium",
    "hard": "Hard",
    "very_hard": "Very Hard",
    "almost_impossible": "Almost Impossible",
}


def _e(fid, tier, hint):
    return fid, {"points": TIER_POINTS[tier], "tier": tier, "hint": hint}


# Broad public hints only — category-level, no paths/ports/usernames/commands.
# Order follows difficulty (easy -> almost impossible) within each OS.
FINDING_CATALOG: dict[str, dict[str, dict[str, Any]]] = {
    "linux": dict(
        [
            # --- EASY (8 x 5) ---
            _e("LE1", "easy", "Removed an unused leftover account"),
            _e("LE2", "easy", "Removed a non-business user account"),
            _e("LE3", "easy", "Removed a suspicious tool from a system PATH location"),
            _e("LE4", "easy", "Removed unauthorized software under /opt"),
            _e("LE5", "easy", "Cleared plaintext secrets left in a home folder"),
            _e("LE6", "easy", "Fixed overly open home-directory permissions"),
            _e("LE7", "easy", "Removed or secured a world-readable account-database backup"),
            _e("LE8", "easy", "Locked down or removed an exposed private key"),
            # --- MEDIUM (7 x 10) ---
            _e("LM1", "medium", "Reduced sudo privileges for a local account"),
            _e("LM2", "medium", "Removed a risky sudoers drop-in"),
            _e("LM3", "medium", "Cleared a cron.d job and its companion script"),
            _e("LM4", "medium", "Removed an insecure host-trust configuration"),
            _e("LM5", "medium", "Closed an unexpected TCP listener"),
            _e("LM6", "medium", "Locked down or removed an exposed credential file"),
            _e("LM7", "medium", "Disabled empty-password SSH logins"),
            # --- HARD (5 x 15) ---
            _e("LH1", "hard", "Stopped and disabled an unnecessary systemd service"),
            _e("LH2", "hard", "Removed boot-time rc.local persistence"),
            _e("LH3", "hard", "Tightened permissions on a secrets directory"),
            _e("LH4", "hard", "Closed another unexpected TCP listener"),
            _e("LH5", "hard", "Cleaned a privileged root crontab entry"),
            # --- VERY HARD (3 x 20) ---
            _e("LV1", "very_hard", "Fixed a dangerous SUID binary"),
            _e("LV2", "very_hard", "Removed an unauthorized SSH trust entry for root"),
            _e("LV3", "very_hard", "Removed a second UID 0 (root-equivalent) account"),
            # --- ALMOST IMPOSSIBLE (2 x 25) ---
            _e("LX1", "almost_impossible", "Removed a hidden Linux capability privilege backdoor"),
            _e("LX2", "almost_impossible", "Removed a login-time root persistence script"),
        ]
    ),
    "windows": dict(
        [
            # --- EASY (8 x 5) ---
            _e("WE1", "easy", "Disabled or removed the built-in Guest account"),
            _e("WE2", "easy", "Removed a leftover temporary vendor account"),
            _e("WE3", "easy", "Re-enabled User Account Control"),
            _e("WE4", "easy", "Locked down or removed an overly open SMB share"),
            _e("WE5", "easy", "Required SMB message signing"),
            _e("WE6", "easy", "Cleared an accessibility-feature debugger hijack"),
            _e("WE7", "easy", "Disabled the legacy SMBv1 protocol"),
            _e("WE8", "easy", "Turned the host firewall back on"),
            # --- MEDIUM (7 x 10) ---
            _e("WM1", "medium", "Removed excess Administrators membership"),
            _e("WM2", "medium", "Required Network Level Authentication for RDP"),
            _e("WM3", "medium", "Closed a risky inbound firewall exception"),
            _e("WM4", "medium", "Disabled the AlwaysInstallElevated installer policy"),
            _e("WM5", "medium", "Hardened the Remote Registry service startup"),
            _e("WM6", "medium", "Disabled WDigest cleartext credential caching"),
            _e("WM7", "medium", "Disabled LLMNR name resolution"),
            # --- HARD (5 x 15) ---
            _e("WH1", "hard", "Tightened anonymous SAM / network enumeration settings"),
            _e("WH2", "hard", "Raised the LAN Manager authentication level"),
            _e("WH3", "hard", "Disallowed unencrypted WinRM traffic"),
            _e("WH4", "hard", "Tightened ACLs on a sensitive shared file"),
            _e("WH5", "hard", "Disabled automatic interactive logon with stored secrets"),
            # --- VERY HARD (3 x 20) ---
            _e("WV1", "very_hard", "Fixed or removed an unquoted service path"),
            _e("WV2", "very_hard", "Stopped and disabled an unauthorized Windows service"),
            _e("WV3", "very_hard", "Removed a hidden scheduled-task persistence"),
            # --- ALMOST IMPOSSIBLE (2 x 25) ---
            _e("WX1", "almost_impossible", "Removed a WMI event-subscription persistence"),
            _e("WX2", "almost_impossible", "Removed a hidden administrator account"),
        ]
    ),
}


def _max_for(os_name: str) -> int:
    return sum(v["points"] for v in FINDING_CATALOG[os_name].values())


def _tier_breakdown(os_name: str) -> dict[str, dict[str, int]]:
    out: dict[str, dict[str, int]] = {
        t: {"count": 0, "points": TIER_POINTS[t], "max": 0} for t in TIER_ORDER
    }
    for v in FINDING_CATALOG[os_name].values():
        t = v["tier"]
        out[t]["count"] += 1
        out[t]["max"] += v["points"]
    return out


MAX_LINUX = _max_for("linux")
MAX_WINDOWS = _max_for("windows")
MAX_TOTAL = MAX_LINUX + MAX_WINDOWS
TIER_BREAKDOWN = {"linux": _tier_breakdown("linux"), "windows": _tier_breakdown("windows")}

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
    # Preserve catalog (difficulty) order so fixes group easy -> hard.
    order = {fid: i for i, fid in enumerate(catalog.keys())}
    items = []
    for fid, pts in bucket.items():
        meta = catalog.get(fid, {})
        tier = meta.get("tier", "")
        items.append(
            {
                "id": fid,
                "points": pts,
                "tier": tier,
                "tier_label": TIER_LABELS.get(tier, ""),
                "hint": meta.get("hint", "Fixed a hardening issue"),
            }
        )
    items.sort(key=lambda x: order.get(x["id"], 999))
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
        "tier_breakdown": TIER_BREAKDOWN,
        "tier_labels": TIER_LABELS,
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
        f"<p>Phase 2: <b>{state}</b> &middot; max {snap['max_points']} points "
        f"(L{snap['max_linux']} + W{snap['max_windows']}) &middot; refreshes every 15 s</p>"
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

    # Points integrity: the finding must be known and carry its catalog value.
    # This keeps per-tier / per-machine / team totals exactly on the model.
    meta = FINDING_CATALOG.get(os_name, {}).get(finding_id)
    if meta is None:
        return jsonify({"ok": False, "error": "unknown finding"}), 400
    if points != meta["points"]:
        return jsonify({"ok": False, "error": "points mismatch"}), 400

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
