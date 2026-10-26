# PulseOps — a local CI/CD and observability laboratory

**Project:** Automated CI/CD, Performance Monitoring and Alerting of a Containerized Web Application Using GitHub Actions, Prometheus and Grafana.

A working SQLite task application, independent presentation console, real HTTP traffic generator, pre-provisioned Grafana dashboard, Prometheus rules, durable Alertmanager webhook inbox, versioned deployment and rollback. Runs on one Windows laptop using Docker Desktop with Linux containers. No GCP account is required.

## Start

Double-click **START.cmd**. The first run downloads images, generates a local Grafana password, builds the project, runs tests, validates configuration, starts the services, checks readiness and opens the console. Docker Desktop must be installed; complete its first-run WSL/license prompts if shown. Allow several minutes for the first downloads.

Subsequent starts reuse downloaded dependencies and persistent volumes. Unchanged sources reuse the local images, so the local demonstration can start offline after the first successful setup. Source changes trigger a rebuild; use deploy.ps1 for a versioned application release. Startup never rebuilds into a retained commit-tagged application image. No Python installation is required for the Docker launch.

| Screen | URL |
| --- | --- |
| Presentation console | http://localhost:9001 |
| Standalone task application | http://localhost:8000 |
| Grafana dashboard | http://localhost:3000/d/pulseops/application-overview |
| Prometheus | http://localhost:9090 |
| Alertmanager | http://localhost:9093 |

Grafana permits anonymous **read-only Viewer** access on the loopback-bound demo port. To edit, log in as `admin` using the generated password in the ignored `.env` file. The dashboard is provisioned from source, so edit its source JSON rather than saving UI changes.

## The few manual actions

1. Complete any Docker Desktop first-run prompts if necessary.
2. For GitHub CI/CD, double-click **CONNECT-GITHUB.cmd** and complete the one-time GitHub device sign-in. The helper downloads checksum-verified official CLI/runner archives, creates a private `pulseops` repository under the signed-in account if needed, commits/pushes the project, registers a runner, configures repository variables, saves the console link and dispatches the first deployment. It refuses a public repository and never force-pushes existing history.
3. During the presentation, use the console's traffic buttons and switch to Grafana / GitHub Actions. The two prepared outage commands are below.

GitHub setup is optional for local monitoring but necessary before demonstrating an actual GitHub Actions run. Workflow files alone are not proof that CI/CD ran. GitHub requires internet access. After a reboot, START.cmd automatically reconnects the registered runner in the background; it does not install a Windows service. You do not need to repeat the GitHub connection helper for routine starts.

Use `scripts/connect-github.ps1 -Repository owner/name` to select an existing private repository. The repository must have compatible history and use `main`. The helper does not grant new organizational permissions or change repository visibility. GitHub CLI authentication uses your normal credential storage; tokens are not written into project source.

## Demo flow

Read [the presentation script](docs/DEMO.md). Start normal traffic, observe real metrics, run an error or slow workload for two minutes, show the firing webhook, then run normal traffic and show the resolved webhook. Stopping traffic does not instantly clear a one-minute metric window.

```powershell
# Run these from this directory. Monitoring and console remain online.
.\scripts\outage.ps1 -Action Stop
.\scripts\outage.ps1 -Action Start

# Deploy the current local code as a retained release.
.\scripts\deploy.ps1

# Restore the previous image after a successful deployment.
.\scripts\rollback.ps1

# Stop without deleting tasks, dashboards, incidents or metric history.
.\scripts\stop.ps1
```

Avoid `docker compose down -v` unless you intentionally want to delete the project's persistent data. START.cmd handles the release override automatically; use the provided scripts to operate deployed releases consistently.

## Real delivery pipeline

- Pull requests run application tests and monitoring validation on a GitHub-hosted Linux runner.
- Pushes to `main` (or a manual dispatch) run the local deployment workflow once `PULSEOPS_RUNNER_READY=true`.
- The Windows self-hosted runner builds an image tagged with the commit SHA and tests that exact image.
- Deployment validates monitoring, updates only the app service, checks readiness and verifies the running version/commit. Monitoring and the console stay running.
- A failed deployment attempts to restore the previous image and leaves the workflow failed.
- The previous successful image is retained for the manually triggered rollback workflow.
- `PULSEOPS_HOME` points to the stable laptop project directory, so release state and volumes do not depend on the runner's checkout directory.

