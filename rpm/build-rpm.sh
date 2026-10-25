#!/bin/bash
# Builds c4raven-server-<version>-1.el9.<arch>.rpm by staging a package tree and
# handing it to rpmbuild as a tarball -- the same shape as build-deb.sh, which
# stages a tree and calls `dpkg-deb --build`. There is no compilation at
# package-build time (the backend's venv is built on the *target* machine by the
# setup script, matching install.sh and the .deb).
#
# Usage:
#   PKG_VERSION=2.2.3 ./build-rpm.sh
#
# SERVER_SHA / UI_SHA (optional): pin the package to specific commits of
# c4raven-server / c4raven-ui. Defaults to each repo's current main tip at build
# time -- this is what makes a given RPM version reproducible: the setup script
# checks out exactly this commit, not a floating branch.
#
# OFFLINE_PAYLOAD (optional, set by an offline bundler -- don't set it by hand):
# a staged directory holding the prebuilt backend wheels, the built UI, mediamtx
# and the ATAK plugin. It is shipped at /usr/share/c4raven-server/offline, which
# switches the setup script to installing from those files instead of cloning
# and building from GitHub. The result is arch-specific and needs no internet at
# install time.
#
# DIST (optional, default .el9): the RPM dist tag. Override only if you are
# deliberately building for a different EL release.
set -euo pipefail

: "${PKG_VERSION:?Set PKG_VERSION, e.g. PKG_VERSION=2.2.3 ./build-rpm.sh}"
# RPM forbids '-' in Version (it is the Version-Release separator).
case "$PKG_VERSION" in
  *-*) echo "error: PKG_VERSION must not contain '-' (RPM reserves it); use e.g. 2.2.3 or 2.2.3~rc1" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DIST="${DIST:-.el9}"
OFFLINE_PAYLOAD="${OFFLINE_PAYLOAD:-}"

command -v rpmbuild >/dev/null 2>&1 || {
  echo "error: rpmbuild not found. On EL: dnf install rpm-build; on Debian/Ubuntu: apt install rpm" >&2
  exit 1
}

SERVER_SHA="${SERVER_SHA:-$(git ls-remote https://github.com/C4-Raven/c4raven-server.git refs/heads/main | cut -f1)}"
UI_SHA="${UI_SHA:-$(git ls-remote https://github.com/C4-Raven/c4raven-ui.git refs/heads/main | cut -f1)}"

# ---------------------------------------------------------------------------
# Offline payload: validate hard, before anything is staged.
#
# An offline bundle's wheels are compiled C extensions. Two of the backend's
# locked dependencies have no usable wheel and are built from sdist on every
# arch for cp312/cp313 -- mutf8 (no wheels past cp39, none for aarch64 at all)
# and unishox2-py3 (aarch64 wheels only through cp310). So every bundle contains
# locally-built .so files, and where they were built matters:
#
#   * Rocky 9's glibc is 2.34. Ubuntu noble is 2.39, questing 2.42. A wheel
#     compiled on any current Ubuntu links against a newer glibc than EL9
#     provides and fails at *import* on Rocky.
#   * An x86_64 host cannot produce aarch64 .so files, and the usual "install
#     the wheelhouse into a venv" verification does not catch it: the wrong-arch
#     wheels resolve and install fine on the build host.
#
# Both failures are invisible until the target machine actually runs the code,
# so fail fast here instead of shipping a bundle that cannot work.
# ---------------------------------------------------------------------------
GLIBC_MAX="${GLIBC_MAX:-2.34}"   # EL9 / Rocky 9

