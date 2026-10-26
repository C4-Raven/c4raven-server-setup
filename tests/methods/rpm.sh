#!/bin/bash
# Method: rpm/build-rpm.sh, then `dnf install ./c4raven-server-*.rpm`.
#
# Runs INSIDE the harness container as root. Env: DISTRO ARCH REPO.
set -uo pipefail

EXIT_SKIP=77
say() { printf '\n### %s\n' "$*"; }

case "$DISTRO" in
  rocky-*) ;;
  *) echo "SKIP: the .rpm path is RPM-family only (this is $DISTRO)." >&2
     exit "$EXIT_SKIP" ;;
esac

cd "$REPO" || exit 1

if [ ! -x "$REPO/rpm/build-rpm.sh" ]; then
  if [ -e "$REPO/rpm/build-rpm.sh" ]; then
    echo "SKIP: rpm/build-rpm.sh exists but is not executable (chmod +x it)." >&2
  else
    echo "SKIP: rpm/build-rpm.sh does not exist yet (workstream: rpm packaging)." >&2
  fi
  exit "$EXIT_SKIP"
fi
if ! ls "$REPO"/rpm/*.spec >/dev/null 2>&1; then
  echo "SKIP: no rpm/*.spec yet." >&2
  exit "$EXIT_SKIP"
fi

say "installing build-time tooling for build-rpm.sh"
dnf -y install --setopt=install_weak_deps=False rpm-build rpmdevtools git tar gzip || exit 1

PKG_VERSION="${PKG_VERSION:-0.0.0}"
export PKG_VERSION
say "building the .rpm (PKG_VERSION=$PKG_VERSION)"
./rpm/build-rpm.sh || exit 1

RPM_ARCH=$(rpm --eval '%{_arch}')
mapfile -t RPMS < <(find "$REPO" -name 'c4raven-server-*.rpm' -not -name '*.src.rpm' | sort)
if [ "${#RPMS[@]}" -eq 0 ]; then
  echo "FAIL: build-rpm.sh produced no binary rpm." >&2
  exit 1
fi
say "built: ${RPMS[*]}"
for r in "${RPMS[@]}"; do
  a=$(rpm -qp --qf '%{ARCH}' "$r" 2>/dev/null)
  echo "    $(basename "$r") -> arch=$a"
  case "$a" in
    noarch|"$RPM_ARCH") ;;
    *) echo "FAIL: $(basename "$r") is $a, which cannot install on $RPM_ARCH" >&2; exit 1 ;;
  esac
done

# The package Requires rabbitmq-server, certbot and nginx-mod-stream from
# EPEL/CRB and rabbitmq.com, which the image deliberately lacks -- set them up
# the way the docs tell users to, so this exercises that script too.
say "configuring the EL9 repositories (rpm/c4raven-el9-repos.sh)"
bash "$REPO/rpm/c4raven-el9-repos.sh" || exit 1

say "installing the package"
# -x 'proj-data-*': the per-country PROJ datum grids (~760 MB, 318 MB of it
# proj-data-us) arrive as weak deps of the Recommends: postgis. Nothing here
# reprojects coordinates, and fetching them took 50 of a 55-minute CI run.
dnf -y install -x 'proj-data-*' "${RPMS[@]}"
rc=$?
say "dnf install exited $rc"
exit "$rc"
