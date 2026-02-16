#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ $# -ne 0 ]]; then
  die "in-container Debian 13 build script does not accept arguments"
fi

: "${PODMAN_TAG:?PODMAN_TAG is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${BUILD_VERSION:?BUILD_VERSION is required}"
: "${DISTRO:=trixie}"

PATCH_SOURCE_DIR="/workspace/packaging/patches-debian13"
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
    patch \
    quilt \
    tar \
    xz-utils
}

prepare_sources() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}"
  cd "${WORK_ROOT}"

  log "Fetching Debian ${DISTRO} podman source package"
  apt-get source -qq podman
  DEBIAN_SRC_DIR="$(find "${WORK_ROOT}" -maxdepth 1 -mindepth 1 -type d -name 'podman-*' | head -n 1)"
  [[ -n "${DEBIAN_SRC_DIR}" ]] || die "unable to locate unpacked Debian podman source directory"

  local upstream_version="${PODMAN_TAG#v}"
  UPSTREAM_VERSION="${upstream_version}"
  local upstream_tarball="${WORK_ROOT}/podman-${upstream_version}.tar.gz"
  local upstream_url="https://github.com/containers/podman/archive/refs/tags/${PODMAN_TAG}.tar.gz"
  log "Downloading upstream Podman source: ${upstream_url}"
  curl -fsSL -o "${upstream_tarball}" -L "${upstream_url}"
  tar -xzf "${upstream_tarball}" -C "${WORK_ROOT}"

  UPSTREAM_SRC_DIR="${WORK_ROOT}/podman-${upstream_version}"
  [[ -d "${UPSTREAM_SRC_DIR}" ]] || die "unable to locate unpacked upstream source directory"
  cp -a "${DEBIAN_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"

  local debian_cni_config="${DEBIAN_SRC_DIR}/cni/87-podman-bridge.conflist"
  [[ -f "${debian_cni_config}" ]] || die "required Debian asset missing: ${debian_cni_config}"
  mkdir -p "${UPSTREAM_SRC_DIR}/cni"
  cp -a "${debian_cni_config}" "${UPSTREAM_SRC_DIR}/cni/"

  # Deterministic patch policy: replace distro patches with repository-managed patches.
  rm -rf "${UPSTREAM_SRC_DIR}/debian/patches"
  mkdir -p "${UPSTREAM_SRC_DIR}/debian/patches"
  cp -a "${PATCH_SOURCE_DIR}/." "${UPSTREAM_SRC_DIR}/debian/patches/"

  GO_TOOLCHAIN_VERSION="$(awk '/^go[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?$/ {print $2; exit}' "${UPSTREAM_SRC_DIR}/go.mod")"
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

  log "Installing Go toolchain ${GO_TOOLCHAIN_VERSION} for ${GO_TOOLCHAIN_ARCH} from ${go_url}"
  curl -fsSL -o "${go_tgz}" -L "${go_url}"
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

  export DEBFULLNAME="Podman Debian 13 Builder"
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

  log "Applying patch series from /workspace/packaging/patches-debian13/series"
  dpkg-source --before-build .

  # Containerized build isolation blocks some upstream tests (e.g. /proc/self/exe re-exec).
  # Keep behavior deterministic by always skipping Debian build-time tests.
  export DEB_BUILD_OPTIONS="nocheck"
  export GOTELEMETRY="off"

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
  log "Starting Debian 13 containerized build for ${TARGET_ARCH} (${PODMAN_TAG})"
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
  log "Completed Debian 13 build for ${TARGET_ARCH} (${PODMAN_TAG})"
}

main
