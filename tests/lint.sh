#!/bin/bash
# Tier 1: static checks. No containers, no network, no root -- runs in
# seconds on every push and catches the great majority of regressions in
# this repo, which is almost entirely shell.
#
#   tests/lint.sh            # lint everything, report, exit non-zero on failure
#   STRICT=1 tests/lint.sh   # additionally fail if a linter is not installed
#                            # (what CI uses -- a silently skipped linter in
#                            #  CI is worse than no linter at all)
#
# Checks:
#   * bash -n / sh -n on every shell script, including the debian maintainer
#     scripts and the generated offline installer, which have no .sh suffix
#   * shellcheck on the same set
#   * py_compile on every Python file
#   * YAML parse of the workflows, mediamtx.yml and rabbitmq.conf's siblings
#   * systemd-analyze verify on the shipped units, when available
#   * rpmspec --parse on rpm/*.spec, when both exist
#   * placeholder sweep: no OTS_FOLDER / SERVER_CERT_FILE / CA_CERT_FILE left
#     unsubstituted anywhere outside the templates that are meant to have them
set -uo pipefail

# shellcheck source=tests/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
harness_paths

STRICT="${STRICT:-0}"
FAILED=0
SKIPPED=0

ok()     { printf '%sPASS%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
bad()    { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*"; FAILED=$((FAILED + 1)); }
absent() {
  if [ "$STRICT" = 1 ]; then
    bad "$1 (STRICT=1: install it)"
  else
    printf '%sSKIP%s %s\n' "$C_YEL" "$C_OFF" "$1"
    SKIPPED=$((SKIPPED + 1))
  fi
}

mapfile -t SCRIPTS < <(repo_shell_scripts "$REPO_DIR" | sort)
[ "${#SCRIPTS[@]}" -gt 0 ] || die "found no shell scripts to lint under $REPO_DIR"

# ---------------------------------------------------------------------------
log "Syntax (${#SCRIPTS[@]} shell scripts)"
# ---------------------------------------------------------------------------
syntax_fail=0
for f in "${SCRIPTS[@]}"; do
  case "$(head -n1 "$f")" in
    *bash*) shell='bash' ;;
    *)      shell='sh' ;;
  esac
  if ! out=$("$shell" -n "$f" 2>&1); then
    bad "${f#"$REPO_DIR"/}"
    printf '%s\n' "$out" | sed 's/^/       /'
    syntax_fail=1
  fi
done
[ "$syntax_fail" = 0 ] && ok "all scripts parse"

# ---------------------------------------------------------------------------
log "shellcheck"
# ---------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  # -x follows `source`/`.` into other files (lib/common.sh, colors.sh).
  # SC1091: the installers source files fetched at runtime (colors.sh,
  # /etc/os-release, debconf's confmodule) that are not in the repo.
  if shellcheck --version >/dev/null 2>&1 \
     && shellcheck -x -S warning -e SC1091 "${SCRIPTS[@]}"; then
    ok "shellcheck clean at severity>=warning ($(shellcheck --version | awk '/^version:/{print $2}'))"
  else
    bad "shellcheck reported findings (see above)"
  fi
else
  absent "shellcheck not installed"
fi

# ---------------------------------------------------------------------------
log "Python"
# ---------------------------------------------------------------------------
mapfile -t PYFILES < <(find "$REPO_DIR" -name '*.py' -not -path '*/.git/*' -not -path '*/build/*' | sort)
if [ "${#PYFILES[@]}" -eq 0 ]; then
  ok "no Python files"
elif command -v python3 >/dev/null 2>&1; then
  if python3 -m py_compile "${PYFILES[@]}" 2>&1; then
    ok "${#PYFILES[@]} Python files compile"
  else
    bad "py_compile failed"
  fi
  find "$REPO_DIR" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null
else
  absent "python3 not installed"
fi

