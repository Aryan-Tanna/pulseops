import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_temp = tempfile.TemporaryDirectory()
os.environ["CONSOLE_DB"] = str(Path(_temp.name) / "console.db")
from console.server import app, traffic


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_webhook_is_durable(self):
        payload = {"status": "firing", "alerts": [{"labels": {"alertname": "TestAlert"}}]}
        self.assertEqual(self.client.post("/webhook", json=payload).status_code, 200)
        self.assertEqual(self.client.get("/api/notifications").json[0]["status"], "firing")

    def test_traffic_limits_and_origins(self):
        for body in ({"scenario": "arbitrary"}, {"scenario": "normal", "duration": 9999}, {"scenario": "normal", "workers": 100}, ["invalid object"]):
            self.assertEqual(self.client.post("/api/traffic", json=body).status_code, 400)
        self.assertEqual(self.client.post("/api/traffic", json={"scenario": "normal"}, headers={"Origin": "https://unrelated.example"}).status_code, 403)

    def test_repository_url_validation(self):
        for url in ("javascript:alert(1)", "https://github.com.evil.test/a/b", "https://github.com/a/b/actions"):
            self.assertEqual(self.client.post("/api/settings", json={"repository": url}).status_code, 400)
        self.assertEqual(self.client.post("/api/settings", json={"repository": "https://github.com/example/pulseops"}).status_code, 200)

    def test_task_proxy_preserves_upstream_status(self):
        with patch("console.server.remote", return_value=({"error": "offline"}, 503)):
            self.assertEqual(self.client.get("/api/tasks").status_code, 503)

    def test_concurrent_workloads_are_rejected(self):
        with traffic.lock:
            traffic.state["running"] = True
        try:
            response = self.client.post("/api/traffic", json={"scenario": "normal"})
            self.assertEqual(response.status_code, 409)
        finally:
            with traffic.lock:
                traffic.state["running"] = False
