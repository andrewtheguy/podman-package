#!/usr/bin/env bash

rust_companion_configure_product() {
  case "${PRODUCT}" in
    netavark)
      COMPANION_NAME="netavark"
      COMPANION_DISPLAY="netavark"
      COMPANION_BUILDER_NAME="Netavark"
      COMPANION_TAG="${NETAVARK_TAG:-}"
      COMPANION_UPSTREAM_SHA256="${NETAVARK_UPSTREAM_SHA256:-}"
      COMPANION_VENDOR_SHA256="${NETAVARK_VENDOR_SHA256:-}"
      COMPANION_SOURCE_PACKAGE="netavark"
      COMPANION_SOURCE_GLOB="netavark-*"
      WORK_ROOT="/tmp/netavark-build"
      ;;
    aardvark-dns)
      COMPANION_NAME="aardvark-dns"
      COMPANION_DISPLAY="aardvark-dns"
      COMPANION_BUILDER_NAME="Aardvark-DNS"
      COMPANION_TAG="${AARDVARK_TAG:-}"
      COMPANION_UPSTREAM_SHA256="${AARDVARK_UPSTREAM_SHA256:-}"
      COMPANION_VENDOR_SHA256="${AARDVARK_VENDOR_SHA256:-}"
      COMPANION_SOURCE_PACKAGE="aardvark-dns"
      COMPANION_SOURCE_GLOB="aardvark-dns-*"
      WORK_ROOT="/tmp/aardvark-dns-build"
      ;;
    *)
      die "unsupported Rust companion product: ${PRODUCT}"
      ;;
  esac
}

rust_companion_validate_inputs() {
  : "${COMPANION_TAG:?${PRODUCT} tag is required}"
  : "${COMPANION_UPSTREAM_SHA256:?${PRODUCT} upstream sha256 is required}"
  : "${COMPANION_VENDOR_SHA256:?${PRODUCT} vendor sha256 is required}"
  : "${RUST_VERSION:?RUST_VERSION is required}"

  [[ "${COMPANION_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "invalid ${PRODUCT} tag: ${COMPANION_TAG}"
  [[ "${RUST_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid RUST_VERSION: ${RUST_VERSION}"
}

rust_companion_install_prereqs() {
  local packages=(
    build-essential
    ca-certificates
    curl
    devscripts
    dh-cargo
    dpkg-dev
    equivs
    jq
    patch
    pkg-config
    quilt
    tar
    xz-utils
  )

  if [[ "${PRODUCT}" == "netavark" ]]; then
    packages+=(go-md2man protobuf-compiler)
  fi

  install_packages "${packages[@]}"
}

rust_companion_prepare_sources() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}"
  cd "${WORK_ROOT}"

  fetch_distro_source "${COMPANION_SOURCE_PACKAGE}" "${COMPANION_SOURCE_GLOB}" DISTRO_SRC_DIR

  local upstream_version="${COMPANION_TAG#v}"
  UPSTREAM_VERSION="${upstream_version}"
  local upstream_tarball="${WORK_ROOT}/${COMPANION_NAME}-${upstream_version}.tar.gz"
  local upstream_url="https://github.com/containers/${COMPANION_NAME}/archive/refs/tags/${COMPANION_TAG}.tar.gz"

  log "Downloading upstream ${COMPANION_DISPLAY} source: ${upstream_url}"
  curl -fsSL -o "${upstream_tarball}" -L "${upstream_url}"
  verify_sha256 "${upstream_tarball}" "${COMPANION_UPSTREAM_SHA256}"
  tar -xzf "${upstream_tarball}" -C "${WORK_ROOT}"

  UPSTREAM_SRC_DIR="${WORK_ROOT}/${COMPANION_NAME}-${upstream_version}"
  [[ -d "${UPSTREAM_SRC_DIR}" ]] || die "unable to locate unpacked ${COMPANION_DISPLAY} source directory"
  cp -a "${DISTRO_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"

  local vendor_tarball="${WORK_ROOT}/${COMPANION_NAME}-${COMPANION_TAG}-vendor.tar.gz"
  local vendor_url="https://github.com/containers/${COMPANION_NAME}/releases/download/${COMPANION_TAG}/${COMPANION_NAME}-${COMPANION_TAG}-vendor.tar.gz"
  log "Downloading ${COMPANION_DISPLAY} vendored dependencies: ${vendor_url}"
  curl -fsSL -o "${vendor_tarball}" -L "${vendor_url}"
  verify_sha256 "${vendor_tarball}" "${COMPANION_VENDOR_SHA256}"
  tar -xzf "${vendor_tarball}" -C "${UPSTREAM_SRC_DIR}"
  [[ -d "${UPSTREAM_SRC_DIR}/vendor" ]] || die "vendor directory missing after extracting ${vendor_tarball}"

  mkdir -p "${UPSTREAM_SRC_DIR}/.cargo"
  cat > "${UPSTREAM_SRC_DIR}/.cargo/config.toml" <<'EOF_CARGO'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF_CARGO

  replace_debian_patches "${UPSTREAM_SRC_DIR}"
}

rust_companion_patch_debian_rules() {
  cd "${UPSTREAM_SRC_DIR}"

  case "${PRODUCT}" in
    netavark)
      cat >> debian/rules <<'EOF_NETAVARK_RULES'

override_dh_auto_configure:
	mkdir -p bin

override_dh_auto_clean:
	rm -rf bin targets

# dh_clean strips *.orig/*.rej tree-wide as patch leftovers, which would delete
# the vendored crates' legitimate Cargo.toml.orig files. Keep them.
override_dh_clean:
	dh_clean -X.orig

override_dh_auto_build:
	CARGO_NET_OFFLINE=true $(MAKE) GOMD2MAN=/usr/bin/go-md2man build docs

override_dh_auto_test:
	@echo "Skipping tests in containerized builder workflow"
	true

override_dh_auto_install:
	$(MAKE) DESTDIR=$(CURDIR)/debian/tmp PREFIX=/usr LIBEXECPODMAN=/usr/lib/podman SYSTEMDDIR=/usr/lib/systemd/system GOMD2MAN=/usr/bin/go-md2man install

execute_after_dh_install:
	true

override_dh_missing:
	dh_missing
EOF_NETAVARK_RULES
      ;;
    aardvark-dns)
      cat >> debian/rules <<'EOF_AARDVARK_RULES'

override_dh_auto_configure:
	mkdir -p bin

override_dh_auto_clean:
	rm -rf bin targets

# dh_clean strips *.orig/*.rej tree-wide as patch leftovers, which would delete
# the vendored crates' legitimate Cargo.toml.orig files. Keep them.
override_dh_clean:
	dh_clean -X.orig

override_dh_auto_build:
	CARGO_NET_OFFLINE=true $(MAKE) build

override_dh_auto_test:
	@echo "Skipping tests in containerized builder workflow"
	true

override_dh_auto_install:
	$(MAKE) DESTDIR=$(CURDIR)/debian/tmp PREFIX=/usr LIBEXECPODMAN=/usr/lib/podman install

execute_after_dh_install:
	true

override_dh_missing:
	dh_missing
EOF_AARDVARK_RULES
      ;;
  esac
}

