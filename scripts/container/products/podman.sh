#!/usr/bin/env bash

podman_configure_target() {
  PODMAN_DISTRO_SOURCE_PACKAGE="podman"
  PODMAN_DISTRO_SOURCE_GLOB="podman-*"
  PODMAN_CNI_ASSET="none"

  case "${DISTRO_FAMILY}/${DISTRO}" in
    ubuntu/noble)
      PODMAN_DISTRO_SOURCE_PACKAGE="libpod"
      PODMAN_DISTRO_SOURCE_GLOB="libpod-*"
      PODMAN_CNI_ASSET="required"
      ;;
    ubuntu/resolute)
      PODMAN_CNI_ASSET="none"
      ;;
    debian/trixie)
      PODMAN_CNI_ASSET="required"
      ;;
    *)
      die "unsupported podman target: ${DISTRO_FAMILY}/${DISTRO}"
      ;;
  esac
}

podman_validate_inputs() {
  : "${PODMAN_TAG:?PODMAN_TAG is required}"
  : "${UPSTREAM_SHA256:?UPSTREAM_SHA256 is required}"
}

podman_install_prereqs() {
  install_packages \
    ca-certificates \
    curl \
    devscripts \
    dpkg-dev \
    equivs \
    jq \
    patch \
    quilt \
    tar \
    xz-utils
}

podman_prepare_sources() {
  WORK_ROOT="/tmp/podman-build"
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}"
  cd "${WORK_ROOT}"

  fetch_distro_source "${PODMAN_DISTRO_SOURCE_PACKAGE}" "${PODMAN_DISTRO_SOURCE_GLOB}" DISTRO_SRC_DIR

  local upstream_version="${PODMAN_TAG#v}"
  UPSTREAM_VERSION="${upstream_version}"
  local upstream_tarball="${WORK_ROOT}/podman-${upstream_version}.tar.gz"
  local upstream_url="https://github.com/containers/podman/archive/refs/tags/${PODMAN_TAG}.tar.gz"

  log "Downloading upstream Podman source: ${upstream_url}"
  curl -fsSL -o "${upstream_tarball}" -L "${upstream_url}"
  verify_sha256 "${upstream_tarball}" "${UPSTREAM_SHA256}"
  tar -xzf "${upstream_tarball}" -C "${WORK_ROOT}"

  UPSTREAM_SRC_DIR="${WORK_ROOT}/podman-${upstream_version}"
  [[ -d "${UPSTREAM_SRC_DIR}" ]] || die "unable to locate unpacked upstream Podman source directory"
  cp -a "${DISTRO_SRC_DIR}/debian" "${UPSTREAM_SRC_DIR}/"

  if [[ "${PODMAN_CNI_ASSET}" == "required" ]]; then
    local cni_config="${DISTRO_SRC_DIR}/cni/87-podman-bridge.conflist"
    [[ -f "${cni_config}" ]] || die "required distro CNI asset missing: ${cni_config}"
    mkdir -p "${UPSTREAM_SRC_DIR}/cni"
    cp -a "${cni_config}" "${UPSTREAM_SRC_DIR}/cni/"
  fi

  replace_debian_patches "${UPSTREAM_SRC_DIR}"
  derive_go_toolchain_from_go_mod "${UPSTREAM_SRC_DIR}/go.mod" GO_TOOLCHAIN_VERSION
}

podman_install_go() {
  install_go_toolchain "${GO_TOOLCHAIN_VERSION}"
}

podman_patch_debian_rules() {
  cd "${UPSTREAM_SRC_DIR}"

  if ! grep -q '^export DH_GOLANG_INSTALL_ALL := 1$' debian/rules; then
    awk '
      /^export DH_GOLANG_INSTALL_EXTRA/ && !inserted {
        print
        print "export DH_GOLANG_INSTALL_ALL := 1"
        inserted=1
        next
      }
      { print }
      END {
        if (!inserted) {
          print "export DH_GOLANG_INSTALL_ALL := 1"
        }
      }
    ' debian/rules > debian/rules.new
    mv debian/rules.new debian/rules
    chmod +x debian/rules
  fi

  if ! grep -q '^override_dh_golang:' debian/rules; then
    cat >> debian/rules <<'EOF_DH_GOLANG'

override_dh_golang:
	@echo "Skipping dh_golang in repository builder workflow"
	true
EOF_DH_GOLANG
  fi

  cat >> debian/rules <<'EOF_MODULE_BUILD'

override_dh_auto_configure:
	mkdir -p _output

override_dh_auto_build:
	# PREFIX/LIBDIR must match override_dh_auto_install. Quadlet bakes the
	# podman binary path into generated units at link time.
	GO111MODULE=on GOPATH= $(MAKE) PREFIX=/usr LIBDIR=/usr/lib GOMD2MAN=/usr/bin/go-md2man podman podman-remote podman-testing rootlessport quadlet docs docker-docs

override_dh_auto_install:
	install -D -m 0755 bin/podman debian/tmp/usr/bin/podman
	install -D -m 0755 bin/podman-remote debian/tmp/usr/bin/podman-remote
	install -D -m 0755 bin/podman-testing debian/tmp/usr/bin/podman-testing
	install -D -m 0755 bin/rootlessport debian/tmp/usr/bin/rootlessport
	install -D -m 0755 bin/quadlet debian/tmp/usr/bin/quadlet
	$(MAKE) DESTDIR=debian/tmp PREFIX=/usr LIBDIR=/usr/lib GOMD2MAN=/usr/bin/go-md2man install.systemd install.docker-full install.man
EOF_MODULE_BUILD
}

