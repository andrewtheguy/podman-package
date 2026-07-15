#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: ./scripts/build-deb.sh <package> <distro> <version>

Packages:
  podman
  netavark
  aardvark-dns
  crun
  conmon
  containers-common
  containers-storage

Targets:
  ubuntu noble
  ubuntu resolute
  debian trixie
USAGE
}

if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

PRODUCT="$1"
DISTRO_FAMILY="$2"
DISTRO="$3"

case "${PRODUCT}" in
  podman|netavark|aardvark-dns|crun|conmon|containers-common|containers-storage) ;;
  *)
    usage
    die "unsupported package: ${PRODUCT}"
    ;;
esac

case "${DISTRO_FAMILY}/${DISTRO}" in
  ubuntu/noble)
    DISTRO_LABEL="Ubuntu 24.04"
    BASE_IMAGE="ubuntu:noble"
    ;;
  ubuntu/resolute)
    DISTRO_LABEL="Ubuntu 26.04"
    BASE_IMAGE="ubuntu:resolute"
    ;;
  debian/trixie)
    DISTRO_LABEL="Debian 13"
    BASE_IMAGE="debian:trixie"
    ;;
  *)
    usage
    die "unsupported target: ${DISTRO_FAMILY}/${DISTRO}"
    ;;
esac

if [[ "${PRODUCT}" == "containers-common" ]]; then
  # containers-common is Architecture: all; one deterministic build per target is enough.
  ARCHES=("amd64")
else
  ARCHES=("arm64" "amd64")
fi

OUTPUT_ROOT="${REPO_ROOT}/output"
BUILD_VERSION="$(date -u +%Y%m%d)"
VERSION_CONFIG="${REPO_ROOT}/packaging/versions.env"
PATCH_SOURCE_DIR="${REPO_ROOT}/packaging/${PRODUCT}/${DISTRO_FAMILY}/${DISTRO}/patches"
DOCKERFILE_PATH="${REPO_ROOT}/docker/Dockerfile"
PIPELINE_LABEL="single buildx ${DISTRO_LABEL} ${PRODUCT} pipeline"
DONE_MESSAGE="Done. ${DISTRO_LABEL} ${PRODUCT} artifacts are in ${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"

main() {
  run_orchestrator
}

main
