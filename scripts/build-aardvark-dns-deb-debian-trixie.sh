#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ $# -ne 0 ]]; then
  cat >&2 <<'USAGE'
Usage: ./scripts/build-aardvark-dns-deb-debian-trixie.sh

This script is intentionally zero-argument.
USAGE
  exit 2
fi

PRODUCT="aardvark-dns"
DISTRO="trixie"
ARCHES=("arm64" "amd64")
OUTPUT_ROOT="${REPO_ROOT}/output"
BUILD_VERSION="$(date -u +%Y%m%d)"
VERSION_CONFIG="${REPO_ROOT}/packaging/versions.env"
PATCH_SOURCE_DIR="${REPO_ROOT}/packaging/patches-aardvark-dns-debian-trixie"
DOCKERFILE_PATH="docker/Dockerfile.aardvark-dns-debian-trixie"
PIPELINE_LABEL="single buildx Debian 13 aardvark-dns pipeline"
DONE_MESSAGE="Done. Debian 13 aardvark-dns artifacts are in ${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"

main() {
  run_orchestrator
}

main
