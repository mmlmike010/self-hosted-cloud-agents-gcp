#!/usr/bin/env bash
# Offline checks for everything in this repo. Needs terraform, shellcheck,
# hadolint, and helm on PATH. The Mermaid check runs when mmdc is available
# (set MMDC to its path, or install @mermaid-js/mermaid-cli).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
trap 'echo "check failed at line ${LINENO}" >&2' ERR

step() { printf '\n==> %s\n' "$*"; }

step "terraform fmt -check"
terraform fmt -check -recursive gce/terraform

step "terraform validate"
terraform -chdir=gce/terraform init -backend=false -input=false >/dev/null
terraform -chdir=gce/terraform validate

step "render startup.sh.tpl (with and without the Git token secret)"
mkdir -p "${TMP}/render"
cp gce/terraform/startup.sh.tpl "${TMP}/render/"
cat >"${TMP}/render/main.tf" <<'TF'
locals {
  base = {
    project_id       = "PROJECT_ID"
    registry_host    = "REGION-docker.pkg.dev"
    worker_image     = "REGION-docker.pkg.dev/PROJECT_ID/cursor-workers/cursor-self-hosted-worker:v1"
    secret_id        = "cursor-worker-api-key"
    worker_pool_name = "gce-lab"
    repository_url   = "https://github.com/OWNER/REPO.git"
  }
}
output "with_token" {
  value = templatefile("startup.sh.tpl", merge(local.base, { git_token_secret_id = "cursor-git-read-token" }))
}
output "without_token" {
  value = templatefile("startup.sh.tpl", merge(local.base, { git_token_secret_id = "" }))
}
TF
terraform -chdir="${TMP}/render" init -input=false >/dev/null
terraform -chdir="${TMP}/render" apply -auto-approve -input=false >/dev/null
terraform -chdir="${TMP}/render" output -raw with_token >"${TMP}/startup-with-token.sh"
terraform -chdir="${TMP}/render" output -raw without_token >"${TMP}/startup-without-token.sh"

step "bash -n and shellcheck"
scripts=(
  docker/entrypoint.sh
  gke/helm/scripts/*.sh
  scripts/*.sh
  "${TMP}/startup-with-token.sh"
  "${TMP}/startup-without-token.sh"
)
for f in "${scripts[@]}"; do
  bash -n "${f}"
done
shellcheck "${scripts[@]}"
echo "ok: ${#scripts[@]} scripts"

step "hadolint"
hadolint docker/Dockerfile.gcp
echo "ok"

step "helm template k8s-workers 0.2.2 with gke/helm/values.yaml"
render="gke/helm/scripts/render.sh"
"${render}" >"${TMP}/default.yaml"
"${render}" --set 'extraArgs[0]=--clone-git-repos' >"${TMP}/clone.yaml"
"${render}" --set controller.warmIdle=0 --set auth.sessionToken=true >"${TMP}/session.yaml"
rejected="$("${render}" --set auth.sessionToken=true 2>&1 >/dev/null || true)"
if ! grep -q 'auth.sessionToken requires controller.warmIdle=0' <<<"${rejected}"; then
  echo "expected the chart to reject auth.sessionToken with warmIdle=1" >&2
  exit 1
fi
GKE_VALUES_FILE=/dev/null "${render}" \
  --set pool=gke-workers \
  --set controller.warmIdle=1 \
  --set auth.existingSecret=cursor-workers-api-key \
  --set resources.requests.cpu=1 \
  --set resources.requests.memory=2Gi \
  --set resources.limits.memory=4Gi >"${TMP}/flags.yaml"
diff -u "${TMP}/flags.yaml" "${TMP}/default.yaml"
grep -q -- '- "gke-workers"' "${TMP}/default.yaml"
grep -q -- '--warm-idle' "${TMP}/default.yaml"
grep -q -- 'cursor-workers-api-key' "${TMP}/default.yaml"
grep -q -- '--clone-git-repos' "${TMP}/clone.yaml"
grep -q -- '--session-token' "${TMP}/session.yaml"
echo "ok: values.yaml matches the --set flags; default, --clone-git-repos, and session-token variants render; sessionToken with warmIdle=1 is rejected"

MMDC="${MMDC:-$(command -v mmdc || true)}"
if [[ -n "${MMDC}" ]]; then
  step "mermaid (README.md)"
  printf '{"args":["--no-sandbox"]}\n' >"${TMP}/puppeteer.json"
  "${MMDC}" -q -p "${TMP}/puppeteer.json" -i "${ROOT}/README.md" -o "${TMP}/README.out.md"
  ls "${TMP}"/README.out-*.svg >/dev/null
  echo "ok"
else
  step "mermaid skipped (mmdc not found)"
fi

step "no em or en dashes"
if grep -rnI --exclude-dir=.git --exclude-dir=.terraform $'\u2014\|\u2013' .; then
  echo "found em or en dashes" >&2
  exit 1
fi
echo "ok"

printf '\nAll checks passed.\n'
