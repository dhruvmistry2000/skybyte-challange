#!/usr/bin/env bash
# system-checks.sh — verify the running deployment matches what we promised.
set -euo pipefail

NAMESPACE="${NAMESPACE:-devops-challenge}"
DEPLOYMENT="${DEPLOYMENT:-skybyte-app}"
LABEL_SELECTOR="${LABEL_SELECTOR:-app.kubernetes.io/name=skybyte-app}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-30s}"

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [OK]  %s\n'   "$*"; }
fail() { printf '  [FAIL] %s\n'  "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}
require kubectl

pod_name() {
  kubectl -n "$NAMESPACE" get pod -l "$LABEL_SELECTOR" \
    -o jsonpath='{.items[0].metadata.name}'
}

POD="$(pod_name)"
[ -n "$POD" ] || fail "no pod found in $NAMESPACE matching $LABEL_SELECTOR"
echo "Target pod: $POD (namespace=$NAMESPACE)"

# 1. UID -----------------------------------------------------------------
step "1. In-container UID (expect non-root, i.e. != 0)"
UID_OUT="$(kubectl -n "$NAMESPACE" exec "$POD" -- id -u)"
echo "  uid=$UID_OUT"
[ "$UID_OUT" != "0" ] || fail "container is running as root (uid=0)"
ok "running as non-root (uid=$UID_OUT)"

# 2. Port + capabilities -------------------------------------------------
step "2. Bound port + capabilities"
PORT="$(kubectl -n "$NAMESPACE" get pod "$POD" \
  -o jsonpath='{.spec.containers[0].ports[0].containerPort}')"
echo "  containerPort=$PORT"
[ -n "$PORT" ] || fail "no containerPort declared on the pod"
ok "container exposes port $PORT"

# /proc/1/status shows the actual capability mask the kernel granted.
# CapBnd 0000000000000000 means all caps were dropped.
CAPS="$(kubectl -n "$NAMESPACE" exec "$POD" -- sh -c 'grep ^Cap /proc/1/status')"
echo "$CAPS" | sed 's/^/  /'
echo "$CAPS" | grep -q '^CapBnd:[[:space:]]*0\{16\}$' \
  || fail "container still has Linux capabilities (expected CapBnd=0000000000000000)"
ok "all Linux capabilities dropped"

# 3. GET / ---------------------------------------------------------------
step "3. GET / returns the expected body"
ROOT_BODY="$(kubectl -n "$NAMESPACE" exec "$POD" -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:'+'$PORT'+'/').read().decode())")"
echo "  body=$ROOT_BODY"
echo "$ROOT_BODY" | grep -q 'Hello, Candidate' \
  || fail "GET / did not contain 'Hello, Candidate'"
ok "GET / returned the expected greeting"

# 4. GET /metrics --------------------------------------------------------
step "4. GET /metrics exposes http_requests_total"
METRICS="$(kubectl -n "$NAMESPACE" exec "$POD" -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:'+'$PORT'+'/metrics').read().decode())")"
echo "$METRICS" | grep -q '^# TYPE http_requests_total counter$' \
  || fail "/metrics does not expose http_requests_total"
echo "$METRICS" | grep -E '^http_requests_total\{' | head -3 | sed 's/^/  /'
ok "/metrics exposes http_requests_total"

# 5. Pod delete + recovery within $RECOVERY_TIMEOUT ----------------------
step "5. Delete pod and verify recovery within $RECOVERY_TIMEOUT"
echo "  deleting pod $POD ..."
START=$(date +%s)
kubectl -n "$NAMESPACE" delete pod "$POD" --wait=false >/dev/null

# Wait for the Deployment to be Available again.
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" \
  --timeout="$RECOVERY_TIMEOUT" >/dev/null \
  || fail "deployment did not become Available within $RECOVERY_TIMEOUT"
END=$(date +%s)
ELAPSED=$((END - START))
echo "  recovered in ${ELAPSED}s"

NEW_POD="$(pod_name)"
[ -n "$NEW_POD" ] && [ "$NEW_POD" != "$POD" ] \
  || fail "no new pod replaced $POD"

# Inspect Unhealthy events on the new pod. We only fail on LIVENESS failures,
# because a liveness failure means a pod that was supposed to be alive wasn't,
# and the kubelet would have killed it. A single READINESS failure during
# cold start is expected (the app isn't up yet) and the pod is not in the
# Service's endpoints during that window — no traffic is affected.
EVENTS_RAW="$(kubectl -n "$NAMESPACE" get events \
  --field-selector "involvedObject.kind=Pod,involvedObject.name=$NEW_POD,reason=Unhealthy" \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null || true)"

if [ -n "$EVENTS_RAW" ]; then
  echo "  Unhealthy events on new pod:"
  echo "$EVENTS_RAW" | sed 's/^/    /'
fi

LIVENESS_FAILS="$(printf '%s\n' "$EVENTS_RAW" | grep -c 'Liveness probe failed' || true)"
READINESS_FAILS="$(printf '%s\n' "$EVENTS_RAW" | grep -c 'Readiness probe failed' || true)"

[ "$LIVENESS_FAILS" = "0" ] \
  || fail "$LIVENESS_FAILS Liveness probe failure(s) on new pod $NEW_POD during rollout"

if [ "$READINESS_FAILS" != "0" ]; then
  echo "  note: $READINESS_FAILS readiness probe failure(s) during cold start (acceptable — pod was not yet in Service endpoints)"
fi

ok "deployment recovered (new pod=$NEW_POD, ${ELAPSED}s, no liveness failures)"

printf '\nAll system checks passed.\n'
