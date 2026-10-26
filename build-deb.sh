#!/bin/bash
# Builds c4raven-server_<version>_all.deb by staging a package tree and
# calling `dpkg-deb --build` directly -- not dpkg-buildpackage/debhelper,
# since there's no compilation at package-build time (the backend's venv
# is built on the *target* machine by postinst, matching install.sh).
#
# Usage:
#   PKG_VERSION=2.1.2 ./build-deb.sh
#
# SERVER_SHA / UI_SHA (optional): pin the package to specific commits of
# c4raven-server / c4raven-ui. Defaults to each repo's current main tip
# at build time -- this is what makes a given .deb version reproducible:
# postinst checks out exactly this commit, not a floating branch.
#
# OFFLINE_PAYLOAD (optional, set by build-offline.sh -- don't set it by
# hand): a staged directory holding the prebuilt backend wheels, the built
# UI, mediamtx and the ATAK plugin. It is shipped at
# /usr/share/c4raven-server/offline, which switches postinst to installing
# from those files instead of cloning and building from GitHub, and needs
# no internet at install.
#
# Everything in that payload is a native binary (wheels, mediamtx, the
# venv postinst builds from them), so an offline .deb is per-architecture,
# not Architecture: all. The architecture is NOT guessed from the build
# host -- build-offline.sh can cross-build -- it is read from the payload's
# own MANIFEST, which must carry a line:
#
#   arch         amd64          (a dpkg architecture: amd64, arm64, ...)
#
# and that single value drives the Architecture: control field, the output
# filename, and which mediamtx tarball postinst extracts on the target.
set -euo pipefail

: "${PKG_VERSION:?Set PKG_VERSION, e.g. PKG_VERSION=2.1.2 ./build-deb.sh}"
SERVER_SHA="${SERVER_SHA:-$(git ls-remote https://github.com/C4-Raven/c4raven-server.git refs/heads/main | cut -f1)}"
UI_SHA="${UI_SHA:-$(git ls-remote https://github.com/C4-Raven/c4raven-ui.git refs/heads/main | cut -f1)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_PAYLOAD="${OFFLINE_PAYLOAD:-}"
if [ -n "$OFFLINE_PAYLOAD" ]; then
  [ -f "$OFFLINE_PAYLOAD/MANIFEST" ] || { echo "error: $OFFLINE_PAYLOAD is not a staged offline payload" >&2; exit 1; }
  ARCH=$(awk '$1 == "arch" { print $2; exit }' "$OFFLINE_PAYLOAD/MANIFEST")
  if [ -z "$ARCH" ]; then
    echo "error: $OFFLINE_PAYLOAD/MANIFEST has no 'arch' line." >&2
    echo "       build-offline.sh must record the payload's dpkg architecture, e.g." >&2
    echo "       \"arch         amd64\" -- it can't be inferred here, and guessing it" >&2
    echo "       from the build host would silently mislabel a cross-built payload." >&2
    exit 1
  fi
  # mediamtx names its release tarballs by its own arch strings, which only
  # partly match dpkg's. Mapping them here (rather than only in postinst)
  # lets the payload be checked at build time instead of failing on the
  # customer's machine, which for an offline bundle may be an air-gapped one.
  case "$ARCH" in
    amd64) MTX_ARCH=amd64 ;;
    arm64) MTX_ARCH=arm64 ;;
    armhf) MTX_ARCH=armv7 ;;
    armel) MTX_ARCH=armv6 ;;
    *)
      echo "error: MANIFEST declares arch '$ARCH', which has no mediamtx build." >&2
      echo "       Supported: amd64, arm64, armhf, armel." >&2
      exit 1
      ;;
  esac
  if ! compgen -G "$OFFLINE_PAYLOAD/mediamtx/mediamtx_*_linux_$MTX_ARCH.tar.gz" > /dev/null; then
    echo "error: MANIFEST says arch=$ARCH but the payload has no" >&2
    echo "       mediamtx_*_linux_$MTX_ARCH.tar.gz (it has:" \
         "$(cd "$OFFLINE_PAYLOAD/mediamtx" 2>/dev/null && ls 2>/dev/null | tr '\n' ' '))" >&2
    exit 1
  fi
else
  ARCH=all
fi
STAGE="$HERE/build/c4raven-server_${PKG_VERSION}_${ARCH}"
OUT="$HERE/build/c4raven-server_${PKG_VERSION}_${ARCH}.deb"

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/lib/systemd/system" "$STAGE/usr/share/c4raven-server"

# --- control + maintainer scripts -----------------------------------------
# debian/control has a source stanza (Source/Section/Priority/Maintainer/
# Standards-Version) followed by the binary stanza (Package: onward). Only
# the latter is valid in a binary package's control file, but Maintainer
# is mandatory there too (normally carried over by dpkg-buildpackage/
# debhelper -- there's none of that here, so this script does it by hand),
# along with a Version: field (no changelog to source it from either).
MAINTAINER=$(awk -F': ' '/^Maintainer:/{print $2; exit}' "$HERE/debian/control")
awk '/^Package:/{f=1} f' "$HERE/debian/control" \
  | awk -v ver="$PKG_VERSION" -v maint="$MAINTAINER" \
      '/^Package:/{print; print "Version: " ver; print "Maintainer: " maint; next} 1' \
  > "$STAGE/DEBIAN/control"

