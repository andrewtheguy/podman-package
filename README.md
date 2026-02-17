# Podman Package Builders

Build Podman `.deb` packages in Docker for isolated, deterministic builds.

This repository has two zero-argument build entrypoints:

```bash
./scripts/build-podman-deb.sh
./scripts/build-podman-deb-debian13.sh
```

Release upload helper (requires one argument):

```bash
./scripts/push-deb-assets-to-release.sh <release-tag>
```

## Script Layout

- Host/orchestrator scripts remain under `scripts/`.
- In-container build scripts are under `scripts/container/`.
- Shared helpers remain under `scripts/lib/`.

## Targets

- Ubuntu 24.04 codename `noble` (multi-arch: `amd64`, `arm64`)
- Debian 13 codename `trixie` (multi-arch: `amd64`, `arm64`)

## Output Contract

All artifacts are written to:

`output/<distro>/<version>/<architecture>/`

Where:
- `<distro>` is the codename: `noble` or `trixie`
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

- Runs entirely in Docker containers (host only needs Docker + Buildx).
- Uses one `docker buildx build` pipeline per architecture (no separate `--load` + `docker run` step).
- Uses `docker buildx --pull --no-cache` for each architecture to ensure fresh apt metadata/security updates on every run.
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

Ubuntu (`noble`) patch source:
- `packaging/patches/series`
- `packaging/patches/*.patch`

Debian (`trixie`) patch source:
- `packaging/patches-debian13/series`
- `packaging/patches-debian13/*.patch`

Notes:
- Each workflow uses its own `series` file exactly as-is.
- Empty `series` means patch application is skipped.

## Version Pinning

Pinned upstream input config:
- `packaging/versions.env`

```bash
PODMAN_TAG=v5.8.0
UPSTREAM_SHA256=19723cda810e087ded8903fb0f33918b10d81f7fd1d8964880c41ec30d1daa70
```

Notes:
- Both orchestrators source this file directly.
- `PODMAN_TAG` controls upstream source tarball selection.
- `UPSTREAM_SHA256` is required and must match the downloaded upstream Podman tarball before extraction.
- Go is not separately pinned; it is read from upstream `go.mod` for the pinned tag.

## Output Layout Example

```text
output/
  noble/
    20260216/
      manifest.txt
      amd64/
        *.deb
        *.changes
        *.buildinfo
        build.log
        SHA256SUMS
      arm64/
        *.deb
        *.changes
        *.buildinfo
        build.log
        SHA256SUMS
  trixie/
    20260216/
      manifest.txt
      amd64/
        *.deb
        *.changes
        *.buildinfo
        build.log
        SHA256SUMS
      arm64/
        *.deb
        *.changes
        *.buildinfo
        build.log
        SHA256SUMS
```

## Prerequisites

- Docker with Buildx support.
- GitHub CLI (`gh`) authenticated for your target GitHub host when uploading release assets.
- Network access to:
  - Ubuntu package repositories
  - Debian package repositories
  - Podman source tarballs on GitHub
  - Go toolchain tarballs on `go.dev`

## Upload `.deb` Assets To GitHub Release

Upload all built `.deb` files for a build date to an existing release tag:

```bash
GITHUB_REPOSITORY=<owner/repo> ./scripts/push-deb-assets-to-release.sh <release-tag>
```

The upload script always requires and uploads both distro outputs for that build date:
- `output/noble/<BUILD_VERSION>/...`
- `output/trixie/<BUILD_VERSION>/...`

Optional environment:
- `BUILD_VERSION` (default: `date -u +%Y%m%d`)
- `OUTPUT_ROOT` (default: `output`)
- `GH_HOST` (default: `github.com`)

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
