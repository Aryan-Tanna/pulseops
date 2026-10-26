"""Independent demo console, bounded traffic generator and durable webhook inbox.

No Docker socket, shell execution, or arbitrary request destinations are exposed.
"""
import concurrent.futures
import json
import os
import sqlite3
import threading
import time
from datetime import datetime, timezone
from contextlib import closing, contextmanager
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

from flask import Flask, jsonify, render_template, request


ROOT = Path(__file__).resolve().parents[1]
APP_URL = os.getenv("APP_URL", "http://app:8000")
PROM_URL = os.getenv("PROM_URL", "http://prometheus:9090")
ALERT_URL = os.getenv("ALERT_URL", "http://alertmanager:9093")
GRAFANA_URL = os.getenv("GRAFANA_URL", "http://grafana:3000")
DB_PATH = os.getenv("CONSOLE_DB", "/data/console.db")
app = Flask(__name__, template_folder=str(ROOT / "web"), static_folder=str(ROOT / "web/static"))
app.config["MAX_CONTENT_LENGTH"] = 256 * 1024
Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)


@contextmanager
def database():
    with closing(sqlite3.connect(DB_PATH, timeout=5)) as db:
        db.row_factory = sqlite3.Row
        with db:
            yield db


with database() as db:
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS notifications (id INTEGER PRIMARY KEY, received_at TEXT, payload TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)")


def remote(url, method="GET", payload=None, timeout=3):
    body = json.dumps(payload).encode() if payload is not None else None
    req = Request(url, data=body, method=method, headers={"Content-Type": "application/json"})
    try:
        with urlopen(req, timeout=timeout) as response:
            return json.load(response), response.status
    except HTTPError as exc:
        try:
            return json.loads(exc.read()), exc.code
        except (ValueError, UnicodeError):
            return {"error": f"Upstream HTTP {exc.code}"}, exc.code
        finally:
            exc.close()
    except (URLError, TimeoutError, OSError, ValueError) as exc:
        return {"error": "Service unreachable", "detail": str(exc)[:140]}, 503


class TrafficGenerator:
    def __init__(self):
        self.lock = threading.Lock()
        self.cancel = threading.Event()
        self.state = {"running": False, "scenario": "idle", "sent": 0, "failed": 0, "duration": 0, "started": 0, "workers": 0}

    def snapshot(self):
        with self.lock:
            result = dict(self.state)
        result["remaining"] = max(0, round(result["duration"] - (time.monotonic() - result["started"]))) if result["running"] else 0
        return result

    def start(self, scenario, duration, workers):
        with self.lock:
            if self.state["running"]:
                return False
            self.cancel = threading.Event()
            self.state = {"running": True, "scenario": scenario, "sent": 0, "failed": 0, "duration": duration, "started": time.monotonic(), "workers": workers}
            event = self.cancel
        threading.Thread(target=self.run, args=(scenario, duration, workers, event), daemon=True).start()
        return True

    def run(self, scenario, duration, workers, event):
        deadline = time.monotonic() + duration
        def worker():
            while not event.is_set() and time.monotonic() < deadline:
                _, status = remote(f"{APP_URL}/demo/{scenario}", timeout=4)
                with self.lock:
                    self.state["sent"] += 1
                    self.state["failed"] += int(status >= 400)
                event.wait(.2)
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                list(pool.map(lambda _: worker(), range(workers)))
        finally:
            with self.lock:
                self.state["running"] = False

    def stop(self):
        self.cancel.set()


traffic = TrafficGenerator()


@app.before_request
def same_origin_mutations():
    # Browsers cannot trigger local demo operations from an unrelated website.
    if request.method in ("POST", "PATCH", "DELETE") and request.path != "/webhook":
        origin = request.headers.get("Origin")
        if origin and origin != request.host_url.rstrip("/"):
            return jsonify(error="Cross-origin request rejected"), 403
        if not request.is_json:
            return jsonify(error="Use application/json"), 415


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.route("/api/tasks", methods=["GET", "POST"])
@app.route("/api/tasks/<int:task_id>", methods=["PATCH", "DELETE"])
def tasks(task_id=None):
    path = "/api/tasks" + (f"/{task_id}" if task_id is not None else "")
    payload = request.get_json(silent=True) if request.method != "GET" else None
    data, status = remote(APP_URL + path, request.method, payload)
    return jsonify(data), status


