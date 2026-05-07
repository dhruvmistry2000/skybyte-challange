# Skybyte API

A small Python service that returns a greeting. Runs in Kubernetes via Helm.

> **Note:** the engineer who set this up is no longer with the team. Some of this README may be out of date. **The challenge brief is in [`CHALLENGE.md`](./CHALLENGE.md) — start there.**

---

## Service Level Objective (SLO)

- **SLO Statement:** The Skybyte API must respond with HTTP 200 and the expected JSON payload for 99% of requests within 500ms, as measured over any rolling 24 hour window.
- **How we'd know it broke:** Health check endpoints (e.g. `/healthz`) or main service endpoints consistently fail, or response times exceed SLO thresholds, as observed via logs, CI checks, or monitoring tools.

---

## Prerequisites

- Docker Desktop (or any Docker engine)
- A local Kubernetes cluster (Minikube or Kind)
- Helm 3.x
- Terraform 1.5+
- Python 3.9+ (for running tests locally)

## Quick start

```bash
./setup.sh
```

This script will build the image, apply Terraform, and install the Helm chart.

To verify the deployment:

```bash
kubectl -n devops-challenge get pods
kubectl -n devops-challenge port-forward svc/skybyte-app 8080:8080
curl http://localhost:8080/
# expected: {"message": "Hello, Candidate", "version": "1.0.0"}
```

## Architecture

```
[Client] ──► [Service:8080] ──► [Pod:appuser:8080]
```

The pod runs as a non-root user (uid 10001) and listens on port 8080. Port 8080 is unprivileged on Linux, so the container needs neither root nor `CAP_NET_BIND_SERVICE`. Health checks are wired to `/healthz`.

## CI

GitHub Actions runs lint, helm lint, terraform validate, and a Docker build on every push. See `.github/workflows/ci.yml`.

## Layout

```
/
├── app/                  Python service
├── Dockerfile
├── helm/skybyte-app/     Helm chart
├── terraform/            Namespace + ResourceQuota + secret
├── .github/workflows/    CI
├── setup.sh
└── CHALLENGE.md          ← read this
```