rust_companion_patch_debian_packaging() {
  cd "${UPSTREAM_SRC_DIR}"

  case "${PRODUCT}" in
    netavark)
      cat > debian/netavark.install <<'EOF_INSTALL'
usr/lib/podman/netavark
usr/lib/systemd/system
usr/share/man
EOF_INSTALL
      ;;
    aardvark-dns)
      cat > debian/aardvark-dns.install <<'EOF_INSTALL'
usr/lib/podman/aardvark-dns
EOF_INSTALL
      rm -f debian/aardvark-dns.manpages debian/manpages
      ;;
  esac
}

rust_companion_update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local debianized_upstream="${UPSTREAM_VERSION//-rc/~rc}"
  local build_id="${BUILD_VERSION}-${BUILD_REVISION}"
  local package_version="${debianized_upstream}+${build_id}~${DISTRO}"

  export DEBFULLNAME="${COMPANION_BUILDER_NAME} ${DISTRO_LABEL} Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream ${COMPANION_DISPLAY} ${COMPANION_TAG} (${build_id}) with ${DISTRO_NAME} ${DISTRO} packaging and repo-managed patch series."
}

rust_companion_build_package() {
  cd "${UPSTREAM_SRC_DIR}"
  apply_patch_series "${UPSTREAM_SRC_DIR}"

  export DEB_BUILD_OPTIONS="nocheck noautodbgsym"
  export CARGO_NET_OFFLINE=true

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  dpkg-buildpackage -b -uc -us -d 2>&1 | tee "${build_log}"
}

product_main() {
  rust_companion_configure_product
  rust_companion_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized ${COMPANION_DISPLAY} build for ${TARGET_ARCH} (${COMPANION_TAG})"
  setup_apt_sources
  rust_companion_install_prereqs
  rust_companion_prepare_sources
  install_rust_toolchain "${RUST_VERSION}"
  rust_companion_patch_debian_rules
  rust_companion_patch_debian_packaging
  rust_companion_update_changelog
  rust_companion_build_package
  collect_artifacts "${UPSTREAM_SRC_DIR}"
  log "Completed ${DISTRO_LABEL} ${COMPANION_DISPLAY} build for ${TARGET_ARCH} (${COMPANION_TAG})"
}
