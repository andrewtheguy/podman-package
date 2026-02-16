#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/push-deb-assets-to-release.sh <release-tag>

Uploads all *.deb artifacts from both distros:
  output/noble/<YYYYMMDD>/<arch>/
  output/trixie/<YYYYMMDD>/<arch>/
for BUILD_VERSION.

Required:
  <release-tag>               Existing GitHub release tag (for example: v5.8.0-local)

Optional environment:
  GITHUB_REPOSITORY           owner/repo (auto-detected from git remote origin when omitted)
  BUILD_VERSION               UTC date folder (default: today, date -u +%Y%m%d)
  OUTPUT_ROOT                 Output root directory (default: <repo>/output)
  GH_HOST                     GitHub host for gh CLI (default: github.com)
EOF
}

infer_github_repository() {
  local remote_url
  remote_url="$(git config --get remote.origin.url || true)"
  [[ -n "${remote_url}" ]] || die "unable to determine remote.origin.url; set GITHUB_REPOSITORY"

  if [[ "${remote_url}" =~ ^git@github\.com:([^/]+/[^/]+)(\.git)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${remote_url}" =~ ^https?://github\.com/([^/]+/[^/]+)(\.git)?/?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  die "remote.origin.url is not a github.com repository URL; set GITHUB_REPOSITORY explicitly"
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 2
  fi

  require_cmd gh
  require_cmd git
  require_cmd find

  local release_tag="$1"
  [[ -n "${release_tag}" ]] || die "release tag must not be empty"

  local build_version="${BUILD_VERSION:-$(date -u +%Y%m%d)}"
  local output_root="${OUTPUT_ROOT:-${REPO_ROOT}/output}"
  local github_repo="${GITHUB_REPOSITORY:-}"
  local gh_host="${GH_HOST:-github.com}"

  if [[ -z "${github_repo}" ]]; then
    github_repo="$(infer_github_repository)"
  fi
  github_repo="${github_repo%.git}"
  [[ "${github_repo}" =~ ^[^/]+/[^/]+$ ]] || die "invalid GITHUB_REPOSITORY: ${github_repo}"

  [[ "${build_version}" =~ ^[0-9]{8}$ ]] || die "invalid BUILD_VERSION: ${build_version} (expected YYYYMMDD)"

  local noble_dir="${output_root}/noble/${build_version}"
  local trixie_dir="${output_root}/trixie/${build_version}"
  local -a SEARCH_DIRS=( "${noble_dir}" "${trixie_dir}" )

  log "Checking gh authentication for ${gh_host}"
  gh auth status --hostname "${gh_host}" >/dev/null 2>&1 || \
    die "gh is not authenticated for ${gh_host}; run: gh auth login --hostname ${gh_host}"

  log "Validating release ${release_tag} exists in ${github_repo}"
  gh release view "${release_tag}" --repo "${github_repo}" >/dev/null || \
    die "release tag not found: ${release_tag} in ${github_repo}"

  local -a deb_files=()
  local -a noble_debs=()
  local -a trixie_debs=()
  local dir
  local file

  for dir in "${noble_dir}" "${trixie_dir}"; do
    [[ -d "${dir}" ]] || die "missing output directory for required distro upload: ${dir}"
  done

  while IFS= read -r -d '' file; do
    noble_debs+=( "${file}" )
  done < <(find "${noble_dir}" -type f -name '*.deb' -print0)

  while IFS= read -r -d '' file; do
    trixie_debs+=( "${file}" )
  done < <(find "${trixie_dir}" -type f -name '*.deb' -print0)

  [[ "${#noble_debs[@]}" -gt 0 ]] || die "no .deb files found under required distro path: ${noble_dir}"
  [[ "${#trixie_debs[@]}" -gt 0 ]] || die "no .deb files found under required distro path: ${trixie_dir}"

  for dir in "${SEARCH_DIRS[@]}"; do
    while IFS= read -r -d '' file; do
      deb_files+=( "${file}" )
    done < <(find "${dir}" -type f -name '*.deb' -print0)
  done
  [[ "${#deb_files[@]}" -gt 0 ]] || die "no .deb files found for build version ${build_version} under required distro paths"

  log "Uploading ${#deb_files[@]} .deb file(s) to ${github_repo} release ${release_tag}"
  for file in "${deb_files[@]}"; do
    log "Uploading $(basename "${file}")"
    gh release upload "${release_tag}" "${file}" --repo "${github_repo}" --clobber
  done

  log "Done. Uploaded ${#deb_files[@]} .deb file(s) to release ${release_tag}"
}

main "$@"
