#!/bin/bash
# Minimal assertion library for the container-free unit tier (tests/unit/).
#
# Deliberately tiny and dependency-free: the unit tier's whole value is that
# it runs in under a second on any machine with bash, so pulling in bats or
# shunit2 would cost more than it buys.
#
# A test file sources this, runs assertions, and ends with `t_summary`:
#
#   . "$(dirname "$0")/../lib/assert.sh"
#   t_eq "$(hostname -s)" "$(uname -n)" "hostname matches"
#   t_summary
#
# Exit codes: 0 all passed, 1 something failed, 77 the whole file skipped.

# shellcheck source=tests/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T_PASS=0
T_FAIL=0
T_FAILURES=()
T_NAME="$(basename "${0%.sh}")"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  A_RED=$'\033[31m'; A_GRN=$'\033[32m'; A_YEL=$'\033[33m'
  A_DIM=$'\033[2m';  A_OFF=$'\033[0m'
else
  A_RED=''; A_GRN=''; A_YEL=''; A_DIM=''; A_OFF=''
fi

# VERBOSE=1 prints the passing assertions too. Off by default: a green tier
# that prints 300 lines is a tier nobody reads.
t_ok() {
  T_PASS=$((T_PASS + 1))
  [ "${VERBOSE:-0}" = 1 ] && printf '  %sok%s   %s\n' "$A_GRN" "$A_OFF" "$1"
  return 0
}

t_no() {
  T_FAIL=$((T_FAIL + 1))
  T_FAILURES+=("$1")
  printf '  %sFAIL%s %s\n' "$A_RED" "$A_OFF" "$1"
  [ -n "${2:-}" ] && printf '%s       %s%s\n' "$A_DIM" "$2" "$A_OFF"
  return 0
}

# t_eq GOT WANT DESC
t_eq() {
  if [ "$1" = "$2" ]; then t_ok "$3"
  else t_no "$3" "want: [$2]  got: [$1]"; fi
}

# t_ne GOT NOTWANT DESC
t_ne() {
  if [ "$1" != "$2" ]; then t_ok "$3"
  else t_no "$3" "got [$1], which is exactly what it must not be"; fi
}

# t_has HAYSTACK NEEDLE DESC  -- substring
t_has() {
  case "$1" in
    *"$2"*) t_ok "$3" ;;
    *) t_no "$3" "[$2] not found in: $(printf '%s' "$1" | tr '\n' ' ' | cut -c1-200)" ;;
  esac
}

# t_hasnt HAYSTACK NEEDLE DESC
t_hasnt() {
  case "$1" in
    *"$2"*) t_no "$3" "[$2] is present and must not be: $(printf '%s' "$1" | tr '\n' ' ' | cut -c1-200)" ;;
    *) t_ok "$3" ;;
  esac
}

# t_match GOT ERE DESC
t_match() {
  if printf '%s' "$1" | grep -Eq -- "$2"; then t_ok "$3"
  else t_no "$3" "[$1] does not match /$2/"; fi
}

# t_true DESC -- CMD...   (the `--` keeps a command named like a flag honest)
t_true() {
  local desc=$1; shift
  [ "${1:-}" = "--" ] && shift
  local out
  if out=$("$@" 2>&1); then t_ok "$desc"
  else t_no "$desc" "exit $? -- $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
}

# t_false DESC -- CMD...  -- asserts a NON-zero exit. Used a lot here: half of
# distro.sh's contract is which predicates say "no".
t_false() {
  local desc=$1; shift
  [ "${1:-}" = "--" ] && shift
  local out
  if out=$("$@" 2>&1); then t_no "$desc" "it succeeded, and should not have: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  else t_ok "$desc"; fi
}

# t_skip_all REASON -- the file's subject is not present. Not a failure: the
# packaging workstreams land at different times and a red X nobody can tell
# from a regression is worse than a loud skip.
t_skip_all() {
  printf '%sSKIP%s %s -- %s\n' "$A_YEL" "$A_OFF" "$T_NAME" "$1"
  exit 77
}

t_summary() {
  if [ "$T_FAIL" -gt 0 ]; then
    printf '%s%s: %d passed, %d FAILED%s\n' "$A_RED" "$T_NAME" "$T_PASS" "$T_FAIL" "$A_OFF"
    printf '    - %s\n' "${T_FAILURES[@]}"
    exit 1
  fi
  printf '%s%s: %d passed%s\n' "$A_GRN" "$T_NAME" "$T_PASS" "$A_OFF"
  exit 0
}
