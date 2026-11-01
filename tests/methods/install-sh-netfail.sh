#!/bin/bash
# Method: install.sh fails partway through on a network outage, then the
# user simply runs it again.
#
# Run 1 has the npm/yarn registries unreachable (/etc/hosts points them at
# the container itself), so install.sh gets through packages, backend,
# database, CA, mediamtx and nginx, then dies in the UI step once its yarn
# retries are used up -- the most network-hungry step and the one most
# likely to fail on a real install. The network comes back and run 2 is the
# same install.sh, unchanged. run-matrix.sh then runs verify.sh as for every
# other cell, so a re-run that "succeeds" without a working stack still
# fails.
#
# Runs INSIDE the harness container as root, with the same environment as
# install-sh.sh (DISTRO, ARCH, REPO).
set -uo pipefail

EXIT_SKIP=77   # install-sh.sh skipping (preconditions unmet) is passed through

say() { printf '\n### %s\n' "$*"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS=/tmp/install-sh.typescript
BLOCKED="registry.npmjs.org registry.yarnpkg.com repo.yarnpkg.com"

# /etc/hosts is a bind mount in a container: rewrite it in place, never
# rename over it.
cp /etc/hosts /tmp/hosts.orig
restore_hosts() { cat /tmp/hosts.orig > /etc/hosts; }
trap restore_hosts EXIT
for h in $BLOCKED; do
  printf '127.0.0.1 %s\n::1 %s\n' "$h" "$h" >> /etc/hosts
done
say "run 1: npm/yarn registries unreachable ($BLOCKED)"

bash "$HERE/install-sh.sh"
rc=$?
cp "$TS" /tmp/install-sh.run1.typescript 2>/dev/null || true
if [ "$rc" = "$EXIT_SKIP" ]; then
  echo "SKIP: install-sh.sh skipped run 1 (its reason is above)"
  exit "$EXIT_SKIP"
fi
if [ "$rc" = 0 ]; then
  say "FAIL: run 1 exited 0 with the registries unreachable -- the outage was not simulated"
  exit 1
fi
if ! grep -aq 'The install stopped while: Building and deploying the C4 Raven UI frontend' "$TS"; then
  say "FAIL: run 1 did not stop in the UI step, or did not say where it stopped:"
  grep -a 'The install stopped while' "$TS" || tail -c 1500 "$TS"
  exit 1
fi
say "run 1 stopped in the UI step as intended (exit $rc) and said so"
grep -aq 'retry: attempt 1/' "$TS" && say "  (and retried before giving up)"

restore_hosts
say "run 2: network back; running the same install.sh again"
bash "$HERE/install-sh.sh"
rc=$?
say "run 2 exited $rc"
exit "$rc"
