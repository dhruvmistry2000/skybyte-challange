#!/usr/bin/env bash
# setup.sh — local deployment helper
#
# Builds the image, applies Terraform, installs/upgrades the Helm release.

set -euo pipefail

VALUES_FILE="helm/skybyte-app/values.yaml"
HELM_RELEASE="skybyte-app"
K8S_NAMESPACE="devops-challenge"

IMAGE_REPO="${IMAGE_REPO:-dhruvmistry200/skybyte-app}"
PUSH_IMAGE="${PUSH_IMAGE:-true}" # set to "true" to push

current_tag="$(grep -E '^[[:space:]]*tag:' "$VALUES_FILE" | head -n1 | sed -E 's/^[[:space:]]*tag:[[:space:]]*"?([^"]+)"?/\1/')"
if [[ ! "$current_tag" =~ ^v([0-9]+)$ ]]; then
  echo "ERROR: expected image.tag like v1, v2, ... but found: '${current_tag}' in ${VALUES_FILE}" >&2
  exit 1
fi
next_tag="v$(( ${BASH_REMATCH[1]} + 1 ))"

echo "==> Current Helm image tag: ${current_tag:-<none>}"
echo "==> Next image tag: $next_tag"

echo "==> Building Docker image"
docker build -t "${IMAGE_REPO}:${next_tag}" .

if [[ "$PUSH_IMAGE" == "true" ]]; then
  echo "==> Pushing Docker image"
  docker push "${IMAGE_REPO}:${next_tag}"
else
  echo "==> Skipping push (set PUSH_IMAGE=true to push)"
fi

echo "==> Applying Terraform"
cd terraform
terraform init
terraform apply -auto-approve
cd ..

echo "==> Updating Helm values image.tag"
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required but not installed. Please install yq (https://github.com/mikefarah/yq)." >&2
  exit 1
fi
yq -i -y ".image.tag = \"${next_tag}\"" "$VALUES_FILE"

echo "==> Installing Helm chart"
helm upgrade --install "$HELM_RELEASE" helm/skybyte-app \
  --namespace "$K8S_NAMESPACE" \
  --create-namespace

echo "==> Done"
