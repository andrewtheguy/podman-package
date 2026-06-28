#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ $# -ne 0 ]]; then
  die "in-container Ubuntu 26.04 containers-storage build script does not accept arguments"
fi

: "${CONTAINERS_STORAGE_TAG:?CONTAINERS_STORAGE_TAG is required}"
: "${CONTAINERS_STORAGE_VERSION:?CONTAINERS_STORAGE_VERSION is required}"
: "${CONTAINERS_STORAGE_ARCHIVE_SHA256:?CONTAINERS_STORAGE_ARCHIVE_SHA256 is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${BUILD_VERSION:?BUILD_VERSION is required}"
: "${BUILD_REVISION:=1}"
: "${DISTRO:=resolute}"

[[ "${BUILD_REVISION}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_REVISION must be a positive integer: ${BUILD_REVISION}"

PATCH_SOURCE_DIR="/workspace/packaging/patches-containers-storage-ubuntu-resolute"
[[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
[[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"

WORK_ROOT="/tmp/containers-storage-build"
OUT_DIR="/out/${DISTRO}/${BUILD_VERSION}/${TARGET_ARCH}"
DEBIAN_SRC_DIR=""
UPSTREAM_SRC_DIR=""
GO_TOOLCHAIN_VERSION=""

setup_sources() {
  [[ "${DISTRO}" =~ ^[a-z][a-z0-9-]*$ ]] || \
    die "setup_sources: invalid DISTRO='${DISTRO}' (expected lower-case letters, digits, or hyphens) for /etc/apt/sources.list.d/ubuntu-src.list"

  cat > /etc/apt/sources.list.d/ubuntu-src.list <<EOF
deb-src http://archive.ubuntu.com/ubuntu ${DISTRO} main universe multiverse restricted
deb-src http://archive.ubuntu.com/ubuntu ${DISTRO}-updates main universe multiverse restricted
deb-src http://archive.ubuntu.com/ubuntu ${DISTRO}-security main universe multiverse restricted
EOF
}

install_prereqs() {
  apt-get update -qq
  # containers-storage is a CGO Go build: gcc + the storage C deps (btrfs, libsubid)
  # determine the build tags. go-md2man renders man pages; the Go toolchain itself
  # is installed separately (derived from upstream go.mod).
  apt-get install -y -qq --no-install-recommends \
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
}

prepare_sources() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}"
  cd "${WORK_ROOT}"

  log "Fetching Ubuntu ${DISTRO} golang-github-containers-storage source package"
  apt-get source -qq containers-storage
  DEBIAN_SRC_DIR="$(find "${WORK_ROOT}" -maxdepth 1 -mindepth 1 -type d -name 'golang-github-containers-storage-*' | head -n 1)"
  [[ -n "${DEBIAN_SRC_DIR}" ]] || die "unable to locate unpacked Ubuntu containers-storage source directory"

  # Upstream source for the matching version lives in the containers/container-libs
  # monorepo under storage/; the GitHub tag archive top dir is container-libs-storage-v<ver>.
  local archive="${WORK_ROOT}/container-libs-storage-${CONTAINERS_STORAGE_VERSION}.tar.gz"
  local archive_url="https://github.com/containers/container-libs/archive/refs/tags/${CONTAINERS_STORAGE_TAG}.tar.gz"
  log "Downloading upstream containers-storage source: ${archive_url}"
  curl -fsSL -o "${archive}" -L "${archive_url}"
  verify_sha256 "${archive}" "${CONTAINERS_STORAGE_ARCHIVE_SHA256}"
  tar -xzf "${archive}" -C "${WORK_ROOT}"

  local monorepo_storage="${WORK_ROOT}/container-libs-storage-v${CONTAINERS_STORAGE_VERSION}/storage"
  [[ -d "${monorepo_storage}" ]] || die "unable to locate storage/ subdir in extracted container-libs archive"
  UPSTREAM_SRC_DIR="${WORK_ROOT}/golang-github-containers-storage-${CONTAINERS_STORAGE_VERSION}"
  mv "${monorepo_storage}" "${UPSTREAM_SRC_DIR}"

  cp -a "${DEBIAN_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"

  # Deterministic patch policy: replace distro patches with repository-managed patches.
  rm -rf "${UPSTREAM_SRC_DIR}/debian/patches"
  mkdir -p "${UPSTREAM_SRC_DIR}/debian/patches"
  cp -a "${PATCH_SOURCE_DIR}/." "${UPSTREAM_SRC_DIR}/debian/patches/"
}

derive_go_version() {
  cd "${UPSTREAM_SRC_DIR}"
  # Prefer an explicit toolchain directive, fall back to the go directive.
  GO_TOOLCHAIN_VERSION="$(awk '
    /^toolchain[[:space:]]+go[0-9]+\.[0-9]+(\.[0-9]+)?$/ { v=$2; sub(/^go/,"",v); print v; exit }
  ' go.mod)"
  if [[ -z "${GO_TOOLCHAIN_VERSION}" ]]; then
    GO_TOOLCHAIN_VERSION="$(awk '/^go[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?$/ {print $2; exit}' go.mod)"
  fi
  [[ "${GO_TOOLCHAIN_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
    die "unable to read required Go version from ${UPSTREAM_SRC_DIR}/go.mod"
}

install_go_toolchain() {
  local go_arch
  case "${TARGET_ARCH}" in
    amd64) go_arch="amd64" ;;
    arm64) go_arch="arm64" ;;
    *) die "unsupported TARGET_ARCH for Go toolchain download: ${TARGET_ARCH}" ;;
  esac

  local go_filename="go${GO_TOOLCHAIN_VERSION}.linux-${go_arch}.tar.gz"
  local go_url="https://go.dev/dl/${go_filename}"
  local go_tgz="/tmp/${go_filename}"

  local expected_sha256
  expected_sha256="$(
    curl -fsSL -L "https://go.dev/dl/?mode=json&include=all" | jq -r \
      --arg go_version "go${GO_TOOLCHAIN_VERSION}" \
      --arg go_filename "${go_filename}" '
        map(select(.version == $go_version)) | .[0].files[]? | select(.filename == $go_filename) | .sha256
      ' | head -n 1
  )"
  [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || \
    die "unable to retrieve valid Go checksum for ${go_filename} from go.dev JSON API"

  log "Installing Go toolchain ${GO_TOOLCHAIN_VERSION} for ${go_arch} from ${go_url}"
  curl -fsSL -o "${go_tgz}" -L "${go_url}"
  echo "${expected_sha256}  ${go_tgz}" | sha256sum -c - >/dev/null || \
    die "Go toolchain checksum verification failed for ${go_tgz}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${go_tgz}"

  export GOROOT="/usr/local/go"
  export PATH="/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  local actual_go_version
  actual_go_version="$(go env GOVERSION)"
  [[ "${actual_go_version#go}" == "${GO_TOOLCHAIN_VERSION}" ]] || \
    die "unexpected Go version after install: ${actual_go_version}, expected go${GO_TOOLCHAIN_VERSION}"
}

patch_debian_packaging() {
  cd "${UPSTREAM_SRC_DIR}"

  # The distro packaging is dh-golang/GOPATH based and pins golang-*-dev build-deps
  # that cannot satisfy this version's modern go.mod. Build the CLI with the
  # upstream Makefile against our own pinned Go toolchain (module-aware), then stage
  # the binary, the (graphroot-commented) storage.conf, and man pages by hand.
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

# The upstream docs install target ignores DESTDIR; stage man pages directly.
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

  # Build only the containers-storage CLI package (drop the -dev / other stanzas
  # that would otherwise require the dh-golang build path).
  awk 'BEGIN{RS="";ORS="\n\n"} /^Source:/ || /(^|\n)Package: containers-storage\n/ {print}' debian/control > debian/control.new
  mv debian/control.new debian/control
  find debian -maxdepth 1 -name '*.install' ! -name 'containers-storage.install' -delete

  cat > debian/containers-storage.install <<'EOF_INSTALL'
usr/bin/containers-storage
usr/share/containers/storage.conf
usr/share/man
EOF_INSTALL
}

update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local build_id="${BUILD_VERSION}-${BUILD_REVISION}"
  local package_version="${CONTAINERS_STORAGE_VERSION}+${build_id}~${DISTRO}"

  export DEBFULLNAME="Containers-Storage Resolute Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream containers-storage ${CONTAINERS_STORAGE_TAG} (${build_id}) with Ubuntu ${DISTRO} packaging and repo-managed patch series."
}

build_package() {
  cd "${UPSTREAM_SRC_DIR}"

  log "Applying patch series from ${PATCH_SOURCE_DIR}/series"
  dpkg-source --before-build .

  export DEB_BUILD_OPTIONS="nocheck noautodbgsym"

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  # -d: skip distro build-dep checks; build-deps are provided explicitly by
  # install_prereqs plus the self-installed Go toolchain.
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
  log "Starting Ubuntu 26.04 containerized containers-storage build for ${TARGET_ARCH} (${CONTAINERS_STORAGE_TAG})"
  setup_sources
  install_prereqs
  prepare_sources
  derive_go_version
  install_go_toolchain
  patch_debian_packaging
  update_changelog
  build_package
  collect_artifacts
  log "Completed Ubuntu 26.04 containers-storage build for ${TARGET_ARCH} (${CONTAINERS_STORAGE_TAG})"
}

main
