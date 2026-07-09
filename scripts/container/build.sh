#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/lib/build-common.sh"

if [[ $# -ne 0 ]]; then
  die "container build script does not accept arguments"
fi

validate_common_container_env

case "${PRODUCT}" in
  podman)
    source "${SCRIPT_DIR}/products/podman.sh"
    ;;
  netavark|aardvark-dns)
    source "${SCRIPT_DIR}/products/rust-companion.sh"
    ;;
  containers-common|containers-storage)
    source "${SCRIPT_DIR}/products/container-libs.sh"
    ;;
  *)
    die "unsupported PRODUCT: ${PRODUCT}"
    ;;
esac

product_main
