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
# read-only, adds it as a `file:` source signed by the served keyring, runs
# `apt-get update` and installs $PACKAGES, then asserts that podman came from
# this repository (version suffix ~<suite>) and runs `podman --version`.
# Runs on the host architecture only.
#
# Environment:
#   PACKAGES      (default: podman passt crun conmon — the companions netavark,
#                  aardvark-dns, containers-common and containers-storage are
#                  pulled in through podman's versioned Depends)
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

status=0
for suite in "${SUITES[@]}"; do
  [[ -n ${FAMILY[${suite}]:-} ]] || { echo "ERROR: unknown suite ${suite}" >&2; exit 2; }
  [[ -d ${REPO_ROOT}/dists/${suite} ]] || { echo "ERROR: ${REPO_ROOT}/dists/${suite} missing" >&2; exit 2; }
  image="${FAMILY[${suite}]}:${suite}"
  echo "========================================"
  echo ">>> Smoke test: ${suite} (${image}) — apt-get install ${PACKAGES}"
  echo "========================================"
  if "${DOCKER}" run --rm --pull=always \
       -v "${REPO_ROOT}:/repo:ro" \
       -e DEBIAN_FRONTEND=noninteractive \
       -e SUITE="${suite}" -e KEYRING="${KEYRING_NAME}" -e PACKAGES="${PACKAGES}" \
       "${image}" bash -ec '
         install -D -m 644 "/repo/${KEYRING}.gpg" "/etc/apt/keyrings/${KEYRING}.gpg"
         printf "Types: deb\nURIs: file:/repo\nSuites: %s\nComponents: main\nSigned-By: /etc/apt/keyrings/%s.gpg\n" \
           "${SUITE}" "${KEYRING}" > "/etc/apt/sources.list.d/${KEYRING}.sources"
         apt-get update
         # shellcheck disable=SC2086
         apt-get install -y --no-install-recommends ${PACKAGES}
         echo "--- installed versions ---"
         dpkg-query -W -f="\${Package} \${Version}\n" podman netavark aardvark-dns \
           golang-github-containers-common containers-storage crun conmon passt
         ver=$(dpkg-query -W -f="\${Version}" podman)
         case "${ver}" in
           *"~${SUITE}") ;;
           *) echo "ERROR: podman ${ver} did not come from the ${SUITE} suite" >&2; exit 1 ;;
         esac
         podman --version
       '; then
    echo ">>> ${suite}: OK"
  else
    echo ">>> ${suite}: FAILED" >&2
    status=1
  fi
done
exit "${status}"
