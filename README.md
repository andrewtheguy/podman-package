# Podman Package Builders

Build Podman, netavark, aardvark-dns, containers-common, and containers-storage `.deb` packages in Docker for isolated, deterministic builds.

netavark (Rust network stack), aardvark-dns (Rust DNS server), containers-common
(config files), and containers-storage (storage CLI + `storage.conf`) are
**required companions of Podman 6.0** — Podman 6 will not provide container
networking or name resolution without netavark/aardvark-dns, and needs config
matching its release. They are shipped here as extra packages **built and
released for all targets** (the distro repositories do not provide versions new
enough for Podman 6). Install them together on each target. Podman, the two Rust
components, and containers-storage follow the same pattern (distro `debian/`
packaging + pinned upstream source + repo-managed patches + a self-installed
toolchain); containers-common is `Architecture: all` and needs no compilation
(config files + man pages only).

> **Why containers-storage matters:** Podman 6.0's storage library (v1.63.0)
> honors an explicitly-set `graphroot` even for rootless users (it no longer
> remaps it to `$HOME`). The distros' older `containers-storage` ships a
> `/usr/share/containers/storage.conf` with `graphroot` hardcoded to
> `/var/lib/containers/storage`, so rootless Podman 6.0 hits a root-owned path →
> *permission denied*. The v1.63.0 `storage.conf` built here leaves
> `graphroot`/`runroot` commented out, so rootless Podman falls back to its
> per-user default.

The podman package built here declares versioned dependencies on these
companions, so installing podman pulls the matching set:
`Depends: … netavark (>= 2.0.0), aardvark-dns (>= 2.0.0), golang-github-containers-common (>= 0.68.0), containers-storage (>= 1.63.0)`.
The older distro versions do not satisfy these, so install the repo's `.deb`s
together (e.g. `apt install ./*.deb`).

## Supported Platforms

All compiled packages build for both architectures: `amd64` and `arm64`.
containers-common is `Architecture: all` (one build per distro). Every product
is built for all three targets — and on each target Podman 6.0 needs the
matching netavark, aardvark-dns, and containers-common installed alongside it.

| Platform | Codename |
|----------|----------|
| Ubuntu 24.04 | `noble` |
| Ubuntu 26.04 | `resolute` |
| Debian 13 | `trixie` |

## GitHub Actions (Default)

Two workflows are triggered manually from the Actions tab (`workflow_dispatch`):

- **Build and Release Podman .deb Packages** — builds Podman for every supported platform/architecture in parallel.
- **Build and Release Podman Companion .deb Packages** — builds netavark, aardvark-dns, containers-common, and containers-storage (the packages the Podman workflow does not cover).

Each workflow builds all its platform/architecture combinations in parallel, then publishes a **single unified pre-release** containing every `.deb` from that run plus a combined `SHA256SUMS`:

- Podman: `v<VERSION>-<YYYYMMDD>-<N>`
- Companions: `podman-extras-<YYYYMMDD>-<N>`

`<N>` starts at `1` for the first build of that UTC date and increments for same-day reruns (`2`, `3`, ...).

## Local Builds

Use one explicit Buildx entrypoint:

```bash
./scripts/build-deb.sh <package> <distro> <version>
```

Packages:
- `podman`
- `netavark`
- `aardvark-dns`
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

## Script Layout

- GitHub Actions workflows: `.github/workflows/build-and-release.yml` (Podman) and `.github/workflows/build-and-release-extras.yml` (companion packages)
- Host/orchestrator entrypoint: `scripts/build-deb.sh`
- Shared host helpers: `scripts/lib/`
- Shared in-container dispatcher: `scripts/container/build.sh`
- Product build modules: `scripts/container/products/`
- Shared Dockerfile: `docker/Dockerfile`
- Package patch hierarchy: `packaging/<package>/<distro>/<version>/patches/`

## Output Contract

All artifacts are written to:

`output/<distro>/<version>/<architecture>/`

Where:
- `<distro>` is a supported codename from the Support Matrix above
- `<version>` is UTC date in `YYYYMMDD` format from `date -u +%Y%m%d`
- `<architecture>` is `amd64` or `arm64`

Example UTC date version:
- `20260216` (Monday, February 16, 2026 UTC)

Same-day rerun behavior:
- Each build invocation deletes its own `output/<distro>/<YYYYMMDD>/` directory before rebuilding.
- This intentionally replaces same-day artifacts for that distro.

Per-architecture run behavior:
- Architecture workflows run sequentially in order: arm64, then amd64.
- Each architecture run is isolated.
- Artifacts for an architecture are exported as soon as that architecture finishes.
- If one architecture fails, the script stops before attempting remaining architectures and exits non-zero at the end.

## What The Build Does

- Runs entirely in Docker containers.
- GitHub Actions: uses native `amd64` and `arm64` runners with `docker build` (BuildKit default). All supported distro/arch combinations build in parallel.
- Local: uses `docker buildx build --platform` for cross-compilation. Architectures run sequentially.
- Uses `--pull --no-cache` for each build to ensure fresh apt metadata/security updates on every run.
- Uses pinned upstream inputs from `packaging/versions.env`.
- Derives Go toolchain version from upstream Podman `go.mod`.
- Injects distro packaging (`debian/`) into upstream Podman source.
- Applies repository-managed patch series only (no runtime fallback).
- Forces deterministic container build flags:
  - `DEB_BUILD_OPTIONS="nocheck noautodbgsym"`
  - `GOTELEMETRY=off`