glibc_le() {
  # $1 <= $2 for dotted versions
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

if [ -n "$OFFLINE_PAYLOAD" ]; then
  [ -f "$OFFLINE_PAYLOAD/MANIFEST" ] || { echo "error: $OFFLINE_PAYLOAD is not a staged offline payload" >&2; exit 1; }

  HOST_ARCH=$(uname -m)
  PAYLOAD_ARCH=$(awk '$1=="arch" {print $2; exit}' "$OFFLINE_PAYLOAD/MANIFEST")
  : "${PAYLOAD_ARCH:=$HOST_ARCH}"
  case "$PAYLOAD_ARCH" in
    amd64|x86_64)  RPM_ARCH=x86_64 ;;
    arm64|aarch64) RPM_ARCH=aarch64 ;;
    *) echo "error: unsupported payload arch '$PAYLOAD_ARCH'" >&2; exit 1 ;;
  esac

  # 1. No cross-arch builds.
  if [ "$RPM_ARCH" != "$HOST_ARCH" ]; then
    cat >&2 << EOF
error: this payload targets $RPM_ARCH but the build host is $HOST_ARCH.

  Two of the backend's dependencies (mutf8, unishox2-py3) have no usable wheel
  for cp312/cp313 and are compiled from sdist, so the wheelhouse contains
  host-arch .so files. Cross-building is not possible and the usual
  install-into-a-venv verification cannot detect it, because the wrong-arch
  wheels install cleanly on this machine.

  Build the $RPM_ARCH bundle on an $RPM_ARCH EL9 machine or container.
EOF
    exit 1
  fi

  # 2. The build host must be EL9, or the compiled wheels will carry a glibc
  #    newer than the target has.
  BUILD_OS_ID=""; BUILD_OS_VER=""; BUILD_OS_LIKE=""
  if [ -r /etc/os-release ]; then
    BUILD_OS_ID=$(. /etc/os-release; echo "${ID:-}")
    BUILD_OS_VER=$(. /etc/os-release; echo "${VERSION_ID:-}")
    BUILD_OS_LIKE=$(. /etc/os-release; echo "${ID_LIKE:-}")
  fi
  case "$BUILD_OS_ID:$BUILD_OS_VER" in
    rhel:9*|rocky:9*|almalinux:9*|centos:9*) ;;
    *)
      if [ "${ALLOW_NON_EL9_BUILD:-}" != "1" ]; then
        cat >&2 << EOF
error: an offline EL9 payload must be built on EL9.

  This host is ${BUILD_OS_ID:-unknown} ${BUILD_OS_VER:-?} (ID_LIKE=${BUILD_OS_LIKE:-none}),
  glibc $(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || echo '?').
  Rocky 9 provides glibc $GLIBC_MAX. Wheels compiled here link against this
  host's glibc and will fail at import on the target.

  Build inside a Rocky 9 / AlmaLinux 9 container of the same architecture.
  Set ALLOW_NON_EL9_BUILD=1 only to produce a deliberately unshippable bundle.
EOF
        exit 1
      fi
      echo "warning: ALLOW_NON_EL9_BUILD=1 -- the resulting RPM is NOT shippable." >&2
      ;;
  esac

  # 3. Independent audit: read the actual GLIBC_x.y symbol versions out of every
  #    .so in the wheelhouse. This is the check that would have caught a bundle
  #    built on the wrong host even if steps 1-2 were bypassed.
  if command -v readelf >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    echo "Auditing wheelhouse glibc symbol versions (ceiling $GLIBC_MAX)..."
    AUDIT_TMP=$(mktemp -d)
    WORST=0.0; WORST_FILE=""
    while IFS= read -r whl; do
      rm -rf "${AUDIT_TMP:?}/x"; mkdir -p "$AUDIT_TMP/x"
      unzip -qq -o "$whl" -d "$AUDIT_TMP/x" '*.so' '*.so.*' 2>/dev/null || true
      while IFS= read -r so; do
        [ -n "$so" ] || continue
        v=$(readelf -V "$so" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -V | tail -1)
        [ -n "$v" ] || continue
        if ! glibc_le "$v" "$WORST"; then WORST="$v"; WORST_FILE="$(basename "$whl"):$(basename "$so")"; fi
      done < <(find "$AUDIT_TMP/x" -name '*.so' -o -name '*.so.*' 2>/dev/null)
    done < <(find "$OFFLINE_PAYLOAD/wheelhouse" -name '*.whl' 2>/dev/null)
    rm -rf "$AUDIT_TMP"
    if [ -n "$WORST_FILE" ]; then
      echo "  highest glibc requirement: $WORST ($WORST_FILE)"
      if ! glibc_le "$WORST" "$GLIBC_MAX"; then
        echo "error: that exceeds EL9's glibc $GLIBC_MAX -- the bundle will fail at import on the target." >&2
        exit 1
      fi
    else
      echo "  (no compiled .so found in the wheelhouse -- unexpected; mutf8 and" >&2
      echo "   unishox2-py3 should both be compiled from sdist. Check the payload.)" >&2
    fi
  else
    echo "warning: readelf/unzip not available -- skipping the glibc audit." >&2
  fi

  # 4. mediamtx for the target arch must actually be in the payload.
  case "$RPM_ARCH" in
    x86_64)  MTX_ARCH=amd64 ;;
    aarch64) MTX_ARCH=arm64 ;;
  esac
  ls "$OFFLINE_PAYLOAD"/mediamtx/mediamtx_*_linux_"$MTX_ARCH".tar.gz >/dev/null 2>&1 || {
    echo "error: the payload has no mediamtx build for linux_$MTX_ARCH" >&2; exit 1; }
