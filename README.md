# Podman `.deb` Package Builders

This repository builds pinned Podman and supporting-component releases as
installable `.deb` packages for Ubuntu and Debian on `amd64` and `arm64`.
Source-built packages use Docker, checksum-pinned upstream sources, and distro
packaging to keep builds isolated. Distro source packages and build dependencies
are resolved when a build runs, so the output is not promised to be
byte-for-byte reproducible. The `extra` component also includes exact,
checksum-pinned Ubuntu and Debian `passt` binary packages.

The project is APT-first: the deliverable is the signed APT repository with a
`main` component (Podman and its version-pinned companion packages) and an
`extra` component (optional newer passt, crun, conmon). GitHub releases exist
only as the repository's storage layer, one release per component build.

An RPM sibling, [podman-package-rpm](https://github.com/andrewtheguy/podman-package-rpm),
builds the same pinned Podman stack for **Amazon Linux 2023** (`x86_64` and
`aarch64`) with the same template — Docker builds, checksum-pinned upstream
sources, the distro's own packaging, repo-managed patch series, and a signed
dnf repository on GitHub Pages at
<https://andrewtheguy.github.io/podman-package-rpm/>.

## Install via APT (maintainer's personal repository)

> **Disclaimer — this APT repository is only for my own convenience.** It exists
> so *I* can `apt install` these builds on my own machines. It is not a supported
> distribution channel for anyone else: packages may change, break, or disappear
> without notice, the signing key is mine, and I make no promises about uptime or
> security review. **If you want to use these packages, fork this project and set
> up your own repository with your own signing key** — see
> [Hosting Your Own APT Repository](#hosting-your-own-apt-repository). Do not
> point production systems at my repository.

The repository is served from GitHub Pages at
<https://andrewtheguy.github.io/podman-package/> and is rebuilt by the
**Publish APT Repository** workflow from up to three of the most recently
published `main` releases and up to three of the most recently published
`extra` releases. If fewer exist, it uses every available matching release.
apt installs the newest indexed version; retained older versions stay
downloadable — so a slightly stale `apt update` still resolves — and pinnable
with `sudo apt install podman=<version>` until they rotate out. Use
`apt-cache madison podman` to list the versions currently indexed.

```bash
# 1. Signing key
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/podman-package.gpg \
  https://andrewtheguy.github.io/podman-package/podman-package.gpg

# 2. Repository (DEB822). Use the suite for your distro: noble, resolute, or trixie.
sudo tee /etc/apt/sources.list.d/podman-package.sources <<'EOF'
Types: deb
URIs: https://andrewtheguy.github.io/podman-package
Suites: noble
Components: main extra
Signed-By: /etc/apt/keyrings/podman-package.gpg
EOF

# 3. Install
sudo apt update
sudo apt install podman passt crun conmon
```

`podman` pulls in the required companions (netavark, aardvark-dns,
containers-common, containers-storage) through its versioned `Depends`; `passt`,
`crun`, and `conmon` are listed explicitly because they are recommended rather
than required.

The repository has two components, split by what Podman actually needs
(`packaging/repo/components`); each is built and released by its own run of the
build workflow:

| Component | Packages | Purpose |
|-----------|----------|---------|
| `main` | podman, podman-remote, podman-docker, netavark, aardvark-dns, golang-github-containers-common, containers-storage | Podman and the repo-built companions named by its versioned `Depends`. `Components: main` alone gives a complete install because the remaining runtime/monitor dependencies come from the distro's own crun (or runc) and conmon. |
| `extra` | passt, crun, conmon | Optional newer builds. The distro versions already satisfy podman's dependencies; add the component to install the current upstream releases instead (the pinned passt includes newer `pasta` fixes). |

Use `Components: main` if you only want Podman and its required companions, or
`Components: main extra` (as above) to also pick up the newer passt, crun, and
conmon.

To install every package the repository publishes (the ten below are the full
set for each suite):

```bash
sudo apt install \
  podman podman-remote podman-docker \
  netavark aardvark-dns golang-github-containers-common containers-storage \
  crun conmon passt
```

`podman-remote` is the client-only binary and `podman-docker` provides a
`docker` command that wraps Podman (it `Conflicts` with `docker.io` and
`docker-ce-cli`, so leave it out on hosts running Docker). To upgrade an existing
install after a new publish, `sudo apt update && sudo apt upgrade` is enough —
every package is versioned above its distro counterpart. This also moves a host
from the distro's podman to this repository's. Note that plain
`apt-get upgrade` **holds podman back** in that case, because the new podman
depends on packages the distro never installed (containers-storage, and on
noble netavark/aardvark-dns); use `apt upgrade`, `apt-get upgrade --with-new-pkgs`,
or `apt full-upgrade` instead.

| Suite | Platform | Contents |
|-------|----------|----------|
| `noble` | Ubuntu 24.04 | source-built `~noble` packages + the pinned Ubuntu `passt` binary |
| `resolute` | Ubuntu 26.04 | source-built `~resolute` packages + the pinned Ubuntu `passt` binary |
| `trixie` | Debian 13 | source-built `~trixie` packages + the pinned Debian `passt` binary |

Every suite carries both components and `amd64` and `arm64`. The suite table
lives in `packaging/repo/suites` and the package-to-component table in
`packaging/repo/components` (a `.deb` whose package is not listed there fails
the publish); the signing key fingerprint is printed on the repository's index
page and in `packaging/repo/pubkey.asc`.

## Downloads

The GitHub releases mirror the APT components, one release per component build:

- [`main` component releases](https://github.com/andrewtheguy/podman-package/releases?q=%22main+component%22) (`main-<YYYYMMDD>-<N>`) — podman, podman-remote, podman-docker, netavark, aardvark-dns, containers-common, and containers-storage: a complete Podman.
- [`extra` component releases](https://github.com/andrewtheguy/podman-package/releases?q=%22extra+component%22) (`extra-<YYYYMMDD>-<N>`) — passt, crun, and conmon: optional newer builds.
- [All releases](https://github.com/andrewtheguy/podman-package/releases) — the combined chronological GitHub release history.

For a complete Podman 6.1 installation without this APT repository, download
the `.deb`s for your distro and architecture from the latest `main` release;
add the `extra` release if you want the newer passt/crun/conmon.

netavark (Rust network stack), aardvark-dns (Rust DNS server),
containers-common (config files), and containers-storage (storage CLI +
`storage.conf`) are versioned dependencies of the Podman package built here.
They are therefore part of the `main` component and are **built and released for
all targets**. Installing Podman from the repository pulls in the pinned minimum
versions declared in its package metadata.

crun (C OCI runtime) and conmon (container monitor) are **recommended, not
required**: Podman uses crun as its default runtime and conmon to monitor
containers, and their newest releases track the latest features and fixes. The
distro-provided crun (or runc) and conmon will still run containers. Both are
built and released here for all targets so you can pull in the current releases
when you want them.

passt provides the `pasta` user-mode networking backend. The `extra` release
includes exact `0.0~git20260728.f8df3f1-1` Ubuntu Launchpad and Debian snapshot
binaries for `amd64` and `arm64`; every URL and SHA-256 is pinned in
`packaging/versions.env`. The release asset name identifies the binary's
`ubuntu` or `debian` origin without changing the package contents.

Podman, the two Rust components, crun, conmon, and containers-storage follow the
same pattern (distro `debian/` packaging + pinned upstream source + repo-managed
patches + a self-installed toolchain where needed); crun builds from its
self-contained upstream release tarball (autotools, system libs), conmon builds
from its upstream tag archive with the target distro's packaging, and
containers-common is `Architecture: all` and needs no compilation (config files
and man pages only).

> **Why containers-storage matters:** Podman 6.1.0 embeds storage library
> v1.64.0. Its configuration parser honors an explicitly set `graphroot` even
> for rootless users. The distros' older `containers-storage` packages ship a
> `/usr/share/containers/storage.conf` with `graphroot` hardcoded to
> `/var/lib/containers/storage`, so rootless Podman 6.1 hits a root-owned path →
> *permission denied*. The v1.63.0 `storage.conf` built here leaves
> `graphroot`/`runroot` commented out, so rootless Podman falls back to its
> per-user default.

The podman package built here preserves its distro conmon dependency and declares
versioned dependencies on the required companions, so installing podman pulls
the required matching set while either the distro or repo conmon package can
satisfy the conmon dependency:
`Depends: … netavark (>= 2.0.0), aardvark-dns (>= 2.0.0), golang-github-containers-common (>= 0.68.0), containers-storage (>= 1.63.0)`.
The older distro versions do not satisfy these, so install the repo's `.deb`s
together (e.g. `apt install ./*.deb`).

## Supported Platforms

All compiled packages build for both architectures: `amd64` and `arm64`.
containers-common is `Architecture: all` (one build per distro). passt is
provided as exact Ubuntu and Debian binaries for both architectures. Every
source-built product targets all three distributions — and on each target
the Podman package's versioned dependencies require the repository's netavark,
aardvark-dns, containers-common, and containers-storage packages.

| Platform | Codename |
|----------|----------|
| Ubuntu 24.04 | `noble` |
| Ubuntu 26.04 | `resolute` |
| Debian 13 | `trixie` |

## GitHub Actions (Default)

One build workflow, **Build and Release .deb Packages**
(`.github/workflows/build-and-release.yml`), is triggered manually from the
Actions tab (`workflow_dispatch`) with a `component` input:

- `main` — builds podman (with podman-remote and podman-docker), netavark, aardvark-dns, containers-storage, and containers-common for every supported platform/architecture in parallel. Run it when Podman or a required companion is bumped.
- `extra` — fetches the pinned passt binaries and builds crun and conmon. Run it when one of those is bumped.

Before uploading, the workflow checks every built `.deb` against
`packaging/repo/components` and fails if a package does not belong to the
component being released.

A second workflow, **Publish APT Repository** (`.github/workflows/publish-apt-repo.yml`),
runs automatically after a successful build (and can be dispatched manually).
It downloads the `.deb` assets of up to the `keep_releases` most recent `main`
and `extra` releases (default 3 of each; a dispatch can instead pin exactly one
`main_release` / `extra_release` tag), assembles and signs an
APT repository with every downloaded version indexed into the `main` and `extra`
components, smoke-installs from it inside `noble`, `resolute`, and `trixie`
containers (once with `main extra`, once with `main` alone to prove the split
holds), and deploys the result to GitHub Pages. Each publish replaces the whole
site, so a version is gone once it falls outside the retention window. Its
release assets remain downloadable from GitHub unless the release or assets are
manually deleted. See
[Hosting Your Own APT Repository](#hosting-your-own-apt-repository) for the
one-time setup it needs.

Each run builds or fetches its component's inputs, then publishes a **single
unified pre-release** containing every `.deb` from that run plus a combined
`SHA256SUMS`, tagged `<component>-<YYYYMMDD>-<N>`:

- `main-<YYYYMMDD>-<N>`
- `extra-<YYYYMMDD>-<N>`

`<N>` starts at `1` for the first build of that UTC date and increments for same-day reruns (`2`, `3`, ...).

## Hosting Your Own APT Repository

The published repository is tied to my GitHub Pages site and my signing key, so
to use these packages you run the same pipeline in your own fork. One-time setup:

1. **Fork** this repository and run the build workflow once with
   `component=main` and once with `component=extra` so a `main-*` and an
   `extra-*` release exist.
2. **Generate your own signing key** (never reuse mine):

   ```bash
   ./scripts/apt-repo-keygen.sh
   ```

   This writes the private key to `keys/apt-signing-key.private.asc` — the
   `keys/` directory is gitignored; keep it secret and back it up — and the
   public key to `packaging/repo/pubkey.asc`, which you **commit**. The publish
   script refuses to sign with any key other than the one in
   `packaging/repo/pubkey.asc`, so a fork can never accidentally publish with
   the upstream key.
3. **Store the private key** as the `GPG_PRIVATE_KEY` repository secret. From
   inside your fork's checkout, with the [GitHub CLI](https://cli.github.com/)
   logged in (`gh auth status`):

   ```bash
   gh secret set GPG_PRIVATE_KEY < keys/apt-signing-key.private.asc
   # or, from anywhere:
   gh secret set GPG_PRIVATE_KEY --repo <owner>/<repo> < keys/apt-signing-key.private.asc
   ```

   `gh secret set` reads the armored private key from stdin, fetches the
   repository's public encryption key from the GitHub API, encrypts the value
   locally (libsodium sealed box), and uploads only the ciphertext. GitHub never
   returns a secret's value — `gh secret list` shows just the name and update
   time — so keep `keys/` as your own copy. The value can only be used by
   workflows in this repository, as `${{ secrets.GPG_PRIVATE_KEY }}`; the publish
   workflow pipes it into `gpg --import` inside a throwaway `GNUPGHOME` and the
   Actions log masks it.

   Without the CLI: *Settings → Secrets and variables → Actions → New repository
   secret*, name `GPG_PRIVATE_KEY`, and paste the full contents of
   `keys/apt-signing-key.private.asc` (including the `-----BEGIN/END PGP PRIVATE
   KEY BLOCK-----` lines) as the value.

   Verify with `gh secret list`; the workflow fails at its "Import signing key"
   step with an explanatory error if the secret is missing.

4. **Enable GitHub Pages** in *Settings → Pages* with source **GitHub Actions**.
5. **Run the Publish APT Repository workflow** from the Actions tab (leave the
   release inputs empty to publish the latest releases). From then on it also
   runs automatically after each successful build workflow.

Your repository is served at `https://<owner>.github.io/<repo>/` with the same
`noble` / `resolute` / `trixie` suites and `main` / `extra` components; the
generated index page shows the exact `sources` snippet and key fingerprint for
your fork. If you add a product, add its binary package name to
`packaging/repo/components` or the publish fails. To re-run the assembly
locally (on a Debian/Ubuntu host or container with `dpkg-dev`, `apt-utils`, and
`gnupg`), download as many releases as you want retained — every `.deb` under
the input directory is indexed:

```bash
gpg --import keys/apt-signing-key.private.asc
for tag in <main-tag-1> <main-tag-2> <main-tag-3>; do
  gh release download "$tag" --pattern '*.deb' --dir "debs/main/$tag"
done
for tag in <extra-tag-1> <extra-tag-2> <extra-tag-3>; do
  gh release download "$tag" --pattern '*.deb' --dir "debs/extra/$tag"
done
./scripts/build-apt-repo.sh debs repo-output https://<owner>.github.io/<repo>
./scripts/smoke-apt-repo.sh repo-output      # optional: apt-get install in containers
```

Retention is a size trade-off: one `main` release plus one `extra` release is
roughly 215 MB across all suites and architectures, so the default of three each
keeps the site around 650 MB, below the
[GitHub Pages 1 GB published-site limit](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits).
Raise `keep_releases` with care.

### Signing Key

The repository is trusted through one OpenPGP key pair created by
`scripts/apt-repo-keygen.sh`:

| Half | Location | Role |
|------|----------|------|
| Private | `keys/apt-signing-key.private.asc` (gitignored) and the `GPG_PRIVATE_KEY` repository secret | Signs each suite's `Release` file during publish |
| Public | `packaging/repo/pubkey.asc` (committed), served as `<repo-url>/podman-package.gpg` and `.asc` | Installed by clients under `/etc/apt/keyrings/` and referenced by `Signed-By:` |

**What is signed.** Only `dists/<suite>/Release` is signed (as `InRelease`, and
detached as `Release.gpg`). `Release` lists the size and SHA256/SHA512 of every
`Packages` index, and each `Packages` stanza lists the size and SHA256 of its
`.deb`. That hash chain — signed `InRelease` → `Packages` → `.deb` — is what apt
verifies on `apt update` and `apt install`, so a single signature covers the whole
suite. Modifying signed metadata, an indexed package list, or a referenced
`.deb` makes apt reject the affected update or download. Files outside that hash
chain, such as the HTML landing page, are not covered. The `.deb` files
themselves carry no signature.

**Key properties.** RSA-4096, sign-only, **no passphrase** (the workflow must use
it non-interactively; a passphrase would just be a second secret stored beside
the first) and **no expiry** (an expiring key would break every client's
`apt update` on the expiry date). Protection therefore rests entirely on
keeping the private half out of git and out of logs: `keys/` is gitignored, the
keygen script refuses to run if it is not, and in CI the key is imported into a
throwaway `GNUPGHOME` under `$RUNNER_TEMP` that exists only for that job.

**Which key gets used.** `scripts/build-apt-repo.sh` reads the fingerprint from
the committed `packaging/repo/pubkey.asc` and signs with exactly that key; if the
matching secret key is not in the keyring it aborts. A fork that keeps the
upstream `pubkey.asc` but supplies its own secret fails loudly instead of
publishing a repository nobody can verify.

**Backup.** After generation, the private key is stored in the local gitignored
`keys/` directory and uploaded to the GitHub secret (whose value cannot be read
back). Store an independent encrypted backup. Losing every usable copy does not
affect already published metadata, but no further publish can be signed until
you rotate.

**Rotation (lost, leaked, or scheduled).**

```bash
./scripts/apt-repo-keygen.sh --force                          # new pair; overwrites keys/ and pubkey.asc
gh secret set GPG_PRIVATE_KEY < keys/apt-signing-key.private.asc
git commit -am "chore: rotate APT signing key" && git push     # publish the new public key
gh workflow run "Publish APT Repository"                       # re-sign the repository
```

Every client must then re-download the keyring
(`sudo curl -fsSL -o /etc/apt/keyrings/podman-package.gpg <repo-url>/podman-package.gpg`);
until they do, `apt update` fails with `NO_PUBKEY` for this source. That is the
intended behavior. Replacing a client's keyring removes its trust in the old
key; clients that have not installed the new key still trust signatures made by
the leaked key. If the key leaked, rotate immediately: anyone holding it could
publish packages that clients retaining the old key would trust.

Repository layout notes:

- Suites are defined in `packaging/repo/suites` (one line per distro codename).
  Source-built packages are routed by their `~<suite>` version suffix; the
  pinned `passt` binaries are routed by the `_ubuntu_` / `_debian_` marker in
  their release asset names to every suite of that family.
- Every version found is indexed (`dpkg-scanpackages --multiversion`). A `.deb`
  that recurs across releases with identical content (the pinned `passt`
  binary) is stored once; the same filename with different content aborts the
  publish.
- The pool is partitioned per suite (`pool/<suite>/…`) rather than shared,
  because the Ubuntu and Debian `passt` binaries have identical package
  name/version/architecture but different contents.
- `Release` files carry `Acquire-By-Hash: yes` with `by-hash/` copies of every
  index, so a half-propagated GitHub Pages deploy cannot produce apt
  hash-sum mismatches.
- `scripts/verify-apt-repo.sh` re-checks signatures, `Release` ↔ index hashes,
  and index ↔ pool hashes before anything is uploaded.

## Local Builds

Use one explicit Buildx entrypoint:

```bash
./scripts/build-deb.sh <package> <distro-family> <suite>
```

Packages:
- `podman`
- `netavark`
- `aardvark-dns`
- `crun`
- `conmon`
- `containers-common`
- `containers-storage`

Targets:
- `ubuntu noble`
- `ubuntu resolute`
- `debian trixie`

Examples:

```bash
./scripts/build-deb.sh podman ubuntu noble
./scripts/build-deb.sh netavark debian trixie
./scripts/build-deb.sh containers-storage ubuntu resolute
```

passt is intentionally not rebuilt. To fetch and verify one of the exact
binaries the `extra` component ships:

```bash
./scripts/fetch-passt-deb.sh ubuntu amd64 output/passt
./scripts/fetch-passt-deb.sh debian arm64 output/passt
```

## Script Layout

- GitHub Actions workflows: `.github/workflows/build-and-release.yml` (one APT component per run: `main` or `extra`) and `.github/workflows/publish-apt-repo.yml` (APT repository → GitHub Pages)
- Host/orchestrator entrypoint: `scripts/build-deb.sh`
- Pinned passt binary fetcher: `scripts/fetch-passt-deb.sh`
- APT repository: `scripts/apt-repo-keygen.sh` (signing key), `scripts/build-apt-repo.sh` (assemble + sign), `scripts/verify-apt-repo.sh` (integrity gate), `scripts/smoke-apt-repo.sh` (container install test); config in `packaging/repo/suites`, `packaging/repo/components`, and `packaging/repo/pubkey.asc`; private key in gitignored `keys/`
- Shared host helpers: `scripts/lib/`
- Shared in-container dispatcher: `scripts/container/build.sh`
- Product build modules: `scripts/container/products/`
- Shared Dockerfile: `docker/Dockerfile`
- Package patch hierarchy: `packaging/<package>/<distro-family>/<suite>/patches/`

## Output Contract

Source-build artifacts are written to:

`output/<distro-family>/<suite>/<build-date>/<architecture>/`

Where:
- `<distro-family>` is `ubuntu` or `debian`
- `<suite>` is a supported codename from the Support Matrix above
- `<build-date>` is the UTC date in `YYYYMMDD` format from `date -u +%Y%m%d`
- `<architecture>` is `amd64` or `arm64`

Example UTC date version:
- `20260216` (Monday, February 16, 2026 UTC)

Same-day rerun behavior:
- Each local build invocation deletes
  `output/<distro-family>/<suite>/<YYYYMMDD>/` before rebuilding.
- This intentionally replaces all same-day local artifacts already present for
  that distro family and suite.

Per-architecture run behavior:
- Local compiled-package builds run sequentially in order: arm64, then amd64.
- `containers-common` is `Architecture: all` and therefore runs only through the amd64 builder.
- Each architecture run is isolated.
- Artifacts for an architecture are exported as soon as that architecture finishes.
- If one architecture fails, the script stops before attempting remaining architectures and exits non-zero at the end.

## What The Build Does

- Runs source builds entirely in Docker containers; pinned passt binaries are fetched directly on the GitHub runner.
- GitHub Actions: uses native `amd64` and `arm64` runners with `docker build` (BuildKit default). All supported distro/arch combinations build in parallel.
- Local: uses `docker buildx build --platform` for cross-compilation. Architectures run sequentially.
- Uses `--pull --no-cache` for each build to ensure fresh apt metadata/security updates on every run.
- Uses pinned upstream inputs from `packaging/versions.env`.
- Downloads the exact pinned Ubuntu and Debian passt `.deb`s and verifies their SHA-256 hashes and package metadata.
- Derives the Go toolchain version from upstream `go.mod` for Podman and containers-storage.
- Injects distro packaging (`debian/`) into upstream Podman source.
- Applies repository-managed patch series only (no runtime fallback).
- Uses consistent container build settings:
  - `DEB_BUILD_OPTIONS="nocheck noautodbgsym"`
  - `GOTELEMETRY=off` for Go builds
- Writes `SHA256SUMS` in each arch directory.
- Writes `manifest.txt` at
  `output/<distro-family>/<suite>/<YYYYMMDD>/manifest.txt`.

## Deterministic Patch Policy

No runtime fallback or auto-detection is used.

Patch directory convention:
- `packaging/<package>/<distro-family>/<suite>/patches/series`
- `packaging/<package>/<distro-family>/<suite>/patches/*.patch`

Notes:
- Each target build uses its own `series` file exactly as-is.
- Empty `series` means patch application is skipped.

## Version Pinning

Pinned upstream input config:
- `packaging/versions.env`

```bash
# passt (exact distro-built binary packages)
PASST_VERSION=0.0~git20260728.f8df3f1-1
PASST_UBUNTU_AMD64_SHA256=6dbd1d18e0f0ae5990e1b3d6369e04410c0934742ae144b7ce7b403138d2414a
PASST_UBUNTU_ARM64_SHA256=41d239f7c5650388d8588de127e7324bc8ffcca8f2f85b08702dde9ca09995d3
PASST_DEBIAN_AMD64_SHA256=141ccaa22e36c36a71221458f432fadc90d5f17c53f005ae7d84de963d5bd489
PASST_DEBIAN_ARM64_SHA256=1121baf65be564bd3bc54dd121f27f609f8b61746567c17224fbba08401b0405

# Podman (Go)
PODMAN_TAG=v6.1.0
UPSTREAM_SHA256=e086183db2f852476a7fa2580d0276cef32086b4cf17ae7020948f06eb613e0d

# netavark (Rust)
NETAVARK_TAG=v2.0.0
NETAVARK_UPSTREAM_SHA256=031aeeacc930382e8635d40a885798eff1da164dfcf9024b698f822e5995d9c8
NETAVARK_VENDOR_SHA256=86de7eb3a4e9ecc4acd5addc462879e8f2bac3562a4b99f12a4be67e5218c2cb
RUST_VERSION=1.88.0

# aardvark-dns (Rust) — reuses RUST_VERSION above
AARDVARK_TAG=v2.0.0
AARDVARK_UPSTREAM_SHA256=d3f5d6b3be3c2d80e8257fb9467e34ff104f299474427979454034dca6dc88cc
AARDVARK_VENDOR_SHA256=c5ca49d98c535fa3c8d0d195512faf1f8610ad9ca4f62bec73c7bbfc4ddcc0b6

# crun (C OCI runtime) — built from the upstream release dist tarball
CRUN_TAG=1.28
CRUN_VERSION=1.28
CRUN_ARCHIVE_SHA256=eb8fe73ffe44d868b14bb94fa6c295bd57e8bf023de43b61579da826c07cc406

# conmon (C container monitor) — built from the upstream tag archive
CONMON_TAG=v2.2.1
CONMON_VERSION=2.2.1
CONMON_ARCHIVE_SHA256=814fb5979a3a4b8576b1f901e606b482bebb41cb7e57926e6d5765ee786b96d3

# containers-common (config files; Architecture: all) — from the container-libs monorepo
CONTAINERS_COMMON_TAG=common/v0.68.0
CONTAINERS_COMMON_VERSION=0.68.0
CONTAINERS_COMMON_ARCHIVE_SHA256=61391b67e58ecffe4aae8ed620f35c57098b612d0b602d640ad541fb24b06908

# containers-storage (CLI + storage.conf) — from the container-libs monorepo (Go is derived from go.mod)
CONTAINERS_STORAGE_TAG=storage/v1.63.0
CONTAINERS_STORAGE_VERSION=1.63.0
CONTAINERS_STORAGE_ARCHIVE_SHA256=3a0f119a5abb11ff45e49793243278075c5ab5c409dd93ef5106aa443b410fc7
```

Notes:
- All orchestrators source this file directly.
- passt pins four exact binary URLs and hashes: Ubuntu `amd64`/`arm64` from the
  Launchpad build of `0.0~git20260728.f8df3f1-1`, and Debian `amd64`/`arm64`
  from the immutable `20260728T202839Z` snapshot. The fetcher verifies the
  SHA-256 plus the package name, version, and architecture.
- `PODMAN_TAG` / `NETAVARK_TAG` control upstream source tarball selection.
- `UPSTREAM_SHA256` is required and must match the downloaded upstream Podman tarball before extraction.
  To obtain the checksum for a given tag, download the tarball from GitHub and compute its SHA256:
  ```bash
  curl -fsSL -L "https://github.com/podman-container-tools/podman/archive/refs/tags/v<VERSION>.tar.gz" | sha256sum
  ```
  Use the hex string from the output as the `UPSTREAM_SHA256` value.
- Go is not separately pinned; Podman and containers-storage each derive it
  from the `go.mod` in their pinned source.
- For netavark, both checksums are required:
  - `NETAVARK_UPSTREAM_SHA256` matches the GitHub source archive
    (`.../netavark/archive/refs/tags/v<VERSION>.tar.gz`).
  - `NETAVARK_VENDOR_SHA256` matches the release vendored-deps tarball
    (`.../netavark/releases/download/v<VERSION>/netavark-v<VERSION>-vendor.tar.gz`),
    used for an offline, deterministic cargo build.
  - `RUST_VERSION` pins the Rust toolchain installed in-container (must be >= netavark's MSRV);
    it is downloaded and checksum-verified from `static.rust-lang.org`.
- aardvark-dns mirrors netavark and reuses the same `RUST_VERSION`. Both checksums are required:
  - `AARDVARK_UPSTREAM_SHA256` matches the GitHub source archive
    (`.../aardvark-dns/archive/refs/tags/v<VERSION>.tar.gz`).
  - `AARDVARK_VENDOR_SHA256` matches the release vendored-deps tarball
    (`.../aardvark-dns/releases/download/v<VERSION>/aardvark-dns-v<VERSION>-vendor.tar.gz`).
  - aardvark-dns ships a single binary (no systemd units, no man page).
- crun uses its bare version as the tag (no leading `v`, e.g. `1.28`) and
  `CRUN_TAG` must equal `CRUN_VERSION`. `CRUN_ARCHIVE_SHA256` matches the upstream
  release **dist tarball** (`.../crun/releases/download/<VERSION>/crun-<VERSION>.tar.gz`),
  which is self-contained (bundled libocispec + blake3, pre-generated `configure`),
  so no submodules or autoreconf are needed:
  ```bash
  curl -fsSL -L "https://github.com/containers/crun/releases/download/<VERSION>/crun-<VERSION>.tar.gz" | sha256sum
  ```
  It compiles against system libs (json-c, libseccomp, libsystemd, libcap) and
  installs only the `crun` binary + man page (`--disable-libcrun`, CRIU disabled).
- conmon uses a `v<VERSION>` tag. `CONMON_ARCHIVE_SHA256` matches the GitHub tag
  archive (`.../conmon/archive/refs/tags/v<VERSION>.tar.gz`). Each target starts
  from its distro `conmon` source package's `debian/` metadata, replaces the
  patch series with the repo-managed series, and builds the upstream C source
  against that target's glib, systemd, and seccomp libraries.
- containers-common is built from the `containers/container-libs` monorepo (the
  `common/` subdir), tagged `common/v<VERSION>`. It produces an
  `Architecture: all` package (config files + man pages; no Go compilation), so
  only the archive checksum is pinned:
  - `CONTAINERS_COMMON_TAG` is the monorepo tag, e.g. `common/v0.68.0`.
  - `CONTAINERS_COMMON_ARCHIVE_SHA256` matches the GitHub container-libs tag archive
    (`.../container-libs/archive/refs/tags/common/v<VERSION>.tar.gz`).
- containers-storage is built from the same monorepo (the `storage/` subdir),
  tagged `storage/v<VERSION>`. It is a CGO Go build (the Go toolchain version is
  derived from upstream `go.mod`, like Podman), producing the arch-dependent
  `containers-storage` CLI plus the corrected `storage.conf`:
  - `CONTAINERS_STORAGE_TAG` is the monorepo tag, e.g. `storage/v1.63.0`.
  - `CONTAINERS_STORAGE_ARCHIVE_SHA256` matches the GitHub container-libs tag archive
    (`.../container-libs/archive/refs/tags/storage/v<VERSION>.tar.gz`).

## Output Layout Example

```text
output/
  <distro-family>/
    <suite>/
      <YYYYMMDD>/
        manifest.txt
        <arch>/
          *.deb
          *.changes
          *.buildinfo
          build.log
          SHA256SUMS
```

Where:
- `<distro-family>` is `ubuntu` or `debian`
- `<suite>` is a supported codename from the Support Matrix above
- `<YYYYMMDD>` is the UTC build version (for example `20260216`)
- `<arch>` is `amd64` or `arm64`

## Prerequisites

GitHub Actions (default):
- Repository with Actions enabled and `contents: write` permission for the workflow.
- Access to the standard
  [`ubuntu-24.04-arm` GitHub-hosted runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
  used by the build matrix; private repositories consume Actions minutes for
  that runner.
- For the APT repository: GitHub Pages enabled with source "GitHub Actions", the
  `GPG_PRIVATE_KEY` secret, and your own `packaging/repo/pubkey.asc` (see
  [Hosting Your Own APT Repository](#hosting-your-own-apt-repository)).

Local builds:
- Docker with Buildx support.

Builds require network access to the target distro's package repositories,
GitHub source archives, `go.dev` for Go builds, and `static.rust-lang.org` for
Rust builds. Fetching passt additionally uses Launchpad or
snapshot.debian.org. The workflows also use the GitHub API and Releases.

## Releases

One build workflow, **Build and Release .deb Packages**
(`.github/workflows/build-and-release.yml`), is triggered manually
(`workflow_dispatch`) with a `component` input of `main` or `extra`; releases
mirror the APT components exactly:

- `main-<YYYYMMDD>-<N>` (e.g., `main-20260827-1`) — podman, podman-remote, podman-docker, netavark, aardvark-dns, containers-common, and containers-storage.
- `extra-<YYYYMMDD>-<N>` (e.g., `extra-20260827-1`) — passt, crun, and conmon.

After a run succeeds, **Publish APT Repository** republishes the GitHub Pages
APT repository from the most recent releases of each component (see
[Install via APT](#install-via-apt-maintainers-personal-repository)).

Each run publishes a single unified pre-release containing every `.deb` it
built or fetched plus a combined `SHA256SUMS`. Podman, passt, netavark,
aardvark-dns, crun, conmon, and containers-storage carry both architectures;
containers-common produces one `Architecture: all` `.deb` per suite. No manual
upload is needed.

Package version format inside source-built `.deb`s:
`<UPSTREAM_VERSION>+<YYYYMMDD>-<N>~<DISTRO>` (for example
`6.1.0+20260827-1~trixie` or `2.0.0+20260827-1~trixie`). GitHub normalizes
special characters in release asset filenames, so the workflow renames release
assets before upload to use dots in the filename suffix (for example
`6.1.0+20260827-1.trixie`) while leaving the package version inside the `.deb`
unchanged.

## Runtime Requirement for Newer `pasta` Features

This is a feature-level requirement, not a base Podman package dependency.

Ubuntu 24.04 (`noble`):
- Requirement for `pasta --map-host-loopback`: `passt >= 0.0~git20250217.a1e48a0-1`.
- Ubuntu noble currently provides `passt 0.0~git20240220.1e6f92b-1`, which is below that requirement.
- For noble hosts that need this feature, install the `ubuntu` passt asset from
  the `extra` release (or `apt install passt` with the `extra` component). It is the exact pinned
  [`0.0~git20260728.f8df3f1-1` Launchpad binary](https://launchpad.net/ubuntu/+source/passt/0.0~git20260728.f8df3f1-1).

Ubuntu 26.04 (`resolute`):
- The distro's `passt 0.0~git20260120.386b5f5-1` already provides
  `--map-host-loopback`.
- The `extra` component still replaces it with the July pin needed for Podman
  6.1's Pesto forwarding syntax, described below.

Debian 13 (`trixie`):
- No workaround is required.
- Debian trixie provides `passt 0.0~git20250503.587980c-2+deb13u1`, which satisfies the requirement above.
- The `extra` release also provides the newer exact pinned
  [`0.0~git20260728.f8df3f1-1` Debian sid binary](https://snapshot.debian.org/package/passt/0.0~git20260728.f8df3f1-1/)
  from snapshot.debian.org.
- Quick check:

```bash
apt-cache policy passt
pasta --help | grep -F -- '--map-host-loopback'
```

Example feature check (requires a host service bound to `127.0.0.1:<port>`):

1. Start a host-local test server (terminal A):

```bash
python3 -m http.server --bind 127.0.0.1 18080
```

Expected behavior for this server:
- Requesting `http://127.0.0.1:18080/` returns `200`.
- Requesting a missing path (for example `/does-not-exist`) returns `404`.

2. From another terminal, run a container over `pasta` with loopback mapping (terminal B):

```bash
podman run --rm --network 'pasta:--map-host-loopback,169.254.0.1' \
  docker.io/curlimages/curl:latest \
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 http://169.254.0.1:18080/
```

Expected result for the Python server example above: `200`.
If you intentionally curl a missing path, `404` is also a valid connectivity signal.
A timeout or `000` means connectivity failed.

This repository does not rebuild passt from source. The `extra` workflow
automatically downloads, verifies, and publishes the four exact Ubuntu and
Debian binaries pinned in `packaging/versions.env`.

## Known Issue: Rootless IPv6 Publish Drops on Dynamic-Address Hosts

On hosts with a dynamic IPv6 address (SLAAC privacy/temporary addresses, rotating
delegated prefixes — e.g. WSL instances), rootless containers that publish ports
over the default `pasta` network can stop receiving inbound IPv6 traffic after
the host address rotates, until the container is restarted or a static IPv6
address is configured on the host.

This affects plain `podman run -p ...` and Quadlet units with no `Network=` line:
rootless containers without an explicit network use `default_rootless_network_cmd`
from `containers.conf`, which is `pasta` — so these are on the affected path even
though `--network=pasta` was never written anywhere.

Cause: `pasta` copies the host's addresses into the container namespace once at
startup and forwards inbound connections with the original destination address
preserved (no NAT). After the host's dynamic IPv6 rotates, new inbound
connections arrive addressed to the new host address, which no longer matches
any address inside the namespace, and are dropped. The host-side wildcard bind
is not the problem; `pasta` does not track host address changes at runtime.

### Mitigation: `pesto` kernel-level port forwarding (Podman >= 6.1.0)

[Podman 6.1.0](https://github.com/podman-container-tools/podman/releases/tag/v6.1.0)
adds IPv6 support to the experimental `pesto` rootless port forwarder. `pesto`
DNATs published ports to the container's stable IP on its rootless bridge
network instead of preserving the host destination address, and binds both
`0.0.0.0` and `[::]` when no `HostIP` is given — so host address rotation cannot
strand the forwarding path.

Requirements:

- Podman >= 6.1.0 (this repository's builds satisfy this; see
  `packaging/versions.env`).
- passt `0.0~git20260728.f8df3f1-1` or newer. Merely shipping the `pesto`
  binary is not enough: [Podman 6.1 emits target-address forwarding
  rules](https://github.com/podman-container-tools/podman/blob/v6.1.0/vendor/go.podman.io/common/libnetwork/pasta/pesto_linux.go)
  added upstream in July, and its IPv6 path also needs the later local-mode fix.
  The pinned binaries use the upstream
  [July 28 tag](https://passt.top/passt/tag/?h=2026_07_28.f8df3f1), which contains
  both changes; the former June pin and the supported suites' older distro
  packages do not.
- The container must be on a rootless **bridge** network (a named network or a
  Quadlet `.network` unit referenced via `Network=`). Containers on the plain
  `pasta` default keep the startup-snapshot behavior described above.
- `containers.conf` (`[network]` section):

```ini
[network]
rootless_port_forwarder = "pasta"
```

This option is experimental in Podman 6.1.0 and its behavior may change.

The July 28 pin is therefore the compatibility floor used by this repository,
not just an optional newer passt. Before relying on the experimental IPv6 path,
smoke-test it on the target host: publish a port from a container on a rootless
bridge network, rotate or remove the host's IPv6 address, and confirm inbound
IPv6 still reaches the container.
