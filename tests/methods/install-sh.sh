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
# One answer per [y/n] question, in order. No answer for the "continue
# anyway?" guard: every matrix distro passes distro_supported, so install.sh
# never asks; if it ever does, it gets the Turnstile "n", refuses and exits 1
# -- a clear failure rather than every answer shifted by one. Federation Hub
# is only offered on the Debian family.
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
#
# Each answer is typed only once its [y/n] prompt is on screen. Feeding them
# all up front on stdin does not work: install.sh's first `sudo` (use_pty)
# relays whatever is buffered on the tty into its own pty, apt/dnf swallow
# it, and the first ask_yn then waits forever (run 40310154447 sat at the
# Turnstile prompt for 68 minutes until the cell timeout). The typescript
# (-f: flushed on every write) is what the loop below watches; script still
# copies everything to stdout, i.e. install.log.
mapfile -t answers < "$ANSWERS"
TS=/tmp/install-sh.typescript
FIFO=/tmp/install-sh.stdin
rm -f "$TS" "$FIFO"
mkfifo "$FIFO"
exec 3<>"$FIFO"   # hold a writer open, so script never sees EOF on stdin

# No output at all for this long means install.sh is waiting on a prompt
# the loop does not answer (a free-text read, or a question we did not
# expect); fail with its last words instead of running into TIMEOUT_MIN.
IDLE_MAX=$((15 * 60))

say "running install.sh as tester"
runuser -u tester -- \
  script -qefc "cd $REPO && bash install.sh" "$TS" < "$FIFO" &
pid=$!

given=0 last_size=-1 idle=0
abort() {
  say "$*"
  printf '%s\n' "--- last output:"; tail -c 400 "$TS" 2>/dev/null; echo
  kill "$pid" 2>/dev/null
  pkill -TERM -u tester 2>/dev/null
}
while kill -0 "$pid" 2>/dev/null; do
  sleep 2
  asked=$(grep -aoE '\[y/[nN]\] ' "$TS" 2>/dev/null | wc -l)
  if [ "$asked" -gt "$given" ]; then
    if [ "$given" -ge "${#answers[@]}" ]; then
      abort "install.sh asked an unexpected question (#$((given + 1))) -- aborting"
      break
    fi
    printf '%s\n' "${answers[$given]}" >&3
    given=$((given + 1))
  fi
  size=$(stat -c %s "$TS" 2>/dev/null || echo 0)
  if [ "$size" = "$last_size" ]; then
    idle=$((idle + 2))
  else
    idle=0 last_size=$size
  fi
  if [ "$idle" -ge "$IDLE_MAX" ]; then
    abort "no output from install.sh for ${IDLE_MAX}s -- it is probably waiting on a prompt"
    break
  fi
done
wait "$pid"
rc=$?
exec 3>&-
say "answered $given of ${#answers[@]} question(s)"
say "install.sh exited $rc"
exit "$rc"
