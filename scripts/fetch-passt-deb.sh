#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_CONFIG="${REPO_ROOT}/packaging/versions.env"

usage() {
  echo "Usage: $0 <ubuntu|debian> <amd64|arm64> <output-directory>" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

origin="$1"
arch="$2"
output_dir="$3"

# shellcheck disable=SC1090
source "${VERSION_CONFIG}"

: "${PASST_VERSION:?PASST_VERSION is required}"

case "${origin}/${arch}" in
  ubuntu/amd64)
    url="${PASST_UBUNTU_AMD64_URL:-}"
    expected_sha256="${PASST_UBUNTU_AMD64_SHA256:-}"
    ;;
  ubuntu/arm64)
    url="${PASST_UBUNTU_ARM64_URL:-}"
    expected_sha256="${PASST_UBUNTU_ARM64_SHA256:-}"
    ;;
  debian/amd64)
    url="${PASST_DEBIAN_AMD64_URL:-}"
    expected_sha256="${PASST_DEBIAN_AMD64_SHA256:-}"
    ;;
  debian/arm64)
    url="${PASST_DEBIAN_ARM64_URL:-}"
    expected_sha256="${PASST_DEBIAN_ARM64_SHA256:-}"
    ;;
  *)
    usage
    die "unsupported passt binary target: ${origin}/${arch}"
    ;;
esac

[[ -n "${url}" ]] || die "missing URL for ${origin}/${arch}"
[[ "${expected_sha256}" =~ ^[0-9a-fA-F]{64}$ ]] || \
  die "invalid SHA256 for ${origin}/${arch}: ${expected_sha256:-<empty>}"

mkdir -p "${output_dir}"
output_path="${output_dir}/passt_${PASST_VERSION}_${origin}_${arch}.deb"
temporary_path="${output_path}.part"
trap 'rm -f "${temporary_path}"' EXIT

echo "Downloading pinned passt ${PASST_VERSION} binary for ${origin}/${arch}"
curl --fail --show-error --silent --location \
  --retry 3 --retry-all-errors \
  --output "${temporary_path}" \
  "${url}"

actual_sha256="$(sha256sum "${temporary_path}" | awk '{print $1}')"
[[ "${actual_sha256}" == "${expected_sha256,,}" ]] || \
  die "checksum mismatch for ${origin}/${arch}: expected ${expected_sha256,,}, got ${actual_sha256}"

if command -v dpkg-deb >/dev/null 2>&1; then
  actual_package="$(dpkg-deb -f "${temporary_path}" Package)"
  actual_version="$(dpkg-deb -f "${temporary_path}" Version)"
  actual_arch="$(dpkg-deb -f "${temporary_path}" Architecture)"
  [[ "${actual_package}" == "passt" ]] || die "unexpected package: ${actual_package}"
  [[ "${actual_version}" == "${PASST_VERSION}" ]] || die "unexpected version: ${actual_version}"
  [[ "${actual_arch}" == "${arch}" ]] || die "unexpected architecture: ${actual_arch}"
fi

mv "${temporary_path}" "${output_path}"
trap - EXIT
echo "Verified ${actual_sha256}  ${output_path}"