@app.get("/api/status")
def status():
    services = {"app": (APP_URL + "/health"), "prometheus": PROM_URL + "/-/ready", "grafana": GRAFANA_URL + "/api/health", "alertmanager": ALERT_URL + "/-/ready"}
    def check(item):
        name, url = item
        try:
            with urlopen(url, timeout=2) as response:
                return name, response.status == 200
        except (OSError, URLError):
            return name, False
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        healths = dict(pool.map(check, services.items()))
    version, _ = remote(APP_URL + "/api/version")
    alerts, _ = remote(PROM_URL + "/api/v1/alerts")
    with database() as db:
        row = db.execute("SELECT value FROM settings WHERE key='repository'").fetchone()
    return jsonify(services=healths, version=version, traffic=traffic.snapshot(), alerts=alerts.get("data", {}).get("alerts", []), repository=row[0] if row else "", checked_at=datetime.now(timezone.utc).isoformat())


@app.get("/api/metrics")
def metrics():
    queries = {
        "rps": 'sum(rate(webapp_http_requests_total{job="webapp"}[1m]))',
        "errors": '100 * sum(rate(webapp_http_requests_total{job="webapp",status=~"5.."}[1m])) / sum(rate(webapp_http_requests_total{job="webapp"}[1m]))',
        "latency": 'histogram_quantile(0.95, sum by(le)(rate(webapp_http_request_duration_seconds_bucket{job="webapp"}[1m])))',
        "active": 'sum(webapp_http_requests_in_progress{job="webapp"})',
    }
    def query(item):
        key, expr = item
        data, status = remote(PROM_URL + "/api/v1/query?" + urlencode({"query": expr}))
        result = data.get("data", {}).get("result", [])
        value = result[0]["value"][1] if result else None
        if value in ("NaN", "+Inf", "-Inf"):
            value = None
        return key, {"value": float(value) if value is not None else None, "ok": status == 200}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        return jsonify(dict(pool.map(query, queries.items())))


@app.route("/api/traffic", methods=["GET", "POST", "DELETE"])
def traffic_api():
    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        if not isinstance(data, dict):
            return jsonify(error="Expected a JSON object"), 400
        scenario, duration, workers = data.get("scenario"), data.get("duration", 120), data.get("workers", 4)
        if scenario not in ("normal", "slow", "error") or type(duration) is not int or not 10 <= duration <= 300 or type(workers) is not int or not 1 <= workers <= 6:
            return jsonify(error="Choose normal/slow/error, 10–300 seconds, and 1–6 workers."), 400
        if not traffic.start(scenario, duration, workers):
            return jsonify(error="Stop the current workload before starting another."), 409
    elif request.method == "DELETE":
        traffic.stop()
    return jsonify(traffic.snapshot())


@app.post("/webhook")
def webhook():
    data = request.get_json(silent=True)
    if not isinstance(data, dict) or not isinstance(data.get("alerts"), list):
        return jsonify(error="Invalid Alertmanager payload"), 400
    with database() as db:
        db.execute("INSERT INTO notifications(received_at,payload) VALUES (?,?)", (datetime.now(timezone.utc).isoformat(), json.dumps(data)))
        db.execute("DELETE FROM notifications WHERE id NOT IN (SELECT id FROM notifications ORDER BY id DESC LIMIT 200)")
    return jsonify(ok=True)


@app.get("/api/notifications")
def notifications():
    with database() as db:
        rows = db.execute("SELECT * FROM notifications ORDER BY id DESC LIMIT 50").fetchall()
    return jsonify([{"id": row["id"], "received_at": row["received_at"], **json.loads(row["payload"])} for row in rows])


@app.post("/api/settings")
def settings():
    data = request.get_json(silent=True) or {}
    if not isinstance(data, dict):
        return jsonify(error="Expected a JSON object"), 400
    url = data.get("repository", "")
    if not isinstance(url, str):
        return jsonify(error="Repository must be a URL"), 400
    parsed = urlparse(url)
    segments = parsed.path.strip("/").split("/")
    if url and (parsed.scheme != "https" or parsed.netloc != "github.com" or len(segments) != 2 or not all(segments) or parsed.query or parsed.fragment):
        return jsonify(error="Use https://github.com/owner/repository"), 400
    with database() as db:
        db.execute("INSERT INTO settings VALUES ('repository',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (url.rstrip("/"),))
    return jsonify(ok=True)
