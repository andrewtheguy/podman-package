#!/usr/bin/env bash
# Assemble and sign the APT repository that is deployed to GitHub Pages.
#
# Usage: scripts/build-apt-repo.sh <debs-dir> <output-dir> <repo-url>
#
#   <debs-dir>    Directory holding the .deb files to publish (searched
#                 recursively) — normally every .deb from the most recent few
#                 main-* and extra-* component releases.
#                 Several versions of a package may be present; all of them are
#                 indexed (dpkg-scanpackages --multiversion) so apt installs the
#                 newest while older ones remain downloadable and pinnable. A
#                 .deb that appears more than once with identical content (the
#                 pinned passt binary reused across extra releases) is kept
#                 once; the same filename with different content is an error.
#   <output-dir>  Repository root to create. Must not exist or must be empty.
#   <repo-url>    Public base URL of the repository, e.g.
#                 https://andrewtheguy.github.io/podman-package (only used in
#                 the generated index.html and Release descriptions).
#
# Environment:
#   PUBKEY_FILE   Armored public signing key committed to the repository
#                 (default: packaging/repo/pubkey.asc). The matching SECRET key
#                 must already be imported into the GnuPG keyring ($GNUPGHOME);
#                 the script refuses to sign with any other key.
#   SUITES_FILE   Suite table (default: packaging/repo/suites).
#   COMPONENTS_FILE
#                 Package -> component table (default: packaging/repo/components).
#   KEYRING_NAME  Basename of the keyring files served at the repo root
#                 (default: podman-package -> podman-package.gpg / .asc).
#   ORIGIN        Release Origin/Label (default: podman-package).
#   SOURCE_URL    Link to the source repository shown on index.html
#   SIBLING_URL   Optional link to the sibling RPM repository shown on index.html
#                 (default: derived from the git `origin` remote).
#
# Layout produced:
#   <output-dir>/
#     index.html  .nojekyll
#     <KEYRING_NAME>.gpg               binary keyring for `Signed-By:`
#     <KEYRING_NAME>.asc               the same key, ASCII-armored
#     dists/<suite>/{InRelease,Release,Release.gpg}
#     dists/<suite>/<component>/binary-<arch>/{Packages,Packages.gz,Release,by-hash/}
#     pool/<suite>/<component>/<p>/<package>/<package>_<version>_<arch>.deb
#
# The pool is partitioned per suite (unlike reprepro's single shared pool)
# because the extra release ships two different passt binaries — one Ubuntu,
# one Debian — under the same package name, version and architecture.
#
# Components (packaging/repo/components, keyed by package name; the build
# workflow releases one component per run, but routing never trusts the
# release — only the package name):
#   main   podman and the companions its versioned Depends require; a client
#          with only this component gets a complete, working Podman.
#   extra  optional newer builds (passt, crun, conmon) whose distro versions
#          already satisfy podman's dependencies.
# Every suite publishes every component; a .deb whose package name is not in
# the table is an error.
#
# Routing of a .deb to suites:
#   1. version ends in `~<suite>`            -> that suite (source-built packages)
#   2. asset filename contains `_<family>_`  -> every suite of that family (passt)
#   anything else is an error.
#
# Requires: dpkg-deb, dpkg-scanpackages (dpkg-dev), apt-ftparchive (apt-utils),
#           gpg, gzip, sha256sum — i.e. a Debian/Ubuntu host or container.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}
[[ $# -eq 3 ]] || usage

DEBS_DIR=$1
OUTPUT_DIR=$2
REPO_URL=${3%/}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PUBKEY_FILE=${PUBKEY_FILE:-${ROOT_DIR}/packaging/repo/pubkey.asc}
SUITES_FILE=${SUITES_FILE:-${ROOT_DIR}/packaging/repo/suites}
COMPONENTS_FILE=${COMPONENTS_FILE:-${ROOT_DIR}/packaging/repo/components}
KEYRING_NAME=${KEYRING_NAME:-podman-package}
ORIGIN=${ORIGIN:-podman-package}
ARCHES=(amd64 arm64)

log() { echo ">>> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for tool in dpkg-deb dpkg-scanpackages apt-ftparchive gpg gzip sha256sum; do
  command -v "${tool}" >/dev/null \
    || die "missing required tool: ${tool} (apt-get install dpkg-dev apt-utils gnupg)"
done

[[ -d ${DEBS_DIR} ]] || die "debs directory not found: ${DEBS_DIR}"
[[ -f ${PUBKEY_FILE} ]] || die "public key not found: ${PUBKEY_FILE} — generate one with scripts/apt-repo-keygen.sh"
[[ -f ${SUITES_FILE} ]] || die "suites file not found: ${SUITES_FILE}"
[[ -f ${COMPONENTS_FILE} ]] || die "components file not found: ${COMPONENTS_FILE}"
if [[ -e ${OUTPUT_DIR} ]] && [[ -n $(ls -A "${OUTPUT_DIR}") ]]; then
  die "output directory exists and is not empty: ${OUTPUT_DIR}"
fi
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR=$(cd "${OUTPUT_DIR}" && pwd)
DEBS_DIR=$(cd "${DEBS_DIR}" && pwd)

if [[ -z ${SOURCE_URL:-} ]]; then
  SOURCE_URL=""
  if origin=$(git -C "${ROOT_DIR}" remote get-url origin 2>/dev/null) \
     && [[ ${origin} =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
    SOURCE_URL="https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  fi
fi

# --------------------------------------------------------------------------
# Signing key: the committed public key decides which key we sign with.
# --------------------------------------------------------------------------
FPR=$(gpg --batch --with-colons --import-options show-only --import "${PUBKEY_FILE}" \
      | awk -F: '$1=="fpr"{print $10; exit}')
[[ -n ${FPR} ]] || die "could not read a key fingerprint from ${PUBKEY_FILE}"
if ! gpg --batch --list-secret-keys "${FPR}" >/dev/null 2>&1; then
  die "the secret key for ${FPR} (the key in ${PUBKEY_FILE#"${ROOT_DIR}"/}) is not in the GnuPG keyring.
  - In GitHub Actions: set the GPG_PRIVATE_KEY secret to the matching private key.
  - Locally: gpg --import keys/apt-signing-key.private.asc
  - If you forked this repository: run scripts/apt-repo-keygen.sh to create your own
    key and commit the new ${PUBKEY_FILE#"${ROOT_DIR}"/}."
fi
log "Signing key: ${FPR}"

# --------------------------------------------------------------------------
# Suites
# --------------------------------------------------------------------------
SUITES=()
declare -A SUITE_FAMILY=() SUITE_DESC=()
while read -r suite family desc; do
  [[ -z ${suite} || ${suite} == \#* ]] && continue
  [[ -n ${family} && -n ${desc} ]] || die "malformed line in ${SUITES_FILE}: '${suite} ${family} ${desc}'"
  SUITES+=("${suite}")
  SUITE_FAMILY[${suite}]=${family}
  SUITE_DESC[${suite}]=${desc}
done < "${SUITES_FILE}"
[[ ${#SUITES[@]} -gt 0 ]] || die "no suites defined in ${SUITES_FILE}"
log "Suites: ${SUITES[*]}"

# --------------------------------------------------------------------------
# Components: package name -> component, in table order
# --------------------------------------------------------------------------
COMPONENTS=()
declare -A PKG_COMPONENT=()
while read -r pkg comp _; do
  [[ -z ${pkg} || ${pkg} == \#* ]] && continue
  [[ -n ${comp} && ${comp} =~ ^[a-z][a-z0-9-]*$ ]] \
    || die "malformed line in ${COMPONENTS_FILE}: '${pkg} ${comp}'"
  [[ -z ${PKG_COMPONENT[${pkg}]:-} ]] || die "package ${pkg} listed twice in ${COMPONENTS_FILE}"
  PKG_COMPONENT[${pkg}]=${comp}
  found=0
  for c in "${COMPONENTS[@]}"; do [[ ${c} == "${comp}" ]] && found=1; done
  [[ ${found} -eq 1 ]] || COMPONENTS+=("${comp}")
done < "${COMPONENTS_FILE}"
[[ ${#COMPONENTS[@]} -gt 0 ]] || die "no components defined in ${COMPONENTS_FILE}"
log "Components: ${COMPONENTS[*]}"

# --------------------------------------------------------------------------
# Pool: copy every .deb into pool/<suite>/<component>/<p>/<package>/
# --------------------------------------------------------------------------
pool_path() { # <suite> <component> <package> <version> <arch>
  local suite=$1 comp=$2 pkg=$3 ver=${4#*:} arch=$5 prefix
  if [[ ${pkg} == lib?* ]]; then prefix=${pkg:0:4}; else prefix=${pkg:0:1}; fi
  echo "pool/${suite}/${comp}/${prefix}/${pkg}/${pkg}_${ver}_${arch}.deb"
}

cd "${OUTPUT_DIR}"
log "Sorting .deb files into suites"
deb_count=0
while IFS= read -r -d '' deb; do
  pkg=$(dpkg-deb -f "${deb}" Package)
  ver=$(dpkg-deb -f "${deb}" Version)
  arch=$(dpkg-deb -f "${deb}" Architecture)
  [[ -n ${pkg} && -n ${ver} && -n ${arch} ]] || die "cannot read control metadata from ${deb}"
  comp=${PKG_COMPONENT[${pkg}]:-}
  [[ -n ${comp} ]] \
    || die "package ${pkg} ($(basename "${deb}")) is not assigned to a component — add it to ${COMPONENTS_FILE#"${ROOT_DIR}"/}"

  targets=()
  for s in "${SUITES[@]}"; do
    [[ ${ver} == *"~${s}" ]] && targets+=("${s}")
  done
  if [[ ${#targets[@]} -eq 0 ]]; then
    base=$(basename "${deb}")
    for s in "${SUITES[@]}"; do
      [[ ${base} == *"_${SUITE_FAMILY[${s}]}_"* ]] && targets+=("${s}")
    done
  fi
  [[ ${#targets[@]} -gt 0 ]] \
    || die "cannot route $(basename "${deb}") (version ${ver}) to a suite: expected a '~<suite>' version suffix or a '_<family>_' asset name"

  for s in "${targets[@]}"; do
    dest=$(pool_path "${s}" "${comp}" "${pkg}" "${ver}" "${arch}")
    if [[ -e ${dest} ]]; then
      cmp -s "${deb}" "${dest}" \
        || die "conflicting package in suite ${s}: ${dest} already exists with different content (from ${deb})"
      printf '  %-9s %-6s %s (identical copy, skipped)\n' "${s}" "${comp}" "$(basename "${dest}")"
      continue
    fi
    mkdir -p "$(dirname "${dest}")"
    cp "${deb}" "${dest}"
    printf '  %-9s %-6s %s\n' "${s}" "${comp}" "$(basename "${dest}")"
  done
  deb_count=$((deb_count + 1))
done < <(find "${DEBS_DIR}" -type f -name '*.deb' -print0 | sort -z)
[[ ${deb_count} -gt 0 ]] || die "no .deb files found under ${DEBS_DIR}"

for s in "${SUITES[@]}"; do
  [[ -d pool/${s} ]] || die "suite ${s} received no packages — remove it from ${SUITES_FILE} or fix the routing"
  for c in "${COMPONENTS[@]}"; do
    [[ -d pool/${s}/${c} ]] || die "suite ${s} component ${c} received no packages — every component must be non-empty in every suite"
  done
done

# --------------------------------------------------------------------------
# Keyring files served at the repository root
# --------------------------------------------------------------------------
gpg --batch --yes --dearmor < "${PUBKEY_FILE}" > "${KEYRING_NAME}.gpg"
cp "${PUBKEY_FILE}" "${KEYRING_NAME}.asc"
touch .nojekyll

# --------------------------------------------------------------------------
# Indexes, Release, by-hash, signatures — per suite
# --------------------------------------------------------------------------
for s in "${SUITES[@]}"; do
  log "Suite ${s}: generating indexes"
  for c in "${COMPONENTS[@]}"; do
    for arch in "${ARCHES[@]}"; do
      dir="dists/${s}/${c}/binary-${arch}"
      mkdir -p "${dir}"
      # --arch <arch> scans *_<arch>.deb and *_all.deb only; --multiversion keeps
      # every version of a package in the index instead of only the newest.
      dpkg-scanpackages --multiversion --arch "${arch}" "pool/${s}/${c}" > "${dir}/Packages"
      gzip -9n < "${dir}/Packages" > "${dir}/Packages.gz"
      printf 'Archive: %s\nOrigin: %s\nLabel: %s\nComponent: %s\nArchitecture: %s\n' \
        "${s}" "${ORIGIN}" "${ORIGIN}" "${c}" "${arch}" > "${dir}/Release"
      echo "  ${c}/binary-${arch}: $(grep -c '^Package:' "${dir}/Packages") packages"
    done
  done

  log "Suite ${s}: writing Release"
  conf=$(mktemp)
  cat > "${conf}" <<CONF
APT::FTPArchive::Release {
  Origin "${ORIGIN}";
  Label "${ORIGIN}";
  Suite "${s}";
  Codename "${s}";
  Architectures "${ARCHES[*]}";
  Components "${COMPONENTS[*]}";
  Description "Podman .deb packages for ${SUITE_DESC[${s}]} - ${REPO_URL}";
  Acquire-By-Hash "yes";
};
CONF
  apt-ftparchive -c "${conf}" release "dists/${s}" > "dists/${s}/Release.tmp"
  rm -f "${conf}"
  mv "dists/${s}/Release.tmp" "dists/${s}/Release"
  # Belt and braces: older apt-ftparchive builds ignore the Acquire-By-Hash knob.
  grep -q '^Acquire-By-Hash: yes' "dists/${s}/Release" \
    || sed -i '/^Codename:/a Acquire-By-Hash: yes' "dists/${s}/Release"

  # by-hash copies of every listed index, adjacent to the index. GitHub Pages'
  # CDN can serve a stale Packages next to a fresh InRelease mid-deploy; with
  # Acquire-By-Hash apt fetches indexes by their hash instead and never sees the
  # mismatch.
  for algo in SHA256 SHA512; do
    awk -v a="${algo}:" '$0==a{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print $1, $3}' "dists/${s}/Release" \
    | while read -r hash rel; do
        src="dists/${s}/${rel}"
        [[ -f ${src} ]] || continue
        bh="$(dirname "${src}")/by-hash/${algo}"
        mkdir -p "${bh}"
        cp -f "${src}" "${bh}/${hash}"
      done
  done

  log "Suite ${s}: signing"
  gpg --batch --yes --local-user "${FPR}" --digest-algo SHA512 \
      --clearsign --output "dists/${s}/InRelease" "dists/${s}/Release"
  gpg --batch --yes --local-user "${FPR}" --digest-algo SHA512 \
      --armor --detach-sign --output "dists/${s}/Release.gpg" "dists/${s}/Release"
done

# --------------------------------------------------------------------------
# index.html
# --------------------------------------------------------------------------
log "Writing index.html"
{
  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${ORIGIN} APT repository</title>
<style>
  body{font-family:system-ui,-apple-system,sans-serif;max-width:64em;margin:2em auto;padding:0 1em;line-height:1.5;color:#222}
  pre{background:#f4f4f4;padding:1em;overflow-x:auto;border-radius:4px}
  code{font-size:.95em}
  table{border-collapse:collapse;margin:1em 0}
  td,th{border:1px solid #ccc;padding:.25em .7em;text-align:left;font-family:ui-monospace,monospace;font-size:.9em}
  th{background:#eee}
  .warn{border-left:4px solid #c60;background:#fff6ee;padding:.8em 1em}
</style>
</head>
<body>
<h1>${ORIGIN} APT repository</h1>
<div class="warn">
<p><strong>This repository exists only for its maintainer's own convenience</strong> so the
builds can be installed with <code>apt</code>. It is not a supported distribution channel:
packages may change, break or disappear without notice, and the signing key belongs to the
maintainer. If you want to use these packages yourself, fork the project, generate your own
signing key and publish your own repository — the source repository's README explains how.</p>
</div>
HTML
  [[ -n ${SOURCE_URL} ]] && echo "<p>Source and build workflows: <a href=\"${SOURCE_URL}\">${SOURCE_URL}</a></p>"
  [[ -n ${SIBLING_URL:-} ]] && echo "<p>RPM sibling for Amazon Linux 2023: <a href=\"${SIBLING_URL}\">${SIBLING_URL}</a></p>"
  cat <<HTML
<h2>Usage</h2>
<pre>sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/${KEYRING_NAME}.gpg ${REPO_URL}/${KEYRING_NAME}.gpg

# Pick the suite matching your distro: $(printf '%s ' "${SUITES[@]}")
sudo tee /etc/apt/sources.list.d/${KEYRING_NAME}.sources &lt;&lt;'EOF'
Types: deb
URIs: ${REPO_URL}
Suites: ${SUITES[0]}
Components: ${COMPONENTS[*]}
Signed-By: /etc/apt/keyrings/${KEYRING_NAME}.gpg
EOF

sudo apt update
sudo apt install podman passt crun conmon          # podman pulls in the required companions

# or everything the repository publishes:
sudo apt install podman podman-remote podman-docker netavark aardvark-dns \\
  golang-github-containers-common containers-storage crun conmon passt</pre>
<h2>Components</h2>
<ul>
<li><code>main</code> — podman, podman-remote, podman-docker and the companions podman's
versioned <code>Depends</code> require (netavark, aardvark-dns, golang-github-containers-common,
containers-storage). <code>Components: main</code> alone gives a complete, working Podman; the
runtime and monitor then come from the distro's own crun/runc and conmon.</li>
<li><code>extra</code> — optional newer builds of passt, crun and conmon. The distro versions
already satisfy podman's dependencies; add this component to install the current upstream
releases instead.</li>
</ul>
<p>Signing key: <a href="${KEYRING_NAME}.gpg">${KEYRING_NAME}.gpg</a> (binary keyring) ·
<a href="${KEYRING_NAME}.asc">${KEYRING_NAME}.asc</a> (armored) · fingerprint <code>${FPR}</code></p>
<p>Each suite carries the most recent few releases of every package; apt installs the
newest, and older versions stay downloadable (and pinnable with
<code>apt install podman=&lt;version&gt;</code>) until they rotate out.</p>
<h2>Suites</h2>
HTML
  for s in "${SUITES[@]}"; do
    echo "<h3><code>${s}</code> — ${SUITE_DESC[${s}]}</h3>"
    echo "<p><a href=\"dists/${s}/InRelease\">InRelease</a></p>"
    echo "<table><tr><th>Component</th><th>Package</th><th>Version</th><th>Architecture</th></tr>"
    for c in "${COMPONENTS[@]}"; do   # table order, then package / newest version first
      for arch in "${ARCHES[@]}"; do
        awk '
          /^Package:/      { p=$2 }
          /^Version:/      { v=$2 }
          /^Architecture:/ { a=$2 }
          /^[[:space:]]*$/ { if (p!="") print p "\t" v "\t" a; p=v=a="" }
          END              { if (p!="") print p "\t" v "\t" a }' "dists/${s}/${c}/binary-${arch}/Packages"
      done | sort -u | sort -t "$(printf '\t')" -k1,1 -k2,2Vr -k3,3 \
           | awk -F'\t' -v c="${c}" '{printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", c, $1, $2, $3}'
    done
    echo "</table>"
  done
  echo "<p>Generated $(date -u +'%Y-%m-%d %H:%M UTC').</p>"
  echo "</body></html>"
} > index.html

log "Repository assembled at ${OUTPUT_DIR}"
"${ROOT_DIR}/scripts/verify-apt-repo.sh" "${OUTPUT_DIR}"
