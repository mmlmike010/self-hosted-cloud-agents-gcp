#!/usr/bin/env bash
# Offline checks for everything in the repo. Nothing here talks to GCP or Cursor.
# Needs: terraform, shellcheck, hadolint, helm, kubeconform, python3 with PyYAML.
# Optional: mmdc (Mermaid CLI) for the diagram. Pass extra flags in MMDC_ARGS.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
step() { printf '\n== %s\n' "$*"; }

step "Terraform"
terraform fmt -check -recursive gce/terraform
terraform -chdir=gce/terraform init -backend=false -input=false >/dev/null
terraform -chdir=gce/terraform validate
terraform -chdir=gce/terraform test

step "ShellCheck: scripts"
shellcheck docker/entrypoint.sh gke/scripts/*.sh scripts/*.sh

step "ShellCheck: rendered startup script, with and without a Git token"
for token in "" cursor-git-read-token; do
  python3 - "${token}" >"${TMP}/startup-${token:-none}.sh" <<'PY'
import re, sys
values = {
    "project_id": "PROJECT_ID", "registry_host": "REGION-docker.pkg.dev",
    "worker_image": "REGION-docker.pkg.dev/PROJECT_ID/cursor-workers/cursor-self-hosted-worker:v1",
    "secret_id": "cursor-worker-api-key", "worker_pool_name": "gce-lab", "idle_timeout": "600",
    "repository_url": "https://github.com/OWNER/REPO.git", "git_token_secret_id": sys.argv[1],
}
src = open("gce/terraform/startup.sh.tpl").read()
out = re.sub(r"(?<!\$)\$\{(\w+)\}", lambda m: values[m.group(1)], src).replace("$${", "${")
sys.stdout.write(out)
PY
  bash -n "${TMP}/startup-${token:-none}.sh"
  shellcheck -s bash "${TMP}/startup-${token:-none}.sh"
done

step "bash -n and ShellCheck: shell blocks in READMEs"
python3 - "${TMP}" <<'PY'
import pathlib, re, sys
out = pathlib.Path(sys.argv[1])
for md in sorted(pathlib.Path(".").rglob("*.md")):
    for i, block in enumerate(re.findall(r"```(?:bash|sh)\n(.*?)```", md.read_text(), re.S)):
        name = f"{str(md).replace('/', '_')}_{i}.sh"
        (out / name).write_text("#!/usr/bin/env bash\n" + block)
PY
for f in "${TMP}"/*.md_*.sh; do
  bash -n "${f}"
  # README blocks are pasted into an interactive shell: unused variables and a bare cd are fine there
  shellcheck -s bash -e SC2034,SC2164 "${f}"
done
echo "$(find "${TMP}" -name '*.md_*.sh' | wc -l) blocks clean"

step "hadolint"
hadolint docker/Dockerfile

step "Helm template + kubeconform: base, clone-git-repos, session-token"
chart_url="https://github.com/anysphere/k8s-workers/releases/download/v0.2.2/k8s-workers-0.2.2.tgz"
render() {
  helm template gke-workers "${chart_url}" --namespace cursord -f gke/helm/values.yaml "$@"
}
render >"${TMP}/base.yaml"
render -f gke/helm/values-clone-git-repos.yaml >"${TMP}/clone.yaml"
render -f gke/helm/values-session-token.yaml >"${TMP}/token.yaml"
if render -f gke/helm/values-session-token.yaml --set controller.warmIdle=1 >/dev/null 2>&1; then
  echo "expected the chart to reject session tokens with warmIdle > 0" >&2
  exit 1
fi
for variant in base clone token; do
  python3 - "${TMP}/${variant}.yaml" >"${TMP}/${variant}-pods.yaml" <<'PY'
import re, sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "ConfigMap":
        for key, text in doc.get("data", {}).items():
            if key.endswith((".yaml", ".yml")):
                print("---")
                print(re.sub(r"\$\{(\w+)\}", lambda m: "x-" + m.group(1).lower().replace("_", "-"), text))
PY
  kubeconform -strict -summary -kubernetes-version 1.36.0 "${TMP}/${variant}.yaml" "${TMP}/${variant}-pods.yaml"
done

if command -v mmdc >/dev/null 2>&1; then
  step "Mermaid"
  python3 - "${TMP}/arch.mmd" <<'PY'
import re, sys
blocks = re.findall(r"```mermaid\n(.*?)```", open("docs/reference.md").read(), re.S)
open(sys.argv[1], "w").write(blocks[0])
PY
  read -ra mmdc_args <<<"${MMDC_ARGS:-}"
  mmdc "${mmdc_args[@]}" -i "${TMP}/arch.mmd" -o "${TMP}/arch.svg" >/dev/null
  echo "docs/reference.md diagram renders"
fi

printf '\nAll checks passed.\n'
