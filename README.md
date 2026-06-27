# Podman Package Builders

Build Podman, netavark, and aardvark-dns `.deb` packages in Docker for isolated, deterministic builds.

netavark (Rust network stack) and aardvark-dns (Rust DNS server) are both
required by Podman 6.0. This repo builds all three products with the same
pattern (distro `debian/` packaging + pinned upstream source + repo-managed
patches + a self-installed toolchain).

## Supported Platforms

All supported platforms build for both architectures: `amd64` and `arm64`.
Podman, netavark, and aardvark-dns are all built for all three.

| Platform | Codename |
|----------|----------|
| Ubuntu 24.04 | `noble` |
| Ubuntu 26.04 | `resolute` |
| Debian 13 | `trixie` |

## GitHub Actions (Default)

The primary build method is the **Build and Release Podman .deb Packages** workflow, triggered manually from the Actions tab (`workflow_dispatch`).

The workflow builds all supported platform/architecture combinations in parallel (currently 6 jobs).

On success, one **pre-release** per supported distro codename is created automatically:

- `v<VERSION>-<DISTRO>-<YYYYMMDD>-<N>` — `.deb` files for both architectures + `SHA256SUMS`
  - `<N>` starts at `1` for the first build of that UTC date and increments for same-day reruns (`2`, `3`, ...)

## Local Builds

Zero-argument scripts for building locally with Docker Buildx:

```bash
# Podman
./scripts/build-podman-deb-ubuntu-noble.sh        # Ubuntu 24.04 (noble)
./scripts/build-podman-deb-ubuntu-resolute.sh     # Ubuntu 26.04 (resolute)
./scripts/build-podman-deb-debian-trixie.sh       # Debian 13 (trixie)

# netavark
./scripts/build-netavark-deb-ubuntu-noble.sh      # Ubuntu 24.04 (noble)
./scripts/build-netavark-deb-ubuntu-resolute.sh   # Ubuntu 26.04 (resolute)
./scripts/build-netavark-deb-debian-trixie.sh     # Debian 13 (trixie)

# aardvark-dns
./scripts/build-aardvark-dns-deb-ubuntu-noble.sh      # Ubuntu 24.04 (noble)
./scripts/build-aardvark-dns-deb-ubuntu-resolute.sh   # Ubuntu 26.04 (resolute)
./scripts/build-aardvark-dns-deb-debian-trixie.sh     # Debian 13 (trixie)
```

## Script Layout

- GitHub Actions workflow: `.github/workflows/build-and-release.yml`
- Host/orchestrator scripts remain under `scripts/`.
- In-container build scripts are under `scripts/container/`.
- Shared helpers remain under `scripts/lib/`.

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
- Each script deletes its own `output/<distro>/<YYYYMMDD>/` directory before rebuilding.
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
- Uses pinned `PODMAN_TAG` from `packaging/versions.env`.
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
- `packaging/patches-<family>-<codename>/series`
- `packaging/patches-<family>-<codename>/*.patch`

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

There are three workflows, each triggered manually (`workflow_dispatch`):
- **Build and Release Podman .deb Packages** — `.github/workflows/build-and-release.yml`
- **Build and Release netavark .deb Packages** — `.github/workflows/build-and-release-netavark.yml`
- **Build and Release aardvark-dns .deb Packages** — `.github/workflows/build-and-release-aardvark-dns.yml`

Each creates one pre-release per supported distro codename per workflow run, containing both architecture `.deb` files and a SHA256SUMS file. No manual upload is needed.

Release tag formats:
- Podman: `v<PODMAN_VERSION>-<DISTRO>-<YYYYMMDD>-<N>` (e.g., `v6.0.0-noble-20260415-1`).
- netavark: `netavark-v<NETAVARK_VERSION>-<DISTRO>-<YYYYMMDD>-<N>` (e.g., `netavark-v2.0.0-noble-20260415-1`).
- aardvark-dns: `aardvark-dns-v<AARDVARK_VERSION>-<DISTRO>-<YYYYMMDD>-<N>` (e.g., `aardvark-dns-v2.0.0-noble-20260415-1`).

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
