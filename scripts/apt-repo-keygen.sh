#!/usr/bin/env bash
# Generate the GPG key that signs the APT repository published to GitHub Pages.
#
#   private key -> keys/apt-signing-key.private.asc   (gitignored; upload it as
#                                                      the GPG_PRIVATE_KEY secret)
#   public key  -> packaging/repo/pubkey.asc           (commit it; served to users)
#   fingerprint -> keys/apt-signing-key.fingerprint
#
# Usage: scripts/apt-repo-keygen.sh [--force]
#
#   --force   Replace an existing key pair. Existing users of the repository
#             must then re-import the new public key.
#
# Environment overrides:
#   KEY_NAME    User-ID name    (default: "<repo> APT repository signing key")
#   KEY_EMAIL   User-ID email   (default: "<owner>@users.noreply.github.com",
#                                derived from the `origin` remote)
#   KEY_TYPE    (default: RSA)   KEY_LENGTH (default: 4096)
#
# The key is generated in a throwaway GNUPGHOME so it never touches your
# personal keyring, and has no passphrase because GitHub Actions must use it
# non-interactively. Treat keys/ as a secret.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KEYS_DIR="${ROOT_DIR}/keys"
PRIVATE_KEY="${KEYS_DIR}/apt-signing-key.private.asc"
FINGERPRINT_FILE="${KEYS_DIR}/apt-signing-key.fingerprint"
PUBKEY="${ROOT_DIR}/packaging/repo/pubkey.asc"

die() { echo "ERROR: $*" >&2; exit 1; }

FORCE=0
case "${1:-}" in
  "") ;;
  --force) FORCE=1 ;;
  *) echo "Usage: $(basename "$0") [--force]" >&2; exit 2 ;;
esac

command -v gpg >/dev/null || die "gpg is required"

if [[ ${FORCE} -eq 0 ]] && [[ -e ${PRIVATE_KEY} || -e ${PUBKEY} ]]; then
  die "a signing key already exists (${PRIVATE_KEY#"${ROOT_DIR}"/} or ${PUBKEY#"${ROOT_DIR}"/}). Re-run with --force to replace it."
fi

# Refuse to write a private key into a directory git would track.
if git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mkdir -p "${KEYS_DIR}"
  git -C "${ROOT_DIR}" check-ignore -q "${KEYS_DIR}" \
    || die "${KEYS_DIR#"${ROOT_DIR}"/}/ is not gitignored; add 'keys/' to .gitignore before generating a private key."
fi

# Default User-ID from the origin remote (github.com/<owner>/<repo>).
owner="" repo_name=""
if origin=$(git -C "${ROOT_DIR}" remote get-url origin 2>/dev/null); then
  if [[ ${origin} =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo_name="${BASH_REMATCH[2]%.git}"
  fi
fi
KEY_NAME=${KEY_NAME:-"${repo_name:-podman-package} APT repository signing key"}
KEY_EMAIL=${KEY_EMAIL:-"${owner:-apt-repo}@users.noreply.github.com"}
KEY_TYPE=${KEY_TYPE:-RSA}
KEY_LENGTH=${KEY_LENGTH:-4096}

export GNUPGHOME
GNUPGHOME=$(mktemp -d)
chmod 700 "${GNUPGHOME}"
trap 'rm -rf "${GNUPGHOME}"' EXIT

echo ">>> Generating ${KEY_TYPE}-${KEY_LENGTH} signing key for \"${KEY_NAME} <${KEY_EMAIL}>\""
gpg --batch --quiet --gen-key <<GENKEY
%no-protection
Key-Type: ${KEY_TYPE}
Key-Length: ${KEY_LENGTH}
Key-Usage: sign
Name-Real: ${KEY_NAME}
Name-Email: ${KEY_EMAIL}
Expire-Date: 0
%commit
GENKEY

FPR=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="fpr"{print $10; exit}')
[[ -n ${FPR} ]] || die "key generation produced no fingerprint"

mkdir -p "${KEYS_DIR}" "$(dirname "${PUBKEY}")"
(
  umask 077
  gpg --batch --yes --armor --export-secret-keys "${FPR}" > "${PRIVATE_KEY}"
  echo "${FPR}" > "${FINGERPRINT_FILE}"
)
gpg --batch --yes --armor --export "${FPR}" > "${PUBKEY}"

cat <<NEXT

Generated signing key ${FPR}

  private key : ${PRIVATE_KEY#"${ROOT_DIR}"/}   (gitignored — keep it secret, back it up)
  public key  : ${PUBKEY#"${ROOT_DIR}"/}         (commit this)

Next steps:
  1. Store the private key as a repository secret for the publish workflow:
       gh secret set GPG_PRIVATE_KEY < ${PRIVATE_KEY#"${ROOT_DIR}"/}
  2. Commit ${PUBKEY#"${ROOT_DIR}"/}.
  3. In the repository settings enable GitHub Pages with source "GitHub Actions",
     then run the "Publish APT Repository" workflow.
NEXT
