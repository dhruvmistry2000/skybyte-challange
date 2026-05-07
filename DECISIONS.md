# Decisions Log

Running list of the choices we made on this repo and why. Written as we went so future me (or whoever picks this up) understands the reasoning. Format is roughly: what we did, why, what else we considered, and what the tradeoffs were.

---

## 1. gunicorn instead of flask dev server

We run gunicorn as the actual web server. Flask's built in app.run() is still there for local testing but thats it.

Why - flasks dev server is single threaded and doesnt handle SIGTERM properly. Also prints those big warnings about not using it in production which is annoying. Gunicorn handles signals properly, drains in-flight requests, and exits cleanly within terminationGracePeriodSeconds.

Other options we looked at - uWSGI (too much config overhead for what we need), waitress (windows friendly but thats not our target). Gunicorn is the obvious boring choice here.

Tradeoff - each gunicorn worker has its own in-memory metric counters. So a single prometheus scrape only sees one workers slice of the data. We're running with -w 1 for now and scaling via pods not workers. If we ever need worker-level concurency we'd have to switch to prometheus_client.multiprocess.

---

## 2. port 8080 not port 80

Gunicorn binds to 0.0.0.0:8080. The Service maps whatever external port we want so this is transparent to callers.

Why - ports under 1024 are privleged on linux. Binding to them normally requires root or CAP_NET_BIND_SERVICE. Some clusters have net.ipv4.ip_unprivileged_port_start=0 set in pod namespaces and get away with port 80 fine, others dont. Using 8080 means we never depend on that cluster-specific behavior and the same image runs everywhere.

We did think about just staying on 80 since modern containerd sort of allows it. Rejected that because its a runtime detail not a guarantee. Older clusters and hardened distros still enforce the privleged range.

No real tradeoff here. The Service abstraction handles it.

---

## 3. /metrics endpoint with safe labels

The app exposes a prometheus /metrics endpoint. Two metrics: http_requests_total with method/path/status labels, and http_request_duration_seconds with method/path. The path label is the matched route rule not the raw URL. The /metrics endpoint itself is excluded from the counter.

Why - two real problems with using request.path directly. First is cardinality blowup - any 404 spam like /admin or /wp-login.php creates new label values forever and prometheus doesnt like that. Using the matched route caps cardinality to however many routes we actually defined. Second is the scrape self-pollution issue which is just obvious once you think about it.

We considered just dropping the labels entirely. Doesnt work for us because we need per-route SLO data.

Tradeoff - unmatched requests all collapse into one bucket in metrics. Cant tell /admin from /wp-login.php from the numbers alone. Logs still have the full detail though.

---

## 4. pinned slim base image

FROM python:3.9.23-slim, then apt-get update && apt-get upgrade, then pip install --upgrade pip setuptools wheel before anything else.

Why - :latest makes builds non-reproduceable. Same dockerfile can produce a completely different image tomorrow. The slim base also ships with old setuptools and wheel versions that have HIGH CVEs, bumping them in the dockerfile is what lets trivy pass with HIGH severity gating.

Distroless was on the table. Smaller image, fewer CVEs, but no shell means kubectl exec stops working and our system-checks.sh relies on that. Deliberately deferred, not forgotten.

We do carry a debian userland we dont strictly need. Thats the tradeoff.

---

## 5. non-root user uid 10001

Dockerfile creates uid/gid 10001 and sets USER 10001:10001. Pod also sets runAsNonRoot: true.

Why - container running as root means any RCE hands an attacker a privleged process on the node. Non-root is probably the single biggest win you can get from a container security perspective.

We looked at using whatever user the slim image ships with. Theres no such user, the base runs as root. Creating a uid we control is the standard pattern here.

No meaningful tradeoff.

---

## 6. full pod security context

Pod and container securityContext both set: runAsNonRoot true, runAsUser 10001, allowPrivilegeEscalation false, readOnlyRootFilesystem true, capabilities drop ALL, seccompProfile RuntimeDefault.

Each one closes a different door. Read only rootfs stops an attacker writing binaries into /usr/bin or messing with /etc. Dropping ALL caps removes things like CAP_NET_RAW that we arent using anyway. No priv escalation blocks setuid tricks. Seccomp RuntimeDefault is the kernels basic syscall allowlist, costs nothing to enable.

We considered just relying on PodSecurity admission labels on the namespace. They cover most of this but miss seccompProfile and dont catch resource issues. Kyverno (see decision 13) gives us the same enforcement plus the ability to fail CI without a cluster.

Read only rootfs needs writable mounts wherever the app actually writes. See decision 7 for how that played out.

---

## 7. emptyDir mount at /tmp

Pod has an emptyDir volume mounted at /tmp inside the container.

Why - gunicorn workers create a heartbeat file in /tmp at startup. With readOnlyRootFilesystem on and no writable mount that fails with FileNotFoundError: No usable temporary directory and the pod crashloops. We hit this exact crash, this is the fix.

