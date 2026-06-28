#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ $# -ne 0 ]]; then
  cat >&2 <<'USAGE'
Usage: ./scripts/build-containers-common-deb-ubuntu-resolute.sh

This script is intentionally zero-argument.
USAGE
  exit 2
fi

PRODUCT="containers-common"
DISTRO="resolute"
# containers-common produces an Architecture: all package; a single build is
# sufficient regardless of host/target architecture.
ARCHES=("arm64")
OUTPUT_ROOT="${REPO_ROOT}/output"
BUILD_VERSION="$(date -u +%Y%m%d)"
VERSION_CONFIG="${REPO_ROOT}/packaging/versions.env"
PATCH_SOURCE_DIR="${REPO_ROOT}/packaging/patches-containers-common-ubuntu-resolute"
DOCKERFILE_PATH="docker/Dockerfile.containers-common-ubuntu-resolute"
PIPELINE_LABEL="single buildx Ubuntu 26.04 containers-common pipeline"
DONE_MESSAGE="Done. Ubuntu 26.04 containers-common artifacts are in ${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"

main() {
  run_orchestrator
}

main
