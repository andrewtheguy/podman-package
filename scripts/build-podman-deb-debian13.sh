#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ $# -ne 0 ]]; then
  cat >&2 <<'USAGE'
Usage: ./scripts/build-podman-deb-debian13.sh

This script is intentionally zero-argument.
USAGE
  exit 2
fi

DISTRO="trixie"
ARCHES=("arm64" "amd64")
OUTPUT_ROOT="${REPO_ROOT}/output"
BUILD_VERSION="$(date -u +%Y%m%d)"
VERSION_CONFIG="${REPO_ROOT}/packaging/versions.env"
PATCH_SOURCE_DIR="${REPO_ROOT}/packaging/patches-debian13"
PINNED_PODMAN_TAG=""

load_versions_config() {
  [[ -f "${VERSION_CONFIG}" ]] || die "missing versions config: ${VERSION_CONFIG}"
  # shellcheck disable=SC1090
  source "${VERSION_CONFIG}"

  PINNED_PODMAN_TAG="${PODMAN_TAG:-}"

  [[ "${PINNED_PODMAN_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
    die "invalid or missing PODMAN_TAG in ${VERSION_CONFIG}: ${PINNED_PODMAN_TAG:-<empty>}"
}

check_patch_source() {
  [[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
  [[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"
}

run_build_for_arch() {
  local arch="$1"
  local tag="$2"

  log "Running single buildx Debian 13 pipeline for ${arch} with Podman ${tag}"
  docker buildx build \
    --platform "linux/${arch}" \
    --build-arg "DISTRO=${DISTRO}" \
    --build-arg "BUILD_VERSION=${BUILD_VERSION}" \
    --build-arg "PODMAN_TAG=${tag}" \
    --build-arg "TARGET_ARCH=${arch}" \
    --target artifact-export \
    --output "type=local,dest=${OUTPUT_ROOT}" \
    --file "docker/Dockerfile.debian13-builder" \
    "${REPO_ROOT}"
}

write_manifest() {
  local tag="$1"
  local tag_dir="${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"
  local manifest_path="${tag_dir}/manifest.txt"

  mkdir -p "${tag_dir}"
  {
    echo "podman_tag=${tag}"
    echo "distro=${DISTRO}"
    echo "build_version=${BUILD_VERSION}"
    echo "generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    for arch in "${ARCHES[@]}"; do
      local arch_dir="${tag_dir}/${arch}"
      echo
      echo "[${arch}]"

      if [[ ! -d "${arch_dir}" ]]; then
        echo "missing output directory: ${arch_dir}"
        continue
      fi

      (
        cd "${arch_dir}"
        shopt -s nullglob
        files=( *.deb *.changes *.buildinfo *.dsc *.tar.* )
        if [[ "${#files[@]}" -eq 0 ]]; then
          echo "no package artifacts found"
          exit 0
        fi
        sha256sum "${files[@]}"
      )
    done
  } > "${manifest_path}"

  log "Wrote manifest: ${manifest_path}"
}

main() {
  require_cmd docker
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required"
  load_versions_config
  check_patch_source

  mkdir -p "${OUTPUT_ROOT}"
  local distro_version_dir="${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"
  rm -rf "${distro_version_dir}"

  local resolved_tag="${PINNED_PODMAN_TAG}"
  log "Using pinned Podman tag from ${VERSION_CONFIG}: ${resolved_tag}"
  log "Per-arch runs are sequential; completed arch artifacts are exported immediately."

  local failed_arches=()
  for arch in "${ARCHES[@]}"; do
    log "Starting full workflow for ${arch} (single buildx pipeline)"

    if run_build_for_arch "${arch}" "${resolved_tag}"; then
      log "Completed ${arch}; artifacts exported to ${distro_version_dir}/${arch}"
    else
      log "ERROR: build failed for ${arch}"
      failed_arches+=( "${arch}:build" )
      break
    fi
  done

  write_manifest "${resolved_tag}"

  if [[ "${#failed_arches[@]}" -gt 0 ]]; then
    die "one or more architecture runs failed: ${failed_arches[*]}"
  fi

  log "Done. Debian 13 artifacts are in ${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"
}

main
