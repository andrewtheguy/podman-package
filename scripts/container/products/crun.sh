#!/usr/bin/env bash

crun_configure_product() {
  CRUN_NAME="crun"
  CRUN_DISPLAY="crun"
  CRUN_BUILDER_NAME="Crun"
  CRUN_TAG="${CRUN_TAG:-}"
  CRUN_VERSION="${CRUN_VERSION:-}"
  CRUN_ARCHIVE_SHA256="${CRUN_ARCHIVE_SHA256:-}"
  CRUN_SOURCE_PACKAGE="crun"
  CRUN_SOURCE_GLOB="crun-*"
  WORK_ROOT="/tmp/crun-build"
}

crun_validate_inputs() {
  : "${CRUN_TAG:?CRUN_TAG is required}"
  : "${CRUN_VERSION:?CRUN_VERSION is required}"
  : "${CRUN_ARCHIVE_SHA256:?CRUN_ARCHIVE_SHA256 is required}"

  # crun tags are the bare version (e.g. "1.28" or "1.14.4"); no leading "v".
  [[ "${CRUN_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "invalid crun version: ${CRUN_VERSION}"
  [[ "${CRUN_TAG}" == "${CRUN_VERSION}" ]] || die "crun tag (${CRUN_TAG}) must equal version (${CRUN_VERSION})"
}

crun_install_prereqs() {
  # crun is plain C (autotools). The upstream release tarball is a self-contained
  # dist tree (configure + bundled libocispec/blake3), so no autoreconf is needed.
  # Mandatory libs at 1.28: json-c, libseccomp, libsystemd, libcap. blake3 is
  # embedded and CRIU is disabled (see crun_patch_debian_rules).
  install_packages \
    build-essential \
    ca-certificates \
    curl \
    debhelper \
    devscripts \
    dpkg-dev \
    equivs \
    go-md2man \
    jq \
    libcap-dev \
    libjson-c-dev \
    libseccomp-dev \
    libsystemd-dev \
    patch \
    pkgconf \
    python3 \
    quilt \
    tar \
    xz-utils
}

crun_prepare_sources() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}"
  cd "${WORK_ROOT}"

  fetch_distro_source "${CRUN_SOURCE_PACKAGE}" "${CRUN_SOURCE_GLOB}" DISTRO_SRC_DIR

  UPSTREAM_VERSION="${CRUN_VERSION}"
  local upstream_tarball="${WORK_ROOT}/crun-${CRUN_VERSION}.tar.gz"
  # Use the upstream release dist tarball (contains configure + bundled
  # libocispec), not the git archive, which lacks the submodule and configure.
  local upstream_url="https://github.com/containers/crun/releases/download/${CRUN_TAG}/crun-${CRUN_VERSION}.tar.gz"

  log "Downloading upstream ${CRUN_DISPLAY} source: ${upstream_url}"
  curl -fsSL -o "${upstream_tarball}" -L "${upstream_url}"
  verify_sha256 "${upstream_tarball}" "${CRUN_ARCHIVE_SHA256}"
  tar -xzf "${upstream_tarball}" -C "${WORK_ROOT}"

  UPSTREAM_SRC_DIR="${WORK_ROOT}/crun-${CRUN_VERSION}"
  [[ -d "${UPSTREAM_SRC_DIR}" ]] || die "unable to locate unpacked ${CRUN_DISPLAY} source directory"

  cp -a "${DISTRO_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"
  replace_debian_patches "${UPSTREAM_SRC_DIR}"
}

crun_patch_debian_rules() {
  cd "${UPSTREAM_SRC_DIR}"

  # Replace the distro rules with a minimal autotools build against the shipped
  # configure. dh_autoreconf is skipped so we don't regenerate configure with a
  # mismatched autotools; only the crun executable + man page are installed
  # (--disable-libcrun), blake3 is embedded, and CRIU is left out for a
  # deterministic build across every target.
  cat > debian/rules <<'EOF_RULES'
#!/usr/bin/make -f

%:
	dh $@

override_dh_autoreconf:

override_dh_auto_configure:
	./configure \
		--prefix=/usr \
		--disable-silent-rules \
		--disable-libcrun \
		--disable-criu \
		--enable-embedded-blake3

override_dh_auto_build:
	$(MAKE)

override_dh_auto_test:

override_dh_auto_install:
	$(MAKE) install DESTDIR=$(CURDIR)/debian/tmp prefix=/usr

override_dh_dwz:

override_dh_missing:
	dh_missing
EOF_RULES
  chmod +x debian/rules
}

crun_patch_debian_packaging() {
  cd "${UPSTREAM_SRC_DIR}"

  # Drop distro install/manpage helpers that reference paths from the distro's
  # own (possibly meson) build, then declare exactly what our rules install.
  find debian -maxdepth 1 \( -name '*.install' -o -name '*.manpages' -o -name '*.dirs' -o -name '*.links' \) -delete

  cat > debian/crun.install <<'EOF_INSTALL'
usr/bin/crun
usr/share
EOF_INSTALL
}

crun_update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local build_id="${BUILD_VERSION}-${BUILD_REVISION}"
  local package_version="${CRUN_VERSION}+${build_id}~${DISTRO}"

  export DEBFULLNAME="${CRUN_BUILDER_NAME} ${DISTRO_LABEL} Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream ${CRUN_DISPLAY} ${CRUN_TAG} (${build_id}) with ${DISTRO_NAME} ${DISTRO} packaging and repo-managed patch series."
}

crun_build_package() {
  cd "${UPSTREAM_SRC_DIR}"
  apply_patch_series "${UPSTREAM_SRC_DIR}"

  export DEB_BUILD_OPTIONS="nocheck noautodbgsym"

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  dpkg-buildpackage -b -uc -us -d 2>&1 | tee "${build_log}"
}

product_main() {
  crun_configure_product
  crun_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized ${CRUN_DISPLAY} build for ${TARGET_ARCH} (${CRUN_TAG})"
  setup_apt_sources
  crun_install_prereqs
  crun_prepare_sources
  crun_patch_debian_rules
  crun_patch_debian_packaging
  crun_update_changelog
  crun_build_package
  collect_artifacts "${UPSTREAM_SRC_DIR}"
  log "Completed ${DISTRO_LABEL} ${CRUN_DISPLAY} build for ${TARGET_ARCH} (${CRUN_TAG})"
}
