#!/bin/bash
# Builds the offline install of the C4 Raven server, for machines with no
# internet access at install time.
#
# Usage:
#   PKG_VERSION=2.2.0 ./build-offline.sh
#
# Produces, under build/ (<arch> is TARGET_ARCH, a dpkg architecture name):
#
#   c4raven-server_<ver>_<arch>.deb
#       The whole app in one package: the backend and every Python
#       dependency as prebuilt wheels, the built web UI, mediamtx and the
#       tak.gov-signed CROW Remote Clear ATAK plugin (published to the
#       server's package repo on install, so enrolling devices get it).
#       Installs offline on any box that already has its apt Depends.
#
#   c4raven-server-offline_<ver>_<suite>_<arch>.tar   (one per SUITES entry)
#       That .deb plus every Ubuntu package it depends on (PostgreSQL,
#       RabbitMQ, nginx, ffmpeg, ...) as a local apt repository, and an
#       install.sh that installs from it alone. This is what to carry to a
#       machine that has never been online.
#
# Build-time needs (this machine, not the target): internet, git with read
# access to the C4-Raven repos (they're private -- `gh auth login` or a
# credential helper), Node.js 20.19+ with corepack, apt-get/apt-ftparchive
# (any Ubuntu/Debian), and a python3.X interpreter for every PY_VERSIONS
# entry -- found on PATH or through `uv python find`.
#
# ARCHITECTURE: build each architecture on that architecture if you can.
#
#   Everything in the bundle is arch-specific except the UI: the wheels, the
#   apt packages, mediamtx, the .deb. Most of that is fetched for the target
#   arch, whatever the build host is. The exception is the Python sdists:
#
#     * `pip download --platform` can only take wheels PyPI already has. Any
#       requirement with no wheel for the target falls through to its sdist,
#       which the block below compiles. Four of the lock's sdist-only
#       packages (flask-apscheduler, flask-principal, sgmllib3k, simplekml)
#       are pure Python and build an arch-independent py3-none-any wheel.
#       Two are C extensions: mutf8 1.0.6 (no cp31x wheels at all, for any
#       arch) and unishox2-py3 1.0.0 (wheels stop at cp310). On a native
#       build those come out as linux_<arch> wheels and the verify step
#       installs and imports them.
#
#   So: TARGET_ARCH defaults to this machine's and a mismatch is refused
#   unless ALLOW_CROSS_BUILD=1. The script is arch-clean -- run it unchanged
#   on a native arm64 box, an arm64 cloud VM, or `docker run --platform
#   linux/arm64` on a binfmt/qemu host, and it builds a fully verified
#   arm64 bundle. That is the preferred way.
#
#   ALLOW_CROSS_BUILD=1 builds on a foreign host anyway. Any sdist that does
#   not produce an arch-independent wheel is rebuilt with zig (ziglang from
#   PyPI) as a cross C compiler, against the target's CPython headers
#   (libpython3.X-dev for TARGET_ARCH, fetched from the Ubuntu archive for
#   SUITES) and glibc 2.17, and every .so in the wheelhouse is checked to be
#   an ELF object for TARGET_ARCH. What it cannot do is import those wheels:
#   the verify step drops to a resolve-only check. Smoke-test the first
#   cross-built bundle on real target hardware before shipping it.
#
# Optional overrides:
#   SERVER_SHA / UI_SHA   commits to package (default: each repo's main tip)
#   PLUGIN_APK            plugin APK to bundle (default: the newest APK in
#                         c4raven-clear-plugin's releases/ at its main tip)
#   ALLOW_DEV_SIGNED_PLUGIN=1  accept a plugin not signed by the TAK Product
#                         Center (it won't load on store/tak.gov ATAK)
#   TARGET_ARCH           dpkg architecture to build for: amd64 or arm64
#                         (default: this machine's, and it must match it --
#                         see ARCHITECTURE above)
#   ALLOW_CROSS_BUILD=1   allow TARGET_ARCH != this machine's; see above
#   SUITES                Ubuntu releases to bundle apt dependencies for
#                         (default: "noble questing" = 24.04 and 25.10)
#   PY_VERSIONS           Python versions to ship wheels for; must cover the
#                         python3 of every suite (default: "3.12 3.13")
#   GLIBC_MAX             oldest glibc among the targets (default: derived
#                         from SUITES; see the table below)
#   UBUNTU_MIRROR / UBUNTU_SECURITY_MIRROR
#                         archives to fetch dependencies from (defaults
#                         follow TARGET_ARCH -- archive.ubuntu.com carries
#                         amd64/i386 only, every other arch is on
#                         ports.ubuntu.com)
set -euo pipefail