# ---------------------------------------------------------------------------
log "YAML"
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  yaml_fail=0
  while IFS= read -r f; do
    if ! out=$(python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f" 2>&1); then
      bad "${f#"$REPO_DIR"/}"
      printf '%s\n' "$out" | sed 's/^/       /'
      yaml_fail=1
    fi
  done < <(find "$REPO_DIR" \( -name '*.yml' -o -name '*.yaml' \) \
             -not -path '*/.git/*' -not -path '*/build/*' | sort)
  [ "$yaml_fail" = 0 ] && ok "all YAML parses (workflows, mediamtx.yml)"
else
  absent "python3 + PyYAML not installed"
fi

# ---------------------------------------------------------------------------
log "systemd units"
# ---------------------------------------------------------------------------
mapfile -t UNITS < <(find "$REPO_DIR/debian" "$REPO_DIR/rpm" -name '*.service' 2>/dev/null | sort)
if [ "${#UNITS[@]}" -eq 0 ]; then
  absent "no .service files found"
elif command -v systemd-analyze >/dev/null 2>&1; then
  # Two sources of expected noise, both filtered:
  #   * SYSTEMD_UNIT_PATH pins the search path to a scratch copy of just
  #     our units, so verify does not drag in (and complain about) whatever
  #     unrelated units the machine running the lint happens to have. That
  #     matters: running this on a box that already hosts a TAK server
  #     otherwise reports that box's units as our failures.
  #   * ExecStart= is resolved against the local filesystem, so /opt/raven
  #     not existing here is expected, not a finding.
  unit_fail=0
  unit_tmp=$(mktemp -d)
  cp "${UNITS[@]}" "$unit_tmp/"
  for u in "${UNITS[@]}"; do
    out=$(SYSTEMD_UNIT_PATH="$unit_tmp" systemd-analyze verify "$unit_tmp/$(basename "$u")" 2>&1 \
          | grep -vE "Command .* is not executable|does not exist|Unit .* not found|EnvironmentFile" || true)
    if [ -n "$out" ]; then
      bad "${u#"$REPO_DIR"/}"
      printf '%s\n' "$out" | sed 's/^/       /'
      unit_fail=1
    fi
  done
  rm -rf "$unit_tmp"
  [ "$unit_fail" = 0 ] && ok "${#UNITS[@]} units verify"
else
  absent "systemd-analyze not installed"
fi

# ---------------------------------------------------------------------------
log "RPM spec"
# ---------------------------------------------------------------------------
mapfile -t SPECS < <(find "$REPO_DIR/rpm" -name '*.spec' 2>/dev/null | sort)
if [ "${#SPECS[@]}" -eq 0 ]; then
  printf '%sSKIP%s rpm/*.spec does not exist yet (workstream: rpm packaging)\n' "$C_YEL" "$C_OFF"
  SKIPPED=$((SKIPPED + 1))
elif command -v rpmspec >/dev/null 2>&1; then
  spec_fail=0
  for s in "${SPECS[@]}"; do
    # --parse only expands macros and does not need the sources present.
    # Run it under both architectures: an arch-conditional %ifarch typo is
    # exactly the kind of thing this tier should catch for free.
    for a in x86_64 aarch64; do
      if ! out=$(rpmspec --target "$a" --parse "$s" 2>&1 >/dev/null); then
        bad "${s#"$REPO_DIR"/} (--target $a)"
        printf '%s\n' "$out" | sed 's/^/       /'
        spec_fail=1
      fi
    done
  done
  [ "$spec_fail" = 0 ] && ok "${#SPECS[@]} spec(s) parse for x86_64 and aarch64"
else
  absent "rpmspec not installed (Debian/Ubuntu: the 'rpm' package provides it)"
fi

# ---------------------------------------------------------------------------
log "Debian control"
# ---------------------------------------------------------------------------
if [ -f "$REPO_DIR/debian/control" ]; then
  # build-deb.sh's offline rewrite is awk matching exact Depends spellings
  # and the "Building the UI needs" marker paragraph. It already guards
  # itself at build time; catch the drift here, before anyone builds.
  if grep -q '^ Building the UI needs' "$REPO_DIR/debian/control"; then
    ok "control still has the marker paragraph build-deb.sh's offline rewrite keys off"
  else
    bad "debian/control lost the ' Building the UI needs' marker that build-deb.sh's offline rewrite requires"
  fi
  if command -v dpkg-parsechangelog >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
    # Binary stanza must carry Architecture:; build-deb.sh rewrites it per arch.
    grep -q '^Architecture:' "$REPO_DIR/debian/control" \
      && ok "control declares Architecture:" \
      || bad "debian/control has no Architecture: field"
  fi
fi

# ---------------------------------------------------------------------------
log "Unsubstituted placeholders"
# ---------------------------------------------------------------------------
# These tokens are legitimate only in the shipped templates (nginx_configs/*,
# mediamtx.yml) and in the scripts that substitute them. Anywhere else means
# a template got copied without its sed pass.
PLACEHOLDERS='OTS_FOLDER|SERVER_CERT_FILE|SERVER_KEY_FILE|CA_CERT_FILE'
stray=$(grep -rlE "$PLACEHOLDERS" "$REPO_DIR" \
          --exclude-dir=.git --exclude-dir=build --exclude-dir=tests \
          --exclude-dir=docs --exclude-dir=nginx_configs \
          --exclude='*.md' --exclude=mediamtx.yml \
          --exclude=install.sh --exclude=build-deb.sh --exclude=build-rpm.sh \
          --exclude='*.spec' --exclude='*.postinst' 2>/dev/null || true)
if [ -n "$stray" ]; then
  bad "placeholder tokens outside the templates that define them:"
  printf '%s\n' "$stray" | sed "s#^$REPO_DIR/#       #"
else
  ok "no stray template placeholders"
fi

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -gt 0 ]; then
  printf '%s%d check(s) failed%s' "$C_RED" "$FAILED" "$C_OFF"
  [ "$SKIPPED" -gt 0 ] && printf ', %d skipped' "$SKIPPED"
  echo
  exit 1
fi
printf '%slint: all checks passed%s' "$C_GRN" "$C_OFF"
[ "$SKIPPED" -gt 0 ] && printf ' (%d skipped -- run with STRICT=1 to require them)' "$SKIPPED"
echo
