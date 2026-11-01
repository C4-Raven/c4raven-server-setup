#!/bin/bash
# Offline installer for the C4 Raven server @VERSION@, Ubuntu @SUITE@ (@ARCH@).
#
#   sudo ./install.sh
#
# Installs c4raven-server and everything it depends on from ./repo only --
# no internet needed. apt treats ./repo as the sole package source for this
# run, so it never tries to reach a mirror, and it never downgrades a
# package the system already has at the same or a newer version. Safe to
# re-run, and running the bundle for a newer version upgrades in place.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/repo"

if [ "$(id -u)" != 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release
if [ "${VERSION_CODENAME:-}" != "@SUITE@" ]; then
  echo "This bundle is for Ubuntu @SUITE@; this system is ${PRETTY_NAME:-unknown}." >&2
  echo "Use the c4raven-server-offline_@VERSION@_<release>_@ARCH@.tar built for it." >&2
  exit 1
fi
# Everything in repo/ is prebuilt for one architecture -- the .deb's own
# Architecture: field, the wheels inside it and the mediamtx binary. apt
# would refuse the .deb anyway, but say so plainly rather than making the
# operator read an apt error.
HAVE_ARCH="$(dpkg --print-architecture)"
if [ "$HAVE_ARCH" != "@ARCH@" ]; then
  echo "This bundle is for @ARCH@; this system is $HAVE_ARCH." >&2
  echo "Use the c4raven-server-offline_@VERSION@_@SUITE@_${HAVE_ARCH}.tar built for it." >&2
  exit 1
fi

# The package's setup creates and starts systemd units. In a container without
# systemd as PID 1 it would unpack and then fail halfway; refuse up front.
# (sd_booted(3): systemd is running iff /run/systemd/system exists. Mirrors
# ih_require_systemd in lib/installer.sh, which is not on disk yet here.)
if [ ! -d /run/systemd/system ] && [ "${RAVEN_SKIP_SYSTEMD_CHECK:-0}" != 1 ]; then
  echo "This installer needs systemd running as PID 1 (PID 1 here is '$(cat /proc/1/comm 2>/dev/null || echo unknown)')." >&2
  echo "In a container, start it with systemd as init, e.g.:" >&2
  echo "    docker run -d --privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock \\" >&2
  echo "      -v /sys/fs/cgroup:/sys/fs/cgroup:rw <image-with-systemd> /sbin/init" >&2
  echo "(podman: add --systemd=always), then run this inside it. Nothing was changed." >&2
  exit 1
fi

echo "Checking the bundle is intact..."
(cd "$HERE" && sha256sum --quiet -c SHA256SUMS)

LIST=$(mktemp /tmp/c4raven-offline.XXXXXX.list)
trap 'rm -f "$LIST"' EXIT
echo "deb [trusted=yes] file:$REPO ./" > "$LIST"
chmod 644 "$LIST"

# Only the bundled repository, for this run: no mirrors, no other lists
# deleted (List-Cleanup), and read as root so the bundle can live anywhere.
# DPkg::Lock::Timeout: wait for unattended-upgrades or another apt to finish
# rather than failing on the dpkg lock.
APT=(apt-get
  -o DPkg::Lock::Timeout=600
  -o Dir::Etc::SourceList="$LIST"
  -o Dir::Etc::SourceParts=-
  -o APT::Get::List-Cleanup=false
  -o APT::Sandbox::User=root)

# Network guard. Nothing in this install should need the internet: apt reads
# ./repo only, and the package's setup installs the backend, UI, mediamtx,
# icon sets and ATAK plugin from inside the .deb and skips Let's Encrypt
# (RAVEN_OFFLINE_INSTALL=1). Should anything still try to download, point
# HTTP(S) at a closed local port so it fails at once with a clear cause,
# instead of hanging on a network that silently drops packets or -- on a box
# that does have internet -- quietly succeeding and hiding the bug.
# RAVEN_OFFLINE_GUARD=0 turns the guard off.
export RAVEN_OFFLINE_INSTALL=1
if [ "${RAVEN_OFFLINE_GUARD:-1}" != 0 ]; then
  GUARD=http://127.0.0.1:9
  export http_proxy=$GUARD https_proxy=$GUARD HTTP_PROXY=$GUARD HTTPS_PROXY=$GUARD
  export ftp_proxy=$GUARD all_proxy=$GUARD ALL_PROXY=$GUARD
  export no_proxy=127.0.0.1,localhost,::1 NO_PROXY=127.0.0.1,localhost,::1
  export PIP_NO_INDEX=1 PIP_CONFIG_FILE=/dev/null COREPACK_ENABLE_NETWORK=0
fi

offline_failed() {
  echo >&2
  echo "The install did not finish (see above). Everything done so far is kept." >&2
  echo "If the error mentions 127.0.0.1:9, a proxy, a download or a host name," >&2
  echo "something tried to reach the internet: that is a bug in this bundle --" >&2
  echo "please report it with the output above." >&2
  echo "Otherwise fix the cause, then resume with:  sudo dpkg --configure -a" >&2
  echo "or simply re-run:                           sudo $0" >&2
  exit 1
}

"${APT[@]}" update

# Same version already installed: apt would do nothing, so reinstall it --
# that re-runs the package's setup (idempotent), which is what re-running
# this script is for (repairing a half-finished or damaged install).
# A newer bundle over an older install is an ordinary upgrade.
WANT_VER=$(awk '$1 == "Package:" { p = $2 } p == "c4raven-server" && $1 == "Version:" { print $2; exit }' "$REPO/Packages")
HAVE_VER=$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' c4raven-server 2>/dev/null | awk '$1 == "ii" { print $2 }' || true)
REINSTALL=()
if [ -n "$HAVE_VER" ] && [ "$HAVE_VER" = "$WANT_VER" ]; then
  echo "c4raven-server $HAVE_VER is already installed; reinstalling it to re-run its setup."
  REINSTALL=(--reinstall)
elif [ -n "$HAVE_VER" ]; then
  echo "Upgrading c4raven-server $HAVE_VER -> $WANT_VER. Config, certificates, database and uploads are kept."
fi

"${APT[@]}" install -y --no-install-recommends "${REINSTALL[@]}" c4raven-server || offline_failed

echo
echo "C4 Raven server @VERSION@ installed from the offline bundle."