: "${PKG_VERSION:?Set PKG_VERSION, e.g. PKG_VERSION=2.2.0 ./build-offline.sh}"
SUITES="${SUITES:-noble questing}"
PY_VERSIONS="${PY_VERSIONS:-3.12 3.13}"

# --- target architecture ------------------------------------------------
command -v dpkg >/dev/null || { echo "error: missing build tool: dpkg" >&2; exit 1; }
HOST_ARCH="$(dpkg --print-architecture)"
TARGET_ARCH="${TARGET_ARCH:-$HOST_ARCH}"

# Per-arch names for the three vocabularies this script has to speak: dpkg's
# (the .deb, apt, every filename), PyPI's platform tags, and mediamtx's
# release assets. mediamtx happens to use dpkg's spelling; don't rely on it
# for a third arch without checking the release page.
case "$TARGET_ARCH" in
  amd64)
    WHEEL_ARCH=x86_64
    ELF_MACHINE=62              # ELF e_machine (EM_X86_64), for the .so check
    PLATFORMS=(manylinux_2_28_x86_64 manylinux_2_17_x86_64 manylinux2014_x86_64
               manylinux_2_5_x86_64 manylinux1_x86_64 linux_x86_64 any)
    MEDIAMTX_ARCH=amd64
    MEDIAMTX_SHA256=a5d54f97265f2caf5822877b31f5ea86afedf17f489566dab5a8dd6c43f5acda
    ;;
  arm64)
    WHEEL_ARCH=aarch64
    ELF_MACHINE=183             # EM_AARCH64
    # No manylinux1/manylinux_2_5 here: those tags predate aarch64 support
    # and no project publishes them for it.
    PLATFORMS=(manylinux_2_28_aarch64 manylinux_2_17_aarch64 manylinux2014_aarch64
               linux_aarch64 any)
    MEDIAMTX_ARCH=arm64
    MEDIAMTX_SHA256=c8d62a28bb0a9a94b41e1e6df930c02b24c57f0f0c0005ef841e84071058cf22
    ;;
  *)
    echo "error: TARGET_ARCH=$TARGET_ARCH is not supported (amd64, arm64)" >&2
    exit 1
    ;;
esac

if [ "$TARGET_ARCH" != "$HOST_ARCH" ] && [ "${ALLOW_CROSS_BUILD:-0}" != 1 ]; then
  cat >&2 <<EOF
error: this machine is $HOST_ARCH and TARGET_ARCH=$TARGET_ARCH.

  Cross-builds are off by default. Two locked dependencies -- mutf8 1.0.6
  and unishox2-py3 1.0.0 -- publish no wheel for any supported Python, so
  they are compiled from source, and a plain compile targets $HOST_ARCH no
  matter what --platform says.

  Preferred: build $TARGET_ARCH bundles on $TARGET_ARCH hardware -- a real
  machine, a cloud VM, or 'docker run --platform linux/$TARGET_ARCH' on a
  binfmt/qemu host. This script needs no changes to run there, and the
  bundle gets the full install-and-import verification.

  Or set ALLOW_CROSS_BUILD=1: those packages are then cross-compiled for
  $WHEEL_ARCH with zig (fetched from PyPI) against the target's CPython
  headers, and every shared object is checked to be $WHEEL_ARCH. The wheels
  cannot be imported here, so smoke-test the bundle on $TARGET_ARCH hardware.
EOF
  exit 1
fi
CROSS=0; [ "$TARGET_ARCH" = "$HOST_ARCH" ] || CROSS=1

# archive.ubuntu.com and security.ubuntu.com carry amd64 and i386 only;
# every other architecture lives on ports.ubuntu.com, which also serves the
# -security suite (there is no ports equivalent of security.ubuntu.com).
case "$TARGET_ARCH" in
  amd64|i386)
    UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu/}"
    UBUNTU_SECURITY_MIRROR="${UBUNTU_SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu/}"
    ;;
  *)
    UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports/}"
    UBUNTU_SECURITY_MIRROR="${UBUNTU_SECURITY_MIRROR:-http://ports.ubuntu.com/ubuntu-ports/}"
    ;;
esac

# mediamtx is pinned (install.sh and the online postinst pin the same
# release); bump both together and update the per-arch checksums above from
# the release's checksums.sha256.
MEDIAMTX_VERSION=1.13.0

