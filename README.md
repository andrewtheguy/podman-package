# Podman Noble Builder

Build Ubuntu 24.04 (`noble`) Podman `.deb` packages inside Docker for isolation.

This project has one entrypoint and intentionally accepts no arguments:

```bash
./scripts/build-podman-deb.sh
```

## What It Does

- Builds in Docker containers only (no host toolchain required beyond Docker/Buildx).
- Targets both `amd64` and `arm64`.
- Uses Ubuntu noble `libpod` Debian packaging as the baseline.
- Replaces Ubuntu source content with a pinned upstream Podman release from `packaging/versions.env`.
- Carries Ubuntu's `cni/87-podman-bridge.conflist` into upstream source for Debian install compatibility.
- Reads the required Go version from the pinned Podman tag's upstream `go.mod`.
- Downloads and installs that exact Go toolchain in-container from `go.dev`.
- Sets `DEB_BUILD_OPTIONS=nocheck` in-container for deterministic package builds under isolation.
- Normalizes Debian install metadata (`debian/podman-docker.install`, `debian/not-installed`) for upstream/Ubuntu drift.
- Overrides `dh_golang` in patched `debian/rules` because the workflow uses `/usr/local/go` (not distro-owned Go files).
- Applies only repository-managed patch files from `packaging/patches/`.
- Exports artifacts to `output/<tag>/<arch>/`.
- Writes checksums and a build manifest at `output/<tag>/manifest.txt`.

## Deterministic Patch Policy

There is no runtime patch fallback logic.

- The build always replaces `debian/patches/` with files from this repository:
  - `packaging/patches/series`
  - `packaging/patches/*.patch`
- The `series` file controls exactly which patches are applied.
- The default `series` file is empty, which means patch application is skipped.

## Add Custom Patches

1. Place your patch files in `packaging/patches/`.
2. Add patch filenames to `packaging/patches/series` in apply order.
3. Re-run `./scripts/build-podman-deb.sh`.

Example `packaging/patches/series`:

```text
fix-build-tag-regression.patch
update-criu-compat.patch
```

## Reproducible Version Pins

Non-Ubuntu-noble upstream inputs are pinned in:

`packaging/versions.env`

```bash
PODMAN_TAG=v5.8.0
```

Notes:
- The zero-arg orchestrator reads this file directly.
- `PODMAN_TAG` controls the upstream source tarball used for both arches.
- The Go toolchain version is derived from the pinned Podman tag's `go.mod`.

## Output Layout

```text
output/
  vX.Y.Z/
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
- Network access to:
  - Ubuntu package repositories
  - Podman source tarballs on GitHub
  - Go toolchain tarballs on `go.dev`

## Runtime Requirement for Newer `pasta` Features

This is a feature-level requirement, not a base Podman package dependency.

On Ubuntu 24.04 (`noble`), the archive `passt` build is older and does not provide newer `pasta` options such as `--map-host-loopback` with an address argument. If you need those newer features, install a newer `passt` from Ubuntu `resolute`:

- [`passt` in Ubuntu resolute](https://packages.ubuntu.com/resolute/passt)

Example feature check (expected `404` means host loopback was reached through `pasta` and the HTTP server responded):

```bash
podman run --rm --network 'pasta:--map-host-loopback,169.254.0.1' \
  docker.io/curlimages/curl:latest \
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://169.254.0.1
```

This repository currently builds Podman packages only; it does not build or backport `passt` automatically.
