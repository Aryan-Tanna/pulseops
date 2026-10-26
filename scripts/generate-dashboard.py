"""Regenerate the version-controlled Grafana classic dashboard."""
import json
from pathlib import Path

panels = []
source = {"type": "prometheus", "uid": "prometheus"}


def panel(title, expr, x, y, w=6, h=5, kind="stat", unit="short", description="", legend="", thresholds=None):
    panels.append({
        "id": len(panels) + 1, "title": title, "type": kind,
        "datasource": source, "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "description": description,
        "targets": [{"refId": "A", "expr": expr, "legendFormat": legend, "range": True, "instant": kind == "stat"}],
        "fieldConfig": {"defaults": {
            "unit": unit, "color": {"mode": "palette-classic"},
            "thresholds": {"mode": "absolute", "steps": thresholds or [{"color": "green", "value": None}]},
            "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 12, "showPoints": "never", "spanNulls": False},
        }, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": "value", "graphMode": "area", "textMode": "auto", "legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
    })


rate = 'sum(rate(webapp_http_requests_total{job="webapp"}[1m]))'
error = '100 * sum(rate(webapp_http_requests_total{job="webapp",status=~"5.."}[1m])) / ' + rate
p95 = 'histogram_quantile(0.95, sum by(le)(rate(webapp_http_request_duration_seconds_bucket{job="webapp"}[1m])))'
panel("Metrics endpoint reachable (1 = yes)", 'up{job="webapp"}', 0, 0, description="Scrape success, not a guarantee that all user operations work.")
panel("Request throughput", rate, 6, 0, unit="reqps")
panel("Estimated p95 response duration", p95, 12, 0, unit="s", thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}])
panel("Server error ratio", error, 18, 0, unit="percent", description="No requests produces no meaningful percentage.", thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 10}])
panel("Throughput by endpoint", 'sum by(route)(rate(webapp_http_requests_total{job="webapp"}[1m]))', 0, 5, 12, 8, "timeseries", "reqps", legend="{{route}}")
panel("p95 response duration by endpoint", 'histogram_quantile(0.95, sum by(le,route)(rate(webapp_http_request_duration_seconds_bucket{job="webapp"}[1m])))', 12, 5, 12, 8, "timeseries", "s", legend="{{route}}")
panel("Responses by HTTP status", 'sum by(status)(rate(webapp_http_requests_total{job="webapp"}[1m]))', 0, 13, 12, 8, "timeseries", "reqps", legend="HTTP {{status}}")
panel("Server error percentage", error, 12, 13, 12, 8, "timeseries", "percent")
panel("Requests in progress", 'webapp_http_requests_in_progress{job="webapp"}', 0, 21, 8, 7, "timeseries")
panel("Tasks created", 'increase(webapp_tasks_created_total{job="webapp"}[5m])', 8, 21, 8, 7, "stat", description="Tasks created in the last five minutes; extrapolated increase may be fractional.")
panel("Firing alerts", 'sum(ALERTS{alertstate="firing"}) or vector(0)', 16, 21, 8, 7, "stat")
dashboard = {
    "uid": "pulseops", "title": "Application overview", "tags": ["pulseops", "devops", "demo"],
    "schemaVersion": 39, "version": 1, "editable": False, "timezone": "browser",
    "refresh": "5s", "time": {"from": "now-15m", "to": "now"},
    "panels": panels, "templating": {"list": []}, "annotations": {"list": []},
    "links": [{"title": "Mission control", "url": "http://localhost:9001", "targetBlank": True}],
}
destination = Path(__file__).resolve().parents[1] / "grafana/dashboards/application.json"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(dashboard, indent=2) + "\n", encoding="utf-8")
print(destination)
