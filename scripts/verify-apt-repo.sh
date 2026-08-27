#!/usr/bin/env bash
# Integrity gate for an assembled APT repository (run before deploying).
#
# Usage: scripts/verify-apt-repo.sh <repo-root>
#
# For every suite under <repo-root>/dists/ this asserts what apt itself will
# check at `apt update` / `apt install` time:
#   1. InRelease and Release.gpg verify against the keyring served at the
#      repository root (<KEYRING_NAME>.gpg), and InRelease's payload equals Release.
#   2. Every file listed in Release's SHA256 section exists with that exact size
#      and hash, and (Acquire-By-Hash) has a by-hash/SHA256/<hash> copy.
#   3. Every component x architecture named in Release has a Packages index,
#      and no index exists for a component Release does not name.
#   4. Every Packages stanza points at a pool file with the listed Size and
#      SHA256, and Packages.gz decompresses to exactly Packages.
# Any mismatch exits 1 so an inconsistent repository never reaches GitHub Pages.
#
# Environment: KEYRING_NAME (default: podman-package)
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: $(basename "$0") <repo-root>" >&2; exit 2; }
REPO_ROOT=$(cd "$1" && pwd)
KEYRING_NAME=${KEYRING_NAME:-podman-package}
KEYRING="${REPO_ROOT}/${KEYRING_NAME}.gpg"

[[ -d ${REPO_ROOT}/dists ]] || { echo "ERROR: ${REPO_ROOT} has no dists/ directory" >&2; exit 2; }
[[ -f ${KEYRING} ]] || { echo "ERROR: keyring ${KEYRING} not found" >&2; exit 2; }

sha256() { sha256sum "$1" | awk '{print $1}'; }
fsize()  { wc -c < "$1" | tr -d '[:space:]'; }

verify_sig() { # <signature-or-clearsigned> [<signed-file>]
  if command -v gpgv >/dev/null; then
    gpgv --quiet --keyring "${KEYRING}" "$@" 2>&1
  else
    gpg --batch --quiet --no-default-keyring --keyring "${KEYRING}" --verify "$@" 2>&1
  fi
}

checks=0 failures=0
fail() { echo "  MISMATCH: $*" >&2; failures=$((failures + 1)); }

echo ">>> Verifying repository at ${REPO_ROOT}"
shopt -s nullglob
for suite_dir in "${REPO_ROOT}"/dists/*/; do
  suite=$(basename "${suite_dir}")
  release="${suite_dir}Release"
  echo ">>> Suite ${suite}"
  [[ -f ${release} ]] || { fail "${suite}: Release missing"; continue; }

  # 1. signatures
  for f in InRelease Release.gpg; do
    checks=$((checks + 1))
    [[ -f ${suite_dir}${f} ]] || { fail "${suite}: ${f} missing"; continue; }
  done
  if [[ -f ${suite_dir}InRelease ]]; then
    checks=$((checks + 1))
    out=$(verify_sig "${suite_dir}InRelease") || fail "${suite}: InRelease signature invalid: ${out}"
    checks=$((checks + 1))
    if command -v gpgv >/dev/null; then
      payload=$(gpgv --quiet --keyring "${KEYRING}" --output - "${suite_dir}InRelease" 2>/dev/null)
    else
      payload=$(gpg --batch --quiet --no-default-keyring --keyring "${KEYRING}" --decrypt "${suite_dir}InRelease" 2>/dev/null)
    fi
    [[ "${payload}" == "$(cat "${release}")" ]] || fail "${suite}: InRelease payload differs from Release"
  fi
  if [[ -f ${suite_dir}Release.gpg ]]; then
    checks=$((checks + 1))
    out=$(verify_sig "${suite_dir}Release.gpg" "${release}") || fail "${suite}: Release.gpg signature invalid: ${out}"
  fi

  # 2. Release <-> indexes (+ by-hash)
  by_hash=0
  grep -q '^Acquire-By-Hash: yes' "${release}" && by_hash=1
  while read -r exp_hash exp_size rel; do
    [[ -n ${rel} ]] || continue
    target="${suite_dir}${rel}"
    checks=$((checks + 1))
    [[ -f ${target} ]] || { fail "${suite}: Release lists ${rel} but it is missing"; continue; }
    act_size=$(fsize "${target}")
    [[ ${act_size} == "${exp_size}" ]] || { fail "${suite}: ${rel} size ${act_size} != ${exp_size}"; continue; }
    [[ $(sha256 "${target}") == "${exp_hash}" ]] || fail "${suite}: ${rel} sha256 differs from Release"
    if [[ ${by_hash} -eq 1 ]]; then
      checks=$((checks + 1))
      bh="$(dirname "${target}")/by-hash/SHA256/${exp_hash}"
      [[ -f ${bh} ]] && cmp -s "${bh}" "${target}" || fail "${suite}: by-hash copy for ${rel} missing or different"
    fi
  done < <(awk '$0=="SHA256:"{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print $1, $2, $3}' "${release}")

  # 3. every Components x Architectures pair in Release has a Packages index
  comps=$(awk '/^Components:/{$1="";print}' "${release}")
  archs=$(awk '/^Architectures:/{$1="";print}' "${release}")
  for c in ${comps}; do
    for a in ${archs}; do
      checks=$((checks + 1))
      [[ -f ${suite_dir}${c}/binary-${a}/Packages ]] || fail "${suite}: Release lists component ${c} but ${c}/binary-${a}/Packages is missing"
    done
  done
  for pkgs in "${suite_dir}"*/binary-*/Packages; do
    c=${pkgs#"${suite_dir}"}; c=${c%%/*}
    checks=$((checks + 1))
    [[ " ${comps} " == *" ${c} "* ]] || fail "${suite}: index ${pkgs#"${suite_dir}"} belongs to component ${c} which Release does not list"
  done

  # 4. Packages <-> pool
  for pkgs in "${suite_dir}"*/binary-*/Packages; do
    if [[ -f ${pkgs}.gz ]]; then
      checks=$((checks + 1))
      gzip -dc "${pkgs}.gz" | cmp -s - "${pkgs}" || fail "${suite}: ${pkgs#"${suite_dir}"}.gz != Packages"
    fi
    while read -r filename size sha; do
      [[ -n ${filename} ]] || continue
      checks=$((checks + 1))
      pool_file="${REPO_ROOT}/${filename}"
      [[ -f ${pool_file} ]] || { fail "${suite}: ${filename} missing from pool"; continue; }
      [[ $(fsize "${pool_file}") == "${size}" ]] || { fail "${suite}: ${filename} size != index Size"; continue; }
      [[ $(sha256 "${pool_file}") == "${sha}" ]] || fail "${suite}: ${filename} sha256 != index SHA256"
    done < <(awk '
      /^Filename:/ { fn=$2 }
      /^Size:/     { sz=$2 }
      /^SHA256:/   { sha=$2 }
      /^[[:space:]]*$/ { if (fn!="") print fn, sz, sha; fn=sz=sha="" }
      END { if (fn!="") print fn, sz, sha }' "${pkgs}")
  done
done
shopt -u nullglob

if [[ ${failures} -gt 0 ]]; then
  echo ">>> FAIL: ${failures} mismatch(es) across ${checks} checks — refusing to publish" >&2
  exit 1
fi
echo ">>> OK: ${checks} checks passed"
