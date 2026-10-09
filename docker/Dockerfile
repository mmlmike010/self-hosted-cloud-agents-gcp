# Cursor self-hosted worker image for both the Compute Engine and GKE paths.
FROM ubuntu:24.04
ARG TARGETARCH
# Keep within one minor version of your GKE control plane (Kubernetes version skew policy)
ARG KUBECTL_VERSION=v1.36.5
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/.local/bin:/usr/local/bin:${PATH}"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git jq less openssh-client unzip \
    && rm -rf /var/lib/apt/lists/*

# kubectl is used only by the GKE controller Pod (the k8s-workers spawn hook)
RUN KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}" \
    && curl -fsSLo /usr/local/bin/kubectl "${KUBECTL_URL}/kubectl" \
    && echo "$(curl -fsSL "${KUBECTL_URL}/kubectl.sha256")  /usr/local/bin/kubectl" \
        | sha256sum --check \
    && chmod +x /usr/local/bin/kubectl

# Cursor CLI. The install script installs the single build it currently points to.
RUN curl -fsSL https://cursor.com/install | bash \
    && agent --version

WORKDIR /workspace
COPY config/labels.json /etc/cursor/labels.json
COPY docker/entrypoint.sh /usr/local/bin/cursor-worker-entrypoint
ENTRYPOINT ["/usr/local/bin/cursor-worker-entrypoint"]
