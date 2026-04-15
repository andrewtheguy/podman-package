# Podman Package Builders

Build Podman `.deb` packages in Docker for isolated, deterministic builds.

## Supported Platforms

All supported platforms build for both architectures: `amd64` and `arm64`.

| Platform | Codename |
|----------|----------|
| Ubuntu 24.04 | `noble` |
| Ubuntu 26.04 | `resolute` |
| Debian 12 | `bookworm` |
| Debian 13 | `trixie` |

## GitHub Actions (Default)

The primary build method is the **Build and Release Podman .deb Packages** workflow, triggered manually from the Actions tab (`workflow_dispatch`).

The workflow builds all supported platform/architecture combinations in parallel (currently 8 jobs).

On success, one **pre-release** per supported distro codename is created automatically:

- `v<VERSION>-<DISTRO>-<YYYYMMDD>` — `.deb` files for both architectures + `SHA256SUMS`

## Local Builds

Zero-argument scripts for building locally with Docker Buildx:

```bash
./scripts/build-podman-deb-ubuntu-noble.sh      # Ubuntu 24.04 (noble)
./scripts/build-podman-deb-ubuntu-resolute.sh   # Ubuntu 26.04 (resolute)
./scripts/build-podman-deb-debian-bookworm.sh   # Debian 12 (bookworm)
./scripts/build-podman-deb-debian-trixie.sh     # Debian 13 (trixie)
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
  - `DEB_BUILD_OPTIONS=nocheck`
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
PODMAN_TAG=v5.x.x
UPSTREAM_SHA256=....
```

Notes:
- All orchestrators source this file directly.
- `PODMAN_TAG` controls upstream source tarball selection.
- `UPSTREAM_SHA256` is required and must match the downloaded upstream Podman tarball before extraction.
  To obtain the checksum for a given tag, download the tarball from GitHub and compute its SHA256:
  ```bash
  curl -fsSL -L "https://github.com/containers/podman/archive/refs/tags/v<VERSION>.tar.gz" | sha256sum
  ```
  Use the hex string from the output as the `UPSTREAM_SHA256` value.
- Go is not separately pinned; it is read from upstream `go.mod` for the pinned tag.

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

GitHub Actions creates one pre-release per supported distro codename per workflow run, each containing both architecture `.deb` files and a SHA256SUMS file. No manual upload is needed.

Release tag format: `v<PODMAN_VERSION>-<DISTRO>-<YYYYMMDD>` (e.g., `v5.8.2-noble-20260415`).

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
