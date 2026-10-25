#!/bin/bash
# Shared helpers for the C4 Raven install verification harness.
#
# Sourced by tests/run-matrix.sh, tests/lint.sh and tests/methods/*.sh.
# Nothing here starts a container or touches the host beyond reading files;
# all of that lives in run-matrix.sh.

# Autotools' convention, and the one `run-matrix.sh` keys its summary off:
# a cell that cannot run here is neither a pass nor a failure.
# shellcheck disable=SC2034
EXIT_SKIP=77

# Consumers source this file; shellcheck cannot see their use of these.
# shellcheck disable=SC2034
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_OFF=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*" >&2; }
note() { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }
warn() { printf '%sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# skip "reason" -- for a matrix cell whose inputs do not exist yet. The
# whole point of this exit code is that a half-finished multi-arch port
# reports "not here yet", not a red X that nobody can distinguish from a
# real regression.
skip() { printf '%sSKIP%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; exit "$EXIT_SKIP"; }

# ---------------------------------------------------------------------------
# Repo layout
# ---------------------------------------------------------------------------
# Resolve relative to this file so the harness works from any cwd.
harness_paths() {
  TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  export TESTS_DIR REPO_DIR
}

# Every shell script in the repo, for the lint tier. Tracked files only when
# git is available (so a stray build artifact never fails the lint), with a
# find(1) fallback for tarball checkouts.
repo_shell_scripts() {
  local root=$1 f
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    # --others --exclude-standard as well as --cached: a script added in
    # the working tree but not yet committed is exactly the one you most
    # want linted.
    git -C "$root" ls-files -z --cached --others --exclude-standard \
      | while IFS= read -r -d '' f; do printf '%s\n' "$root/$f"; done
  else
    find "$root" -type f -not -path '*/.git/*' -not -path '*/build/*' -print
  fi | while IFS= read -r f; do
    case "$f" in
      */build/*) continue ;;
      *.sh) [ -f "$f" ] && printf '%s\n' "$f"; continue ;;
      *.py|*.yml|*.yaml|*.md|*.conf|*.service|*.templates|*.deb|*.apk) continue ;;
    esac
    # debian/* maintainer scripts and offline/install.sh carry no .sh suffix.
    [ -f "$f" ] || continue
    case "$(head -c 128 "$f" 2>/dev/null | tr -d '\0')" in
      '#!'*/sh*|'#!'*/bash*|'#!'*env\ sh*|'#!'*env\ bash*) printf '%s\n' "$f" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Container engine
# ---------------------------------------------------------------------------
# Docker is the default (see tests/README.md for why systemd-in-Docker and
# not podman or a VM); CONTAINER_ENGINE=podman is supported and tested for
# the local-developer case.
detect_engine() {
  if [ -n "${CONTAINER_ENGINE:-}" ]; then
    command -v "$CONTAINER_ENGINE" >/dev/null 2>&1 \
      || die "CONTAINER_ENGINE=$CONTAINER_ENGINE is not on PATH"
    echo "$CONTAINER_ENGINE"
    return
  fi
  for e in docker podman; do
    if command -v "$e" >/dev/null 2>&1; then echo "$e"; return; fi
  done
  skip "no docker or podman on PATH -- the container tier needs one of them"
}

# The flags that make systemd actually work as PID 1. See tests/README.md
# ("systemd in a container") for what each one is for and what it costs.
engine_run_flags() {
  local engine=$1 arch=$2
  printf '%s\n' \
    --detach \
    --privileged \
    --cgroupns=host \
    --tmpfs /run \
    --tmpfs /run/lock \
    --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --hostname c4raven-test \
    --platform "linux/$arch"
  # podman needs to be told explicitly; docker infers it from the image CMD.
  [ "$engine" = podman ] && printf '%s\n' --systemd=always
  return 0
}

# ---------------------------------------------------------------------------
# Matrix definition
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
ALL_DISTROS="ubuntu-24.04 rocky-9"
# shellcheck disable=SC2034
ALL_ARCHES="amd64 arm64"
# install-sh   curl|bash path, online, builds everything on the target
# deb          build-deb.sh + apt install, online postinst
# deb-offline  build-offline.sh bundle, no network at install time
# rpm          rpm/build-rpm.sh + dnf install   (Rocky only)
# shellcheck disable=SC2034
ALL_METHODS="install-sh deb deb-offline rpm"

# Which install methods are meaningful on which distro.
methods_for_distro() {
  case "$1" in
    ubuntu-*) echo "install-sh deb deb-offline" ;;
    rocky-*)  echo "install-sh rpm" ;;
    *)        die "unknown distro: $1" ;;
  esac
}

host_arch() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "unsupported" ;;
  esac
}
