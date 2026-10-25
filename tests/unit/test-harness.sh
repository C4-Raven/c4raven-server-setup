#!/bin/bash
# Self-tests for the harness itself (tests/lib/common.sh and the files the
# matrix dispatches to).
#
# A verification harness that has quietly stopped verifying is worse than no
# harness: every cell goes green because every cell skipped. These checks are
# the cheap guard against that -- they cost milliseconds and they catch the
# two ways it actually happens, which are "a method was added to the matrix
# and nobody wrote its script" and "a file lost its executable bit".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$HERE/../lib/assert.sh"
harness_paths

# ===========================================================================
echo "== matrix definition"
# ===========================================================================
t_eq "$EXIT_SKIP" "77" "EXIT_SKIP is autotools' 77 (what run-matrix.sh and tests/unit/run.sh both key off)"
t_ne "$ALL_DISTROS" "" "ALL_DISTROS is not empty"
t_ne "$ALL_ARCHES" ""  "ALL_ARCHES is not empty"
t_ne "$ALL_METHODS" "" "ALL_METHODS is not empty"

t_eq "$(methods_for_distro ubuntu-24.04)" "install-sh deb deb-offline" \
     "ubuntu runs the three Debian-family methods"
t_eq "$(methods_for_distro rocky-9)" "install-sh rpm" \
     "rocky runs install.sh and the rpm, and no .deb path"
t_false "methods_for_distro rejects an unknown distro loudly" -- methods_for_distro freebsd-14

# Every method named in the matrix must have a script, and every script must
# be named in the matrix. Either half missing is a silent hole.
for m in $ALL_METHODS; do
  [ -f "$TESTS_DIR/methods/$m.sh" ] \
    && t_ok "tests/methods/$m.sh exists for method '$m'" \
    || t_no "tests/methods/$m.sh exists for method '$m'" "ALL_METHODS names it; nothing implements it"
