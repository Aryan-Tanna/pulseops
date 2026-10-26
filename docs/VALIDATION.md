# Local validation evidence

These checks were performed against the Docker stack on 26 October 2026. The figures below are observations from this laptop, not performance guarantees.

| Check | Observed result |
| --- | --- |
| Application and console tests | All 10 passed in the Linux application image |
| Prometheus configuration and rules | promtool validation passed; three alert rules loaded |
| Outage rule unit test | Pending, firing and recovery expectations passed |
| Alertmanager configuration | amtool validation passed |
| Application, console, Grafana, Prometheus and Alertmanager | Readiness checks passed |
| Prometheus application target | Up |
| Task lifecycle through the console | Create, update and delete passed |
| HTTP 500 workload | Actual HighServerErrorRate firing webhook delivered after 42.5 seconds of polling |
| Error recovery | Actual resolved webhook delivered after 62.7 seconds of polling |
| Slow-request workload | Actual HighResponseLatency firing webhook delivered after 62.7 seconds of polling |
| Latency recovery | Actual resolved webhook delivered after 52.7 seconds of polling |
| Versioned deployment | Version 1.0.1 with a unique rehearsal tag became active |
| Image rollback | Original version 1.0.0 and its commit identity restored |
| Persistent data | A task survived deployment and rollback |
| Application outage | Metrics-unreachable firing webhook delivered while the console stayed online |
| Outage recovery | Application restored; actual resolved webhook delivered |

During the recorded error scenario, Prometheus reported a 100% server-error ratio and approximately 14.45 requests/second. During the slow scenario, it reported approximately 2.25 requests/second and an estimated p95 duration of 1.975 seconds. The endpoint intentionally sleeps about 1.6 seconds; the quantile estimate reflects histogram bucket interpolation.

Raw local evidence is saved in the ignored `.runtime/rehearsal.json`, `.runtime/release-rehearsal.json` and `.runtime/latest-verification.json` files. Re-run the supplied rehearsal scripts for fresh observations.

The browser permission gate declined the local preview, so visual layout verification was not performed in that session. API, container, syntax, configuration, deployment and alert-delivery checks were performed independently. GitHub workflow execution should be assessed using the actual Actions run and its logs; workflow source alone is not evidence of a successful run.

## Real GitHub Actions execution

The first real deployment workflow passed: https://github.com/Aryan-Tanna/pulseops/actions/runs/40271711270. Its Windows self-hosted runner built and tested the commit-tagged image, deployed it, verified the application identity and monitoring target, and published a release summary.
