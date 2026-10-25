#!/bin/bash
# Method: build-deb.sh, then `apt-get install ./c4raven-server_*.deb`.
# This is the online .deb -- postinst clones and builds on the target.
#
# Runs INSIDE the harness container as root. Env from run-matrix.sh:
#   DISTRO ARCH REPO, plus optional SERVER_SHA / UI_SHA / GIT_ASKPASS creds.
set -uo pipefail

EXIT_SKIP=77
say() { printf '\n### %s\n' "$*"; }

case "$DISTRO" in
  ubuntu-*) ;;
  *) echo "SKIP: the .deb path is Debian-family only (this is $DISTRO)." >&2
     exit "$EXIT_SKIP" ;;
esac

cd "$REPO" || exit 1

export DEBIAN_FRONTEND=noninteractive

say "installing build-time tooling for build-deb.sh"
apt-get update -qq
apt-get install -y -qq --no-install-recommends dpkg-dev git xz-utils ca-certificates curl

# build-deb.sh resolves SERVER_SHA / UI_SHA with `git ls-remote` against the
# private C4-Raven repos when they are not supplied. Without credentials
# that fails, and so does every subsequent clone in postinst.
if [ -z "${SERVER_SHA:-}" ] || [ -z "${UI_SHA:-}" ]; then
  if ! git ls-remote https://github.com/C4-Raven/c4raven-server.git HEAD >/dev/null 2>&1; then
    echo "SKIP: no read access to the private C4-Raven repositories." >&2
    echo "      The online install paths clone c4raven-server and c4raven-ui," >&2
    echo "      so this cell needs a token (see tests/README.md)." >&2
    exit "$EXIT_SKIP"
  fi
fi

PKG_VERSION="${PKG_VERSION:-0.0.0~ci}"
export PKG_VERSION
say "building the .deb (PKG_VERSION=$PKG_VERSION)"
./build-deb.sh || exit 1

# build-deb.sh names the file by the architecture it decided on. Accept
# either `all` (the online build today) or the host's dpkg arch, and fail
# loudly on a package that cannot install here -- that is precisely the
# multi-arch regression this cell is for.
HOST_ARCH=$(dpkg --print-architecture)
DEB=""
for cand in "build/c4raven-server_${PKG_VERSION}_all.deb" \
            "build/c4raven-server_${PKG_VERSION}_${HOST_ARCH}.deb"; do
  [ -f "$cand" ] && DEB=$cand
done
if [ -z "$DEB" ]; then
  echo "FAIL: build-deb.sh produced nothing installable on $HOST_ARCH:" >&2
  ls -1 build/*.deb 2>/dev/null | sed 's/^/      /' >&2
  exit 1
fi
say "built $DEB"
dpkg-deb -I "$DEB" | sed 's/^/    /'

# --- debconf: answer the same questions install.sh asks on the tty ---------
say "preseeding debconf"
apt-get install -y -qq --no-install-recommends debconf-utils
debconf-set-selections <<'EOF'
c4raven-server c4raven-server/domain string
c4raven-server c4raven-server/turnstile-enable boolean false
EOF

say "installing the package"
apt-get install -y -o Dpkg::Options::=--force-confnew "./$DEB"
rc=$?
say "apt-get install exited $rc"
exit "$rc"