done
for f in "$TESTS_DIR"/methods/*.sh; do
  [ -f "$f" ] || continue
  m=$(basename "$f" .sh)
  case " $ALL_METHODS " in
    *" $m "*) t_ok "method script $m.sh is reachable from ALL_METHODS" ;;
    *) t_no "method script $m.sh is reachable from ALL_METHODS" "it will never run" ;;
  esac
done

# Every method must be claimed by at least one distro, or it is dead code.
for m in $ALL_METHODS; do
  claimed=0
  for d in $ALL_DISTROS; do
    case " $(methods_for_distro "$d") " in *" $m "*) claimed=1 ;; esac
  done
  [ "$claimed" = 1 ] \
    && t_ok "method '$m' is claimed by at least one distro" \
    || t_no "method '$m' is claimed by at least one distro" "no distro in ALL_DISTROS runs it"
done

# Every distro in the matrix needs an image to run in.
for d in $ALL_DISTROS; do
  [ -f "$TESTS_DIR/images/Dockerfile.$d" ] \
    && t_ok "tests/images/Dockerfile.$d exists" \
    || t_no "tests/images/Dockerfile.$d exists" "the $d cells would all skip"
done

# ===========================================================================
echo "== host_arch"
# ===========================================================================
t_match "$(host_arch)" '^(amd64|arm64|unsupported)$' "host_arch returns a dpkg-style name"
case "$(uname -m)" in
  x86_64)  t_eq "$(host_arch)" amd64 "x86_64 host -> amd64" ;;
  aarch64) t_eq "$(host_arch)" arm64 "aarch64 host -> arm64" ;;
  *)       t_ok "host_arch on $(uname -m) (no expectation pinned)" ;;
esac
# The names host_arch produces must be the names the matrix uses, or every
# cell silently decides it is cross-architecture and skips.
case " $ALL_ARCHES " in
  *" $(host_arch) "*) t_ok "host_arch's vocabulary matches ALL_ARCHES" ;;
  *) t_no "host_arch's vocabulary matches ALL_ARCHES" "host_arch=$(host_arch), ALL_ARCHES='$ALL_ARCHES'" ;;
esac

# ===========================================================================
echo "== container run flags"
# ===========================================================================
# These are the flags that make systemd work as PID 1. Losing one does not
# produce an error -- it produces a container where systemd boots into
# "degraded" and half the units never start, which reads as an install bug.
flags=$(engine_run_flags docker amd64 | tr '\n' ' ')
for f in --detach --privileged --cgroupns=host "--tmpfs /run" \
         "/sys/fs/cgroup:/sys/fs/cgroup:rw" "--platform linux/amd64"; do
  t_has "$flags" "$f" "docker run flags include $f"
done
t_has "$(engine_run_flags podman arm64 | tr '\n' ' ')" "--systemd=always" \
      "podman is told --systemd=always (docker infers it from the image CMD)"
t_has "$(engine_run_flags docker arm64 | tr '\n' ' ')" "--platform linux/arm64" \
      "the requested architecture reaches --platform"
t_hasnt "$(engine_run_flags docker amd64 | tr '\n' ' ')" "--systemd" \
        "docker is not given podman's flag"

# ===========================================================================
echo "== script discovery for the lint tier"
# ===========================================================================
scripts=$(repo_shell_scripts "$REPO_DIR")
t_ne "$scripts" "" "repo_shell_scripts finds something"
for f in install.sh build-deb.sh update.sh tests/verify.sh tests/lint.sh; do
  [ -f "$REPO_DIR/$f" ] || continue
  t_has "$scripts" "$REPO_DIR/$f" "lint sees $f"
done
# The maintainer scripts carry no .sh suffix and are the ones most likely to
# be skipped by a naive *.sh glob -- they are also the ones that run as root
# on a customer's machine.
for f in debian/c4raven-server.postinst debian/c4raven-server.prerm \
         debian/c4raven-server.postrm debian/c4raven-server.config \
         offline/install.sh rpm/c4raven-setup; do
  [ -f "$REPO_DIR/$f" ] || continue
  t_has "$scripts" "$REPO_DIR/$f" "lint sees the suffix-less maintainer script $f"
done
t_hasnt "$scripts" "$REPO_DIR/build/" "lint ignores build/ artifacts"
t_hasnt "$scripts" ".service" "lint does not try to shellcheck a systemd unit"
t_hasnt "$scripts" ".yml" "lint does not try to shellcheck a YAML file"

# ===========================================================================
echo "== the harness's own files"
# ===========================================================================
for f in lint.sh run-matrix.sh verify.sh unit/run.sh; do
  [ -x "$TESTS_DIR/$f" ] \
    && t_ok "tests/$f is executable" \
    || t_no "tests/$f is executable" "chmod +x it, or CI invokes it through bash by accident"
done
for f in "$TESTS_DIR"/methods/*.sh "$TESTS_DIR"/unit/test-*.sh; do
  [ -f "$f" ] || continue
  head -1 "$f" | grep -q '^#!' \
    && t_ok "$(basename "$f") has a shebang" \
    || t_no "$(basename "$f") has a shebang"
done

# run-matrix.sh dispatches to tests/methods/$method.sh inside the container
# and reads EXIT_SKIP back out of it. Each method script must therefore agree
# on the number, and must print a "SKIP:" line run-matrix.sh can quote.
for f in "$TESTS_DIR"/methods/*.sh; do
  [ -f "$f" ] || continue
  grep -q 'EXIT_SKIP=77' "$f" \
    && t_ok "$(basename "$f") uses the same skip code as the runner" \
    || t_no "$(basename "$f") uses the same skip code as the runner" "run-matrix.sh only recognises 77"
  if grep -q "exit \"\$EXIT_SKIP\"" "$f"; then
    grep -q '^[[:space:]]*echo "SKIP:' "$f" \
      && t_ok "$(basename "$f") prints a SKIP: reason the matrix summary can quote" \
      || t_no "$(basename "$f") prints a SKIP: reason the matrix summary can quote"
  fi
done

t_summary
