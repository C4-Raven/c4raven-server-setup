#!/bin/bash
# Method: install.sh is killed outright partway through (SSH session dropped
# without nohup, OOM killer, Ctrl-C mashed), then the user runs it again.
#
# Run 1 is SIGKILLed -- no traps, no cleanup -- while `poetry install` is
# populating the backend venv, which leaves a half-built .venv, the app
# user created but nothing after it. Run 2 is the same install.sh,
# unchanged, and must finish; run-matrix.sh then runs verify.sh as usual.
#
# Runs INSIDE the harness container as root, with the same environment as
# install-sh.sh (DISTRO, ARCH, REPO).
set -uo pipefail

EXIT_SKIP=77   # install-sh.sh skipping (preconditions unmet) is passed through

say() { printf '\n### %s\n' "$*"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS=/tmp/install-sh.typescript
MARK_STEP='Cloning and installing the Raven backend'
# poetry's own line once it starts installing from the lock file
MARK_POETRY='Installing dependencies from lock file'
KILL_AFTER=${KILL_AFTER:-10}   # seconds into poetry install
WAIT_MAX=$((40 * 60))

rm -f "$TS"
say "run 1: will be SIGKILLed ${KILL_AFTER}s into poetry install"
bash "$HERE/install-sh.sh" &
runner=$!

waited=0 seen=""
while kill -0 "$runner" 2>/dev/null && [ "$waited" -lt "$WAIT_MAX" ]; do
  if grep -aq "$MARK_STEP" "$TS" 2>/dev/null && grep -aq "$MARK_POETRY" "$TS" 2>/dev/null; then
    seen=1; break
  fi
  sleep 2; waited=$((waited + 2))
done
if [ -z "$seen" ]; then
  wait "$runner"; rc=$?
  if [ "$rc" = "$EXIT_SKIP" ]; then
    echo "SKIP: install-sh.sh skipped run 1 (its reason is above)"
    exit "$EXIT_SKIP"
  fi
  say "FAIL: never saw poetry install start (runner exit $rc, waited ${waited}s)"
  tail -c 1500 "$TS" 2>/dev/null
  exit 1
fi
sleep "$KILL_AFTER"

say "killing the whole install with SIGKILL"
kill -KILL "$runner" 2>/dev/null
for _ in 1 2 3; do
  pkill -KILL -x script 2>/dev/null
  pkill -KILL -u tester 2>/dev/null
  pkill -KILL -u raven 2>/dev/null
  pkill -KILL -x sudo 2>/dev/null
  sleep 1
done
wait "$runner" 2>/dev/null
cp "$TS" /tmp/install-sh.run1.typescript 2>/dev/null || true
if grep -aq 'Raven backend installed' "$TS"; then
  say "note: poetry install had already finished; the kill landed in a later step"
else
  say "run 1 killed inside '$MARK_STEP' (poetry install), as intended"
fi
ls -d /opt/raven/c4raven-server/.venv 2>/dev/null && say "half-built venv left behind, as intended"

say "run 2: running the same install.sh again"
bash "$HERE/install-sh.sh"
rc=$?
say "run 2 exited $rc"
exit "$rc"
