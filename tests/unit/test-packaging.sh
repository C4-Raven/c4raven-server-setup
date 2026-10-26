#!/bin/bash
# Unit tests for the packaging scripts' *guards* -- the refusals that fire
# before any work happens.
#
# Nothing here builds a package: these run in under a second and need no
# network, no Node, no Poetry and no credentials. They exist because the
# guards being tested are the only thing standing between the project and
# an arm64-labelled bundle full of x86-64 shared objects, and a guard that
# has quietly stopped firing looks exactly like a guard that works.
#
# A guard whose script does not exist yet SKIPs, so this file stays green
# through a half-landed packaging workstream.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$HERE/../lib/assert.sh"
harness_paths

WORK=$(mktemp -d "${TMPDIR:-/tmp}/c4raven-pkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Every invocation below is expected to die in the first few lines. Pin the
# two SHAs so nothing reaches `git ls-remote` against the private repos, and
# run with a short timeout so a guard that has been removed shows up as a
# clear failure rather than a CI job that hangs for an hour.
export SERVER_SHA=0000000000000000000000000000000000000000
export UI_SHA=1111111111111111111111111111111111111111
export PKG_VERSION=0.0.0~unittest

# run_guard SCRIPT [ENV=VAL ...] -- prints "<exit>\n<combined output>"
run_guard() {
  local script=$1; shift
  local out rc
  out=$(cd "$REPO_DIR" && timeout 60 env "$@" bash "$script" 2>&1)
  rc=$?
  printf '%s\n' "$rc"
  printf '%s' "$out"
}
guard_rc()  { printf '%s' "$1" | head -1; }
guard_out() { printf '%s' "$1" | tail -n +2; }

host_deb_arch() {
  if command -v dpkg >/dev/null 2>&1; then dpkg --print-architecture; return; fi
  case "$(uname -m)" in x86_64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo unknown ;; esac
}
HOST=$(host_deb_arch)
case "$HOST" in amd64) OTHER=arm64 ;; arm64) OTHER=amd64 ;; *) OTHER="" ;; esac

# ===========================================================================
echo "== build-offline.sh: the cross-build refusal"
# ===========================================================================
# Two locked dependencies (mutf8 1.0.6 and unishox2-py3 1.0.0) publish no
# wheel for any supported Python on any arch, so they are compiled from sdist,
# and a plain compile is a HOST-arch .so no matter what --platform says.
# ALLOW_CROSS_BUILD=1 cross-compiles them for the target (zig) and checks
# every .so's ELF machine, but cannot import them; a native build can. So a
# cross-build stays opt-in: the default refuses, and CI must build arm64 on
# an arm64 runner, where the bundle gets the full install-and-import check.
if [ ! -f "$REPO_DIR/build-offline.sh" ]; then
  t_no "build-offline.sh exists" "cannot test the cross-build guard without it"
elif [ -z "$OTHER" ]; then
  t_ok "cross-build guard SKIPPED -- this host is $(uname -m), neither amd64 nor arm64"
elif ! command -v dpkg >/dev/null 2>&1; then
  t_ok "cross-build guard SKIPPED -- build-offline.sh needs dpkg to know the host arch"
