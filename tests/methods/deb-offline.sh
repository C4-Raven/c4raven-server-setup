#!/bin/bash
# Method: the offline bundle (build-offline.sh), installed with no network.
#
# Unlike the other methods this one does NOT build inside the target
# container: build-offline.sh is a build-host operation (it needs Node 20.19+,
# corepack, apt-ftparchive, several Python interpreters and read access to
# three private repos, and it takes tens of minutes). run-matrix.sh builds
# the bundle on the host and bind-mounts it in; this script only installs it,
# which is the part worth testing in a pristine container.
#
# Env: DISTRO ARCH REPO, and BUNDLE_DIR = the unpacked
# c4raven-server-offline_<ver>_<suite>_<arch> directory, or BUNDLE_TAR.
set -uo pipefail

EXIT_SKIP=77
say() { printf '\n### %s\n' "$*"; }

case "$DISTRO" in
  ubuntu-*) ;;
  *) echo "SKIP: the offline bundle is Debian-family only (this is $DISTRO)." >&2
     exit "$EXIT_SKIP" ;;
esac

if [ -z "${BUNDLE_DIR:-}" ] && [ -z "${BUNDLE_TAR:-}" ]; then
  echo "SKIP: no offline bundle supplied." >&2
  echo "      Build one first (PKG_VERSION=x.y.z ./build-offline.sh) and re-run with" >&2
  echo "      tests/run-matrix.sh --method deb-offline --bundle build/c4raven-server-offline_*.tar" >&2
  exit "$EXIT_SKIP"
fi

if [ -n "${BUNDLE_TAR:-}" ]; then
  BUNDLE_DIR=/opt/harness/bundle
  mkdir -p "$BUNDLE_DIR"
  say "unpacking $BUNDLE_TAR"
  tar -xf "$BUNDLE_TAR" -C "$BUNDLE_DIR" --strip-components=1 || exit 1
fi

[ -x "$BUNDLE_DIR/install.sh" ] || {
  echo "FAIL: $BUNDLE_DIR has no executable install.sh -- is it an offline bundle?" >&2
  ls -1 "$BUNDLE_DIR" | sed 's/^/      /' >&2
  exit 1
}

# The bundle's own install.sh refuses a suite or architecture mismatch; let
# it, and surface the message rather than second-guessing it here.
say "bundle contents"
ls -1 "$BUNDLE_DIR" | sed 's/^/    /'

# Prove it really is offline: take the default route away for the duration
# of the install. Anything that reaches for PyPI, npm or GitHub now fails
# loudly instead of quietly succeeding because CI happens to have internet.
say "removing the default route (the offline path must not need it)"
DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -1)
[ -n "$DEFAULT_ROUTE" ] && ip route del default 2>/dev/null
# shellcheck disable=SC2086  # DEFAULT_ROUTE is a whole route spec; it must split.
restore_route() { [ -n "$DEFAULT_ROUTE" ] && ip route add $DEFAULT_ROUTE 2>/dev/null; return 0; }
trap restore_route EXIT

say "running the bundle installer"
"$BUNDLE_DIR/install.sh"
rc=$?
say "bundle install.sh exited $rc"
exit "$rc"
