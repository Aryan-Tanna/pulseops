"""End-to-end rehearsal: real traffic, firing notifications, recovery, and latency.

Run after START.cmd. Usually takes 4–7 minutes. A JSON evidence report is saved.
"""
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

BASE = "http://localhost:9001"
evidence = []


def call(path, method="GET", body=None):
    request = Request(BASE + path, data=json.dumps(body or {}).encode() if method != "GET" else None, method=method, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=15) as response:
        return json.load(response)


def wait(predicate, description, timeout=150):
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        if predicate():
            elapsed = round(time.monotonic() - started, 1)
            print(f"PASS {description} ({elapsed}s)", flush=True)
            evidence.append({"check": description, "seconds_waited": elapsed, "passed": True})
            return
        time.sleep(3)
    raise RuntimeError(f"Timed out: {description}")


def alert_delivered(name, status, after):
    return any(item["id"] > after and item.get("status") == status and any(a.get("labels", {}).get("alertname") == name for a in item.get("alerts", [])) for item in call("/api/notifications"))


def stop():
    call("/api/traffic", "DELETE")
    wait(lambda: not call("/api/traffic")["running"], "Workload stopped", 15)


def marker():
    return max((item["id"] for item in call("/api/notifications")), default=0)


def scenario(mode, alert):
    last = marker()
    call("/api/traffic", "POST", {"scenario": mode, "duration": 180, "workers": 4})
    wait(lambda: alert_delivered(alert, "firing", last), f"{alert}: actual firing webhook delivered")
    metrics = call("/api/metrics")
    evidence.append({"scenario": mode, "metrics": metrics})
    stop()
    last = marker()
    call("/api/traffic", "POST", {"scenario": "normal", "duration": 180, "workers": 4})
    wait(lambda: alert_delivered(alert, "resolved", last), f"{alert}: actual resolved webhook delivered")
    stop()


def main():
    status = call("/api/status")
    if not all(status["services"].values()):
        raise RuntimeError("Start all services before rehearsing")
    if status["traffic"]["running"]:
        raise RuntimeError("Stop the current workload before rehearsing")
    # Exercise real app CRUD through the independent console.
    task = call("/api/tasks", "POST", {"title": "Automated end-to-end rehearsal", "priority": "low"})
    call(f"/api/tasks/{task['id']}", "PATCH", {"done": True})
    call(f"/api/tasks/{task['id']}", "DELETE")
    evidence.append({"check": "Task CRUD through console", "passed": True})
    try:
        scenario("error", "HighServerErrorRate")
        scenario("slow", "HighResponseLatency")
    finally:
        call("/api/traffic", "DELETE")


if __name__ == "__main__":
    report = Path(__file__).resolve().parents[1] / ".runtime/rehearsal.json"
    report.parent.mkdir(exist_ok=True)
    try:
        main()
    except Exception as exc:
        evidence.append({"passed": False, "error": str(exc)})
        raise
    finally:
        report.write_text(json.dumps({"checked_at": datetime.now(timezone.utc).isoformat(), "results": evidence}, indent=2), encoding="utf-8")