if [ -n "$OFFLINE_PAYLOAD" ]; then
  # Nothing is cloned or built on the target, so git, Node.js and the
  # compiler toolchain drop out of Depends; everything else is still needed
  # at runtime (python3-venv makes the venv, python3-yaml edits config.yml).
  #
  # `skip` drops the trailing Description paragraphs from " Building the UI
  # needs" onward (the Node.js note and the Architecture: all note, neither
  # of which is true here) and replaces them with the offline wording -- so
  # that marker line must stay the start of the LAST block in
  # debian/control. The guards below fail the build if any of this stops
  # matching rather than shipping a .deb with a stale Depends line, and the
  # END block aborts if the marker itself has gone -- without that, a reworded
  # Description silently ships an offline package whose own long description
  # claims it is Architecture: all and needs Node.js from NodeSource.
  #
  # The other half of that coupling -- "the marker paragraph must be LAST" --
  # is enforced by the `skip` rule itself: everything it drops has to be
  # Description continuation prose (a line starting with a space). A control
  # FIELD or a new stanza written below the marker would be deleted from the
  # offline package with nothing said, so refuse to build instead. Both
  # halves are restated in debian/control's own header comment.
  awk -v arch="$ARCH" '
    /^Architecture:/ { print "Architecture: " arch; next }
    /^ (git|build-essential|python3-pip|python3-dev|nodejs[^,]*),$/ { next }
    /^ Building the UI needs/ { skip = 1 }
    skip {
      if ($0 !~ /^[ \t]/) {
        print "error: debian/control line " NR " is below the \" Building the UI" > "/dev/stderr"
        print "       needs\" marker, which the offline build drops to end of file:" > "/dev/stderr"
        print "" > "/dev/stderr"
        print "         " $0 > "/dev/stderr"
        print "" > "/dev/stderr"
        print "       That line would vanish from the offline package without a word." > "/dev/stderr"
        print "       Only Description continuation lines (leading space, including" > "/dev/stderr"
        print "       the \" .\" separators) may follow the marker -- move any control" > "/dev/stderr"
        print "       field, new stanza or build-independent prose ABOVE it." > "/dev/stderr"
        bad = 1
        exit 1
      }
      next
    }
    { print }
    END {
      if (bad) { exit 1 }
      if (!skip) {
        print "error: debian/control has no \" Building the UI needs\" line, so the" > "/dev/stderr"
        print "       online-only Description paragraphs (Node.js, Architecture: all)" > "/dev/stderr"
        print "       were not dropped from the offline control file. Keep that line" > "/dev/stderr"
        print "       as the start of the LAST Description block, or update the marker" > "/dev/stderr"
        print "       in build-deb.sh to match." > "/dev/stderr"
        exit 1
      }
      print " This is the offline build: the backend wheels, the built UI, mediamtx"
      print " and the CROW Remote Clear ATAK plugin are all inside the package, so"
      print " installing it needs no internet access and no Node.js. It is built"
      print " for one architecture (" arch ") because all of that is native code."
    }' "$STAGE/DEBIAN/control" > "$STAGE/DEBIAN/control.new"
  mv "$STAGE/DEBIAN/control.new" "$STAGE/DEBIAN/control"
  sed -i 's/^\(Description: .*\)$/\1 (offline)/' "$STAGE/DEBIAN/control"
  grep -qx "Architecture: $ARCH" "$STAGE/DEBIAN/control" \
    || { echo "error: offline control rewrite did not set Architecture: $ARCH" >&2; exit 1; }
  if grep -qE '^ (git|build-essential|python3-pip|python3-dev|nodejs)' "$STAGE/DEBIAN/control"; then
    echo "error: offline control still Depends on a build-time-only package" >&2
    echo "       (the Depends line's spelling changed -- update the awk filter above)" >&2
    exit 1
  fi
  grep -q 'no internet access' "$STAGE/DEBIAN/control" \
    || { echo "error: offline Description paragraph was not appended" >&2; exit 1; }
fi

for f in preinst postinst prerm postrm config; do
  [ -f "$HERE/debian/c4raven-server.$f" ] || continue
  cp "$HERE/debian/c4raven-server.$f" "$STAGE/DEBIAN/$f"
  chmod 755 "$STAGE/DEBIAN/$f"
done
cp "$HERE/debian/c4raven-server.templates" "$STAGE/DEBIAN/templates"

# --- systemd units (static, no templating needed -- see postinst comment) -
for svc in raven eud_handler eud_handler_ssl cot_parser mediamtx; do
  cp "$HERE/debian/$svc.service" "$STAGE/lib/systemd/system/$svc.service"
