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
- Replaces Ubuntu source content with the latest stable upstream Podman release at run time.
- Carries Ubuntu's `cni/87-podman-bridge.conflist` into upstream source for Debian install compatibility.
- Installs and uses the exact Go version declared in upstream `go.mod` before `dpkg-buildpackage`.
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
  - GitHub releases API and Podman source tarballs