# Oldest glibc the bundled wheels may need. This is a property of the
# OLDEST TARGET, not a universal constant -- it is the floor the locally
# compiled wheels have to clear, so adding a target with an older glibc
# lowers it and may mean the build has to move to an older distro.
#
#   Ubuntu 24.04 noble     2.39      Ubuntu 25.10 questing  2.42
#   Rocky Linux 9 / EL9    2.34      Debian 12 bookworm     2.36
#
# EL9's 2.34 is well below the Ubuntu floor: an rpm bundle built on Ubuntu
# would need GLIBC_MAX=2.34, which no current Ubuntu can satisfy. Build
# those on EL9.
glibc_for_suite() {
  case "$1" in
    noble)    echo 2.39 ;;
    questing) echo 2.42 ;;
    *) echo "error: no glibc baseline known for suite '$1'; set GLIBC_MAX" >&2; return 1 ;;
  esac
}
if [ -z "${GLIBC_MAX:-}" ]; then
  for s in $SUITES; do
    g=$(glibc_for_suite "$s") || exit 1
    [ -n "${GLIBC_MAX:-}" ] && [ "$(printf '%s\n%s\n' "$g" "$GLIBC_MAX" | sort -V | head -1)" = "$GLIBC_MAX" ] \
      || GLIBC_MAX=$g
  done
fi

PLUGIN_PACKAGE=com.atakmap.android.ravenclear.plugin
SERVER_REPO=https://github.com/C4-Raven/c4raven-server.git
UI_REPO=https://github.com/C4-Raven/c4raven-ui.git
PLUGIN_REPO=https://github.com/C4-Raven/c4raven-clear-plugin.git

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/build/offline-work"
PAYLOAD="$WORK/payload"

log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing build tool: $1"; }

for t in git curl node corepack apt-get apt-ftparchive dpkg dpkg-deb objdump sha256sum python3; do need "$t"; done
node -e '
  const [a, b] = process.versions.node.split(".").map(Number);
  process.exit((a === 20 && b >= 19) || (a === 22 && b >= 12) || a >= 23 ? 0 : 1);' \
  || die "Node.js 20.19+ is needed to build the UI (found $(node --version))"
[ -r /usr/share/keyrings/ubuntu-archive-keyring.gpg ] \
  || die "missing /usr/share/keyrings/ubuntu-archive-keyring.gpg (apt install ubuntu-keyring)"

find_python() {
  local v=$1 p
  p=$(command -v "python$v" 2>/dev/null) || p=$(uv python find "$v" 2>/dev/null) || return 1
  "$p" -c "import sys; sys.exit(sys.version_info[:2] != tuple(map(int, '$v'.split('.'))))" || return 1
  echo "$p"
}
declare -A PYTHON
for v in $PY_VERSIONS; do
  PYTHON[$v]=$(find_python "$v") || die "no python$v found on PATH or via 'uv python find $v'"
done

SERVER_SHA="${SERVER_SHA:-$(git ls-remote "$SERVER_REPO" refs/heads/main | cut -f1)}"
UI_SHA="${UI_SHA:-$(git ls-remote "$UI_REPO" refs/heads/main | cut -f1)}"
[ -n "$SERVER_SHA" ] && [ -n "$UI_SHA" ] || die "could not resolve the main tips (git access to C4-Raven?)"

rm -rf "$WORK"
mkdir -p "$PAYLOAD"/{wheelhouse/common,ui,mediamtx,plugins} "$WORK/src"

# A full clone at an exact commit (not `git archive`): the UI build stamps
# the git commit hash into the bundle, so it needs a real repository.
clone_at() {
  local url=$1 sha=$2 dest=$3
  git clone --quiet --filter=blob:none --no-checkout "$url" "$dest"
  git -C "$dest" -c advice.detachedHead=false checkout --quiet "$sha"
}

# --- build tools --------------------------------------------------------
log "Setting up build tools"
python3 -m venv "$WORK/tools"
TOOLS="$WORK/tools/bin"
"$TOOLS/pip" install --quiet --disable-pip-version-check \
  poetry==2.2.1 poetry-plugin-export==1.10.1 androguard==4.1.3

# pip's --platform flags, shared by the download and the cross-build verify.
PLATFORM_FLAGS=()
for p in "${PLATFORMS[@]}"; do PLATFORM_FLAGS+=(--platform "$p"); done

if [ "$CROSS" = 1 ]; then
  # Cross C compiler for the sdists that turn out to be C extensions. zig
  # bundles clang plus libc stubs for every target, so nothing needs to be
  # installed on the host; .2.17 pins the glibc symbol versions it links
  # against to manylinux2014's floor, well under any GLIBC_MAX.
  "$TOOLS/pip" install --quiet --disable-pip-version-check ziglang==0.16.0
  printf '#!/bin/sh\nexec "%s" -m ziglang cc -target %s-linux-gnu.2.17 "$@"\n' \
    "$TOOLS/python" "$WHEEL_ARCH" > "$WORK/cross-cc"
  chmod 755 "$WORK/cross-cc"

  # The target's CPython headers. Only pyconfig.h is really arch-specific,
  # but take the whole set from the same archive the bundle's apt half comes
  # from, so they match what the target's python3 was built with. One
  # private apt root over every suite: noble carries libpython3.12-dev,
  # questing libpython3.13-dev.
  XA="$WORK/apt-pyheaders"
  mkdir -p "$XA"/etc/apt/{sources.list.d,apt.conf.d,preferences.d} \
           "$XA"/var/lib/apt/lists/partial "$XA"/var/cache/apt/archives/partial "$XA"/var/lib/dpkg
  : > "$XA/var/lib/dpkg/status"
  for s in $SUITES; do
    cat >> "$XA/etc/apt/sources.list.d/ubuntu.sources" << EOF
