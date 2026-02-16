#!/usr/bin/env bash

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp_utc)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

load_versions_config() {
  [[ -f "${VERSION_CONFIG}" ]] || die "missing versions config: ${VERSION_CONFIG}"
  # shellcheck disable=SC1090
  source "${VERSION_CONFIG}"

  PINNED_PODMAN_TAG="${PODMAN_TAG:-}"
  PINNED_UPSTREAM_SHA256="${UPSTREAM_SHA256:-}"

  [[ "${PINNED_PODMAN_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
    die "invalid or missing PODMAN_TAG in ${VERSION_CONFIG}: ${PINNED_PODMAN_TAG:-<empty>}"
  [[ "${PINNED_UPSTREAM_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || \
    die "invalid or missing UPSTREAM_SHA256 in ${VERSION_CONFIG}: ${PINNED_UPSTREAM_SHA256:-<empty>}"
}

check_patch_source() {
  [[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
  [[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"
}

run_build_for_arch() {
  local arch="$1"
  local tag="$2"
  local pipeline_label="${PIPELINE_LABEL:-single buildx pipeline}"

  log "Running ${pipeline_label} for ${arch} with Podman ${tag}"
  docker buildx build \
    --pull \
    --no-cache \
    --platform "linux/${arch}" \
    --build-arg "DISTRO=${DISTRO}" \
    --build-arg "BUILD_VERSION=${BUILD_VERSION}" \
    --build-arg "PODMAN_TAG=${tag}" \
    --build-arg "UPSTREAM_SHA256=${PINNED_UPSTREAM_SHA256}" \
    --build-arg "TARGET_ARCH=${arch}" \
    --target artifact-export \
    --output "type=local,dest=${OUTPUT_ROOT}" \
    --file "${DOCKERFILE_PATH}" \
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

run_orchestrator() {
  require_cmd docker
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required"
  load_versions_config
  check_patch_source

  mkdir -p "${OUTPUT_ROOT}"
  local distro_version_dir="${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"
  rm -rf "${distro_version_dir}"

  local resolved_tag="${PINNED_PODMAN_TAG}"
  log "Using pinned Podman tag from ${VERSION_CONFIG}: ${resolved_tag}"
  log "Builds run with docker buildx --pull --no-cache so apt metadata/packages refresh every run."
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

  log "${DONE_MESSAGE}"
}
