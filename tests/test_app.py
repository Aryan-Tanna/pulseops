import os
import tempfile
import unittest
from pathlib import Path

_temp = tempfile.TemporaryDirectory()
os.environ["APP_DB"] = str(Path(_temp.name) / "default.db")
from app.server import create_app


class ApplicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = create_app(str(Path(self.temp.name) / "tasks.db"))
        self.client = self.app.test_client()

    def tearDown(self):
        self.temp.cleanup()

    def test_task_lifecycle_and_persistence(self):
        response = self.client.post("/api/tasks", json={"title": "Demo assignment", "priority": "high"})
        self.assertEqual(response.status_code, 201)
        task_id = response.json["id"]
        self.assertEqual(self.client.patch(f"/api/tasks/{task_id}", json={"done": True}).status_code, 200)
        other = create_app(self.app.config["DATABASE"]).test_client()
        saved = next(t for t in other.get("/api/tasks").json if t["id"] == task_id)
        self.assertEqual(saved["done"], 1)
        self.assertEqual(other.delete(f"/api/tasks/{task_id}").status_code, 200)
        self.assertEqual(other.patch(f"/api/tasks/{task_id}", json={"done": True}).status_code, 404)

    def test_validation_and_sql_text(self):
        for payload in ({"title": ""}, {"title": "x", "priority": "invalid"}, {"title": ["bad"]}, ["invalid object"]):
            self.assertEqual(self.client.post("/api/tasks", json=payload).status_code, 400)
        self.assertEqual(self.client.post("/api/tasks", json={"title": "Robert'); DROP TABLE tasks;--"}).status_code, 201)
        self.assertEqual(self.client.get("/health").status_code, 200)
        self.assertEqual(self.client.patch("/api/tasks/1", json={"done": "false"}).status_code, 400)

    def test_failed_requests_are_instrumented_and_metrics_excluded(self):
        self.client.get("/demo/error")
        self.client.get("/health")
        self.client.get("/metrics")
        body = self.client.get("/metrics").text
        self.assertIn('status="500"} 1.0', body)
        self.assertNotIn('route="/metrics"', body)
        self.assertNotIn('route="/health"', body)
        self.assertIn("webapp_http_request_duration_seconds_bucket", body)

    def test_metric_labels_use_template_for_task_ids(self):
        for number in (1, 2, 9876):
            self.client.patch(f"/api/tasks/{number}", json={"done": True})
        metrics = self.client.get("/metrics").text
        self.assertIn('route="/api/tasks/<int:task_id>"', metrics)
        self.assertNotIn('route="/api/tasks/9876"', metrics)

    def test_demo_endpoints_can_be_disabled(self):
        self.app.config["DEMO_ENABLED"] = False
        self.assertEqual(self.client.get("/demo/error").status_code, 404)


if __name__ == "__main__":
    unittest.main()
