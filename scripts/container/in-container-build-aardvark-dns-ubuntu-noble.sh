#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ $# -ne 0 ]]; then
  die "in-container Ubuntu 24.04 aardvark-dns build script does not accept arguments"
fi

: "${AARDVARK_TAG:?AARDVARK_TAG is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${BUILD_VERSION:?BUILD_VERSION is required}"
: "${BUILD_REVISION:=1}"
: "${AARDVARK_UPSTREAM_SHA256:?AARDVARK_UPSTREAM_SHA256 is required}"
: "${AARDVARK_VENDOR_SHA256:?AARDVARK_VENDOR_SHA256 is required}"
: "${RUST_VERSION:?RUST_VERSION is required}"
: "${DISTRO:=noble}"

[[ "${BUILD_REVISION}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_REVISION must be a positive integer: ${BUILD_REVISION}"

PATCH_SOURCE_DIR="/workspace/packaging/patches-aardvark-dns-ubuntu-noble"
[[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
[[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"

WORK_ROOT="/tmp/aardvark-dns-build"
OUT_DIR="/out/${DISTRO}/${BUILD_VERSION}/${TARGET_ARCH}"
DEBIAN_SRC_DIR=""
UPSTREAM_VERSION=""
UPSTREAM_SRC_DIR=""

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
  apt-get install -y -qq --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    devscripts \
    dh-cargo \
    dpkg-dev \
    equivs \
    jq \
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

  log "Fetching Ubuntu ${DISTRO} aardvark-dns source package"
  apt-get source -qq aardvark-dns
  DEBIAN_SRC_DIR="$(find "${WORK_ROOT}" -maxdepth 1 -mindepth 1 -type d -name 'aardvark-dns-*' | head -n 1)"
  [[ -n "${DEBIAN_SRC_DIR}" ]] || die "unable to locate unpacked Ubuntu aardvark-dns source directory"

  local upstream_version="${AARDVARK_TAG#v}"
  UPSTREAM_VERSION="${upstream_version}"
  local upstream_tarball="${WORK_ROOT}/aardvark-dns-${upstream_version}.tar.gz"
  local upstream_url="https://github.com/containers/aardvark-dns/archive/refs/tags/${AARDVARK_TAG}.tar.gz"
  log "Downloading upstream aardvark-dns source: ${upstream_url}"
  curl -fsSL -o "${upstream_tarball}" -L "${upstream_url}"
  verify_sha256 "${upstream_tarball}" "${AARDVARK_UPSTREAM_SHA256}"
  tar -xzf "${upstream_tarball}" -C "${WORK_ROOT}"

  UPSTREAM_SRC_DIR="${WORK_ROOT}/aardvark-dns-${upstream_version}"
  [[ -d "${UPSTREAM_SRC_DIR}" ]] || die "unable to locate unpacked upstream source directory"
  cp -a "${DEBIAN_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"

  # Vendored crates from the upstream release tarball enable a deterministic,
  # offline cargo build that matches the pinned Cargo.lock.
  local vendor_tarball="${WORK_ROOT}/aardvark-dns-${AARDVARK_TAG}-vendor.tar.gz"
  local vendor_url="https://github.com/containers/aardvark-dns/releases/download/${AARDVARK_TAG}/aardvark-dns-${AARDVARK_TAG}-vendor.tar.gz"
  log "Downloading aardvark-dns vendored dependencies: ${vendor_url}"
  curl -fsSL -o "${vendor_tarball}" -L "${vendor_url}"
  verify_sha256 "${vendor_tarball}" "${AARDVARK_VENDOR_SHA256}"
  tar -xzf "${vendor_tarball}" -C "${UPSTREAM_SRC_DIR}"
  [[ -d "${UPSTREAM_SRC_DIR}/vendor" ]] || die "vendor directory missing after extracting ${vendor_tarball}"

  mkdir -p "${UPSTREAM_SRC_DIR}/.cargo"
  cat > "${UPSTREAM_SRC_DIR}/.cargo/config.toml" <<'EOF_CARGO'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF_CARGO

  # Deterministic patch policy: replace Ubuntu patches with repository-managed patches.
  rm -rf "${UPSTREAM_SRC_DIR}/debian/patches"
  mkdir -p "${UPSTREAM_SRC_DIR}/debian/patches"
  cp -a "${PATCH_SOURCE_DIR}/." "${UPSTREAM_SRC_DIR}/debian/patches/"
}

install_rust_toolchain() {
  local triple
  case "${TARGET_ARCH}" in
    amd64) triple="x86_64-unknown-linux-gnu" ;;
    arm64) triple="aarch64-unknown-linux-gnu" ;;
    *) die "unsupported TARGET_ARCH for Rust toolchain download: ${TARGET_ARCH}" ;;
  esac

  local rust_dir="rust-${RUST_VERSION}-${triple}"
  local rust_tarball="/tmp/${rust_dir}.tar.gz"
  local rust_url="https://static.rust-lang.org/dist/${rust_dir}.tar.gz"
  local sha_url="${rust_url}.sha256"

  local expected_sha256
  expected_sha256="$(curl -fsSL -L "${sha_url}" | awk '{print $1}')"
  [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || \
    die "unable to retrieve valid Rust checksum from ${sha_url}"

  log "Installing Rust toolchain ${RUST_VERSION} for ${triple} from ${rust_url}"
  curl -fsSL -o "${rust_tarball}" -L "${rust_url}"
  echo "${expected_sha256}  ${rust_tarball}" | sha256sum -c - >/dev/null || \
    die "Rust toolchain checksum verification failed for ${rust_tarball}"

  rm -rf /tmp/rust-install
  mkdir -p /tmp/rust-install
  tar -C /tmp/rust-install --strip-components=1 -xzf "${rust_tarball}"
  /tmp/rust-install/install.sh \
    --prefix=/usr/local \
    --components="rustc,cargo,rust-std-${triple}" \
    --disable-ldconfig >/dev/null

  export CARGO_HOME=/usr/local/cargo
  export PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

  local actual_rust_version
  actual_rust_version="$(rustc --version | awk '{print $2}')"
  [[ "${actual_rust_version}" == "${RUST_VERSION}" ]] || \
    die "unexpected Rust version after install: ${actual_rust_version}, expected ${RUST_VERSION}"
}

patch_debian_rules() {
  cd "${UPSTREAM_SRC_DIR}"

  # The distro packaging is dh-cargo based and pins librust-*-dev build-deps that
  # cannot satisfy aardvark-dns's modern Cargo.lock. Build with the upstream
  # Makefile against the vendored crates and our own pinned Rust toolchain
  # instead. aardvark-dns ships a single binary (no systemd units, no man page).
  cat >> debian/rules <<'EOF_MODULE_BUILD'

override_dh_auto_configure:
	mkdir -p bin

# Do NOT call `make clean`: its `$(MAKE) -C docs clean` recurses into a docs
# Makefile that does not exist in this release and would abort the build.
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

# The distro's execute_after_dh_install hook assumes the dh-cargo binary layout
# (debian/aardvark-dns/usr/bin) and relocates it; our make-based install already
# stages the final /usr/lib/podman layout, so neutralize the hook.
execute_after_dh_install:
	true

# Distro packaging may ship a different file list than upstream `make install`.
# debian/aardvark-dns.install captures everything we intend to ship.
override_dh_missing:
	dh_missing
EOF_MODULE_BUILD
}

patch_debian_packaging() {
  cd "${UPSTREAM_SRC_DIR}"

  # aardvark-dns v2.0.0 installs only the binary (no systemd units, no man page).
  cat > debian/aardvark-dns.install <<'EOF_INSTALL'
usr/lib/podman/aardvark-dns
EOF_INSTALL

  # Older distro packaging may reference a man page that this release no longer
  # ships, which would make dh_installman fail. Drop those references.
  rm -f debian/aardvark-dns.manpages debian/manpages
}

update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local debianized_upstream="${UPSTREAM_VERSION//-rc/~rc}"
  local build_id="${BUILD_VERSION}-${BUILD_REVISION}"
  local package_version="${debianized_upstream}+${build_id}~${DISTRO}"

  export DEBFULLNAME="Aardvark-DNS Noble Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream aardvark-dns ${AARDVARK_TAG} (${build_id}) with Ubuntu ${DISTRO} packaging and repo-managed patch series."
}

build_package() {
  cd "${UPSTREAM_SRC_DIR}"

  log "Applying patch series from ${PATCH_SOURCE_DIR}/series"
  dpkg-source --before-build .

  export DEB_BUILD_OPTIONS="nocheck noautodbgsym"
  export CARGO_NET_OFFLINE=true

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  # -d: skip distro build-dep checks; build-deps are provided explicitly by
  # install_prereqs plus the self-installed Rust toolchain and vendored crates.
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
  log "Starting Ubuntu 24.04 containerized aardvark-dns build for ${TARGET_ARCH} (${AARDVARK_TAG})"
  setup_sources
  install_prereqs
  prepare_sources
  install_rust_toolchain
  patch_debian_rules
  patch_debian_packaging
  update_changelog
  build_package
  collect_artifacts
  log "Completed Ubuntu 24.04 aardvark-dns build for ${TARGET_ARCH} (${AARDVARK_TAG})"
}

main
