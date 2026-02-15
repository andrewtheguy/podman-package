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
ARCHES=("amd64" "arm64")
OUTPUT_DIR="${REPO_ROOT}/output"
BUILDER_IMAGE_PREFIX="podman-noble-builder"

build_builder_image() {
  local arch="$1"
  local image_tag="${BUILDER_IMAGE_PREFIX}:${DISTRO}-${arch}"

  log "Building builder image for ${arch}: ${image_tag}"
  docker buildx build \
    --load \
    --platform "linux/${arch}" \
    --tag "${image_tag}" \
    --file "${REPO_ROOT}/docker/Dockerfile.noble-builder" \
    "${REPO_ROOT}"
}

resolve_latest_podman_tag() {
  local resolver_image="${BUILDER_IMAGE_PREFIX}:${DISTRO}-amd64"
  local tag

  tag="$(
    docker run --rm --platform linux/amd64 "${resolver_image}" bash -lc \
      'set -euo pipefail; curl -fsSL https://api.github.com/repos/containers/podman/releases/latest | jq -r .tag_name'
  )"
  [[ "${tag}" =~ ^v[0-9] ]] || die "failed to resolve a valid latest Podman tag, got: ${tag}"
  printf '%s\n' "${tag}"
}

run_build_for_arch() {
  local arch="$1"
  local tag="$2"
  local image_tag="${BUILDER_IMAGE_PREFIX}:${DISTRO}-${arch}"

  log "Running isolated build for ${arch} with Podman ${tag}"
  docker run --rm \
    --platform "linux/${arch}" \
    -e DISTRO="${DISTRO}" \
    -e PODMAN_TAG="${tag}" \
    -e TARGET_ARCH="${arch}" \
    -v "${REPO_ROOT}:/workspace:ro" \
    -v "${OUTPUT_DIR}:/out" \
    "${image_tag}" \
    /workspace/scripts/in-container-build.sh
}

write_manifest() {
  local tag="$1"
  local tag_dir="${OUTPUT_DIR}/${tag}"
  local manifest_path="${tag_dir}/manifest.txt"

  mkdir -p "${tag_dir}"
  {
    echo "podman_tag=${tag}"
    echo "distro=${DISTRO}"
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

  mkdir -p "${OUTPUT_DIR}"

  # Build amd64 image first so we can resolve the latest stable Podman tag once.
  build_builder_image "amd64"
  local resolved_tag
  resolved_tag="$(resolve_latest_podman_tag)"
  log "Resolved latest stable Podman tag: ${resolved_tag}"

  for arch in "${ARCHES[@]}"; do
    if [[ "${arch}" != "amd64" ]]; then
      build_builder_image "${arch}"
    fi
    run_build_for_arch "${arch}" "${resolved_tag}"
  done

  write_manifest "${resolved_tag}"
  log "Done. Artifacts are in ${OUTPUT_DIR}/${resolved_tag}"
}

main
