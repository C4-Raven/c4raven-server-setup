#!/bin/bash
# Tier 2: run the installer end to end in a systemd container, then assert.
#
#   tests/run-matrix.sh                                  # every cell valid on this host
#   tests/run-matrix.sh --distro rocky-9 --method rpm
#   tests/run-matrix.sh --arch arm64 --emulated          # qemu; smoke only, see README
#   tests/run-matrix.sh --list                           # show the matrix and exit
#   tests/run-matrix.sh --keep                           # leave containers up to poke at
#   tests/run-matrix.sh --reboot-check                   # also restart and re-verify
#
# A cell whose inputs do not exist yet (lib/distro.sh, rpm/build-rpm.sh, an
# offline bundle, credentials for the private repos) is SKIPPED with the
# reason printed, never failed. Only a real regression goes red.
#
# This script needs docker (or podman) and will start privileged containers.
# It does not touch the host outside the container runtime and
# tests/.artifacts/.
set -uo pipefail

# shellcheck source=tests/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
harness_paths

DISTROS=""; ARCHES=""; METHODS=""
KEEP=0; REBOOT_CHECK=0; EMULATED=0; LIST=0
BUNDLE_TAR=""
TIMEOUT_MIN="${TIMEOUT_MIN:-60}"

usage() { sed -n '2,24p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --distro)  DISTROS="${DISTROS} $2"; shift 2 ;;
    --arch)    ARCHES="${ARCHES} $2";   shift 2 ;;
    --method)  METHODS="${METHODS} $2"; shift 2 ;;
    --bundle)  BUNDLE_TAR=$2; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    --reboot-check) REBOOT_CHECK=1; shift ;;
    --emulated) EMULATED=1; shift ;;
    --list)    LIST=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

[ -n "$DISTROS" ] || DISTROS=$ALL_DISTROS
[ -n "$ARCHES" ]  || ARCHES=$(host_arch)
[ -n "$METHODS" ] || METHODS=$ALL_METHODS

HOST_ARCH=$(host_arch)
[ "$HOST_ARCH" = unsupported ] && die "unsupported host architecture: $(uname -m)"

# ---------------------------------------------------------------------------
# Enumerate the matrix
# ---------------------------------------------------------------------------
CELLS=()
for d in $DISTROS; do
  valid=$(methods_for_distro "$d")
  for a in $ARCHES; do
    for m in $METHODS; do
      case " $valid " in *" $m "*) CELLS+=("$d/$a/$m") ;; esac
    done
  done
done
[ "${#CELLS[@]}" -gt 0 ] || die "no valid cells for distro='$DISTROS' arch='$ARCHES' method='$METHODS'"

if [ "$LIST" = 1 ]; then
  printf 'host arch: %s\n\n' "$HOST_ARCH"
  printf '%-14s %-6s %-12s %s\n' DISTRO ARCH METHOD "HOW IT RUNS HERE"
  for c in "${CELLS[@]}"; do
    IFS=/ read -r d a m <<<"$c"
    if [ "$a" = "$HOST_ARCH" ]; then how="native"
    elif [ "$EMULATED" = 1 ]; then how="qemu (smoke only)"
    else how="skipped (pass --emulated, or use a native $a runner)"
    fi
    printf '%-14s %-6s %-12s %s\n' "$d" "$a" "$m" "$how"
  done
  exit 0
fi

ENGINE=$(detect_engine)
log "container engine: $ENGINE ($("$ENGINE" --version 2>/dev/null | head -1))"

ARTIFACTS="$TESTS_DIR/.artifacts"
rm -rf "$ARTIFACTS"; mkdir -p "$ARTIFACTS"

# ---------------------------------------------------------------------------
# Emulation preflight
# ---------------------------------------------------------------------------
binfmt_ready() {
  case "$1" in
    arm64) [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] ;;
    amd64) [ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ] ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# One cell
