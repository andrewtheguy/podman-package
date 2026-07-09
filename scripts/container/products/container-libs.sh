#!/usr/bin/env bash

container_libs_configure_product() {
  case "${PRODUCT}" in
    containers-common)
      LIBS_NAME="containers-common"
      LIBS_DISPLAY="containers-common"
      LIBS_BUILDER_NAME="Containers-Common"
      LIBS_TAG="${CONTAINERS_COMMON_TAG:-}"
      LIBS_VERSION="${CONTAINERS_COMMON_VERSION:-}"
      LIBS_ARCHIVE_SHA256="${CONTAINERS_COMMON_ARCHIVE_SHA256:-}"
      LIBS_SOURCE_PACKAGE="golang-github-containers-common"
      LIBS_SOURCE_GLOB="golang-github-containers-common-*"
      LIBS_MONOREPO_DIR="container-libs-common-v${LIBS_VERSION}/common"
      LIBS_UPSTREAM_DIR="golang-github-containers-common-${LIBS_VERSION}"
      WORK_ROOT="/tmp/containers-common-build"
      ;;
    containers-storage)
      LIBS_NAME="containers-storage"
      LIBS_DISPLAY="containers-storage"
      LIBS_BUILDER_NAME="Containers-Storage"
      LIBS_TAG="${CONTAINERS_STORAGE_TAG:-}"
      LIBS_VERSION="${CONTAINERS_STORAGE_VERSION:-}"
      LIBS_ARCHIVE_SHA256="${CONTAINERS_STORAGE_ARCHIVE_SHA256:-}"
      LIBS_SOURCE_PACKAGE="containers-storage"
      LIBS_SOURCE_GLOB="golang-github-containers-storage-*"
      LIBS_MONOREPO_DIR="container-libs-storage-v${LIBS_VERSION}/storage"
      LIBS_UPSTREAM_DIR="golang-github-containers-storage-${LIBS_VERSION}"
      WORK_ROOT="/tmp/containers-storage-build"
      ;;
    *)
      die "unsupported container-libs product: ${PRODUCT}"
      ;;
  esac
}

container_libs_validate_inputs() {
  : "${LIBS_TAG:?${PRODUCT} tag is required}"
  : "${LIBS_VERSION:?${PRODUCT} version is required}"
  : "${LIBS_ARCHIVE_SHA256:?${PRODUCT} archive sha256 is required}"

  [[ "${LIBS_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid ${PRODUCT} version: ${LIBS_VERSION}"
}

container_libs_install_prereqs() {
  case "${PRODUCT}" in
    containers-common)
      install_packages \
        ca-certificates \
        curl \
        debhelper \
        devscripts \
        dpkg-dev \
        equivs \
        go-md2man \
        jq \
        patch \
        quilt \
        tar \
        xz-utils
      ;;
    containers-storage)
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
        libbtrfs-dev \
        libdevmapper-dev \
        libsubid-dev \
        patch \
        pkg-config \
        quilt \
        tar \
        xz-utils
      ;;
  esac
}

container_libs_prepare_sources() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}"
  cd "${WORK_ROOT}"

  fetch_distro_source "${LIBS_SOURCE_PACKAGE}" "${LIBS_SOURCE_GLOB}" DISTRO_SRC_DIR

  local archive="${WORK_ROOT}/container-libs-${LIBS_VERSION}.tar.gz"
  local archive_url="https://github.com/containers/container-libs/archive/refs/tags/${LIBS_TAG}.tar.gz"
  log "Downloading upstream ${LIBS_DISPLAY} source: ${archive_url}"
  curl -fsSL -o "${archive}" -L "${archive_url}"
  verify_sha256 "${archive}" "${LIBS_ARCHIVE_SHA256}"
  tar -xzf "${archive}" -C "${WORK_ROOT}"

  local monorepo_subdir="${WORK_ROOT}/${LIBS_MONOREPO_DIR}"
  [[ -d "${monorepo_subdir}" ]] || die "unable to locate ${LIBS_NAME} subdir in extracted container-libs archive"

  UPSTREAM_SRC_DIR="${WORK_ROOT}/${LIBS_UPSTREAM_DIR}"
  mv "${monorepo_subdir}" "${UPSTREAM_SRC_DIR}"

  cp -a "${DISTRO_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"
  replace_debian_patches "${UPSTREAM_SRC_DIR}"
}

