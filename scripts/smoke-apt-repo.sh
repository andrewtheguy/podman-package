#!/usr/bin/env bash
# Install Podman from an assembled (not yet deployed) APT repository inside a
# throwaway container per suite, to prove the published metadata is usable.
#
# Usage: scripts/smoke-apt-repo.sh <repo-root> [suite ...]
#
#   <repo-root>  Output of scripts/build-apt-repo.sh (contains dists/, pool/).
#   [suite ...]  Suites to test (default: every suite in packaging/repo/suites).
#
# For each suite the matching official image (<family>:<suite>) mounts the repo
# read-only, adds it as a `file:` source signed by the served keyring and runs
# two installs:
#   1. Components: main extra — installs $PACKAGES, asserts that podman AND
#      every $PACKAGES member came from this repository (version suffix
#      ~<suite>, or the pinned passt version), runs `podman --version`.
#   2. Components: main only  — installs $MAIN_PACKAGES and asserts they came
#      from this repository, while crun/conmon resolve from the distro archive.
#      This is the contract of the split: `main` alone is a complete Podman.
# Runs on the host architecture only.
#
# Environment:
#   PACKAGES      (default: podman passt crun conmon — the companions netavark,
#                  aardvark-dns, containers-common and containers-storage are
#                  pulled in through podman's versioned Depends)
#   MAIN_PACKAGES (default: podman) packages for the main-only install
#   SUITES_FILE   (default: packaging/repo/suites)
#   KEYRING_NAME  (default: podman-package)
#   DOCKER        container CLI (default: docker; podman works too)
set -euo pipefail

[[ $# -ge 1 ]] || { echo "Usage: $(basename "$0") <repo-root> [suite ...]" >&2; exit 2; }
REPO_ROOT=$(cd "$1" && pwd); shift

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SUITES_FILE=${SUITES_FILE:-${ROOT_DIR}/packaging/repo/suites}
KEYRING_NAME=${KEYRING_NAME:-podman-package}
PACKAGES=${PACKAGES:-podman passt crun conmon}
MAIN_PACKAGES=${MAIN_PACKAGES:-podman}
DOCKER=${DOCKER:-docker}

declare -A FAMILY=()
ALL_SUITES=()
while read -r suite family _; do
  [[ -z ${suite} || ${suite} == \#* ]] && continue
  ALL_SUITES+=("${suite}")
  FAMILY[${suite}]=${family}
done < "${SUITES_FILE}"

SUITES=("$@")
[[ ${#SUITES[@]} -gt 0 ]] || SUITES=("${ALL_SUITES[@]}")

# run_install <suite> <components> <packages>: install <packages> from the
# repo restricted to <components>; every listed package must come from the repo.
run_install() {
  local suite=$1 components=$2 packages=$3 image="${FAMILY[$1]}:$1"
  echo "========================================"
  echo ">>> Smoke test: ${suite} (${image}) — Components: ${components} — apt-get install ${packages}"
  echo "========================================"
  "${DOCKER}" run --rm --pull=always \
       -v "${REPO_ROOT}:/repo:ro" \
       -e DEBIAN_FRONTEND=noninteractive \
       -e SUITE="${suite}" -e KEYRING="${KEYRING_NAME}" \
       -e COMPONENTS="${components}" -e PACKAGES="${packages}" \
       "${image}" bash -ec '
         install -D -m 644 "/repo/${KEYRING}.gpg" "/etc/apt/keyrings/${KEYRING}.gpg"
         printf "Types: deb\nURIs: file:/repo\nSuites: %s\nComponents: %s\nSigned-By: /etc/apt/keyrings/%s.gpg\n" \
           "${SUITE}" "${COMPONENTS}" "${KEYRING}" > "/etc/apt/sources.list.d/${KEYRING}.sources"
         apt-get update
         # shellcheck disable=SC2086
         apt-get install -y --no-install-recommends ${PACKAGES}
         echo "--- installed versions ---"
         dpkg-query -W -f="\${Package} \${Version}\n" podman netavark aardvark-dns \
           golang-github-containers-common containers-storage crun conmon passt 2>/dev/null || true
         for pkg in ${PACKAGES}; do
           ver=$(dpkg-query -W -f="\${Version}" "${pkg}")
           # The installed version must be one this repository publishes for
           # the suite, i.e. a matching .deb exists in the suite pool.
           if ! compgen -G "/repo/pool/${SUITE}/*/*/${pkg}/${pkg}_${ver#*:}_*.deb" >/dev/null; then
             echo "ERROR: ${pkg} ${ver} did not come from the ${SUITE} suite of this repository" >&2; exit 1
           fi
           echo "${pkg} ${ver}: from repository"
         done
         podman --version
       '
}

status=0
for suite in "${SUITES[@]}"; do
  [[ -n ${FAMILY[${suite}]:-} ]] || { echo "ERROR: unknown suite ${suite}" >&2; exit 2; }
  [[ -d ${REPO_ROOT}/dists/${suite} ]] || { echo "ERROR: ${REPO_ROOT}/dists/${suite} missing" >&2; exit 2; }
  if run_install "${suite}" "main extra" "${PACKAGES}"; then
    echo ">>> ${suite} (main extra): OK"
  else
    echo ">>> ${suite} (main extra): FAILED" >&2
    status=1
  fi
  if run_install "${suite}" "main" "${MAIN_PACKAGES}"; then
    echo ">>> ${suite} (main only): OK"
  else
    echo ">>> ${suite} (main only): FAILED" >&2
    status=1
  fi
done
exit "${status}"
