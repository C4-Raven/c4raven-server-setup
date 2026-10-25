#!/bin/bash
# Method: the curl|bash installer (install.sh), online.
#
# Runs INSIDE the harness container as root. run-matrix.sh exports:
#   DISTRO  ubuntu-24.04 | rocky-9
#   ARCH    amd64 | arm64
#   REPO    writable copy of the working tree, e.g. /opt/harness/repo
set -uo pipefail

EXIT_SKIP=77
say() { printf '\n### %s\n' "$*"; }

cd "$REPO" || exit 1

# --- preconditions ---------------------------------------------------------
case "$DISTRO" in
  rocky-*)
    if [ ! -f "$REPO/lib/distro.sh" ]; then
      echo "SKIP: install.sh has no distro shim yet (lib/distro.sh is missing)," >&2
      echo "      so it would still run apt on $DISTRO. Nothing to test here." >&2
      exit "$EXIT_SKIP"
    fi
    if grep -q 'apt install -y' "$REPO/install.sh" && ! grep -q 'distro.sh' "$REPO/install.sh"; then
      echo "SKIP: lib/distro.sh exists but install.sh does not source it yet." >&2
      exit "$EXIT_SKIP"
    fi
    ;;
esac

# --- point the installer at this working tree ------------------------------
# install.sh hardcodes REPO_RAW to the master branch on raw.githubusercontent
# and curls colors.sh, mediamtx.yml, rabbitmq.conf, seed_admin.py and the
# nginx templates from it. Left alone, a PR build would silently test
# master's copies of all of those, which is worse than not testing at all.
# curl speaks file://, so rewriting the one assignment is enough.
#
# FIXME(upstream): install.sh should read REPO_RAW from the environment
#   (REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/...}") so this
#   patch is not needed. Same for update.sh.
if ! grep -q '^REPO_RAW=' install.sh; then
  echo "SKIP: install.sh no longer has a REPO_RAW= assignment to redirect." >&2
  echo "      Update tests/methods/install-sh.sh for its new shape." >&2
  exit "$EXIT_SKIP"
fi
sed -i "s~^REPO_RAW=.*~REPO_RAW=file://$REPO~" install.sh
chmod -R a+rX "$REPO"

# --- the answers install.sh reads from /dev/tty -----------------------------
ANSWERS=/tmp/install-sh.answers
: > "$ANSWERS"
# No answer for the "continue anyway?" guard: every matrix distro passes
# distro_supported, so install.sh never asks, and a stray y here would shift
# every answer below by one (Turnstile on, keys "n"). Federation Hub is only
# offered on the Debian family.
echo n >> "$ANSWERS"   # Cloudflare Turnstile
echo n >> "$ANSWERS"   # public domain (certbot cannot work in here anyway)
case "$DISTRO" in
  ubuntu-*) echo n >> "$ANSWERS" ;;   # Federation Hub .deb
esac
say "answers fed to install.sh: $(tr '\n' ' ' < "$ANSWERS")"

# --- run it exactly as a human would ---------------------------------------
# install.sh refuses to run as root or as `raven`; the image provides a
# sudo-capable `tester`. `script` gives it a real pty so its `read < /dev/tty`
# calls work, and -e makes it return install.sh's own exit status.
say "running install.sh as tester"
runuser -u tester -- \
  script -qec "cd $REPO && bash install.sh" /dev/null < "$ANSWERS"
rc=$?
say "install.sh exited $rc"
exit "$rc"
