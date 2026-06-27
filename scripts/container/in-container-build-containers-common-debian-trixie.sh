#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ $# -ne 0 ]]; then
  die "in-container Debian 13 containers-common build script does not accept arguments"
fi

: "${CONTAINERS_COMMON_TAG:?CONTAINERS_COMMON_TAG is required}"
: "${CONTAINERS_COMMON_VERSION:?CONTAINERS_COMMON_VERSION is required}"
: "${CONTAINERS_COMMON_ARCHIVE_SHA256:?CONTAINERS_COMMON_ARCHIVE_SHA256 is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${BUILD_VERSION:?BUILD_VERSION is required}"
: "${BUILD_REVISION:=1}"
: "${DISTRO:=trixie}"

[[ "${BUILD_REVISION}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_REVISION must be a positive integer: ${BUILD_REVISION}"

PATCH_SOURCE_DIR="/workspace/packaging/patches-containers-common-debian-trixie"
[[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
[[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"

WORK_ROOT="/tmp/containers-common-build"
OUT_DIR="/out/${DISTRO}/${BUILD_VERSION}/${TARGET_ARCH}"
DEBIAN_SRC_DIR=""
UPSTREAM_SRC_DIR=""

setup_sources() {
  cat > /etc/apt/sources.list <<EOF_APT
deb http://deb.debian.org/debian ${DISTRO} main
deb http://deb.debian.org/debian ${DISTRO}-updates main
deb http://deb.debian.org/debian-security ${DISTRO}-security main
deb-src http://deb.debian.org/debian ${DISTRO} main
deb-src http://deb.debian.org/debian ${DISTRO}-updates main
deb-src http://deb.debian.org/debian-security ${DISTRO}-security main
EOF_APT
}

install_prereqs() {
  apt-get update -qq
  # containers-common is Architecture: all (config files + man pages only): no Go
  # compiler is needed. go-md2man renders the man pages; debhelper drives packaging.
  apt-get install -y -qq --no-install-recommends \
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
}

prepare_sources() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}"
  cd "${WORK_ROOT}"

  log "Fetching Debian ${DISTRO} golang-github-containers-common source package"
  apt-get source -qq golang-github-containers-common
  DEBIAN_SRC_DIR="$(find "${WORK_ROOT}" -maxdepth 1 -mindepth 1 -type d -name 'golang-github-containers-common-*' | head -n 1)"
  [[ -n "${DEBIAN_SRC_DIR}" ]] || die "unable to locate unpacked Debian containers-common source directory"

  # Upstream source for the matching version lives in the containers/container-libs
  # monorepo under common/; the GitHub tag archive top dir is container-libs-common-v<ver>.
  local archive="${WORK_ROOT}/container-libs-${CONTAINERS_COMMON_VERSION}.tar.gz"
  local archive_url="https://github.com/containers/container-libs/archive/refs/tags/${CONTAINERS_COMMON_TAG}.tar.gz"
  log "Downloading upstream containers-common source: ${archive_url}"
  curl -fsSL -o "${archive}" -L "${archive_url}"
  verify_sha256 "${archive}" "${CONTAINERS_COMMON_ARCHIVE_SHA256}"
  tar -xzf "${archive}" -C "${WORK_ROOT}"

  local monorepo_common="${WORK_ROOT}/container-libs-common-v${CONTAINERS_COMMON_VERSION}/common"
  [[ -d "${monorepo_common}" ]] || die "unable to locate common/ subdir in extracted container-libs archive"
  UPSTREAM_SRC_DIR="${WORK_ROOT}/golang-github-containers-common-${CONTAINERS_COMMON_VERSION}"
  mv "${monorepo_common}" "${UPSTREAM_SRC_DIR}"

  cp -a "${DEBIAN_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"

  # Deterministic patch policy: replace distro patches with repository-managed patches.
  rm -rf "${UPSTREAM_SRC_DIR}/debian/patches"
  mkdir -p "${UPSTREAM_SRC_DIR}/debian/patches"
  cp -a "${PATCH_SOURCE_DIR}/." "${UPSTREAM_SRC_DIR}/debian/patches/"
}

patch_debian_packaging() {
  cd "${UPSTREAM_SRC_DIR}"

  # The distro packaging is dh-golang based and pins golang-*-dev build-deps that
  # cannot satisfy this version's modern go.mod. But the runtime package is
  # Architecture: all and ships only config files + man pages, so we bypass the
  # Go toolchain entirely: render man pages with go-md2man and copy config files.
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

  # Build only the runtime config package; drop the -dev (gocode source) package
  # which would otherwise require the dh-golang build path.
  awk 'BEGIN{RS="";ORS="\n\n"} !/Package: golang-github-containers-common-dev/' debian/control > debian/control.new
  mv debian/control.new debian/control
  rm -f debian/golang-github-containers-common-dev.install debian/golang-github-containers-common-dev.*

  # Ship config files (upstream) + Debian-provided policy/shortnames + man pages.
  # policy.json and shortnames.conf come from the distro debian/ tree; include them
  # only if present so the build is robust across distro packaging variants.
  {
    [[ -f debian/etc/containers/policy.json ]] && printf '%s\n' 'debian/etc/containers/policy.json	/etc/containers/'
    [[ -f debian/shortnames.conf ]] && printf '%s\n' 'debian/shortnames.conf	/etc/containers/registries.conf.d'
    printf '%s\n' 'pkg/config/containers.conf	/usr/share/containers'
    printf '%s\n' 'pkg/seccomp/seccomp.json	/usr/share/containers'
    printf '%s\n' 'usr/share/man/man5	/usr/share/man'
  } > debian/golang-github-containers-common.install
}

update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local build_id="${BUILD_VERSION}-${BUILD_REVISION}"
  local package_version="${CONTAINERS_COMMON_VERSION}+${build_id}~${DISTRO}"

  export DEBFULLNAME="Containers-Common Debian 13 Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream containers-common ${CONTAINERS_COMMON_TAG} (${build_id}) with Debian ${DISTRO} packaging and repo-managed patch series."
}

build_package() {
  cd "${UPSTREAM_SRC_DIR}"

  log "Applying patch series from ${PATCH_SOURCE_DIR}/series"
  dpkg-source --before-build .

  export DEB_BUILD_OPTIONS="nocheck noautodbgsym"

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  # -d: skip distro build-dep checks; the build needs only go-md2man + debhelper.
  dpkg-buildpackage -b -uc -us -d 2>&1 | tee "${build_log}"
}

collect_artifacts() {
  local parent_dir
  parent_dir="$(dirname "${UPSTREAM_SRC_DIR}")"

  shopt -s nullglob
  local artifacts=(
    "${parent_dir}"/*.deb
    "${parent_dir}"/*.changes
    "${parent_dir}"/*.buildinfo
    "${parent_dir}"/*.dsc
    "${parent_dir}"/*.tar.*
  )
  shopt -u nullglob

  [[ "${#artifacts[@]}" -gt 0 ]] || die "no build artifacts were produced"

  cp -f "${artifacts[@]}" "${OUT_DIR}/"

  (
    cd "${OUT_DIR}"
    shopt -s nullglob
    checksum_files=( *.deb *.changes *.buildinfo *.dsc *.tar.* )
    if [[ "${#checksum_files[@]}" -gt 0 ]]; then
      sha256sum "${checksum_files[@]}" > SHA256SUMS
    fi
  )
}

main() {
  log "Starting Debian 13 containerized containers-common build for ${TARGET_ARCH} (${CONTAINERS_COMMON_TAG})"
  setup_sources
  install_prereqs
  prepare_sources
  patch_debian_packaging
  update_changelog
  build_package
  collect_artifacts
  log "Completed Debian 13 containers-common build for ${TARGET_ARCH} (${CONTAINERS_COMMON_TAG})"
}

main