# ---------------------------------------------------------------------------
run_cell() {
  local distro=$1 arch=$2 method=$3
  local tag="$distro/$arch/$method"
  local name="c4raven-test-${distro}-${arch}-${method}"
  local out="$ARTIFACTS/${distro}_${arch}_${method}"
  mkdir -p "$out"

  if [ "$arch" != "$HOST_ARCH" ]; then
    if [ "$EMULATED" != 1 ]; then
      skip_cell "$tag" "host is $HOST_ARCH; run this on a native $arch machine (CI: runs-on ubuntu-24.04-arm) or pass --emulated for the smoke tier"
      return
    fi
    if ! binfmt_ready "$arch"; then
      skip_cell "$tag" "no binfmt_misc handler for $arch -- register one with: $ENGINE run --privileged --rm tonistiigi/binfmt --install all"
      return
    fi
    warn "$tag: running under qemu emulation. See tests/README.md -- a full install is NOT expected to pass here (Node and the Erlang JIT are the usual casualties); treat any result as smoke only."
  fi

  local dockerfile="$TESTS_DIR/images/Dockerfile.$distro"
  [ -f "$dockerfile" ] || { skip_cell "$tag" "no $dockerfile"; return; }

  log "$tag: building image"
  if ! "$ENGINE" build --platform "linux/$arch" \
        -t "c4raven-test:${distro}-${arch}" \
        -f "$dockerfile" "$TESTS_DIR/images" > "$out/image-build.log" 2>&1; then
    tail -40 "$out/image-build.log" >&2
    fail_cell "$tag" "image build failed (see $out/image-build.log)"
    return
  fi

  "$ENGINE" rm -f "$name" >/dev/null 2>&1

  log "$tag: booting systemd"
  local flags=()
  mapfile -t flags < <(engine_run_flags "$ENGINE" "$arch")
  if ! "$ENGINE" run "${flags[@]}" --name "$name" \
        "c4raven-test:${distro}-${arch}" > "$out/run.log" 2>&1; then
    cat "$out/run.log" >&2
    fail_cell "$tag" "container would not start"
    return
  fi

  local state="" i
  for i in $(seq 1 120); do
    state=$("$ENGINE" exec "$name" systemctl is-system-running 2>/dev/null | tr -d '\r')
    case "$state" in running|degraded) break ;; esac
    sleep 1
  done
  case "$state" in
    running|degraded) note "$tag: systemd is $state after ${i}s" ;;
    *) "$ENGINE" logs "$name" > "$out/pid1.log" 2>&1
       fail_cell "$tag" "systemd never came up inside the container (last state: '${state:-none}'; see $out/pid1.log)"
       teardown "$name"; return ;;
  esac

  log "$tag: copying the working tree in"
  "$ENGINE" exec "$name" mkdir -p /opt/harness/repo
  if ! tar -C "$REPO_DIR" --exclude=./.git --exclude=./build --exclude=./tests/.artifacts \
         -cf - . | "$ENGINE" cp - "$name:/opt/harness/repo"; then
    fail_cell "$tag" "could not copy the repo into the container"
    teardown "$name"; return
  fi

  # c4raven-server and c4raven-ui are private, and every online install path
  # clones them -- as the `raven` user, from inside the container. Write the
  # credential into /etc/gitconfig directly (git itself is not installed
  # yet at this point) so it applies to every user. The container is
  # thrown away at the end of the cell.
  if [ -n "${GH_TOKEN:-}" ]; then
    "$ENGINE" exec --env "TOK=$GH_TOKEN" "$name" sh -c '
      printf "[url \"https://x-access-token:%s@github.com/\"]\n\tinsteadOf = https://github.com/\n" "$TOK" > /etc/gitconfig
      chmod 644 /etc/gitconfig' >/dev/null 2>&1 \
      || warn "$tag: could not install git credentials in the container"
  fi

  local bundle_env=()
  if [ -n "$BUNDLE_TAR" ]; then
    "$ENGINE" cp "$BUNDLE_TAR" "$name:/opt/harness/bundle.tar"
    bundle_env=(--env "BUNDLE_TAR=/opt/harness/bundle.tar")
  fi

  log "$tag: installing (method: $method)"
  local rc=0
  timeout "${TIMEOUT_MIN}m" \
    "$ENGINE" exec \
      --env "DISTRO=$distro" --env "ARCH=$arch" --env REPO=/opt/harness/repo \
      --env "PKG_VERSION=${PKG_VERSION:-0.0.0}" --env GIT_TERMINAL_PROMPT=0 \
      --env "SERVER_SHA=${SERVER_SHA:-}" --env "UI_SHA=${UI_SHA:-}" \
      "${bundle_env[@]}" \
      "$name" bash "/opt/harness/repo/tests/methods/$method.sh" \
    2>&1 | tee "$out/install.log"
  rc=${PIPESTATUS[0]}

  if [ "$rc" = "$EXIT_SKIP" ]; then
    skip_cell "$tag" "$(grep -m1 '^SKIP:' "$out/install.log" | sed 's/^SKIP: //')"
    teardown "$name"; return
  fi
  if [ "$rc" = 124 ]; then
    collect "$name" "$out"
    fail_cell "$tag" "install timed out after ${TIMEOUT_MIN}m (see $out/)"
    teardown "$name"; return
  fi
  if [ "$rc" != 0 ]; then
    collect "$name" "$out"
    fail_cell "$tag" "install failed with exit $rc (see $out/install.log)"
    teardown "$name"; return
  fi

  log "$tag: verifying"
  if ! "$ENGINE" exec "$name" bash /opt/harness/repo/tests/verify.sh \
         --expect-arch "$arch" > "$out/verify.log" 2>&1; then
    cat "$out/verify.log"
    collect "$name" "$out"
    fail_cell "$tag" "assertions failed (see $out/verify.log)"
    teardown "$name"; return
  fi
  tail -5 "$out/verify.log"

  if [ "$REBOOT_CHECK" = 1 ]; then
    # `systemctl enable` is only half the promise; this is the other half.
    # Restarting PID 1 is as close to a reboot as a container gets, and it
    # is the cheapest way to catch a unit that only ever ran because the
    # installer started it by hand.
    log "$tag: restarting the container and re-verifying (boot persistence)"
    "$ENGINE" restart "$name" >/dev/null 2>&1
    for i in $(seq 1 180); do
      state=$("$ENGINE" exec "$name" systemctl is-system-running 2>/dev/null | tr -d '\r')
      case "$state" in running|degraded) break ;; esac
      sleep 1
    done
    sleep 20   # let the units finish their own startup, not just systemd's
    if ! "$ENGINE" exec "$name" bash /opt/harness/repo/tests/verify.sh \
           --expect-arch "$arch" --skip-login > "$out/verify-reboot.log" 2>&1; then
      cat "$out/verify-reboot.log"
      collect "$name" "$out"
      fail_cell "$tag" "the stack does not come back after a reboot (see $out/verify-reboot.log)"
      teardown "$name"; return
    fi
    note "$tag: survives a reboot"
  fi

  pass_cell "$tag"
  teardown "$name"
}

