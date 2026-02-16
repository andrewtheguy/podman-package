#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ $# -ne 0 ]]; then
  cat >&2 <<'EOF'
Usage: ./scripts/build-podman-deb.sh

This script is intentionally zero-argument.
EOF
  exit 2
fi

DISTRO="noble"
ARCHES=("arm64" "amd64")
OUTPUT_ROOT="${REPO_ROOT}/output"
BUILD_VERSION="$(date -u +%Y%m%d)"
VERSION_CONFIG="${REPO_ROOT}/packaging/versions.env"
PATCH_SOURCE_DIR="${REPO_ROOT}/packaging/patches"
DOCKERFILE_PATH="docker/Dockerfile.noble-builder"
PIPELINE_LABEL="single buildx pipeline"
DONE_MESSAGE="Done. Artifacts are in ${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"
PINNED_PODMAN_TAG=""
PINNED_UPSTREAM_SHA256=""

main() {
  run_orchestrator
}

main