done
if [ -n "$OFFLINE_PAYLOAD" ]; then
  # The offline install has no source checkout: the backend lives in a
  # plain venv (/opt/raven/venv, a symlink postinst swaps on upgrade).
  sed -i -e 's~/opt/raven/c4raven-server/\.venv/~/opt/raven/venv/~' \
         -e 's~^WorkingDirectory=/opt/raven/c4raven-server$~WorkingDirectory=/opt/raven/data~' \
         "$STAGE"/lib/systemd/system/*.service
  if grep -q 'c4raven-server' "$STAGE"/lib/systemd/system/*.service; then
    echo "error: a unit still points into the source checkout" >&2
    exit 1
  fi
fi

# --- data files -------------------------------------------------------
# The nginx/mediamtx/rabbitmq templates are shared with install.sh, which
# fills in the cert/data paths with sed at install time. Every one of those
# paths is a fixed constant under /opt/raven for the .deb, so do the same
# substitution here, at build time, from the ONE copy of each template --
# a second hand-maintained copy under usr/share/ drifted from the
# templates within days.
DATA_DIR=/opt/raven/data
subst() {
  sed -e "s~OTS_FOLDER~$DATA_DIR~g" \
      -e "s~SERVER_CERT_FILE~$DATA_DIR/ca/certs/raven/raven.pem~g" \
      -e "s~SERVER_KEY_FILE~$DATA_DIR/ca/certs/raven/raven.nopass.key~g" \
      -e "s~CA_CERT_FILE~$DATA_DIR/ca/ca.pem~g" \
      "$1" > "$2"
}
mkdir -p "$STAGE/usr/share/c4raven-server/nginx_configs"
for f in "$HERE"/nginx_configs/*; do
  subst "$f" "$STAGE/usr/share/c4raven-server/nginx_configs/$(basename "$f")"
done
subst "$HERE/mediamtx.yml" "$STAGE/usr/share/c4raven-server/mediamtx.yml"
cp "$HERE/rabbitmq.conf" "$HERE/seed_admin.py" "$HERE/seed_plugin.py" "$STAGE/usr/share/c4raven-server/"
# The shared distro/firewall shim, shipped exactly where the RPM puts it
# (rpm/build-rpm.sh) so postinst can open the same ports install.sh and
# rpm/configure.sh do. Optional in the same way it is for the RPM: postinst
# degrades to printing the ports if it isn't here, so a checkout without
# lib/ still builds -- but say so, because the resulting .deb is the odd
# one out of the three install paths.
if [ -f "$HERE/lib/distro.sh" ]; then
  install -D -m 644 "$HERE/lib/distro.sh" "$STAGE/usr/share/c4raven-server/lib/distro.sh"
else
  echo "warning: no lib/distro.sh in this checkout -- the .deb will not open" >&2
  echo "         firewall ports, unlike install.sh and the RPM." >&2
fi
if grep -rq 'OTS_FOLDER\|SERVER_CERT_FILE\|SERVER_KEY_FILE\|CA_CERT_FILE' "$STAGE/usr/share/c4raven-server/"; then
  echo "error: unsubstituted placeholder left in staged data files" >&2
  exit 1
fi
# The one placeholder that is NOT build-time: raven_certificate_enrollment_domain's
# DOMAIN_NAME is the admin's domain, filled in by the installer only after
# certbot has a certificate for it. It has to arrive intact.
if ! grep -q 'DOMAIN_NAME' "$STAGE/usr/share/c4raven-server/nginx_configs/raven_certificate_enrollment_domain"; then
  echo "error: staged raven_certificate_enrollment_domain lost its DOMAIN_NAME placeholder" >&2
  exit 1
fi
echo -n "$SERVER_SHA" > "$STAGE/usr/share/c4raven-server/SERVER_SHA"
echo -n "$UI_SHA" > "$STAGE/usr/share/c4raven-server/UI_SHA"
if [ -n "$OFFLINE_PAYLOAD" ]; then
  cp -a "$OFFLINE_PAYLOAD" "$STAGE/usr/share/c4raven-server/offline"
  echo -n "$PKG_VERSION" > "$STAGE/usr/share/c4raven-server/offline/VERSION"
fi

chmod -R go-w "$STAGE"
# -Zxz pins the compressor rather than taking dpkg-deb's default, which is
# zstd on dpkg >= 1.21.18 (noble and newer) -- an offline bundle is carried
# to air-gapped machines that may run an older dpkg than the build host, and
# xz is the format every dpkg since 2013 can unpack. No -z level: the wheels
# and APK are already compressed, and -9 roughly doubles build time for a
# percent or two. This applies to the online Architecture: all build too;
# only the container format changes, nothing about the package contents.
dpkg-deb -Zxz --build --root-owner-group "$STAGE" "$OUT"

echo
echo "Built: $OUT"
echo "  c4raven-server @ $SERVER_SHA"
echo "  c4raven-ui     @ $UI_SHA"