collect() {
  local name=$1 out=$2
  "$ENGINE" exec "$name" journalctl -b --no-pager > "$out/journal.log" 2>&1 || true
  "$ENGINE" exec "$name" systemctl list-units --state=failed --no-pager \
    > "$out/failed-units.log" 2>&1 || true
  "$ENGINE" exec "$name" sh -c 'cat /opt/raven/data/logs/raven.log 2>/dev/null' \
    > "$out/raven.log" 2>&1 || true
  "$ENGINE" exec "$name" sh -c 'cat /var/log/nginx/error.log 2>/dev/null' \
    > "$out/nginx-error.log" 2>&1 || true
}

teardown() {
  if [ "$KEEP" = 1 ]; then
    note "--keep: container $1 left running ($ENGINE exec -it $1 bash)"
  else
    "$ENGINE" rm -f "$1" >/dev/null 2>&1 || true
  fi
}

RESULTS=()
pass_cell() { RESULTS+=("PASS|$1|"); printf '%sPASS%s %s\n' "$C_GRN" "$C_OFF" "$1" >&2; }
fail_cell() { RESULTS+=("FAIL|$1|$2"); printf '%sFAIL%s %s -- %s\n' "$C_RED" "$C_OFF" "$1" "$2" >&2; }
skip_cell() { RESULTS+=("SKIP|$1|$2"); printf '%sSKIP%s %s -- %s\n' "$C_YEL" "$C_OFF" "$1" "$2" >&2; }

for c in "${CELLS[@]}"; do
  IFS=/ read -r d a m <<<"$c"
  echo
  printf '%s================ %s ================%s\n' "$C_BLU" "$c" "$C_OFF"
  run_cell "$d" "$a" "$m"
done

# ---------------------------------------------------------------------------
echo
printf '%sMatrix summary%s\n' "$C_BLU" "$C_OFF"
nfail=0; npass=0; nskip=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r status cell reason <<<"$r"
  case "$status" in
    PASS) npass=$((npass + 1)); printf '  %sPASS%s %-34s\n' "$C_GRN" "$C_OFF" "$cell" ;;
    FAIL) nfail=$((nfail + 1)); printf '  %sFAIL%s %-34s %s\n' "$C_RED" "$C_OFF" "$cell" "$reason" ;;
    SKIP) nskip=$((nskip + 1)); printf '  %sSKIP%s %-34s %s\n' "$C_YEL" "$C_OFF" "$cell" "$reason" ;;
  esac
done
printf '\n%d passed, %d failed, %d skipped. Logs: %s\n' "$npass" "$nfail" "$nskip" "$ARTIFACTS"
[ "$nfail" -eq 0 ] || exit 1
# REQUIRE_PASS=1 (CI, when it has the token) makes that a failure instead:
# a job that verified nothing must not show green.
[ "$npass" -gt 0 ] || {
  warn "every cell was skipped -- nothing was actually verified"
  [ -n "${REQUIRE_PASS:-}" ] && exit 1
  exit 0
}