The console never pretends to have pipeline results: it links to the actual GitHub Actions history. Local deployment works without GitHub using the same deployment script.

## Monitoring

Metrics: `webapp_http_requests_total`, `webapp_http_request_duration_seconds`, `webapp_http_requests_in_progress`, `webapp_tasks_created_total`, `webapp_build_info`. `/metrics`, `/health`, `/api/version` and static assets are excluded from business request metrics. Route templates prevent per-task-ID cardinality growth. The bounded demo scenarios have separate labels.

Prometheus scrapes every 5 seconds, evaluates every 5 seconds, and retains up to 7 days / approximately 1 GB of metric data, subject to normal retention processing. Application and console use one Gunicorn worker with eight threads; this is deliberate because metrics and workload control use process-local state.

| Alert | Expression meaning | Hold |
| --- | --- | --- |
| WebAppMetricsUnreachable | Latest configured application scrape failed | 20 seconds |
| HighServerErrorRate | 1-minute HTTP 5xx ratio >10%, traffic >0.5 req/s | 30 seconds |
| HighResponseLatency | Estimated 1-minute p95 >1 second, traffic >0.5 req/s | 30 seconds |

Alertmanager waits 5 seconds initially and sends firing/resolved webhooks to the console. Real notification payloads are persisted in SQLite (latest 200 deliveries). Thresholds are shortened for teaching, not production SLOs. `up=1` measures scrape success, not user-facing availability. Empty/NaN readings are displayed as a dash instead of invented zero values.

The console's traffic generator calls only the configured application. Each run is bounded to 10–300 seconds and 1–6 workers. Normal/error workers wait 0.2 seconds between requests; slow requests also wait approximately 1.6 seconds at the application. This is a demonstration workload, not a calibrated capacity benchmark. Stop cancels future requests while in-flight requests finish.

## Checks

```powershell
.\scripts\check.ps1
.\scripts\verify.ps1

# Optional full rehearsal (Python standard library only; stack must already run).
python scripts/rehearse.py

# Optional deployment/rollback and outage rehearsal (briefly stops the app).
.\scripts\release-rehearsal.ps1
```

The rehearsal exercises task CRUD and verifies real firing and resolved notifications for error and latency alerts, saving `.runtime/rehearsal.json`. Local verification saves `.runtime/latest-verification.json`. Rule unit tests verify outage pending/firing/recovery. Application tests cover CRUD, validation, persistence, metric accounting, route label cardinality, demo disabling, webhook persistence, workload bounds, origin validation and upstream failure handling.

## Structure

`app/`: instrumented application. `console/`: independent control/receiver service. `web/`: presentation UI. `monitoring/`: scrape/rule/notification configuration. `grafana/`: provisioned datasource and dashboard. `scripts/`: setup, deployment, rollback and testing. `.github/workflows/`: CI and local CD. `docs/`: project explanation and demonstration script.

## Boundaries

All published ports bind to `127.0.0.1`; this is a single-user educational environment. There is no production authentication or multi-tenant isolation. Docker restart policies do not restart a merely unhealthy process. Monitoring does not repair application bugs. The console receives webhooks only from the local Compose stack in the intended setup. No Docker socket is mounted in the web services. Only run trusted code on the laptop runner. A laptop outage also stops its monitoring. Image rollback does not undo database migrations; keep schema compatibility for the demo. Host CPU/memory, distributed traces, public HTTPS and cloud deployment are future extensions.

## Official references

- [Prometheus getting started](https://prometheus.io/docs/prometheus/latest/getting_started/)
- [Instrumentation guidance](https://prometheus.io/docs/practices/instrumentation/)
- [Prometheus alerting](https://prometheus.io/docs/alerting/latest/overview/)
- [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Docker Compose networking](https://docs.docker.com/compose/how-tos/networking/)
- [GitHub Actions concepts](https://docs.github.com/en/actions/get-started/understanding-github-actions)
- [Self-hosted runner security](https://docs.github.com/en/actions/reference/security/secure-use)