Alternative was passing --worker-tmp-dir /dev/shm to gunicorn. Works but /dev/shm is a node-shared resource and is more fragile across runtimes. emptyDir is per-pod, ephemeral, gone when the pod dies. Exactly what we want.

---

## 8. startupProbe before liveness and readiness

startupProbe hits /healthz once a second, up to 30 times. Liveness and readiness dont run until after it passes.

Why - without a startup probe the readiness probe was firing the second the container started, before gunicorn had actually bound the socket, producing connection refused events on every pod creation. Startup probe gates everything else until the app is actually serving.

We tried bumping readinessProbe.initialDelaySeconds instead. Works for this app right now but its a guess. If startup ever slows down the probes start flapping again. Startup probe asks the app not the clock.

Adds one more probe block to the manifest. Worth it.

---

## 9. always declare resource requests and limits

Container has requests of 50m cpu and 64Mi memory, limits of 200m cpu and 128Mi memory.

Why - without requests the scheduler cant pick the right node. Without limits one bad pod can starve the namespace, especially since the namespace has a 512Mi memory ResourceQuota. The original chart shipped with neither.

Just requests with no limits is a common pattern that lets pods burst. We rejected it because the namespace quota requires limits.memory for admission to even work.

Numbers are conservative. If real load needs more we revisit.

---

## 10. terraform owns the secret, helm just references it

The api-token kubernetes secret is created by terraform/main.tf. The helm chart Deployment references it by name with secretKeyRef. The chart doesnt ship any Secret manifest of its own anymore.

Why - cluster bootstrap stuff (namespace, quota, secrets) outlives any individual app release. Terraform owns that layer. App release stuff (Deployment, Service, probes) changes every push and Helm owns that. The original setup had apiToken in values.yaml in plaintext. Once thats in git history you cant take it back.

We considered having Helm create the secret from a value - same problem as before. External Secrets Operator is probably the right long-term answer (fetches from AWS/GCP/Vault) but adds a controller dependency. Listed as a next week thing.

Tradeoff - the token lives in terraform state so the state file is now sensitive. It needs to live in an encrypted backend like S3+KMS or GCS+CMEK. Never in git, never on a laptop.

---

## 11. deleted the secret template from helm entirely

Deleted helm/skybyte-app/templates/secrets.yaml and the apiToken/apiTokenSecret keys from values.yaml. Only the secretKeyRef with hardcoded name api-token / key token remains in the Deployment.

Why - a flag like apiTokenSecret.create: true is one bad copy-paste away from re-introducing the original problem. With the template gone there is nothing for helm template to leak even by accident.

We did think about keeping the template behind an if .Values condition. Defensive but every reviewer would have to verify the flag is off in every values file forever. Easier to just delete the code.

The chart no longer works standalone. It now requires terraform (or equivalent) to have created the Secret first. Ordering is documented in setup.sh and docs/api-token-flow.txt.

---

## 12. prometheus scrape via pod annotations not ServiceMonitor

Pod template has prometheus.io/scrape: true, prometheus.io/path: /metrics, prometheus.io/port: 8080. Gated by metrics.enabled which defaults to true.

Why - ServiceMonitor requires the prometheus operator CRDs (monitoring.coreos.com/v1). Installing the chart on a clean kind cluster for the demo recording would fail with no matches for kind ServiceMonitor. Annotations work with kube-prometheus-stacks default kubernetes-pods scrape job and the standard prometheus config.

Pod-level annotations not Service-level because pod annotations make prometheus scrape each pod directly so you keep per-pod labels. Service annotations route through the VIP and load-balance scrapes - aggregate numbers only, no per-pod attribution. Bad for SLOs.

We'd add a ServiceMonitor gated by serviceMonitor.enabled: false the day we know the target cluster runs the operator.

---

## 13. kyverno over OPA/gatekeeper or PSA labels

Two ClusterPolicy resources in policies/. require-pod-security covers non-root, drop all caps, no privilege escalation, read-only rootfs. require-resource-limits requires every container to declare cpu and memory requests and limits.

Why kyverno - the pattern syntax is plain YAML. Reviewers can read it without learning Rego. PodSecurity admission labels handle most of the security baseline but skip resources entirely and cant fail CI without a live cluster.

OPA/Gatekeeper is more expressive but Rego has a real learning curve and the syntax looks nothing like the kubernetes manifests its validating. Higher reviewer friction.

Kyverno is less expressive than Rego. We dont need the extra power yet.

---

## 14. validate rendered helm output not raw templates

CI runs helm template first then pipes the YAML into kyverno and kubeconform. We never feed the raw helm templates to a validator.

Why - helm templates have Go template syntax in them ({{ ... }}) which isnt valid YAML. Rendering first gives deterministic schema-conformant manifests that any validator understands.

