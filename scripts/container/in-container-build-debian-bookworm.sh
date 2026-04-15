#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ $# -ne 0 ]]; then
  die "in-container Debian 12 build script does not accept arguments"
fi

: "${PODMAN_TAG:?PODMAN_TAG is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${BUILD_VERSION:?BUILD_VERSION is required}"
: "${UPSTREAM_SHA256:?UPSTREAM_SHA256 is required}"
: "${DISTRO:=bookworm}"

PATCH_SOURCE_DIR="/workspace/packaging/patches-bookworm"
[[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
[[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"

WORK_ROOT="/tmp/podman-build"
OUT_DIR="/out/${DISTRO}/${BUILD_VERSION}/${TARGET_ARCH}"
GO_TOOLCHAIN_VERSION=""
GO_TOOLCHAIN_ARCH=""
DEBIAN_SRC_DIR=""
UPSTREAM_VERSION=""
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
  apt-get install -y -qq --no-install-recommends \
    ca-certificates \
    curl \
    devscripts \
    dpkg-dev \
    equivs \
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

  log "Fetching Debian ${DISTRO} libpod source package"
  apt-get source -qq libpod
  DEBIAN_SRC_DIR="$(find "${WORK_ROOT}" -maxdepth 1 -mindepth 1 -type d -name 'libpod-*' | head -n 1)"
  [[ -n "${DEBIAN_SRC_DIR}" ]] || die "unable to locate unpacked Debian libpod source directory"

  local upstream_version="${PODMAN_TAG#v}"
  UPSTREAM_VERSION="${upstream_version}"
  local upstream_tarball="${WORK_ROOT}/podman-${upstream_version}.tar.gz"
  local upstream_url="https://github.com/containers/podman/archive/refs/tags/${PODMAN_TAG}.tar.gz"
  log "Downloading upstream Podman source: ${upstream_url}"
  curl -fsSL -o "${upstream_tarball}" -L "${upstream_url}"

  local expected_sha256="${UPSTREAM_SHA256,,}"
  [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || \
    die "invalid UPSTREAM_SHA256 format: ${UPSTREAM_SHA256}"
  local actual_sha256
  actual_sha256="$(sha256sum "${upstream_tarball}" | awk '{print $1}')"
  [[ "${actual_sha256}" == "${expected_sha256}" ]] || \
    die "upstream tarball checksum mismatch for ${upstream_tarball}: expected ${expected_sha256}, got ${actual_sha256}"

  tar -xzf "${upstream_tarball}" -C "${WORK_ROOT}"

  UPSTREAM_SRC_DIR="${WORK_ROOT}/podman-${upstream_version}"
  [[ -d "${UPSTREAM_SRC_DIR}" ]] || die "unable to locate unpacked upstream source directory"
  cp -a "${DEBIAN_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"

  local debian_cni_config="${DEBIAN_SRC_DIR}/cni/87-podman-bridge.conflist"
  if [[ -f "${debian_cni_config}" ]]; then
    mkdir -p "${UPSTREAM_SRC_DIR}/cni"
    cp -a "${debian_cni_config}" "${UPSTREAM_SRC_DIR}/cni/"
  fi

  # Deterministic patch policy: replace distro patches with repository-managed patches.
  rm -rf "${UPSTREAM_SRC_DIR}/debian/patches"
  mkdir -p "${UPSTREAM_SRC_DIR}/debian/patches"
  cp -a "${PATCH_SOURCE_DIR}/." "${UPSTREAM_SRC_DIR}/debian/patches/"

  GO_TOOLCHAIN_VERSION="$(awk '/^go[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?$/ {print $2; exit}' "${UPSTREAM_SRC_DIR}/go.mod")"
  if [[ -z "${GO_TOOLCHAIN_VERSION}" ]]; then
    GO_TOOLCHAIN_VERSION="$(awk '
      /^toolchain[[:space:]]+go[0-9]+\.[0-9]+(\.[0-9]+)?$/ {
        version=$2
        sub(/^go/, "", version)
        print version
        exit
      }
    ' "${UPSTREAM_SRC_DIR}/go.mod")"
  fi
  [[ -n "${GO_TOOLCHAIN_VERSION}" ]] || die "unable to read required Go version from ${UPSTREAM_SRC_DIR}/go.mod"
}

install_go_toolchain() {
  case "${TARGET_ARCH}" in
    amd64) GO_TOOLCHAIN_ARCH="amd64" ;;
    arm64) GO_TOOLCHAIN_ARCH="arm64" ;;
    *) die "unsupported TARGET_ARCH for Go toolchain download: ${TARGET_ARCH}" ;;
  esac

  local go_tgz="/tmp/go${GO_TOOLCHAIN_VERSION}.linux-${GO_TOOLCHAIN_ARCH}.tar.gz"
  local go_url="https://go.dev/dl/go${GO_TOOLCHAIN_VERSION}.linux-${GO_TOOLCHAIN_ARCH}.tar.gz"
  local go_filename="go${GO_TOOLCHAIN_VERSION}.linux-${GO_TOOLCHAIN_ARCH}.tar.gz"
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

  log "Installing Go toolchain ${GO_TOOLCHAIN_VERSION} for ${GO_TOOLCHAIN_ARCH} from ${go_url}"
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

patch_debian_rules() {
  cd "${UPSTREAM_SRC_DIR}"

  if ! grep -q '^export DH_GOLANG_INSTALL_ALL := 1$' debian/rules; then
    awk '
      /^export DH_GOLANG_INSTALL_EXTRA/ && !inserted {
        print
        print "export DH_GOLANG_INSTALL_ALL := 1"
        inserted=1
        next
      }
      { print }
      END {
        if (!inserted) {
          print "export DH_GOLANG_INSTALL_ALL := 1"
        }
      }
    ' debian/rules > debian/rules.new
    mv debian/rules.new debian/rules
    chmod +x debian/rules
  fi

  if ! grep -q '^override_dh_golang:' debian/rules; then
    cat >> debian/rules <<'EOF_RULES'

override_dh_golang:
	@echo "Skipping dh_golang in local builder workflow"
	true
EOF_RULES
  fi

  # Bookworm's libpod packaging (Podman 4.3.1 era) is incompatible with Podman 5.8.x:
  # - dh-golang's dh_auto_configure creates _output as a GOPATH symlink tree;
  #   skip it and just mkdir so dh_auto_clean doesn't chdir-fail.
  # - dh_auto_build runs "go generate" on all packages which fails with 5.8.x;
  #   use upstream Makefile targets directly instead.
  # Appending at EOF: last definition wins in GNU Make, so these override any
  # earlier definitions without needing to remove them.
  cat >> debian/rules <<'EOF_BOOKWORM'

override_dh_auto_configure:
	mkdir -p _output

override_dh_auto_build:
	$(MAKE) GOMD2MAN=go-md2man podman podman-remote rootlessport quadlet docs docker-docs
EOF_BOOKWORM
}

patch_debian_packaging() {
  cd "${UPSTREAM_SRC_DIR}"

  local podman_docker_install="debian/podman-docker.install"
  if [[ -f "${podman_docker_install}" ]]; then
    for entry in \
      "etc/profile.d/podman-docker.sh" \
      "etc/profile.d/podman-docker.csh"; do
      grep -qxF "${entry}" "${podman_docker_install}" || echo "${entry}" >> "${podman_docker_install}"
    done
  fi

  local not_installed_file="debian/not-installed"
  touch "${not_installed_file}"
  for entry in \
    "usr/bin/podman-testing" \
    ".config/go/telemetry/local/*" \
    ".config/go/telemetry/*"; do
    grep -qxF "${entry}" "${not_installed_file}" || echo "${entry}" >> "${not_installed_file}"
  done
}

update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local debianized_upstream="${UPSTREAM_VERSION//-rc/~rc}"
  local package_version="${debianized_upstream}+local1.${BUILD_VERSION}~${DISTRO}"

  export DEBFULLNAME="Podman Bookworm Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream ${PODMAN_TAG} (${BUILD_VERSION}) with Debian ${DISTRO} packaging and repo-managed patch series."
}

install_build_deps() {
  cd "${UPSTREAM_SRC_DIR}"
  apt-get update -qq
  mk-build-deps \
    --install \
    --remove \
    --tool "apt-get -y --no-install-recommends" \
    debian/control
}

build_package() {
  cd "${UPSTREAM_SRC_DIR}"

  log "Applying patch series from /workspace/packaging/patches-bookworm/series"
  dpkg-source --before-build .

  # Containerized build isolation blocks some upstream tests (e.g. /proc/self/exe re-exec).
  # Keep behavior deterministic by always skipping build-time tests.
  export DEB_BUILD_OPTIONS="nocheck"
  export GOTELEMETRY="off"
  # Podman v5.8+ Makefile requires RELEASE_VERSION even for clean.
  export RELEASE_VERSION="${PODMAN_TAG}"

  # Podman 5.8+ Makefile tries to build go-md2man from test/tools/vendor/ which
  # fails with bookworm-era source layout. Symlink the system binary (installed
  # as a build dependency) so the Makefile skips the vendor build.
  if command -v go-md2man >/dev/null 2>&1; then
    mkdir -p "${UPSTREAM_SRC_DIR}/test/tools/build"
    ln -sf "$(command -v go-md2man)" "${UPSTREAM_SRC_DIR}/test/tools/build/go-md2man"
  fi

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  dpkg-buildpackage -b -uc -us 2>&1 | tee "${build_log}"
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
  log "Starting Debian 12 containerized build for ${TARGET_ARCH} (${PODMAN_TAG})"
  setup_sources
  install_prereqs
  prepare_sources
  install_go_toolchain
  patch_debian_rules
  patch_debian_packaging
  update_changelog
  install_build_deps
  build_package
  collect_artifacts
  log "Completed Debian 12 build for ${TARGET_ARCH} (${PODMAN_TAG})"
}

main