else
  r=$(run_guard build-offline.sh "TARGET_ARCH=$OTHER")
  rc=$(guard_rc "$r"); out=$(guard_out "$r")
  t_ne "$rc" "0" "build-offline.sh refuses TARGET_ARCH=$OTHER on a $HOST host"
  t_ne "$rc" "124" "the refusal is immediate, not a 60s hang"
  t_has "$out" "mutf8" "the refusal explains WHY (mutf8 has no wheel)"
  t_has "$out" "unishox2-py3" "the refusal names unishox2-py3 too"
  t_has "$out" "$OTHER" "the refusal names the architecture that was asked for"
  t_has "$out" "ALLOW_CROSS_BUILD=1" "the refusal documents its own escape hatch"
  # Nothing may have been produced on the way to refusing.
  t_eq "$(find "$REPO_DIR/build" -maxdepth 1 -name "*$PKG_VERSION*" 2>/dev/null | wc -l)" "0" \
       "the refusal happens before anything is staged under build/"

  # An unsupported arch is a different, equally early refusal.
  r=$(run_guard build-offline.sh "TARGET_ARCH=riscv64")
  t_ne "$(guard_rc "$r")" "0" "build-offline.sh refuses an unsupported TARGET_ARCH"
  t_has "$(guard_out "$r")" "riscv64" "...and names it"

  # The escape hatch must still exist -- but it must NOT be what CI uses.
  t_true "ALLOW_CROSS_BUILD is still honoured as an escape hatch" -- \
    grep -q 'ALLOW_CROSS_BUILD' "$REPO_DIR/build-offline.sh"
  for wf in "$REPO_DIR"/.github/workflows/*.yml; do
    [ -f "$wf" ] || continue
    t_hasnt "$(cat "$wf")" "ALLOW_CROSS_BUILD" \
            "$(basename "$wf") does not set ALLOW_CROSS_BUILD (CI must build arm64 on arm64)"
  done
fi

# ===========================================================================
echo "== build-deb.sh: the payload MANIFEST is the only source of arch"
# ===========================================================================
# build-deb.sh must never infer the architecture from the build host: that is
# precisely how a cross-built payload gets mislabelled. It reads one line out
# of the payload's MANIFEST, and refuses anything it cannot read.
if [ ! -f "$REPO_DIR/build-deb.sh" ]; then
  t_no "build-deb.sh exists" "cannot test the MANIFEST arch guard without it"
else
  mkdir -p "$WORK/empty"
  r=$(run_guard build-deb.sh "OFFLINE_PAYLOAD=$WORK/empty")
  t_ne "$(guard_rc "$r")" "0" "a payload directory with no MANIFEST is refused"
  t_has "$(guard_out "$r")" "not a staged offline payload" "...with a message that says so"

  mkdir -p "$WORK/noarch"
  printf 'c4raven-server 0.0.0 (offline)\nserver deadbeef\n' > "$WORK/noarch/MANIFEST"
  r=$(run_guard build-deb.sh "OFFLINE_PAYLOAD=$WORK/noarch")
  t_ne "$(guard_rc "$r")" "0" "a MANIFEST with no 'arch' line is refused"
  t_has "$(guard_out "$r")" "no 'arch' line" "...naming the missing field"
  t_has "$(guard_out "$r")" "guessing it" \
        "...and explaining that guessing from the build host would mislabel a cross-built payload"

  mkdir -p "$WORK/badarch"
  printf 'arch         sparc64\n' > "$WORK/badarch/MANIFEST"
  r=$(run_guard build-deb.sh "OFFLINE_PAYLOAD=$WORK/badarch")
  t_ne "$(guard_rc "$r")" "0" "a MANIFEST arch with no mediamtx build is refused"
  t_has "$(guard_out "$r")" "sparc64" "...naming the offending arch"

  # The arch is declared but the payload does not actually contain a mediamtx
  # tarball for it -- i.e. a payload assembled for one arch and relabelled.
  mkdir -p "$WORK/mismatch/mediamtx"
  printf 'arch         arm64\n' > "$WORK/mismatch/MANIFEST"
  : > "$WORK/mismatch/mediamtx/mediamtx_v1.9.0_linux_amd64.tar.gz"
  r=$(run_guard build-deb.sh "OFFLINE_PAYLOAD=$WORK/mismatch")
  t_ne "$(guard_rc "$r")" "0" "a payload whose mediamtx tarball is the wrong arch is refused"
  t_has "$(guard_out "$r")" "linux_arm64" "...naming the tarball it expected"
  t_eq "$(find "$REPO_DIR/build" -maxdepth 1 -name "*$PKG_VERSION*" 2>/dev/null | wc -l)" "0" \
       "every MANIFEST refusal happens before build/ is touched"
fi

# ===========================================================================
echo "== build-offline.sh: vendored file: requirements become name==version pins"
# poetry export writes a path dependency as `name @ file:///<build host>/...`;
# that path does not exist on the target. Run the real function, extracted
# from the script, over a requirements file in poetry's exact format.
VF="$WORK/vendor_file_reqs.sh"
[ -f "$REPO_DIR/build-offline.sh" ] && sed -n '/^vendor_file_reqs() {$/,/^}$/p' "$REPO_DIR/build-offline.sh" > "$VF"
if ! [ -s "$VF" ]; then
  t_no "build-offline.sh's vendor_file_reqs could be extracted" \
       "the function was renamed or reshaped; this test can no longer exercise it"
else
  vf_run() {  # vf_run REQS WHEELHOUSE INDEX -- in a subshell, so die only ends it
    ( die() { echo "error: $*" >&2; exit 1; }
      # shellcheck source=/dev/null
      . "$VF"; vendor_file_reqs "$@" ) 2>&1
  }
  mkdir -p "$WORK/vend/src" "$WORK/vend/wh"
  : > "$WORK/vend/src/adsbxcot-6.0.4-py3-none-any.whl"
  : > "$WORK/vend/src/Ai.SCot-7.0.10-py3-none-any.whl"
  M='python_version >= "3.10" and python_version < "3.15"'
  {
    echo "adsbxcot @ file://$WORK/vend/src/adsbxcot-6.0.4-py3-none-any.whl ; $M"
    echo "aiohttp==3.13.3 ; $M"
    echo "ai-scot @ file://$WORK/vend/src/Ai.SCot-7.0.10-py3-none-any.whl"
  } > "$WORK/vend/req.txt"
  if out=$(vf_run "$WORK/vend/req.txt" "$WORK/vend/wh" "$WORK/vend/index.txt"); then
    t_ok "vendor_file_reqs accepts poetry's file: wheel lines"
    t_hasnt "$(cat "$WORK/vend/req.txt")" "file:" "no file: URL is left in the shipped requirements.txt"
    t_eq "$(sed -n 1p "$WORK/vend/req.txt")" "adsbxcot==6.0.4 ; $M" "a file: wheel becomes name==version, marker kept"
    t_eq "$(sed -n 2p "$WORK/vend/req.txt")" "aiohttp==3.13.3 ; $M" "an index requirement passes through unchanged"
    t_eq "$(sed -n 3p "$WORK/vend/req.txt")" "ai-scot==7.0.10" "a line with no marker gets none; a non-normalised wheel name still matches"
    t_true "the vendored wheel is copied into the wheelhouse" test -f "$WORK/vend/wh/adsbxcot-6.0.4-py3-none-any.whl"
    t_eq "$(cat "$WORK/vend/index.txt")" "aiohttp==3.13.3 ; $M" "vendored names are kept out of what pip download fetches from PyPI"
  else
    t_no "vendor_file_reqs accepts poetry's file: wheel lines" "$out"
  fi
  for bad in "sdist:foo @ file://$WORK/vend/src/foo-1.0.tar.gz" \
             "dir:foo @ file://$WORK/vend/src" \
             "platform wheel:foo @ file://$WORK/vend/src/foo-1.0-cp312-cp312-linux_x86_64.whl" \
             "missing wheel:foo @ file://$WORK/vend/src/foo-1.0-py3-none-any.whl" \
             "name mismatch:bar @ file://$WORK/vend/src/adsbxcot-6.0.4-py3-none-any.whl"; do
    echo "${bad#*:}" > "$WORK/vend/bad.txt"
    out=$(vf_run "$WORK/vend/bad.txt" "$WORK/vend/wh" "$WORK/vend/index.txt") \
      && t_no "vendor_file_reqs refuses a ${bad%%:*} file: requirement" "it exited 0: $(cat "$WORK/vend/bad.txt")" \
      || t_has "$out" "error:" "vendor_file_reqs refuses a ${bad%%:*} file: requirement"
  done
fi

# ===========================================================================
echo "== the contract between build-offline.sh and build-deb.sh"
# ===========================================================================
# build-offline.sh writes the line; build-deb.sh parses it with
# `awk '$1 == "arch" {print $2}'`. They are 400 lines apart in two files and
# nothing else checks that they still agree.
if [ -f "$REPO_DIR/build-offline.sh" ] && [ -f "$REPO_DIR/build-deb.sh" ]; then
  line=$(grep -oE '"arch +\$TARGET_ARCH"' "$REPO_DIR/build-offline.sh" | head -1)
  if [ -z "$line" ]; then
    t_no "build-offline.sh writes an 'arch <value>' MANIFEST line" \
         "could not find the echo that writes it -- if its shape changed, build-deb.sh's awk may no longer match"
  else
    t_ok "build-offline.sh writes an 'arch <value>' MANIFEST line"
    for a in amd64 arm64; do
      printf 'c4raven-server 0.0.0 (offline)\narch         %s\nbuilt        now\n' "$a" > "$WORK/m"
      t_eq "$(awk '$1 == "arch" { print $2; exit }' "$WORK/m")" "$a" \
           "build-deb.sh's awk reads '$a' back out of a MANIFEST in build-offline.sh's exact format"
    done
  fi
  t_true "build-deb.sh parses the arch with the documented awk expression" -- \
    grep -q "awk '\$1 == \"arch\"" "$REPO_DIR/build-deb.sh"
fi

# ===========================================================================
echo "== build-rpm.sh guards"
# ===========================================================================
if [ ! -f "$REPO_DIR/rpm/build-rpm.sh" ]; then
  t_ok "build-rpm.sh guards SKIPPED -- rpm/build-rpm.sh does not exist yet"
else
  # RPM reserves '-' as the Version-Release separator, so a version like
  # 2.2.3-rc1 produces a package that cannot be upgraded past.
  r=$(run_guard rpm/build-rpm.sh "PKG_VERSION=2.2.3-rc1")
  t_ne "$(guard_rc "$r")" "0" "build-rpm.sh refuses a PKG_VERSION containing '-'"
  t_has "$(guard_out "$r")" "-" "...with an explanation"

  r=$(run_guard rpm/build-rpm.sh "PKG_VERSION=")
  t_ne "$(guard_rc "$r")" "0" "build-rpm.sh refuses an empty PKG_VERSION"
fi

# ===========================================================================
echo "== the RPM spec and debian/control describe the same package"
# ===========================================================================
SPEC="$REPO_DIR/rpm/c4raven-server.spec"
CTRL="$REPO_DIR/debian/control"
if [ -f "$SPEC" ] && [ -f "$CTRL" ]; then
  t_eq "$(awk -F': *' '/^Name:/{print $2; exit}' "$SPEC")" \
       "$(awk -F': *' '/^Package:/{print $2; exit}' "$CTRL")" \
       "the RPM Name and the .deb Package are the same package name"
  # The units are the contract verify.sh asserts on. Both packagings must
  # ship all five, or the Rocky cell fails in a way that looks like a
  # runtime bug rather than a packaging omission.
  for u in raven cot_parser eud_handler eud_handler_ssl mediamtx; do
    t_has "$(cat "$SPEC")" "$u.service" "the spec references $u.service"
    [ -f "$REPO_DIR/debian/$u.service" ] \
      && t_ok "debian/$u.service exists" \
      || t_no "debian/$u.service exists"
  done
fi

# ===========================================================================
echo "== debian/control: the trailing Description paragraph must stay last"
# ===========================================================================
# build-deb.sh's offline rewrite drops EVERYTHING from the " Building the UI
# needs" marker to EOF and appends its own paragraph. That makes the marker's
# position -- not just its existence -- load-bearing, and nothing in the file
# itself says so to a reader adding a field at the bottom.
#
# build-deb.sh's own END block catches a marker that has been reworded away,
# and tests/lint.sh catches it being deleted. Neither catches the other half:
# a field or paragraph appended AFTER the marker is silently dropped from the
# offline control file only, so the online .deb keeps it, the offline .deb
# loses it, and both builds exit 0. That is the case below.
CTRL="$REPO_DIR/debian/control"
DEB="$REPO_DIR/build-deb.sh"
if [ ! -f "$CTRL" ] || [ ! -f "$DEB" ]; then
  t_ok "control ordering guard SKIPPED -- debian/control or build-deb.sh is absent"
else
  # Read the marker out of build-deb.sh rather than hard-coding it here, so
  # that rewording it on one side only is what fails, not this test rotting.
  MARKER=$(sed -n "s/^ *\/\^\( Building[^/]*\)\/ *{ *skip = 1 *}.*/\1/p" "$DEB" | head -1)
  if [ -z "$MARKER" ]; then
    t_no "build-deb.sh still has a '{ skip = 1 }' marker rule" \
         "the offline Description rewrite was restructured -- re-point this test at the new mechanism"
  else
    t_ok "build-deb.sh's marker rule found: [$MARKER]"

    # Count only real occurrences: start-of-line, and below Package: (the
    # header comment above the source stanza quotes the marker on purpose,
    # and build-deb.sh strips everything above Package: before the awk runs).
    n=$(awk -v m="$MARKER" '/^Package:/{f=1} f && index($0,m)==1 {c++} END{print c+0}' "$CTRL")
    t_eq "$n" "1" \
         "the marker appears exactly once as a real line in debian/control's binary stanza"

    # The binary stanza is all build-deb.sh keeps; a marker above Package:
    # would make the awk drop the entire binary stanza.
    t_eq "$(awk -v m="$MARKER" 'index($0,m)==1{print NR; exit}' "$CTRL" | \
            awk -v p="$(awk '/^Package:/{print NR; exit}' "$CTRL")" '{print ($1>p)?"after":"before"}')" \
         "after" "the marker sits inside the binary stanza, below Package:"

    # The whole point: nothing but Description continuation lines may follow
    # the marker. A continuation starts with a space; a field does not.
    stray=$(awk -v m="$MARKER" 'index($0,m)==1{s=1} s && /^[A-Za-z][A-Za-z0-9-]*:/ {print}' "$CTRL")
    t_eq "$stray" "" \
         "no control FIELD appears after the marker (build-deb.sh would drop it from the offline .deb only)"

    nonblank=$(awk -v m="$MARKER" 'index($0,m)==1{s=1} s && NF && !/^ / {print}' "$CTRL")
    t_eq "$nonblank" "" \
         "every line after the marker is a Description continuation, so dropping them loses no metadata"

    # The marker paragraph really is the LAST paragraph: no further content
    # can be appended below it without tripping one of the two checks above.
    t_eq "$(tail -1 "$CTRL" | cut -c1)" " " \
         "debian/control's final line is a Description continuation, not a new field"
  fi

  # --- exercise build-deb.sh's actual awk, extracted from the script -------
  # Running the real program (not a copy) is what makes this a guard rather
  # than a second implementation that can drift from the first.
  awkprog="$WORK/rewrite.awk"
  sed -n "/^  awk -v arch=\"\$ARCH\" '/,/^    }' /p" "$DEB" \
    | sed -e "1s/^.*awk -v arch=\"\$ARCH\" '//" -e "\$s/' \".*\$//" > "$awkprog"
  binstanza="$WORK/control.bin"
  awk '/^Package:/{f=1} f' "$CTRL" > "$binstanza"

  if ! [ -s "$awkprog" ] || ! grep -q 'skip' "$awkprog"; then
    t_no "build-deb.sh's offline rewrite awk could be extracted" \
         "the awk invocation was reshaped; this test can no longer exercise the real program"
  else
    out="$WORK/control.out"
    if awk -v arch=arm64 -f "$awkprog" "$binstanza" > "$out" 2>"$WORK/err"; then
      t_ok "the real rewrite awk succeeds on the current debian/control"
      t_has "$(cat "$out")" "Architecture: arm64" "the rewrite stamps the arch it was given"
      t_has "$(cat "$out")" "no internet access" \
            "the rewrite appends the offline paragraph build-deb.sh then greps for"
      t_hasnt "$(cat "$out")" "NodeSource" "the online-only Node.js prose is gone from the offline control"
      t_hasnt "$(cat "$out")" "Architecture: all" "the stale 'Architecture: all' prose is gone too"
      # Mandatory binary-stanza fields must survive the rewrite.
      for f in Package: Architecture: Description: Depends:; do
        t_has "$(cat "$out")" "$f" "the rewrite keeps the $f field"
      done
      # Build-time-only deps must be gone -- the same thing build-deb.sh
      # re-checks at build time, asserted here before anyone builds.
      t_eq "$(grep -cE '^ (git|build-essential|python3-pip|python3-dev|nodejs)' "$out")" "0" \
           "the rewrite drops every build-time-only dependency"
    else
      t_no "the real rewrite awk succeeds on the current debian/control" \
           "$(head -2 "$WORK/err" | tr '\n' ' ')"
    fi

    # The END guard must still fire when the marker is gone. If this stops
    # failing, the offline build will happily ship a stale Description.
    grep -vF -- "${MARKER:- Building the UI needs}" "$binstanza" > "$WORK/control.nomarker"
    if awk -v arch=arm64 -f "$awkprog" "$WORK/control.nomarker" >/dev/null 2>"$WORK/err2"; then
      t_no "the rewrite refuses a control file with no marker" \
           "it exited 0 and silently shipped the online Description paragraphs"
    else
      t_ok "the rewrite refuses a control file with no marker"
      t_has "$(cat "$WORK/err2")" "LAST Description block" \
            "...and the error explains the ordering requirement"
    fi
  fi

  # Each spelling the Depends filter targets must match a real line, or the
  # filter is silently a no-op and the offline .deb keeps a build-only dep.
  for d in git build-essential python3-pip python3-dev nodejs; do
    grep -qE "^ ${d}[^,]*,\$" "$CTRL" \
      && t_ok "the Depends filter's '$d' pattern matches a real line in debian/control" \
      || t_no "the Depends filter's '$d' pattern matches a real line in debian/control" \
              "build-deb.sh filters for it; if the spelling changed the filter quietly does nothing"
  done
fi

# RabbitMQ 4.x (every EL install) denies transient non-exclusive queues by
# default and cot_parser crash-loops on the 541 it gets back. Every install
# path must re-permit them -- and only on 4+, since 3.12's schema has no such
# key and the broker would refuse to start on it.
for f in install.sh rpm/configure.sh debian/c4raven-server.postinst; do
  t_true "$f re-permits transient_nonexcl_queues for RabbitMQ 4+" -- \
    grep -q 'deprecated_features.permit.transient_nonexcl_queues = true' "$REPO_DIR/$f"
  t_true "$f gates the permit on RabbitMQ major >= 4" -- \
    grep -q '"$RABBIT_MAJOR" -ge 4' "$REPO_DIR/$f"
done
t_hasnt "$(cat "$REPO_DIR/rabbitmq.conf")" "deprecated_features" \
  "the shared rabbitmq.conf stays loadable by RabbitMQ 3.12 (no deprecated_features key)"

t_summary
