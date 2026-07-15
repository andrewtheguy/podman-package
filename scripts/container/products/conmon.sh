#!/usr/bin/env bash

conmon_configure_product() {
  CONMON_DISPLAY="conmon"
  CONMON_BUILDER_NAME="Conmon"
  CONMON_TAG="${CONMON_TAG:-}"
  CONMON_VERSION="${CONMON_VERSION:-}"
  CONMON_ARCHIVE_SHA256="${CONMON_ARCHIVE_SHA256:-}"
  CONMON_SOURCE_PACKAGE="conmon"
  CONMON_SOURCE_GLOB="conmon-*"
  WORK_ROOT="/tmp/conmon-build"
}

conmon_validate_inputs() {
  : "${CONMON_TAG:?CONMON_TAG is required}"
  : "${CONMON_VERSION:?CONMON_VERSION is required}"
  : "${CONMON_ARCHIVE_SHA256:?CONMON_ARCHIVE_SHA256 is required}"

  [[ "${CONMON_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid conmon tag: ${CONMON_TAG}"
  [[ "${CONMON_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid conmon version: ${CONMON_VERSION}"
  [[ "${CONMON_TAG}" == "v${CONMON_VERSION}" ]] || \
    die "conmon tag (${CONMON_TAG}) must equal v${CONMON_VERSION}"
}

conmon_install_prereqs() {
  install_packages \
    build-essential \
    ca-certificates \
    curl \
    debhelper \
    devscripts \
    dpkg-dev \
    equivs \
    go-md2man \
    libglib2.0-dev \
    libseccomp-dev \
    libsystemd-dev \
    patch \
    pkg-config \
    quilt \
    tar \
    xz-utils
}

conmon_prepare_sources() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}"
  cd "${WORK_ROOT}"

  fetch_distro_source "${CONMON_SOURCE_PACKAGE}" "${CONMON_SOURCE_GLOB}" DISTRO_SRC_DIR

  UPSTREAM_VERSION="${CONMON_VERSION}"
  local upstream_tarball="${WORK_ROOT}/conmon-${CONMON_VERSION}.tar.gz"
  local upstream_url="https://github.com/containers/conmon/archive/refs/tags/${CONMON_TAG}.tar.gz"

  log "Downloading upstream ${CONMON_DISPLAY} source: ${upstream_url}"
  curl -fsSL -o "${upstream_tarball}" -L "${upstream_url}"
  verify_sha256 "${upstream_tarball}" "${CONMON_ARCHIVE_SHA256}"
  tar -xzf "${upstream_tarball}" -C "${WORK_ROOT}"

  UPSTREAM_SRC_DIR="${WORK_ROOT}/conmon-${CONMON_VERSION}"
  [[ -d "${UPSTREAM_SRC_DIR}" ]] || die "unable to locate unpacked ${CONMON_DISPLAY} source directory"

  cp -a "${DISTRO_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"
  replace_debian_patches "${UPSTREAM_SRC_DIR}"
}

conmon_patch_debian_packaging() {
  cd "${UPSTREAM_SRC_DIR}"

  # Older distro packages also produce a Go development package. Upstream
  # conmon is now C-only, so retain the distro's binary package metadata only.
  awk 'BEGIN{RS="";ORS="\n\n"} /^Source:/ || /(^|\n)Package: conmon\n/ {print}' debian/control > debian/control.new
  mv debian/control.new debian/control
  find debian -maxdepth 1 \
    \( -name 'golang-github-containers-conmon-dev.*' -o -name 'golang-github-containers-conmon-dev' \) \
    -delete
}

conmon_update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local build_id="${BUILD_VERSION}-${BUILD_REVISION}"
  local package_version="${CONMON_VERSION}+${build_id}~${DISTRO}"

  export DEBFULLNAME="${CONMON_BUILDER_NAME} ${DISTRO_LABEL} Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream ${CONMON_DISPLAY} ${CONMON_TAG} (${build_id}) with ${DISTRO_NAME} ${DISTRO} packaging and repo-managed patch series."
}

conmon_build_package() {
  cd "${UPSTREAM_SRC_DIR}"
  apply_patch_series "${UPSTREAM_SRC_DIR}"

  export DEB_BUILD_OPTIONS="nocheck noautodbgsym"

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  dpkg-buildpackage -b -uc -us -d 2>&1 | tee "${build_log}"
}

product_main() {
  conmon_configure_product
  conmon_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized ${CONMON_DISPLAY} build for ${TARGET_ARCH} (${CONMON_TAG})"
  setup_apt_sources
  conmon_install_prereqs
  conmon_prepare_sources
  conmon_patch_debian_packaging
  conmon_update_changelog
  conmon_build_package
  collect_artifacts "${UPSTREAM_SRC_DIR}"
  log "Completed ${DISTRO_LABEL} ${CONMON_DISPLAY} build for ${TARGET_ARCH} (${CONMON_TAG})"
}
