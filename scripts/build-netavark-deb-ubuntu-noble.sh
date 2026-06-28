#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ $# -ne 0 ]]; then
  cat >&2 <<'USAGE'
Usage: ./scripts/build-netavark-deb-ubuntu-noble.sh

This script is intentionally zero-argument.
USAGE
  exit 2
fi

PRODUCT="netavark"
DISTRO="noble"
ARCHES=("arm64" "amd64")
OUTPUT_ROOT="${REPO_ROOT}/output"
BUILD_VERSION="$(date -u +%Y%m%d)"
VERSION_CONFIG="${REPO_ROOT}/packaging/versions.env"
PATCH_SOURCE_DIR="${REPO_ROOT}/packaging/patches-netavark-ubuntu-noble"
DOCKERFILE_PATH="docker/Dockerfile.netavark-ubuntu-noble"
PIPELINE_LABEL="single buildx Ubuntu 24.04 netavark pipeline"
DONE_MESSAGE="Done. Ubuntu 24.04 netavark artifacts are in ${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"

main() {
  run_orchestrator
}

main