container_libs_patch_containers_common() {
  cd "${UPSTREAM_SRC_DIR}"

  cat > debian/rules <<'EOF_RULES'
#!/usr/bin/make -f

%:
	dh $@

override_dh_auto_configure:

override_dh_auto_build:
	$(MAKE) -C docs docs GOMD2MAN=/usr/bin/go-md2man

override_dh_auto_test:

override_dh_auto_install:
	$(MAKE) -C docs install DESTDIR=$(CURDIR)/debian/tmp PREFIX=/usr

override_dh_dwz:
EOF_RULES
  chmod +x debian/rules

  awk 'BEGIN{RS="";ORS="\n\n"} !/Package: golang-github-containers-common-dev/' debian/control > debian/control.new
  mv debian/control.new debian/control
  rm -f debian/golang-github-containers-common-dev.install debian/golang-github-containers-common-dev.*

  {
    [[ -f debian/etc/containers/policy.json ]] && printf '%s\n' 'debian/etc/containers/policy.json	/etc/containers/'
    [[ -f debian/shortnames.conf ]] && printf '%s\n' 'debian/shortnames.conf	/etc/containers/registries.conf.d'
    printf '%s\n' 'pkg/config/containers.conf	/usr/share/containers'
    printf '%s\n' 'pkg/seccomp/seccomp.json	/usr/share/containers'
    printf '%s\n' 'usr/share/man/man5	/usr/share/man'
  } > debian/golang-github-containers-common.install
}

container_libs_patch_containers_storage() {
  cd "${UPSTREAM_SRC_DIR}"

  cat > debian/rules <<'EOF_RULES'
#!/usr/bin/make -f
export GOTOOLCHAIN := local
export GOFLAGS := -mod=mod
export GOPATH := /root/go
export CGO_ENABLED := 1
export PATH := /usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

%:
	dh $@

override_dh_auto_configure:

override_dh_auto_build:
	$(MAKE) containers-storage GO=/usr/local/go/bin/go
	$(MAKE) docs GOMD2MAN=/usr/bin/go-md2man

override_dh_auto_test:

override_dh_auto_install:
	install -D -m0755 containers-storage $(CURDIR)/debian/tmp/usr/bin/containers-storage
	install -D -m0644 storage.conf $(CURDIR)/debian/tmp/usr/share/containers/storage.conf
	install -d -m0755 $(CURDIR)/debian/tmp/usr/share/man/man1 $(CURDIR)/debian/tmp/usr/share/man/man5
	install -m0644 docs/*.1 $(CURDIR)/debian/tmp/usr/share/man/man1/
	install -m0644 docs/*.5 $(CURDIR)/debian/tmp/usr/share/man/man5/

override_dh_dwz:

override_dh_golang:
	true
EOF_RULES
  chmod +x debian/rules

  awk 'BEGIN{RS="";ORS="\n\n"} /^Source:/ || /(^|\n)Package: containers-storage\n/ {print}' debian/control > debian/control.new
  mv debian/control.new debian/control
  find debian -maxdepth 1 -name '*.install' ! -name 'containers-storage.install' -delete

  cat > debian/containers-storage.install <<'EOF_INSTALL'
usr/bin/containers-storage
usr/share/containers/storage.conf
usr/share/man
EOF_INSTALL
}

container_libs_update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local build_id="${BUILD_VERSION}-${BUILD_REVISION}"
  local package_version="${LIBS_VERSION}+${build_id}~${DISTRO}"

  export DEBFULLNAME="${LIBS_BUILDER_NAME} ${DISTRO_LABEL} Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream ${LIBS_DISPLAY} ${LIBS_TAG} (${build_id}) with ${DISTRO_NAME} ${DISTRO} packaging and repo-managed patch series."
}

container_libs_build_package() {
  cd "${UPSTREAM_SRC_DIR}"
  apply_patch_series "${UPSTREAM_SRC_DIR}"

  export DEB_BUILD_OPTIONS="nocheck noautodbgsym"

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  dpkg-buildpackage -b -uc -us -d 2>&1 | tee "${build_log}"
}

product_main() {
  container_libs_configure_product
  container_libs_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized ${LIBS_DISPLAY} build for ${TARGET_ARCH} (${LIBS_TAG})"
  setup_apt_sources
  container_libs_install_prereqs
  container_libs_prepare_sources

  case "${PRODUCT}" in
    containers-common)
      container_libs_patch_containers_common
      ;;
    containers-storage)
      derive_go_toolchain_from_go_mod "${UPSTREAM_SRC_DIR}/go.mod" GO_TOOLCHAIN_VERSION
      install_go_toolchain "${GO_TOOLCHAIN_VERSION}"
      container_libs_patch_containers_storage
      ;;
  esac

  container_libs_update_changelog
  container_libs_build_package
  collect_artifacts "${UPSTREAM_SRC_DIR}"
  log "Completed ${DISTRO_LABEL} ${LIBS_DISPLAY} build for ${TARGET_ARCH} (${LIBS_TAG})"
}