else
  RPM_ARCH=noarch
fi

TOP="$REPO/build/rpm"
STAGE="$TOP/stageroot-${PKG_VERSION}-${RPM_ARCH}"
rm -rf "$STAGE"
mkdir -p "$TOP"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}
mkdir -p "$STAGE/etc/c4raven-server" \
         "$STAGE/usr/sbin" \
         "$STAGE/usr/libexec/c4raven-server" \
         "$STAGE/usr/lib/systemd/system" \
         "$STAGE/usr/share/c4raven-server/nginx_configs"

# --- answer file, setup command, worker -----------------------------------
install -m 600 "$HERE/setup.conf"    "$STAGE/etc/c4raven-server/setup.conf"
install -m 755 "$HERE/c4raven-setup" "$STAGE/usr/sbin/c4raven-setup"
install -m 755 "$HERE/configure.sh"  "$STAGE/usr/libexec/c4raven-server/configure.sh"

# --- systemd units ---------------------------------------------------------
# Shared verbatim with the .deb; /usr/lib/systemd/system is the RPM home for
# them (Debian's /lib/systemd/system is the same directory via the usr-merge
# symlink, but rpm wants the real path).
for svc in raven eud_handler eud_handler_ssl cot_parser mediamtx; do
  install -m 644 "$REPO/debian/$svc.service" "$STAGE/usr/lib/systemd/system/$svc.service"
