# Decisions Log

Here's what we decided and why, in really simple words.

---

## D-001: We use Kyverno to check rules

**What we decided:**  
We made two rule files (YAML) in the `policies/` folder and use Kyverno to check them for every change. The two rules are:

- All pods must not run as root, must drop all Linux capabilities, can't get special powers, and have a read-only filesystem.
- Every container must say how much CPU and memory it needs and set limits.

**Why:**  
The project needed these rules because the original setup was unsafe and didn’t have any limits. These rules stop us from making the same mistake.

**Other ideas:**  
We thought about using OPA/Gatekeeper, but it’s harder to read and set up.  
We also thought about using Kubernetes’s PSA labels, but that only does some checks and misses resources.

**What happens:**  
- We catch problems before merging code, because Kyverno runs in CI and checks everything.
- These files can also protect the actual cluster when Kyverno is installed.

---

## D-002: We check the output of Helm, not the templates

**What we decided:**  
In CI, we run Helm to turn templates into real files, then run Kyverno on those files—never the templates directly.

**Why:**  
The templates have weird code (`{{ ... }}`) that Kyverno can’t read, so we check after rendering.

**Other ideas:**  
We could check only in a real cluster, but then it’s too late to find mistakes.

**What happens:**  
- The checks run exactly the same every time, and you don’t need a cluster to test.
- It’s easy to add new charts—just render and check them.

---

## D-003: We enforce rules, not just warn

**What we decided:**  
Our rules are set to "Enforce", so things must follow them. "Audit" (just warning) is not enough.

**Why:**  
If we only warn, people might miss mistakes and deploy broken stuff. Enforce blocks bad configs.

**What happens:**  
- Bad configs can't be added or deployed.
- Everyone has to follow the rules from the start.

---

## Proof that broken pods are rejected

We tested Kyverno on:

1. The Helm output (should pass)
2. A good pod file (`good-pod.yaml`, should pass)
3. A broken pod file (`bad-pod.yaml`, should FAIL because it misses security stuff and resources)

Here’s what happens if you try the bad one:

```text
pass: 0, fail: 5, warn: 0, error: 0, skip: 0
```
It fails, as it should!

---

### To try yourself

```bash
# Render the Helm chart to YAML
helm template skybyte-app helm/skybyte-app --namespace devops-challenge > /tmp/rendered.yaml

# Check the rendered chart
kyverno apply policies/require-pod-security.yaml policies/require-resource-limits.yaml --resource /tmp/rendered.yaml

# Check the bad test file
kyverno apply policies/require-pod-security.yaml policies/require-resource-limits.yaml --resource policies/tests/bad-pod.yaml
```