podman_patch_debian_packaging() {
  cd "${UPSTREAM_SRC_DIR}"

  local podman_docker_install="debian/podman-docker.install"
  if [[ -f "${podman_docker_install}" ]]; then
    for entry in \
      "etc/profile.d/podman-docker.sh" \
      "etc/profile.d/podman-docker.csh"; do
      grep -qxF "${entry}" "${podman_docker_install}" || echo "${entry}" >> "${podman_docker_install}"
    done
  fi

  local not_installed_file="debian/not-installed"
  touch "${not_installed_file}"
  for entry in \
    "usr/bin/podman-testing" \
    ".config/go/telemetry/local/*" \
    ".config/go/telemetry/*"; do
    grep -qxF "${entry}" "${not_installed_file}" || echo "${entry}" >> "${not_installed_file}"
  done

  podman_patch_control_dependencies
}

podman_patch_control_dependencies() {
  cd "${UPSTREAM_SRC_DIR}"
  [[ -f debian/control ]] || die "debian/control not found while patching podman dependencies"
  [[ -f /workspace/packaging/versions.env ]] || die "missing pinned version config in container"

  # shellcheck disable=SC1091
  source /workspace/packaging/versions.env

  export PODMAN_DEP_NETAVARK="${NETAVARK_TAG#v}"
  export PODMAN_DEP_AARDVARK="${AARDVARK_TAG#v}"
  export PODMAN_DEP_CONTAINERS_COMMON="${CONTAINERS_COMMON_VERSION}"
  export PODMAN_DEP_CONTAINERS_STORAGE="${CONTAINERS_STORAGE_VERSION}"

  [[ "${PODMAN_DEP_NETAVARK}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "invalid NETAVARK_TAG for dependency rewrite"
  [[ "${PODMAN_DEP_AARDVARK}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "invalid AARDVARK_TAG for dependency rewrite"
  [[ "${PODMAN_DEP_CONTAINERS_COMMON}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid CONTAINERS_COMMON_VERSION"
  [[ "${PODMAN_DEP_CONTAINERS_STORAGE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid CONTAINERS_STORAGE_VERSION"

  perl -i -00 -pe '
    next unless /^Package:[ \t]*podman[ \t]*$/m;
    my $netavark = $ENV{"PODMAN_DEP_NETAVARK"};
    my $aardvark = $ENV{"PODMAN_DEP_AARDVARK"};
    my $common = $ENV{"PODMAN_DEP_CONTAINERS_COMMON"};
    my $storage = $ENV{"PODMAN_DEP_CONTAINERS_STORAGE"};
    s{^Depends:(.*?)(?=^\S|\z)}{
      my $val=$1; $val =~ s/\s+/ /g;
      my %drop = map { $_=>1 } qw(netavark aardvark-dns golang-github-containers-common containers-storage);
      my @toks = grep { length } map { my $t=$_; $t =~ s/^\s+//; $t =~ s/\s+$//; $t } split /,/, $val;
      @toks = grep { my ($n)=/^(\S+)/; !$drop{$n} } @toks;
      push @toks,
        "netavark (>= $netavark)",
        "aardvark-dns (>= $aardvark)",
        "golang-github-containers-common (>= $common)",
        "containers-storage (>= $storage)";
      "Depends: " . join(",\n ", @toks) . "\n"
    }mse;
  ' debian/control

  grep -qE "containers-storage \(>= ${PODMAN_DEP_CONTAINERS_STORAGE//./\\.}\)" debian/control || \
    die "failed to inject companion dependencies into podman debian/control"
}

podman_update_changelog() {
  cd "${UPSTREAM_SRC_DIR}"

  local debianized_upstream="${UPSTREAM_VERSION//-rc/~rc}"
  local build_id="${BUILD_VERSION}-${BUILD_REVISION}"
  local package_version="${debianized_upstream}+${build_id}~${DISTRO}"

  export DEBFULLNAME="Podman ${DISTRO_LABEL} Builder"
  export DEBEMAIL="builder@example.invalid"

  dch \
    --distribution "${DISTRO}" \
    --force-distribution \
    --newversion "${package_version}" \
    "Build upstream ${PODMAN_TAG} (${build_id}) with ${DISTRO_NAME} ${DISTRO} packaging and repo-managed patch series."
}

podman_install_build_deps() {
  cd "${UPSTREAM_SRC_DIR}"
  apt-get update -qq
  mk-build-deps \
    --install \
    --remove \
    --tool "apt-get -y --no-install-recommends" \
    debian/control
}

podman_build_package() {
  cd "${UPSTREAM_SRC_DIR}"
  apply_patch_series "${UPSTREAM_SRC_DIR}"

  export DEB_BUILD_OPTIONS="nocheck noautodbgsym"
  export GOTELEMETRY="off"
  export RELEASE_VERSION="${PODMAN_TAG}"

  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"
  log "Running dpkg-buildpackage for ${TARGET_ARCH}; logging to ${build_log}"
  dpkg-buildpackage -b -uc -us 2>&1 | tee "${build_log}"
}

product_main() {
  podman_configure_target
  podman_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized podman build for ${TARGET_ARCH} (${PODMAN_TAG})"
  setup_apt_sources
  podman_install_prereqs
  podman_prepare_sources
  podman_install_go
  podman_patch_debian_rules
  podman_patch_debian_packaging
  podman_update_changelog
  podman_install_build_deps
  podman_build_package
  collect_artifacts "${UPSTREAM_SRC_DIR}"
  log "Completed ${DISTRO_LABEL} podman build for ${TARGET_ARCH} (${PODMAN_TAG})"
}