---

## 15. kyverno in enforce mode not audit

Both policies set validationFailureAction: Enforce.

Audit mode produces a report and lets the manifest through. We want bad manifests blocked both at admission time in a real cluster and in CI (kyverno apply exits non-zero on enforced violations which fails the build). Audit mode for a brownfield migration makes sense. For a fresh policy on a chart that already complies its just noise.

A new workload that doesnt comply cant merge. Thats the point.

---

## 16. kubeconform pinned to k8s 1.29

CI step runs: helm template ... | kubeconform -strict -kubernetes-version 1.29.0. kubeconform v0.7.0 and the k8s version are pinned in the workflow env block.

Why - helm lint checks chart syntax and helm conventions but knows nothing about kubernetes types. A typo like containerPorts: 8080 or runAsRoot: false passes lint fine but blows up on a real cluster. kubeconform -strict validates against the actual API schema and rejects unknown fields.

kubeval was the obvious alternative but its been unmaintained since 2022 with stale schemas. kubectl --dry-run=server against a kind cluster is more authoritative but takes 60-90s per run and adds a moving dependency.

Kubeconform doesnt know about CRDs by default. We have none right now. If we add a ServiceMonitor later we'll need -schema-location or a skip list.

---

## 17. ruff not flake8

CI runs ruff check app/ with no --exit-zero or || true.

The original CI ran flake8 app/ --exit-zero which prints findings and then exits 0 regardless. Completely useless. Ruff is the modern faster replacement for flake8+isort+pyupgrade combined. One tool, one config, fast enough that nobody grumbles about it.

Could have just fixed flake8 to use --exit-code. Works, but ruff is faster and covers more rules.

---

## 18. multi arch images amd64 and arm64 with buildx

CI uses docker/setup-qemu-action and docker/setup-buildx-action, then runs two separate docker/build-push-action steps - one per platform - both with load: true, giving us two locally loaded images for trivy to scan.

Two builds instead of one because dockers local image store doesnt accept multi-platform manifests via --load. Options were build twice and load each, or build once with --push to a registry. Push-then-pull needs registry credentials in CI and burns network and quota on every PR. Two local builds keeps everything on the runner.

arm64 matters because Apple Silicon dev machines and Graviton/Ampere k8s nodes are real. A dockerfile change that breaks arm64 should fail PR CI not surface at release time.

Building amd64 only on PRs and arm64 only on tags was considered. Faster PRs but hides arm64 regressions for days. Not worth it.

QEMU emulated arm64 is 2-4x slower than native. The docker job is the longest in our CI matrix. If runs get expensive we'd switch to GitHubs native arm runners or move arm builds to release-only.

---

## 19. trivy strict on deps lenient on unfixed OS CVEs

Three trivy scans, all severity HIGH+, all --exit-code 1. trivy fs . on the source tree has no --ignore-unfixed. The two image scans (amd64 and arm64) both use --ignore-unfixed.

Why split - source dependencies are always in our control. If flask ships a HIGH CVE we bump the pin in the same PR and CI should fail. OS packages in a slim base often have HIGH CVEs that debian acknowledges before actually shipping a fix - thats the unfixed category. Failing CI on those would freeze us on debiasn's release schedule with no remediation available on our end.

apt-get upgrade after apt-get update in the dockerfile plus upgrading pip/setuptools/wheel closes real HIGH findings (OpenSSL, setuptools, wheel) that the slim base ships with.

--ignore-unfixed everywhere lets dependency CVEs slip through. No --ignore-unfixed anywhere means CI is permanently red on debians schedule. Neither option works.

Unfixed debian CVEs in the image arent visiable in CI right now. We rely on the next docker build (which re-runs apt-get upgrade) to pull fixes once debian ships them. A weekly scheduled rebuild would close the gap but thats not done yet.

---

## 20. system-checks - liveness failures fatal, readiness misses tolerated

system-checks.sh step 5 deletes the running pod, waits for the Deployment to recover within 30s, then looks at Unhealthy events on the new pod. Liveness probe failures fail the script. Readiness probe failures during cold start are reported but dont fail it.

Why - liveness failure means the kubelet is killing a pod that was supposed to be alive. Real outage signal, should fail. Readiness failure during cold start doesnt affect users - the pod isnt in the Services endpoints during that window so no traffic routes to it. Treating both the same would fail the script on totally normal startup behaviour and trains people to ignore alerts.

Failing on both was considered. Too noisy. The readiness failures we actually saw were a single 503 in the first millisecond of pod life with zero user impact. The startupProbe (decision 8) means this barely happens anymore anyway. The check is defense in depth.

A genuine readiness-only outage (app starts but /healthz returns 503 forever) passes step 5 but fails step 3 which curls /. The check suite as a whole still catches it. Documented here so a future reader doesnt soften the script thinking it looks wrong.