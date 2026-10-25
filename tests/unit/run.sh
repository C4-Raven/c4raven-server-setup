#!/bin/bash
# Tier 1b: unit tests. No containers, no root, no network, no package
# manager -- a second or two, on every push.
#
#   tests/unit/run.sh              # every test-*.sh in this directory
#   tests/unit/run.sh distro       # just tests/unit/test-distro.sh
#   VERBOSE=1 tests/unit/run.sh    # print passing assertions too
#   STRICT=1 tests/unit/run.sh     # a skipped FILE is a failure (CI uses this
#                                  #   for files whose subject must exist by now)
#
# Each test file is a separate bash process so that one blowing up cannot
# take the rest with it. Exit 0 all green, 1 something failed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
. "$HERE/../lib/common.sh"
harness_paths

STRICT="${STRICT:-0}"

FILES=()
if [ $# -gt 0 ]; then
  for a in "$@"; do
    for cand in "$HERE/$a" "$HERE/test-$a.sh" "$HERE/$a.sh"; do
      [ -f "$cand" ] && { FILES+=("$cand"); continue 2; }
    done
    die "no such unit test: $a (have: $(cd "$HERE" && echo test-*.sh))"
  done
else
  mapfile -t FILES < <(find "$HERE" -maxdepth 1 -name 'test-*.sh' | sort)
fi
[ "${#FILES[@]}" -gt 0 ] || die "no test-*.sh files in $HERE"

npass=0; nfail=0; nskip=0
FAILED=()
SKIPPED=()

for f in "${FILES[@]}"; do
  printf '%s--- %s%s\n' "$C_BLU" "$(basename "$f")" "$C_OFF"
  bash "$f"
  rc=$?
  case "$rc" in
    0)  npass=$((npass + 1)) ;;
    77) nskip=$((nskip + 1)); SKIPPED+=("$(basename "$f")") ;;
    *)  nfail=$((nfail + 1)); FAILED+=("$(basename "$f") (exit $rc)") ;;
  esac
  echo
done

printf '%sunit: %d file(s) passed, %d failed, %d skipped%s\n' \
  "$([ "$nfail" -eq 0 ] && printf '%s' "$C_GRN" || printf '%s' "$C_RED")" \
  "$npass" "$nfail" "$nskip" "$C_OFF"
[ "${#FAILED[@]}"  -gt 0 ] && printf '  failed:  %s\n'  "${FAILED[@]}"
[ "${#SKIPPED[@]}" -gt 0 ] && printf '  skipped: %s\n' "${SKIPPED[@]}"

[ "$nfail" -eq 0 ] || exit 1
if [ "$STRICT" = 1 ] && [ "$nskip" -gt 0 ]; then
  die "STRICT=1 and $nskip file(s) skipped -- their subject is supposed to exist by now"
fi
exit 0