Types: deb
URIs: $UBUNTU_MIRROR
Suites: $s $s-updates
Components: main
Architectures: $TARGET_ARCH
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $UBUNTU_SECURITY_MIRROR
Suites: $s-security
Components: main
Architectures: $TARGET_ARCH
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

EOF
  done
  XAPT=(apt-get -q
    -o Dir="$XA" -o Dir::State::status="$XA/var/lib/dpkg/status"
    -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$XA/etc/apt/sources.list.d"
    -o Dir::Etc::Parts="$XA/etc/apt/apt.conf.d" -o Dir::Etc::Preferences="$XA/etc/apt/preferences"
    -o Dir::Etc::PreferencesParts="$XA/etc/apt/preferences.d"
    -o APT::Architecture="$TARGET_ARCH" -o APT::Architectures::="$TARGET_ARCH"
    -o Debug::NoLocking=true)
  "${XAPT[@]}" update >/dev/null || die "could not fetch $TARGET_ARCH package lists for the Python headers"
fi

# cross_wheel V SDIST OUTDIR -- rebuilds SDIST as a C extension for
# TARGET_ARCH, with the zig cross compiler and the target's Python V headers.
# No build isolation: an isolated build env would be populated by a pip that
# _PYTHON_HOST_PLATFORM has convinced it is on TARGET_ARCH. The build venv
# already has setuptools and wheel, which is all a plain C extension needs.
cross_wheel() {
  local v=$1 sdist=$2 out=$3 d="$WORK/pyheaders-$1" w
  if [ ! -d "$d/root" ]; then
    mkdir -p "$d/deb"
    (cd "$d/deb" && "${XAPT[@]}" download "libpython$v-dev" >/dev/null) \
      || die "no libpython$v-dev for $TARGET_ARCH in SUITES ($SUITES); cannot cross-compile for Python $v"
    dpkg-deb -x "$d"/deb/*.deb "$d/root"
  fi
  [ -f "$d/root/usr/include/$WHEEL_ARCH-linux-gnu/python$v/pyconfig.h" ] \
    || die "libpython$v-dev for $TARGET_ARCH has no $WHEEL_ARCH-linux-gnu/python$v/pyconfig.h"
  # -I ahead of the host interpreter's own include dirs, which setuptools
  # appends; -g0 drops the host CFLAGS' -g (debug info only bloats the .deb).
  CC="$WORK/cross-cc" LDSHARED="$WORK/cross-cc -shared" \
  CFLAGS="-I$d/root/usr/include/python$v -I$d/root/usr/include -g0" \
  _PYTHON_HOST_PLATFORM="linux-$WHEEL_ARCH" \
  SETUPTOOLS_EXT_SUFFIX=".cpython-${v/./}-$WHEEL_ARCH-linux-gnu.so" \
    "$WORK/build-cp${v/./}/bin/pip" wheel --quiet --disable-pip-version-check --no-deps \
      --no-build-isolation --no-cache-dir -w "$out" "$sdist" \
    || die "could not cross-compile $(basename "$sdist") for $TARGET_ARCH; build this bundle
     on a $TARGET_ARCH machine instead (see the ARCHITECTURE note at the top)"
  for w in "$out"/*.whl; do
    case "$w" in
      *-linux_"$WHEEL_ARCH".whl) echo "  cross-compiled $(basename "$w")" ;;
      *) die "cross-compiling $(basename "$sdist") produced $(basename "$w"), not a linux_$WHEEL_ARCH wheel" ;;
    esac
  done
}

# --- backend ------------------------------------------------------------
log "Backend: c4raven-server @ $SERVER_SHA"
clone_at "$SERVER_REPO" "$SERVER_SHA" "$WORK/src/server"
(
  cd "$WORK/src/server"
  "$TOOLS/poetry" check --lock >/dev/null || die "poetry.lock is out of date with pyproject.toml"
  "$TOOLS/poetry" export --without-hashes -f requirements.txt -o "$PAYLOAD/requirements.txt"
)
# The package version doubles as the backend's version stamp: there are no
# git tags in c4raven-server for poetry-dynamic-versioning to derive one from.
POETRY_DYNAMIC_VERSIONING_BYPASS="$PKG_VERSION" \
  "$TOOLS/pip" wheel --quiet --disable-pip-version-check --no-deps \
  -w "$PAYLOAD/wheelhouse/common" "$WORK/src/server"
ls "$PAYLOAD"/wheelhouse/common/raven-*.whl >/dev/null || die "backend wheel was not built"
# The backend is pure Python, so its wheel is arch-independent and the same
# one serves every target. Assert it, rather than assume it: a C extension
# appearing in c4raven-server would otherwise be built for the build host.
for w in "$PAYLOAD"/wheelhouse/common/raven-*.whl; do
  case "$(basename "$w")" in
    *-none-any.whl) ;;
    *) die "$(basename "$w") is arch-specific; the backend is assumed pure Python" ;;
  esac
done

# --- dependency wheels, per Python version ------------------------------
for v in $PY_VERSIONS; do
  tag="cp${v/./}"
  log "Dependencies for Python $v"
  dl="$WORK/dl/$tag"
  mkdir -p "$dl"
  # --no-deps: requirements.txt is the complete lock, resolved already.
  # --prefer-binary: take a wheel wherever PyPI has one for this target,
  # and fall back to the sdist (built below) only where it doesn't.
  "$TOOLS/pip" download --quiet --disable-pip-version-check --no-deps --prefer-binary \
    -r "$PAYLOAD/requirements.txt" -d "$dl" \
    --python-version "$v" --implementation cp --abi "$tag" --abi abi3 --abi none \
    "${PLATFORM_FLAGS[@]}"

  shopt -s nullglob
  sdists=("$dl"/*.tar.gz "$dl"/*.zip)
  shopt -u nullglob
  if [ ${#sdists[@]} -gt 0 ]; then
    echo "building ${#sdists[@]} source-only package(s) with ${PYTHON[$v]}"
    "${PYTHON[$v]}" -m venv "$WORK/build-$tag"
    "$WORK/build-$tag/bin/pip" install --quiet --disable-pip-version-check -U pip setuptools wheel
    # One at a time, so each sdist's output is known: a pure-Python one
    # (py3-none-any) is fine for any target; anything else is a C extension
    # compiled for THIS machine, which on a cross-build is thrown away and
    # rebuilt for the target.
    for sd in "${sdists[@]}"; do
      out=$(mktemp -d -p "$WORK")
      "$WORK/build-$tag/bin/pip" wheel --quiet --disable-pip-version-check --no-deps -w "$out" "$sd"
      if [ "$CROSS" = 1 ]; then
        for w in "$out"/*.whl; do
          case "$w" in
            *-none-any.whl) ;;
            *) rm -f "$out"/*.whl; cross_wheel "$v" "$sd" "$out"; break ;;
          esac
        done
      fi
      mv "$out"/*.whl "$dl/"
      rmdir "$out"
    done
    rm -f "${sdists[@]}"
  fi
  mkdir -p "$PAYLOAD/wheelhouse/$tag"
  mv "$dl"/*.whl "$PAYLOAD/wheelhouse/$tag/"
done

# Identical wheels (pure Python ones, mostly) are shipped once, in common/.
first="cp${PY_VERSIONS%% *}"; first="${first/./}"
for f in "$PAYLOAD/wheelhouse/$first"/*.whl; do
  b=$(basename "$f")
  everywhere=1
  for v in $PY_VERSIONS; do
    cmp -s "$f" "$PAYLOAD/wheelhouse/cp${v/./}/$b" || { everywhere=0; break; }
  done
  [ "$everywhere" = 1 ] || continue
  cp "$f" "$PAYLOAD/wheelhouse/common/$b"
  for v in $PY_VERSIONS; do rm -f "$PAYLOAD/wheelhouse/cp${v/./}/$b"; done
done

# Wheels compiled here are linked against this machine's glibc (or, on a
# cross-build, zig's 2.17 stubs); make sure none of them needs a newer one
# than the oldest target release has, and that every shared object in them
# is actually a $WHEEL_ARCH ELF -- the backstop against a host-arch .so
# slipping into a bundle labelled for another arch.
log "Checking locally built wheels: $WHEEL_ARCH objects, glibc <= $GLIBC_MAX"
for w in "$PAYLOAD"/wheelhouse/*/*-linux_"$WHEEL_ARCH".whl; do
  [ -f "$w" ] || continue
  d=$(mktemp -d -p "$WORK")
  python3 -m zipfile -e "$w" "$d"
  # e_machine is read straight out of the ELF header: the host's objdump
  # may not know the target's architecture at all (Ubuntu's amd64 binutils
  # prints "UNKNOWN!" for aarch64), but it still reads the symbol versions.
  while IFS= read -r -d '' so; do
    m=$(python3 -c 'import struct, sys
h = open(sys.argv[1], "rb").read(20)
print(struct.unpack("<H", h[18:20])[0] if h[:4] == b"\x7fELF" else "not-ELF")' "$so")
    [ "$m" = "$ELF_MACHINE" ] \
      || die "$(basename "$w") contains ${so#"$d"/}, which is not a $WHEEL_ARCH object (e_machine $m, want $ELF_MACHINE)"
  done < <(find "$d" -name '*.so*' -type f -print0)
  need_glibc=$(find "$d" -name '*.so*' -type f -exec objdump -T {} + 2>/dev/null \
    | { grep -oE 'GLIBC_[0-9.]+' || true; } | sed 's/GLIBC_//' | sort -Vu | tail -1)
  rm -rf "$d"
  echo "  $(basename "$w"): glibc ${need_glibc:-none}"
  if [ -n "$need_glibc" ] && [ "$(printf '%s\n%s\n' "$need_glibc" "$GLIBC_MAX" | sort -V | tail -1)" != "$GLIBC_MAX" ]; then
    die "$(basename "$w") needs glibc $need_glibc (> $GLIBC_MAX); build on an older distro"
  fi
done

# Prove the wheelhouse is complete: a clean, index-less install per Python.
for v in $PY_VERSIONS; do
  tag="cp${v/./}"
  log "Verifying an offline install on Python $v"
  if [ "$CROSS" = 1 ]; then
    # $TARGET_ARCH wheels cannot be installed or imported on $HOST_ARCH, so
    # all that is left is the resolution: does every requirement have a
    # distribution in the wheelhouse that is valid for the target? That
    # catches a missing or mistagged wheel, but NOT a wheel that imports
    # badly -- hence the warning. --target is pip's requirement for using
    # --platform at all; the directory is scratch and thrown away.
    "${PYTHON[$v]}" -m venv "$WORK/verify-$tag"
    PIP_CONFIG_FILE=/dev/null "$WORK/verify-$tag/bin/pip" install \
      --quiet --disable-pip-version-check --no-index --dry-run --ignore-installed \
      --only-binary=:all: --target "$WORK/verify-$tag/target" \
      --python-version "$v" --implementation cp --abi "$tag" --abi abi3 --abi none \
      "${PLATFORM_FLAGS[@]}" \
      --find-links "$PAYLOAD/wheelhouse/$tag" --find-links "$PAYLOAD/wheelhouse/common" \
      -r "$PAYLOAD/requirements.txt" "$PAYLOAD"/wheelhouse/common/raven-*.whl \
      || die "the Python $v wheelhouse does not resolve for $TARGET_ARCH"
    echo "  resolves for $TARGET_ARCH; NOT import-checked (cross-build)"
    continue
  fi
  venv="$WORK/verify-$tag"
  "${PYTHON[$v]}" -m venv "$venv"
  PIP_CONFIG_FILE=/dev/null "$venv/bin/pip" install --quiet --disable-pip-version-check --no-index \
    --find-links "$PAYLOAD/wheelhouse/$tag" --find-links "$PAYLOAD/wheelhouse/common" \
    -r "$PAYLOAD/requirements.txt"
  PIP_CONFIG_FILE=/dev/null "$venv/bin/pip" install --quiet --disable-pip-version-check --no-index --no-deps \
    "$PAYLOAD"/wheelhouse/common/raven-*.whl
  "$venv/bin/pip" check
  "$venv/bin/python" -c 'import raven.app, raven.eud_handler.eud_handler, raven.cot_parser.cot_parser, raven
print("raven", raven.__version__, "imports cleanly")'
  for ep in raven eud_handler cot_parser flask; do
    [ -x "$venv/bin/$ep" ] || die "entry point $ep missing from the Python $v install"
  done
done

# --- frontend -----------------------------------------------------------
log "Frontend: c4raven-ui @ $UI_SHA"
clone_at "$UI_REPO" "$UI_SHA" "$WORK/src/ui"
(
  cd "$WORK/src/ui"
  # Not --immutable: the committed lockfile still names the workspace by its
  # pre-rename package name, which yarn rewrites (metadata only).
  corepack yarn install
  corepack yarn build
)
cp -a "$WORK/src/ui/dist/." "$PAYLOAD/ui/"
[ -f "$PAYLOAD/ui/index.html" ] || die "UI build produced no index.html"

# --- mediamtx -----------------------------------------------------------
log "mediamtx $MEDIAMTX_VERSION ($MEDIAMTX_ARCH)"
MTX="mediamtx_v${MEDIAMTX_VERSION}_linux_${MEDIAMTX_ARCH}.tar.gz"
curl -fsSL -o "$PAYLOAD/mediamtx/$MTX" \
  "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/$MTX"
echo "$MEDIAMTX_SHA256  $PAYLOAD/mediamtx/$MTX" | sha256sum -c --quiet \
  || die "mediamtx checksum mismatch"

# --- ATAK plugin --------------------------------------------------------
log "CROW Remote Clear ATAK plugin"
if [ -n "${PLUGIN_APK:-}" ]; then
  [ -f "$PLUGIN_APK" ] || die "no such APK: $PLUGIN_APK"
  APK_SRC="$PLUGIN_APK"
  PLUGIN_SRC="$PLUGIN_APK"
else
  PLUGIN_SHA=$(git ls-remote "$PLUGIN_REPO" refs/heads/main | cut -f1)
  clone_at "$PLUGIN_REPO" "$PLUGIN_SHA" "$WORK/src/plugin"
  APK_SRC=$(find "$WORK/src/plugin/releases" -maxdepth 1 -name '*.apk' | sort -V | tail -1)
  [ -n "$APK_SRC" ] || die "no APK in c4raven-clear-plugin/releases @ $PLUGIN_SHA"
  PLUGIN_SRC="c4raven-clear-plugin@$PLUGIN_SHA:releases/$(basename "$APK_SRC")"
fi
"$TOOLS/python" - "$APK_SRC" "$PLUGIN_PACKAGE" "${ALLOW_DEV_SIGNED_PLUGIN:-0}" <<'PYEOF'
import re, sys
from loguru import logger
logger.remove()
from androguard.core.apk import APK

path, want_pkg, allow_dev = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
apk = APK(path)
if apk.get_package() != want_pkg:
    sys.exit(f"{path} is {apk.get_package()}, not {want_pkg}")
if not apk.is_signed():
    sys.exit(f"{path} is not signed")
signers = [c.subject.human_friendly for c in apk.get_certificates()]
tak_signed = any("TAK Product Center" in s for s in signers)
xml = apk.get_android_manifest_axml().get_xml().decode("utf-8", "replace")
m = re.search(r'value="(com\.atakmap\.app@[^"]+)"', xml)
print(f"  {apk.get_app_name()} {apk.get_androidversion_name()} "
      f"(revision {apk.get_androidversion_code()}), plugin-api {m.group(1) if m else '?'}")
print(f"  signed by: {'; '.join(signers)}")
if not tak_signed and not allow_dev:
    sys.exit("refusing to bundle a plugin not signed by the TAK Product Center "
             "(set ALLOW_DEV_SIGNED_PLUGIN=1 to override)")
PYEOF
cp "$APK_SRC" "$PAYLOAD/plugins/"

# --- manifest + package -------------------------------------------------
# `arch` is the contract with build-deb.sh, which reads it out of the staged
# payload to set the .deb's Architecture: field, the .deb's filename and the
# glob it extracts mediamtx with. It is a dpkg architecture name (amd64,
# arm64) -- which mediamtx also happens to use in its asset names. Parse it
# as `awk '$1=="arch" {print $2}' MANIFEST`.
{
  echo "c4raven-server $PKG_VERSION (offline)"
  echo "arch         $TARGET_ARCH"
  echo "built        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "server       $SERVER_SHA"
  echo "ui           $UI_SHA"
  echo "mediamtx     $MEDIAMTX_VERSION"
  echo "plugin       $PLUGIN_SRC"
  echo "plugin_sha256 $(sha256sum "$APK_SRC" | cut -d' ' -f1)"
  echo "python       $PY_VERSIONS"
} > "$PAYLOAD/MANIFEST"

log "Building the .deb"
OFFLINE_PAYLOAD="$PAYLOAD" SERVER_SHA="$SERVER_SHA" UI_SHA="$UI_SHA" PKG_VERSION="$PKG_VERSION" \
  "$HERE/build-deb.sh"
DEB="$HERE/build/c4raven-server_${PKG_VERSION}_${TARGET_ARCH}.deb"
[ -f "$DEB" ] || die "build-deb.sh did not produce $DEB"

# --- per-release apt dependency bundles ---------------------------------
# apt runs against a private root with an EMPTY dpkg status, so it resolves
# the dependency closure as if nothing at all were installed. The target
# never downgrades anything: install.sh installs through apt from this
# repository, and apt skips packages the target already has at that
# version or newer.
bundle_suite() {
  local suite=$1
  local A="$WORK/apt-$suite"
  local B="$WORK/bundle-$suite"
  local name="c4raven-server-offline_${PKG_VERSION}_${suite}_${TARGET_ARCH}"
  log "apt dependencies for Ubuntu $suite ($TARGET_ARCH)"
  mkdir -p "$A"/etc/apt/{sources.list.d,apt.conf.d,preferences.d} \
           "$A"/var/lib/apt/lists/partial "$A"/var/cache/apt/archives/partial "$A"/var/lib/dpkg
  : > "$A/var/lib/dpkg/status"
  # Architectures: pins each stanza to the target arch, so the index fetch
  # only pulls what this bundle needs. For a non-amd64 target both stanzas
  # point at ports.ubuntu.com, which serves -security itself; there is no
  # ports counterpart to security.ubuntu.com.
  cat > "$A/etc/apt/sources.list.d/ubuntu.sources" << EOF
Types: deb
URIs: $UBUNTU_MIRROR
Suites: $suite $suite-updates
Components: main universe
Architectures: $TARGET_ARCH
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $UBUNTU_SECURITY_MIRROR
Suites: $suite-security
Components: main universe
Architectures: $TARGET_ARCH
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  # APT::Architecture/Architectures are set explicitly so apt never falls
  # back to asking dpkg what this machine is -- which is what makes a
  # foreign-arch resolve work without `dpkg --add-architecture` touching
  # the build host's real dpkg state.
  local APT=(apt-get -q
    -o Dir="$A" -o Dir::State::status="$A/var/lib/dpkg/status"
    -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$A/etc/apt/sources.list.d"
    -o Dir::Etc::Parts="$A/etc/apt/apt.conf.d" -o Dir::Etc::Preferences="$A/etc/apt/preferences"
    -o Dir::Etc::PreferencesParts="$A/etc/apt/preferences.d"
    -o APT::Architecture="$TARGET_ARCH" -o APT::Architectures::="$TARGET_ARCH"
    -o APT::Install-Recommends=false -o Debug::NoLocking=true)
  "${APT[@]}" update >/dev/null
  "${APT[@]}" install -y --download-only "$DEB" >"$A/resolve.log" \
    || { tail -30 "$A/resolve.log" >&2; die "could not resolve dependencies for $suite"; }

  rm -rf "$B"
  mkdir -p "$B/$name/repo"
  cp "$A"/var/cache/apt/archives/*.deb "$B/$name/repo/"
  cp "$DEB" "$B/$name/repo/"
  (
    cd "$B/$name/repo"
    apt-ftparchive packages . > Packages
    gzip -9kn Packages
    apt-ftparchive -o APT::FTPArchive::Release::Suite=c4raven-offline release . > Release
  )

  # Prove the repository is self-sufficient: resolve c4raven-server again,
  # from an empty system, with this repository as the ONLY source.
  local T="$WORK/check-$suite"
  mkdir -p "$T"/etc/apt/sources.list.d "$T"/etc/apt/apt.conf.d "$T"/etc/apt/preferences.d "$T"/var/lib/apt/lists/partial "$T"/var/cache/apt/archives/partial "$T"/var/lib/dpkg
  : > "$T/var/lib/dpkg/status"
  echo "deb [trusted=yes] file:$B/$name/repo ./" > "$T/etc/apt/sources.list.d/offline.list"
  local CHECK=(apt-get -q
    -o Dir="$T" -o Dir::State::status="$T/var/lib/dpkg/status"
    -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$T/etc/apt/sources.list.d"
    -o Dir::Etc::Parts="$T/etc/apt/apt.conf.d"
    -o APT::Architecture="$TARGET_ARCH" -o APT::Architectures::="$TARGET_ARCH"
    -o APT::Install-Recommends=false -o Debug::NoLocking=true)
  "${CHECK[@]}" update >/dev/null
  "${CHECK[@]}" install -s -y c4raven-server >"$T/simulate.log" \
    || { tail -30 "$T/simulate.log" >&2; die "the $suite bundle is missing packages"; }

  sed -e "s/@SUITE@/$suite/g" -e "s/@VERSION@/$PKG_VERSION/g" -e "s/@ARCH@/$TARGET_ARCH/g" \
    "$HERE/offline/install.sh" > "$B/$name/install.sh"
  chmod 755 "$B/$name/install.sh"
  sed -e "s/@SUITE@/$suite/g" -e "s/@VERSION@/$PKG_VERSION/g" -e "s/@ARCH@/$TARGET_ARCH/g" \
    "$HERE/offline/README.txt" > "$B/$name/README.txt"
  cp "$PAYLOAD/MANIFEST" "$B/$name/MANIFEST"
  (cd "$B/$name" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum > SHA256SUMS)

  tar -C "$B" -cf "$HERE/build/$name.tar" "$name"
  echo "  $(ls "$B/$name/repo"/*.deb | wc -l) packages, $(du -h "$HERE/build/$name.tar" | cut -f1)"
}

for suite in $SUITES; do bundle_suite "$suite"; done

log "Done ($TARGET_ARCH)"
echo "  $DEB ($(du -h "$DEB" | cut -f1))"
for suite in $SUITES; do
  f="$HERE/build/c4raven-server-offline_${PKG_VERSION}_${suite}_${TARGET_ARCH}.tar"
  echo "  $f ($(du -h "$f" | cut -f1))"
done
echo
cat "$PAYLOAD/MANIFEST"
