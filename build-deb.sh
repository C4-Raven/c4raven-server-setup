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
set -euo pipefail

: "${PKG_VERSION:?Set PKG_VERSION, e.g. PKG_VERSION=2.1.2 ./build-deb.sh}"
SERVER_SHA="${SERVER_SHA:-$(git ls-remote https://github.com/C4-Raven/c4raven-server.git refs/heads/main | cut -f1)}"
UI_SHA="${UI_SHA:-$(git ls-remote https://github.com/C4-Raven/c4raven-ui.git refs/heads/main | cut -f1)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$HERE/build/c4raven-server_${PKG_VERSION}_all"
OUT="$HERE/build/c4raven-server_${PKG_VERSION}_all.deb"

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
cp "$HERE/rabbitmq.conf" "$HERE/seed_admin.py" "$STAGE/usr/share/c4raven-server/"
if grep -rq 'OTS_FOLDER\|SERVER_CERT_FILE\|SERVER_KEY_FILE\|CA_CERT_FILE' "$STAGE/usr/share/c4raven-server/"; then
  echo "error: unsubstituted placeholder left in staged data files" >&2
  exit 1
fi
echo -n "$SERVER_SHA" > "$STAGE/usr/share/c4raven-server/SERVER_SHA"
echo -n "$UI_SHA" > "$STAGE/usr/share/c4raven-server/UI_SHA"

chmod -R go-w "$STAGE"
dpkg-deb --build --root-owner-group "$STAGE" "$OUT"

echo
echo "Built: $OUT"
echo "  c4raven-server @ $SERVER_SHA"
echo "  c4raven-ui     @ $UI_SHA"
