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

verify_sha256() {
  local file="$1"
  local expected="${2,,}"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "invalid expected sha256 for ${file}: ${2}"
  local actual
  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || \
    die "checksum mismatch for ${file}: expected ${expected}, got ${actual}"
}

# Loads packaging/versions.env and resolves the product-specific pinned inputs.
# PRODUCT selects which input set to validate and which docker build args to pass.
load_versions_config() {
  [[ -f "${VERSION_CONFIG}" ]] || die "missing versions config: ${VERSION_CONFIG}"
  # shellcheck disable=SC1090
  source "${VERSION_CONFIG}"

  : "${PRODUCT:?PRODUCT is required}"
  PRODUCT_BUILD_ARGS=()

  case "${PRODUCT}" in
    podman)
      PINNED_PODMAN_TAG="${PODMAN_TAG:-}"
      PINNED_UPSTREAM_SHA256="${UPSTREAM_SHA256:-}"
      [[ "${PINNED_PODMAN_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
        die "invalid or missing PODMAN_TAG in ${VERSION_CONFIG}: ${PINNED_PODMAN_TAG:-<empty>}"
      [[ "${PINNED_UPSTREAM_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing UPSTREAM_SHA256 in ${VERSION_CONFIG}: ${PINNED_UPSTREAM_SHA256:-<empty>}"
      RESOLVED_TAG="${PINNED_PODMAN_TAG}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "PODMAN_TAG=${PINNED_PODMAN_TAG}"
        --build-arg "UPSTREAM_SHA256=${PINNED_UPSTREAM_SHA256}"
      )
      ;;
    netavark)
      local tag="${NETAVARK_TAG:-}"
      local upstream_sha="${NETAVARK_UPSTREAM_SHA256:-}"
      local vendor_sha="${NETAVARK_VENDOR_SHA256:-}"
      local rust="${RUST_VERSION:-}"
      [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
        die "invalid or missing NETAVARK_TAG in ${VERSION_CONFIG}: ${tag:-<empty>}"
      [[ "${upstream_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing NETAVARK_UPSTREAM_SHA256 in ${VERSION_CONFIG}: ${upstream_sha:-<empty>}"
      [[ "${vendor_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing NETAVARK_VENDOR_SHA256 in ${VERSION_CONFIG}: ${vendor_sha:-<empty>}"
      [[ "${rust}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid or missing RUST_VERSION in ${VERSION_CONFIG}: ${rust:-<empty>}"
      RESOLVED_TAG="${tag}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "NETAVARK_TAG=${tag}"
        --build-arg "NETAVARK_UPSTREAM_SHA256=${upstream_sha}"
        --build-arg "NETAVARK_VENDOR_SHA256=${vendor_sha}"
        --build-arg "RUST_VERSION=${rust}"
      )
      ;;
    aardvark-dns)
      local tag="${AARDVARK_TAG:-}"
      local upstream_sha="${AARDVARK_UPSTREAM_SHA256:-}"
      local vendor_sha="${AARDVARK_VENDOR_SHA256:-}"
      local rust="${RUST_VERSION:-}"
      [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
        die "invalid or missing AARDVARK_TAG in ${VERSION_CONFIG}: ${tag:-<empty>}"
      [[ "${upstream_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing AARDVARK_UPSTREAM_SHA256 in ${VERSION_CONFIG}: ${upstream_sha:-<empty>}"
      [[ "${vendor_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing AARDVARK_VENDOR_SHA256 in ${VERSION_CONFIG}: ${vendor_sha:-<empty>}"
      [[ "${rust}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid or missing RUST_VERSION in ${VERSION_CONFIG}: ${rust:-<empty>}"
      RESOLVED_TAG="${tag}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "AARDVARK_TAG=${tag}"
        --build-arg "AARDVARK_UPSTREAM_SHA256=${upstream_sha}"
        --build-arg "AARDVARK_VENDOR_SHA256=${vendor_sha}"
        --build-arg "RUST_VERSION=${rust}"
      )
      ;;
    crun)
      local tag="${CRUN_TAG:-}"
      local version="${CRUN_VERSION:-}"
      local archive_sha="${CRUN_ARCHIVE_SHA256:-}"
      [[ "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
        die "invalid or missing CRUN_VERSION in ${VERSION_CONFIG}: ${version:-<empty>}"
      [[ "${tag}" == "${version}" ]] || \
        die "CRUN_TAG (${tag:-<empty>}) must equal CRUN_VERSION (${version:-<empty>}) in ${VERSION_CONFIG}"
      [[ "${archive_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing CRUN_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${archive_sha:-<empty>}"
      RESOLVED_TAG="${tag}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "CRUN_TAG=${tag}"
        --build-arg "CRUN_VERSION=${version}"
        --build-arg "CRUN_ARCHIVE_SHA256=${archive_sha}"
      )
      ;;
    conmon)
      local tag="${CONMON_TAG:-}"
      local version="${CONMON_VERSION:-}"
      local archive_sha="${CONMON_ARCHIVE_SHA256:-}"
      [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid or missing CONMON_TAG in ${VERSION_CONFIG}: ${tag:-<empty>}"
      [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid or missing CONMON_VERSION in ${VERSION_CONFIG}: ${version:-<empty>}"
      [[ "${tag}" == "v${version}" ]] || \
        die "CONMON_TAG (${tag}) must equal v${CONMON_VERSION} in ${VERSION_CONFIG}"
      [[ "${archive_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing CONMON_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${archive_sha:-<empty>}"
      RESOLVED_TAG="${tag}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "CONMON_TAG=${tag}"
        --build-arg "CONMON_VERSION=${version}"
        --build-arg "CONMON_ARCHIVE_SHA256=${archive_sha}"
      )
      ;;
    containers-common)
      local tag="${CONTAINERS_COMMON_TAG:-}"
      local version="${CONTAINERS_COMMON_VERSION:-}"
      local archive_sha="${CONTAINERS_COMMON_ARCHIVE_SHA256:-}"
      [[ "${tag}" =~ ^common/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid or missing CONTAINERS_COMMON_TAG in ${VERSION_CONFIG}: ${tag:-<empty>}"
      [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid or missing CONTAINERS_COMMON_VERSION in ${VERSION_CONFIG}: ${version:-<empty>}"
      [[ "${archive_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing CONTAINERS_COMMON_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${archive_sha:-<empty>}"
      RESOLVED_TAG="${tag}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "CONTAINERS_COMMON_TAG=${tag}"
        --build-arg "CONTAINERS_COMMON_VERSION=${version}"
        --build-arg "CONTAINERS_COMMON_ARCHIVE_SHA256=${archive_sha}"
      )
      ;;
    containers-storage)
      local tag="${CONTAINERS_STORAGE_TAG:-}"
      local version="${CONTAINERS_STORAGE_VERSION:-}"
      local archive_sha="${CONTAINERS_STORAGE_ARCHIVE_SHA256:-}"
      [[ "${tag}" =~ ^storage/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid or missing CONTAINERS_STORAGE_TAG in ${VERSION_CONFIG}: ${tag:-<empty>}"
      [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid or missing CONTAINERS_STORAGE_VERSION in ${VERSION_CONFIG}: ${version:-<empty>}"
      [[ "${archive_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "invalid or missing CONTAINERS_STORAGE_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${archive_sha:-<empty>}"
      RESOLVED_TAG="${tag}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "CONTAINERS_STORAGE_TAG=${tag}"
        --build-arg "CONTAINERS_STORAGE_VERSION=${version}"
        --build-arg "CONTAINERS_STORAGE_ARCHIVE_SHA256=${archive_sha}"
      )
      ;;
    *)
      die "unknown PRODUCT: ${PRODUCT} (expected 'podman', 'netavark', 'aardvark-dns', 'crun', 'conmon', 'containers-common', or 'containers-storage')"
      ;;
  esac
}

check_patch_source() {
  [[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
  [[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"
}

run_build_for_arch() {
  local arch="$1"
  local revision="${BUILD_REVISION:-1}"
  local pipeline_label="${PIPELINE_LABEL:-single buildx pipeline}"

  log "Running ${pipeline_label} for ${arch} with ${PRODUCT} ${RESOLVED_TAG}"
  docker buildx build \
    --pull \
    --no-cache \
    --platform "linux/${arch}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "PRODUCT=${PRODUCT}" \
    --build-arg "DISTRO_FAMILY=${DISTRO_FAMILY}" \
    --build-arg "DISTRO=${DISTRO}" \
    --build-arg "BUILD_VERSION=${BUILD_VERSION}" \
    --build-arg "BUILD_REVISION=${revision}" \
    "${PRODUCT_BUILD_ARGS[@]}" \
    --build-arg "TARGET_ARCH=${arch}" \
    --target artifact-export \
    --output "type=local,dest=${OUTPUT_ROOT}" \
    --file "${DOCKERFILE_PATH}" \
    "${REPO_ROOT}"
}

write_manifest() {
  local tag="$1"
  local revision="${BUILD_REVISION:-1}"
  local tag_dir="${OUTPUT_ROOT}/${DISTRO}/${BUILD_VERSION}"
  local manifest_path="${tag_dir}/manifest.txt"

  mkdir -p "${tag_dir}"
  {
    echo "product=${PRODUCT}"
    echo "${PRODUCT}_tag=${tag}"
    echo "distro=${DISTRO}"
    echo "build_version=${BUILD_VERSION}"
    echo "build_revision=${revision}"
    echo "build_id=${BUILD_VERSION}-${revision}"
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

  local resolved_tag="${RESOLVED_TAG}"
  log "Using pinned ${PRODUCT} tag from ${VERSION_CONFIG}: ${resolved_tag}"
  log "Builds run with docker buildx --pull --no-cache so apt metadata/packages refresh every run."
  log "Per-arch runs are sequential; completed arch artifacts are exported immediately."

  local failed_arches=()
  for arch in "${ARCHES[@]}"; do
    log "Starting full workflow for ${arch} (single buildx pipeline)"

    if run_build_for_arch "${arch}"; then
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
