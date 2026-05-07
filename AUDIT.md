# AUDIT — DevOps Challenge Starter Repo

## Security


### Image tag uses `latest` (not pinned, reproducibility issues)
- **Where:** `helm/skybyte-app/values.yaml`, `setup.sh`
- **What’s wrong:** Images default to `:latest` in both Helm and the build script, so the tag is always moving.
- **Why it matters:** You can’t guarantee what’s being deployed. Rollbacks and provenance are a nightmare. Risky from a supply-chain standpoint.
- **Fix:** Always pin tags—ideally to the Git SHA or a genuinely unique value—and use unchanging image references in Helm. In the Dockerfile, also pin the base image (including patch version and ideally digest).

### Secret checked into repo as plaintext (Helm values)
- **Where:** `helm/skybyte-app/values.yaml`
- **What’s wrong:** There's an `apiToken` sitting in plaintext in the values file, checked into git.
- **Why it matters:** Once a secret lands in version control, scrubbing it is tough (history, forks, caches—yikes). Looks like a real token too. Opens the door for accidental leaks, especially if people reuse the pattern in the future.
- **Fix:** Yank `apiToken` out of the values file and pull it from a proper Kubernetes Secret (using `env.valueFrom.secretKeyRef`, probably created by Terraform). Double-check that running `helm template` doesn’t output any secret strings.

### App runs as root and on privileged port by default
- **Where:** `Dockerfile`, `app/main.py`, `helm/skybyte-app/templates/deployment.yaml`
- **What’s wrong:** Dockerfile never switches to a non-root user. Flask binds to port 80, which is privileged on Linux. There’s zero `securityContext` in the deployment.
- **Why it matters:** Containers running as root are a security red flag—RCE turns into full node compromise, privilege escalation, etc. Privileged ports mean you *have* to be root or hold `CAP_NET_BIND_SERVICE`. This fails basic container security best practices.
- **Fix:** Run the app on 8080 (unprivileged), map via the Service. Switch the Dockerfile to a non-root UID and add a pod/container `securityContext`:
    - `runAsNonRoot: true`
    - `readOnlyRootFilesystem: true`
    - `allowPrivilegeEscalation: false`
    - Drop *all* Linux capabilities
    - `seccompProfile` set to `RuntimeDefault`

### Filesystem isn’t hardened (no read-only rootfs)
- **Where:** `helm/skybyte-app/templates/deployment.yaml`, `Dockerfile`
- **What’s wrong:** No sign of `readOnlyRootFilesystem`, so the app can write pretty much anywhere.
- **Why it matters:** Writable rootfs lets attackers persist or mess with the app/filesystem. Blocking most writes reduces attack surface.
- **Fix:** Use `readOnlyRootFilesystem: true` in the Pod/Container spec; if the app needs to write files, mount an `emptyDir` (usually at `/tmp` or similar) for just that purpose.

---

## Reliability

### Probes don’t use health endpoints and are poorly specified
- **Where:** `helm/skybyte-app/templates/deployment.yaml`, `app/main.py`
- **What’s wrong:** Both liveness and readiness probes just hit `/` with a barebones `httpGet`, no sensible timeouts or thresholds set. There *is* a `/healthz` handler, but it’s ignored.
- **Why it matters:** If startup is slow or load spikes, pods might be incorrectly killed due to aggressive or misconfigured probes. Checking `/` means accidentally coupling health to actual app traffic, not just shallow checks.
- **Fix:** Switch probes to target dedicated endpoints—`/healthz` for liveness, `/readyz` for readiness if you add it. Set appropriate values for:
    - `initialDelaySeconds`
    - `periodSeconds`
    - `timeoutSeconds`
    - `failureThreshold`
    - `successThreshold`

### Missing CPU and memory resource requests/limits
- **Where:** `helm/skybyte-app/templates/deployment.yaml`
- **What’s wrong:** No resource `requests` or `limits` are set at all.
- **Why it matters:** K8s can’t schedule reliably, and the container could consume too much CPU/mem, crowding out neighbors or being OOM-killed unpredictably. Bad for stability and makes cluster planning a guessing game.
- **Fix:** Add `resources.requests` and `resources.limits` for both CPU and memory—pick decent (if conservative) values as a baseline.

### Flask dev server (not production!) is used in the container
- **Where:** `app/main.py`, `Dockerfile`
- **What’s wrong:** Default CMD runs the built-in Flask server on `python main.py`.
- **Why it matters:** Flask built-in server is single-threaded, doesn’t handle signals well, and is NOT meant for production. Won’t gracefully shut down on SIGTERM, leading to stuck pods or dropped connections.
- **Fix:** Use a real WSGI server (gunicorn, uwsgi, etc.), and make sure it’s set up for graceful shutdowns—must exit cleanly within the `terminationGracePeriodSeconds` window.

### `setup.sh` script isn’t strict
- **Where:** `setup.sh`
- **What’s wrong:** Script doesn’t use `set -euo pipefail`, so errors are easy to miss. It also installs into a namespace that might not exist, but doesn’t ensure it’s created.
- **Why it matters:** Officially “successful” runs may have actually failed. Idempotency and reliability go out the window.
- **Fix:** Add Bash strict mode to the top (`set -euo pipefail`) and make namespace creation deterministic (either via Terraform or with Helm’s `--create-namespace`). No silent failures!

---

## Hygiene

### CI shows green even if actual checks fail or are skipped
- **Where:** `.github/workflows/ci.yml`
- **What’s wrong:**
    - Python lint step: `flake8 app/ --exclude=app/* --exit-zero` disables failures and maybe even skips useful files.
    - Helm and Terraform lint/validate are run with `|| true`, so their failures are ignored.
- **Why it matters:** The badge looks green while underlying problems go undetected. Regressions creep in and trust in CI goes down.
- **Fix:** Remove all failure-suppressing flags like `--exit-zero` and `|| true`. Add real checks that must pass: rendered Helm manifests validation (`kubeconform`), `terraform fmt -check`, run actual unit tests, container scans (Trivy), and policy checks when feasible.

### Dockerfile is not minimal or strictly reproducible
- **Where:** `Dockerfile`
- **What’s wrong:** Uses `FROM python:3.9` (not minimal; not pinned to patch or digest), no multi-stage build, and may install version-drifting dependencies.
- **Why it matters:** Larger than needed images, slower builds, more vulnerabilities and more difficult debugging or SBOM generation.
- **Fix:** Use `python:3.9-slim` (or better, distroless or multi-stage). Pin to a full version (e.g., `3.9.18-slim`) and ideally digest. Lock dependencies. Consider multi-stage builds if compiling anything.

---

## Documentation

### README says non-root appuser + `/healthz` probes, but code/manifests don’t match
- **Where:** `README.md`, `helm/skybyte-app/templates/deployment.yaml`, `Dockerfile`
- **What’s wrong:** README claims non-root execution and `/healthz` checks, but neither the Dockerfile nor deployment YAML enforces it.
- **Why it matters:** Misleading docs create false confidence and sloppy operational assumptions. If we say a thing is safe, it needs to _be_ safe.
- **Fix:** Either update the implementation to deliver on the docs (strongly preferred!) or rewrite the README to match reality. Don’t forget to add an SLO, a summary of changes, and link to a demo if you can.

---
