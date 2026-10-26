# Presentation script — 10 to 15 minutes

## Before class

Run START.cmd once with internet access so images are downloaded. Complete CONNECT-GITHUB.cmd sign-in and confirm at least one successful real Actions run. After a reboot, START.cmd reconnects the registered runner automatically. Rehearse with `python scripts/rehearse.py`; save screenshots or a short recording of a successful run as a fallback for classroom internet issues. Keep the app version, workflow commit and release badge consistent.

Open console, Grafana, GitHub Actions and (optionally) Prometheus in four tabs. Do not display `.env`, credential storage, registration tokens or runner diagnostic secrets. Open a PowerShell terminal in the project folder for the optional outage commands.

## 1. Introduce the problem — one minute

“A running application can still be slow or return errors. Our project automates deployment, measures actual request behavior, visualizes performance, and delivers alerts when problems persist.”

Show Overview. Explain which component does what. `up` means Prometheus can scrape the metrics endpoint; it is not a complete availability test.

## 2. Show the application — one minute

Open Task application. Add “Prepare final viva”, mark it complete, then optionally delete it. Explain that tasks live in SQLite on a persistent Docker volume. Show the standalone application and version badge.

## 3. Show automation — two to four minutes

Use a small prepared change to `version.txt` (for example 1.0.0 → 1.1.0) and push it to main after GitHub setup. Open Actions. Show checkout, image build, exact-image tests, deployment verification and monitoring verification. Show the new application version and matching commit. Do not describe a previously recorded workflow as a currently running one.

If internet is unavailable, show a clearly identified previous successful workflow recording and demonstrate local deployment with `.\scripts\deploy.ps1`. Explain the limitation honestly.

## 4. Baseline — one minute

Run normal traffic. Open Grafana. Point out requests per second, p95 duration, error percentage and endpoint breakdown. Initial rates require at least two scrape samples; allow roughly 15–30 seconds before discussing them.

## 5. Failure detection — two minutes

Stop the workload and let in-flight requests finish. Run error traffic for two minutes. Show HTTP 500s, the increased error ratio, pending/firing alert state and the actual delivered webhook. Alternatively use slow traffic and explain the intentional 1.6-second request duration.

Expected alert timing depends on history, scrape/evaluation alignment and Alertmanager grouping. Allow around one to two minutes; do not promise an exact second. The thresholds are chosen for a teaching demo.

## 6. Recovery — one to two minutes

Stop error/slow traffic. Start normal traffic to demonstrate recovery. The old observations remain in the one-minute window until they age out. Show the alert clearing and a real resolved webhook in the inbox. Firing and resolved deliveries are retained for explanation.

## 7. Optional outage — one minute

Run `.\scripts\outage.ps1 -Action Stop`. The console and monitoring remain online. Show target reachability falling and WebAppMetricsUnreachable firing after its 20-second hold plus collection/delivery overhead. Restore with `.\scripts\outage.ps1 -Action Start` and show recovery. Do not stop the entire stack for this demonstration.

## 8. Optional rollback — one minute

After a successful versioned deployment, run `.\scripts\rollback.ps1` or dispatch “Restore previous local release” in GitHub. Show the previous version returning while tasks and monitoring history remain. This is a manually triggered image rollback, not automatic recovery from every incident.

## Common viva questions

**Why GitHub Actions instead of Jenkins?** Both can orchestrate CI/CD. We chose GitHub Actions for repository-integrated workflow execution and used a self-hosted runner to deploy on our laptop.

**Why no GCP?** Containers, CI/CD, metric collection and alerting can run locally. Cloud hosting is an extension, not a requirement for the demonstrated mechanisms.

**Who collects the metrics?** Prometheus pulls `/metrics`. Grafana queries Prometheus. Prometheus evaluates rules, and Alertmanager routes notifications.

**Why a separate console?** It remains usable while the application is stopped, so workloads and notifications do not depend on the monitored app staying online.

**Does the application restart automatically when an alert fires?** No. Alerts provide detection. We demonstrate explicit recovery or rollback. The deployment script separately attempts to restore the previous image if a new release fails readiness/version verification.

**Can monitoring detect the laptop turning off?** This local stack cannot notify while the entire laptop is off. Independent external monitoring would be needed.
