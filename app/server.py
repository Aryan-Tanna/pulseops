"""A real SQLite task application with Prometheus request instrumentation."""
import os
import sqlite3
import time
from contextlib import closing, contextmanager
from pathlib import Path

from flask import Flask, Response, g, jsonify, render_template, request
from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST


def create_app(database=None):
    root = Path(__file__).resolve().parents[1]
    app = Flask(__name__, template_folder=str(root / "web"), static_folder=str(root / "web/static"))
    app.config["DATABASE"] = database or os.getenv("APP_DB", "/data/tasks.db")
    app.config["MAX_CONTENT_LENGTH"] = 16 * 1024
    app.config["DEMO_ENABLED"] = os.getenv("DEMO_ENABLED", "true").lower() == "true"
    registry = CollectorRegistry()
    requests = Counter("webapp_http_requests_total", "Completed application requests", ["method", "route", "status"], registry=registry)
    latency = Histogram("webapp_http_request_duration_seconds", "Application response time", ["route"], buckets=(.01, .05, .1, .25, .5, 1, 1.5, 2, 3, 5), registry=registry)
    active = Gauge("webapp_http_requests_in_progress", "Requests currently executing", registry=registry)
    created = Counter("webapp_tasks_created_total", "Tasks created through the API", registry=registry)
    info = Gauge("webapp_build_info", "Deployed application version", ["version", "commit"], registry=registry)
    info.labels(os.getenv("APP_VERSION", "1.0.0"), os.getenv("COMMIT_SHA", "local")).set(1)
    # Pre-initialize error series so zero errors is observable before the first 500.
    for route in ("/api/tasks", "/demo/normal", "/demo/slow", "/demo/error"):
        for status in ("200", "500"):
            requests.labels("GET", route, status)

    @contextmanager
    def connection():
        with closing(sqlite3.connect(app.config["DATABASE"], timeout=5)) as db:
            db.row_factory = sqlite3.Row
            with db:
                yield db

    Path(app.config["DATABASE"]).parent.mkdir(parents=True, exist_ok=True)
    with connection() as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY, title TEXT NOT NULL, priority TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
        db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT)")
        if not db.execute("SELECT 1 FROM metadata WHERE key='seeded'").fetchone():
            db.executemany("INSERT INTO tasks(title,priority,done) VALUES (?,?,?)", [
                ("Instrument the task API", "high", 1),
                ("Build the Grafana dashboard", "high", 0),
                ("Rehearse the failure and recovery demo", "medium", 0),
            ])
            db.execute("INSERT INTO metadata VALUES ('seeded','true')")

    @app.before_request
    def before():
        if request.path not in ("/metrics", "/health", "/api/version") and not request.path.startswith("/static/"):
            g.started = time.perf_counter()
            active.inc()

    @app.after_request
    def after(response):
        if hasattr(g, "started"):
            route = request.url_rule.rule if request.url_rule else "unmatched"
            if route == "/demo/<scenario>" and request.view_args.get("scenario") in ("normal", "slow", "error"):
                route = "/demo/" + request.view_args["scenario"]
            requests.labels(request.method, route, str(response.status_code)).inc()
            latency.labels(route).observe(time.perf_counter() - g.started)
            active.dec()
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.get("/")
    def index():
        return render_template("application.html")

    @app.get("/health")
    def health():
        with connection() as db:
            db.execute("SELECT 1 FROM tasks LIMIT 1")
        return jsonify(status="ok")

    @app.get("/api/version")
    def version():
        return jsonify(version=os.getenv("APP_VERSION", "1.0.0"), commit=os.getenv("COMMIT_SHA", "local"), environment="Local demo")

    @app.get("/metrics")
    def metrics():
        return Response(generate_latest(registry), content_type=CONTENT_TYPE_LATEST)

    @app.get("/api/tasks")
    def list_tasks():
        with connection() as db:
            return jsonify([dict(row) for row in db.execute("SELECT * FROM tasks ORDER BY done,id DESC")])

    @app.post("/api/tasks")
    def add_task():
        data = request.get_json(silent=True) or {}
        if not isinstance(data, dict):
            return jsonify(error="Expected a JSON object"), 400
        title = data.get("title")
        priority = data.get("priority", "medium")
        if not isinstance(title, str) or not title.strip() or len(title.strip()) > 160 or priority not in ("low", "medium", "high"):
            return jsonify(error="Enter a title of 1–160 characters and a valid priority."), 400
        with connection() as db:
            cursor = db.execute("INSERT INTO tasks(title,priority) VALUES (?,?)", (title.strip(), priority))
            task_id = cursor.lastrowid
        created.inc()
        return jsonify(id=task_id, title=title.strip(), priority=priority, done=0), 201

    @app.patch("/api/tasks/<int:task_id>")
    def update_task(task_id):
        data = request.get_json(silent=True) or {}
        if not isinstance(data, dict):
            return jsonify(error="Expected a JSON object"), 400
        if type(data.get("done")) is not bool:
            return jsonify(error="done must be true or false"), 400
        with connection() as db:
            count = db.execute("UPDATE tasks SET done=? WHERE id=?", (int(data["done"]), task_id)).rowcount
        return (jsonify(ok=True), 200) if count else (jsonify(error="Task not found"), 404)

    @app.delete("/api/tasks/<int:task_id>")
    def delete_task(task_id):
        with connection() as db:
            count = db.execute("DELETE FROM tasks WHERE id=?", (task_id,)).rowcount
        return (jsonify(ok=True), 200) if count else (jsonify(error="Task not found"), 404)

    @app.get("/demo/<scenario>")
    def demo(scenario):
        if not app.config["DEMO_ENABLED"]:
            return jsonify(error="Demo endpoints disabled"), 404
        if scenario not in ("normal", "slow", "error"):
            return jsonify(error="Unknown scenario"), 404
        # Explicit route names keep a small, bounded metric label set.
        if scenario == "slow":
            time.sleep(1.6)
        return jsonify(scenario=scenario, simulated=True), 500 if scenario == "error" else 200

    return app


app = create_app()