done
if [ -n "$OFFLINE_PAYLOAD" ]; then
  # The offline install has no source checkout: the backend lives in a plain
  # venv (/opt/raven/venv, a symlink the setup script swaps on upgrade).
  sed -i -e 's~/opt/raven/c4raven-server/\.venv/~/opt/raven/venv/~' \
         -e 's~^WorkingDirectory=/opt/raven/c4raven-server$~WorkingDirectory=/opt/raven/data~' \
         "$STAGE"/usr/lib/systemd/system/*.service
  if grep -q 'c4raven-server' "$STAGE"/usr/lib/systemd/system/*.service; then
    echo "error: a unit still points into the source checkout" >&2
    exit 1
  fi
fi

# --- data files ------------------------------------------------------------
# The nginx/mediamtx/rabbitmq templates are shared with install.sh, which fills
# in the cert/data paths with sed at install time. Every one of those paths is a
# fixed constant under /opt/raven for the package, so do the same substitution
# here, at build time, from the ONE copy of each template.
DATA_DIR=/opt/raven/data
subst() {
  sed -e "s~OTS_FOLDER~$DATA_DIR~g" \
      -e "s~SERVER_CERT_FILE~$DATA_DIR/ca/certs/raven/raven.pem~g" \
      -e "s~SERVER_KEY_FILE~$DATA_DIR/ca/certs/raven/raven.nopass.key~g" \
      -e "s~CA_CERT_FILE~$DATA_DIR/ca/ca.pem~g" \
      "$1" > "$2"
}
for f in "$REPO"/nginx_configs/*; do
  subst "$f" "$STAGE/usr/share/c4raven-server/nginx_configs/$(basename "$f")"
  chmod 644 "$STAGE/usr/share/c4raven-server/nginx_configs/$(basename "$f")"
done
subst "$REPO/mediamtx.yml" "$STAGE/usr/share/c4raven-server/mediamtx.yml"
install -m 644 "$REPO/rabbitmq.conf" "$REPO/seed_admin.py" "$REPO/seed_plugin.py" \
               "$STAGE/usr/share/c4raven-server/"
# Debian's nginx ships /etc/nginx/proxy_params and EL's does not; the raven_http
# and raven_https templates `include` it, so nginx would refuse to start.
install -m 644 "$HERE/proxy_params" "$STAGE/usr/share/c4raven-server/proxy_params"
# 10. configure.sh prefers this to lib/distro.sh's nginx_disable_default_site.
install -m 755 "$HERE/nginx_default_server.py" "$STAGE/usr/share/c4raven-server/nginx_default_server.py"
if grep -rq 'OTS_FOLDER\|SERVER_CERT_FILE\|SERVER_KEY_FILE\|CA_CERT_FILE' "$STAGE/usr/share/c4raven-server/"; then
  echo "error: unsubstituted placeholder left in staged data files" >&2
  exit 1
fi

# Ship the shared distro shim when the repo has one, so the setup script uses
# the same detection as install.sh instead of its built-in EL9 fallbacks.
if [ -f "$REPO/lib/distro.sh" ]; then
  install -D -m 644 "$REPO/lib/distro.sh" "$STAGE/usr/share/c4raven-server/lib/distro.sh"
fi

printf '%s' "$SERVER_SHA" > "$STAGE/usr/share/c4raven-server/SERVER_SHA"
printf '%s' "$UI_SHA"     > "$STAGE/usr/share/c4raven-server/UI_SHA"
chmod 644 "$STAGE/usr/share/c4raven-server/SERVER_SHA" "$STAGE/usr/share/c4raven-server/UI_SHA"
if [ -n "$OFFLINE_PAYLOAD" ]; then
  cp -a "$OFFLINE_PAYLOAD" "$STAGE/usr/share/c4raven-server/offline"
  printf '%s' "$PKG_VERSION" > "$STAGE/usr/share/c4raven-server/offline/VERSION"
fi

chmod -R go-w "$STAGE"

# --- hand the staged tree to rpmbuild -------------------------------------
TARBALL="$TOP/SOURCES/c4raven-server-${PKG_VERSION}-stage.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" --owner=0 --group=0 .

RPMBUILD_ARGS=(
  -bb "$HERE/c4raven-server.spec"
  --define "_topdir $TOP"
  --define "pkg_version $PKG_VERSION"
  --define "dist $DIST"
)
if [ -n "$OFFLINE_PAYLOAD" ]; then
  RPMBUILD_ARGS+=(--with offline --target "$RPM_ARCH")
fi

rpmbuild "${RPMBUILD_ARGS[@]}"

OUT=$(find "$TOP/RPMS" -name "c4raven-server-${PKG_VERSION}-1${DIST}.*.rpm" -newer "$TARBALL" | head -1)
[ -n "$OUT" ] || OUT=$(find "$TOP/RPMS" -name "c4raven-server-${PKG_VERSION}-1${DIST}.*.rpm" | head -1)

echo
echo "Built: $OUT"
echo "  c4raven-server @ $SERVER_SHA"
echo "  c4raven-ui     @ $UI_SHA"
echo
if [ -z "$OFFLINE_PAYLOAD" ]; then
  cat << 'EOF'
Before installing on a fresh Rocky 9 box, the third-party repositories this
package resolves against have to exist:

    sudo ./rpm/c4raven-el9-repos.sh

Then set the install-time answers (optional) and install:

    sudo dnf install ./c4raven-server-*.rpm
    sudo $EDITOR /etc/c4raven-server/setup.conf && sudo c4raven-setup
EOF
fi
