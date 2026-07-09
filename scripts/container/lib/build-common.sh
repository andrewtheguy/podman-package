#!/usr/bin/env bash

validate_common_container_env() {
  : "${PRODUCT:?PRODUCT is required}"
  : "${DISTRO_FAMILY:?DISTRO_FAMILY is required}"
  : "${DISTRO:?DISTRO is required}"
  : "${TARGET_ARCH:?TARGET_ARCH is required}"
  : "${BUILD_VERSION:?BUILD_VERSION is required}"
  : "${BUILD_REVISION:=1}"

  [[ "${BUILD_REVISION}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_REVISION must be a positive integer: ${BUILD_REVISION}"

  case "${TARGET_ARCH}" in
    amd64|arm64) ;;
    *) die "unsupported TARGET_ARCH: ${TARGET_ARCH}" ;;
  esac

  case "${DISTRO_FAMILY}/${DISTRO}" in
    ubuntu/noble)
      DISTRO_NAME="Ubuntu"
      DISTRO_LABEL="Ubuntu 24.04"
      ;;
    ubuntu/resolute)
      DISTRO_NAME="Ubuntu"
      DISTRO_LABEL="Ubuntu 26.04"
      ;;
    debian/trixie)
      DISTRO_NAME="Debian"
      DISTRO_LABEL="Debian 13"
      ;;
    *)
      die "unsupported target: ${DISTRO_FAMILY}/${DISTRO}"
      ;;
  esac

  PATCH_SOURCE_DIR="/workspace/packaging/${PRODUCT}/${DISTRO_FAMILY}/${DISTRO}/patches"
  [[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
  [[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"

  OUT_DIR="/out/${DISTRO}/${BUILD_VERSION}/${TARGET_ARCH}"
}

setup_apt_sources() {
  case "${DISTRO_FAMILY}" in
    ubuntu)
      [[ "${DISTRO}" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid Ubuntu codename: ${DISTRO}"
      cat > /etc/apt/sources.list.d/ubuntu-src.list <<EOF_APT
deb-src http://archive.ubuntu.com/ubuntu ${DISTRO} main universe multiverse restricted
deb-src http://archive.ubuntu.com/ubuntu ${DISTRO}-updates main universe multiverse restricted
deb-src http://archive.ubuntu.com/ubuntu ${DISTRO}-security main universe multiverse restricted
EOF_APT
      ;;
    debian)
      [[ "${DISTRO}" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid Debian codename: ${DISTRO}"
      cat > /etc/apt/sources.list <<EOF_APT
deb http://deb.debian.org/debian ${DISTRO} main
deb http://deb.debian.org/debian ${DISTRO}-updates main
deb http://deb.debian.org/debian-security ${DISTRO}-security main
deb-src http://deb.debian.org/debian ${DISTRO} main
deb-src http://deb.debian.org/debian ${DISTRO}-updates main
deb-src http://deb.debian.org/debian-security ${DISTRO}-security main
EOF_APT
      ;;
    *)
      die "unsupported DISTRO_FAMILY: ${DISTRO_FAMILY}"
      ;;
  esac
}

install_packages() {
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "$@"
}

fetch_distro_source() {
  local source_package="$1"
  local source_glob="$2"
  local output_var="$3"

  log "Fetching ${DISTRO_LABEL} ${source_package} source package"
  apt-get source -qq "${source_package}"

  local source_dir
  source_dir="$(find "${WORK_ROOT}" -maxdepth 1 -mindepth 1 -type d -name "${source_glob}" | head -n 1)"
  [[ -n "${source_dir}" ]] || die "unable to locate unpacked ${DISTRO_LABEL} ${source_package} source directory"

  printf -v "${output_var}" '%s' "${source_dir}"
}

replace_debian_patches() {
  local upstream_src_dir="$1"

  rm -rf "${upstream_src_dir}/debian/patches"
  mkdir -p "${upstream_src_dir}/debian/patches"
  cp -a "${PATCH_SOURCE_DIR}/." "${upstream_src_dir}/debian/patches/"
}

derive_go_toolchain_from_go_mod() {
  local go_mod="$1"
  local output_var="$2"
  local version

  version="$(awk '/^go[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?$/ {print $2; exit}' "${go_mod}")"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "unable to read required Go version from ${go_mod}"

  printf -v "${output_var}" '%s' "${version}"
}

install_go_toolchain() {
  local go_version="$1"
  local go_arch

  case "${TARGET_ARCH}" in
    amd64) go_arch="amd64" ;;
    arm64) go_arch="arm64" ;;
    *) die "unsupported TARGET_ARCH for Go toolchain download: ${TARGET_ARCH}" ;;
  esac

  local go_filename="go${go_version}.linux-${go_arch}.tar.gz"
  local go_url="https://go.dev/dl/${go_filename}"
  local go_tgz="/tmp/${go_filename}"
  local expected_sha256

  expected_sha256="$(
    curl -fsSL -L "https://go.dev/dl/?mode=json&include=all" | jq -r \
      --arg go_version "go${go_version}" \
      --arg go_filename "${go_filename}" '
        map(select(.version == $go_version)) | .[0].files[]? | select(.filename == $go_filename) | .sha256
      ' | head -n 1
  )"
  [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || die "unable to retrieve valid Go checksum for ${go_filename}"

  log "Installing Go toolchain ${go_version} for ${go_arch} from ${go_url}"
  curl -fsSL -o "${go_tgz}" -L "${go_url}"
  echo "${expected_sha256}  ${go_tgz}" | sha256sum -c - >/dev/null || die "Go checksum verification failed for ${go_tgz}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${go_tgz}"

  export GOROOT="/usr/local/go"
  export PATH="/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  local actual_go_version
  actual_go_version="$(go env GOVERSION)"
  [[ "${actual_go_version#go}" == "${go_version}" ]] || die "unexpected Go version: ${actual_go_version}, expected go${go_version}"
}

install_rust_toolchain() {
  local rust_version="$1"
  local triple

  case "${TARGET_ARCH}" in
    amd64) triple="x86_64-unknown-linux-gnu" ;;
    arm64) triple="aarch64-unknown-linux-gnu" ;;
    *) die "unsupported TARGET_ARCH for Rust toolchain download: ${TARGET_ARCH}" ;;
  esac

  local rust_dir="rust-${rust_version}-${triple}"
  local rust_tarball="/tmp/${rust_dir}.tar.gz"
  local rust_url="https://static.rust-lang.org/dist/${rust_dir}.tar.gz"
  local expected_sha256

  expected_sha256="$(curl -fsSL -L "${rust_url}.sha256" | awk '{print $1}')"
  [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || die "unable to retrieve valid Rust checksum for ${rust_url}"

  log "Installing Rust toolchain ${rust_version} for ${triple} from ${rust_url}"
  curl -fsSL -o "${rust_tarball}" -L "${rust_url}"
  echo "${expected_sha256}  ${rust_tarball}" | sha256sum -c - >/dev/null || die "Rust checksum verification failed for ${rust_tarball}"

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
  [[ "${actual_rust_version}" == "${rust_version}" ]] || die "unexpected Rust version: ${actual_rust_version}, expected ${rust_version}"
}

apply_patch_series() {
  local upstream_src_dir="$1"

  cd "${upstream_src_dir}"
  log "Applying patch series from ${PATCH_SOURCE_DIR}/series"
  dpkg-source --before-build .
}

collect_artifacts() {
  local upstream_src_dir="$1"
  local parent_dir
  parent_dir="$(dirname "${upstream_src_dir}")"

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
