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

"${APT[@]}" update
if ! "${APT[@]}" install -y --no-install-recommends c4raven-server; then
  echo >&2
  echo "The install did not finish (see above). Everything done so far is kept;" >&2
  echo "fix the cause, then resume with:  sudo dpkg --configure -a" >&2
  echo "or simply re-run:                 sudo $0" >&2
  exit 1
fi

echo
echo "C4 Raven server @VERSION@ installed from the offline bundle."