- Writes `SHA256SUMS` in each arch directory.
- Writes `manifest.txt` at `output/<distro>/<YYYYMMDD>/manifest.txt`.

## Deterministic Patch Policy

No runtime fallback or auto-detection is used.

Patch directory convention:
- `packaging/<package>/<distro>/<version>/patches/series`
- `packaging/<package>/<distro>/<version>/patches/*.patch`

Notes:
- Each workflow uses its own `series` file exactly as-is.
- Empty `series` means patch application is skipped.

## Version Pinning

Pinned upstream input config:
- `packaging/versions.env`

```bash
# Podman (Go)
PODMAN_TAG=v6.0.0
UPSTREAM_SHA256=f35ac7c40f0fd01bfedfe627c23ff7a577b071d50f2b0726e4734d51810f5a7d

# netavark (Rust)
NETAVARK_TAG=v2.0.0
NETAVARK_UPSTREAM_SHA256=031aeeacc930382e8635d40a885798eff1da164dfcf9024b698f822e5995d9c8
NETAVARK_VENDOR_SHA256=86de7eb3a4e9ecc4acd5addc462879e8f2bac3562a4b99f12a4be67e5218c2cb
RUST_VERSION=1.88.0

# aardvark-dns (Rust) — reuses RUST_VERSION above
AARDVARK_TAG=v2.0.0
AARDVARK_UPSTREAM_SHA256=d3f5d6b3be3c2d80e8257fb9467e34ff104f299474427979454034dca6dc88cc
AARDVARK_VENDOR_SHA256=c5ca49d98c535fa3c8d0d195512faf1f8610ad9ca4f62bec73c7bbfc4ddcc0b6

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
- `PODMAN_TAG` / `NETAVARK_TAG` control upstream source tarball selection.
- `UPSTREAM_SHA256` is required and must match the downloaded upstream Podman tarball before extraction.
  To obtain the checksum for a given tag, download the tarball from GitHub and compute its SHA256:
  ```bash
  curl -fsSL -L "https://github.com/containers/podman/archive/refs/tags/v<VERSION>.tar.gz" | sha256sum
  ```
  Use the hex string from the output as the `UPSTREAM_SHA256` value.
- Go is not separately pinned; it is read from upstream `go.mod` for the pinned Podman tag.
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
  <distro>/
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
- `<distro>` is a supported codename from the Support Matrix above
- `<YYYYMMDD>` is the UTC build version (for example `20260216`)
- `<arch>` is `amd64` or `arm64`

## Prerequisites

GitHub Actions (default):
- Repository with Actions enabled and `contents: write` permission for the workflow.
- Native `arm64` runners require a GitHub Team/Enterprise plan or a public repository.

Local builds:
- Docker with Buildx support.

Both methods require network access to:
  - Ubuntu package repositories
  - Debian package repositories
  - Podman source tarballs on GitHub
  - Go toolchain tarballs on `go.dev`

## Releases

There are two workflows, each triggered manually (`workflow_dispatch`):
- **Build and Release Podman .deb Packages** — `.github/workflows/build-and-release.yml`
- **Build and Release Podman Companion .deb Packages** — `.github/workflows/build-and-release-extras.yml` (netavark, aardvark-dns, containers-common, containers-storage)

Each workflow run publishes a single unified pre-release containing every `.deb` it built (across all distros) plus a combined `SHA256SUMS`. The Podman, netavark, aardvark-dns, and containers-storage `.deb`s carry both architectures; containers-common is the single `Architecture: all` `.deb`. No manual upload is needed.

Release tag formats:
- Podman: `v<PODMAN_VERSION>-<YYYYMMDD>-<N>` (e.g., `v6.0.0-20260415-1`).
- Companions: `podman-extras-<YYYYMMDD>-<N>` (e.g., `podman-extras-20260415-1`) — one release holding the netavark, aardvark-dns, containers-common, and containers-storage `.deb`s for every distro.

Package version format inside generated `.deb` filenames: `<UPSTREAM_VERSION>+<YYYYMMDD>-<N>~<DISTRO>` (for example `6.0.0+20260415-1~trixie` or `2.0.0+20260415-1~trixie`).

## Runtime Requirement for Newer `pasta` Features

This is a feature-level requirement, not a base Podman package dependency.

Ubuntu 24.04 (`noble`):
- Requirement for `pasta --map-host-loopback`: `passt >= 0.0~git20250217.a1e48a0-1`.
- Ubuntu noble currently provides `passt 0.0~git20240220.1e6f92b-1`, which is below that requirement.
- For noble hosts that need this feature, install `passt` from Ubuntu `plucky` or newer.

- [`passt` in Ubuntu plucky](https://packages.ubuntu.com/plucky/passt)

Debian 13 (`trixie`):
- No workaround is required.
- Debian trixie provides `passt 0.0~git20250503.587980c-2`, which satisfies the requirement above.
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

This repository currently builds Podman packages only; it does not build or backport `passt` automatically.
