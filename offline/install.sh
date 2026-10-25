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

echo "Checking the bundle is intact..."
(cd "$HERE" && sha256sum --quiet -c SHA256SUMS)

LIST=$(mktemp /tmp/c4raven-offline.XXXXXX.list)
trap 'rm -f "$LIST"' EXIT
echo "deb [trusted=yes] file:$REPO ./" > "$LIST"
chmod 644 "$LIST"

# Only the bundled repository, for this run: no mirrors, no other lists
# deleted (List-Cleanup), and read as root so the bundle can live anywhere.
APT=(apt-get
  -o Dir::Etc::SourceList="$LIST"
  -o Dir::Etc::SourceParts=-
  -o APT::Get::List-Cleanup=false
  -o APT::Sandbox::User=root)

"${APT[@]}" update
"${APT[@]}" install -y --no-install-recommends c4raven-server

echo
echo "C4 Raven server @VERSION@ installed from the offline bundle."
