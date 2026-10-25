#!/bin/bash
# A hermetic sandbox for unit-testing lib/distro.sh without a container.
#
# detect_distro() reads exactly two things about the machine -- /etc/os-release
# and `uname -m` -- and everything else in lib/distro.sh is a pure function of
# the variables it sets. That makes the whole shim testable with two stubs and
# no root, no container, no package manager and no network, which is why this
# is the cheapest tier in the harness and the one that runs on every push.
#
# Two mechanisms:
#
#   1. A *hermetic PATH*. Each probe runs with PATH pointing only at a handful
#      of symlinks to real coreutils plus whatever stubs the test asked for.
#      Nothing else is reachable. That matters more than it sounds: half of
#      distro.sh's behaviour is `command -v firewall-cmd`, `command -v ufw`,
#      `command -v getenforce`, `command -v semanage`. Run those against the
#      developer's real PATH and the test passes or fails depending on whose
#      laptop it is. Here, "this tool is absent" is something the test states,
#      not something it inherits.
#
#   2. A *patched copy* of lib/distro.sh in which the single literal
#      `/etc/os-release` becomes `${OS_RELEASE_FILE:-/etc/os-release}`. That is
#      the one thing a test cannot stub with PATH, since it is an absolute path
#      read by the `.` builtin. The substitution is asserted to apply exactly
#      once; if lib/distro.sh ever starts reading os-release some other way,
#      this tier SKIPs loudly instead of silently testing a stale shape.
#
# Nothing in this file touches anything outside $SANDBOX.

# shellcheck disable=SC2034   # consumers use these
SANDBOX=""
HERMETIC_PATH=""
DISTRO_SHIM=""
CALL_LOG=""

# The real tools a probe is allowed to see. Anything NOT in this list is
# absent inside a probe unless a stub provides it -- on purpose.
_SANDBOX_REAL_TOOLS="sh bash sed grep egrep awk cat cut tr head tail sort uniq
                     id mktemp rm ls mkdir ln printf basename dirname test env
                     touch wc expr find xargs chmod stat date echo"

sandbox_init() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/c4raven-unit.XXXXXX") || return 1
  mkdir -p "$SANDBOX/sys" "$SANDBOX/stub" "$SANDBOX/os" "$SANDBOX/extra"
  CALL_LOG="$SANDBOX/calls.log"
  : > "$CALL_LOG"

  local t p
  for t in $_SANDBOX_REAL_TOOLS; do
    # type -P, not `command -v`: it ignores aliases, functions and builtins
    # and returns only a real executable path, which is all we can symlink.
    p=$(type -P "$t" 2>/dev/null) || continue
    [ -n "$p" ] && ln -sf "$p" "$SANDBOX/sys/$t"
  done

  SANDBOX_REAL_UNAME=$(type -P uname)
  SANDBOX_REAL_NODE=$(type -P node || true)
  export SANDBOX_REAL_UNAME SANDBOX_REAL_NODE

  # `uname -m` is the other half of detect_distro's input.
  sandbox_stub uname <<EOF
#!/bin/sh
case "\${1:-}" in
  -m) echo "\${STUB_UNAME_M:-x86_64}" ;;
  *)  exec "$SANDBOX_REAL_UNAME" "\$@" ;;
esac
EOF

  HERMETIC_PATH="$SANDBOX/stub:$SANDBOX/sys"
}

sandbox_cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; return 0; }

# sandbox_stub NAME            -- body on stdin
# sandbox_stub NAME --in DIR   -- into an opt-in directory instead of the
#                                 always-on one, so a test can say "this
#                                 machine has firewalld" and the next one
#                                 can say it does not.
sandbox_stub() {
  local name=$1 dir="$SANDBOX/stub"
  if [ "${2:-}" = "--in" ]; then dir="$SANDBOX/extra/$3"; mkdir -p "$dir"; fi
  cat > "$dir/$name"
  chmod +x "$dir/$name"
}

# sandbox_recorder NAME [DIR] [EXIT]
# A stub that writes "<name> <args...>" to the call log and exits EXIT (0).
# This is how the mutating helpers are tested: we never run apt, dnf, ln,
# systemctl or semanage -- we assert the exact command line they were given.
sandbox_recorder() {
  local name=$1 dir=${2:-} rc=${3:-0} target="$SANDBOX/stub"
  [ -n "$dir" ] && { target="$SANDBOX/extra/$dir"; mkdir -p "$target"; }
  cat > "$target/$name" <<EOF
#!/bin/sh
printf '%s' "$name" >> "$CALL_LOG"
for a in "\$@"; do printf ' %s' "\$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
exit $rc
EOF
  chmod +x "$target/$name"
}

sandbox_log_reset() { : > "$CALL_LOG"; }
sandbox_log()       { cat "$CALL_LOG"; }

# ---------------------------------------------------------------------------
# os-release fixtures
# ---------------------------------------------------------------------------
# Values copied from the real files on each distro -- in particular ID_LIKE,
# which is what detect_distro's family match keys off and is the field most
# often guessed wrong.
os_fixture() {
  local name=$1
  case "$name" in
    ubuntu-24.04) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="Ubuntu"
VERSION="24.04.1 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
VERSION_ID="24.04"
EOF
      ;;
    ubuntu-22.04) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="Ubuntu"
VERSION="22.04.5 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
VERSION_ID="22.04"
EOF
      ;;
    debian-12) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="Debian GNU/Linux"
ID=debian
VERSION_ID="12"
VERSION="12 (bookworm)"
EOF
      ;;
    rocky-9) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="Rocky Linux"
VERSION="9.5 (Blue Onyx)"
ID="rocky"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.5"
PLATFORM_ID="platform:el9"
EOF
      ;;
    rocky-8) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="Rocky Linux"
VERSION="8.10 (Green Obsidian)"
ID="rocky"
ID_LIKE="rhel centos fedora"
VERSION_ID="8.10"
PLATFORM_ID="platform:el8"
EOF
      ;;
    almalinux-9) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="AlmaLinux"
VERSION="9.5 (Teal Serval)"
ID="almalinux"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.5"
EOF
      ;;
    rhel-9) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="Red Hat Enterprise Linux"
VERSION="9.4 (Plow)"
ID="rhel"
ID_LIKE="fedora"
VERSION_ID="9.4"
EOF
      ;;
    centos-9) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="CentOS Stream"
VERSION="9"
ID="centos"
ID_LIKE="rhel fedora"
VERSION_ID="9"
EOF
      ;;
    fedora-41) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="Fedora Linux"
VERSION="41 (Server Edition)"
ID=fedora
VERSION_ID=41
EOF
      ;;
    alpine-3.20) cat > "$SANDBOX/os/$name" <<'EOF'
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.20.3
EOF
      ;;
    empty) : > "$SANDBOX/os/$name" ;;
    *) echo "sandbox: no os-release fixture named '$name'" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# The patched copy of lib/distro.sh
# ---------------------------------------------------------------------------
# Returns 1 (with a message on stderr) when the shim is missing or has grown a
# shape this file does not know how to patch. Callers turn that into a SKIP.
sandbox_distro_shim() {
  local src="$REPO_DIR/lib/distro.sh" n
  if [ ! -f "$src" ]; then
    echo "lib/distro.sh does not exist yet" >&2
    return 1
  fi
  # Count only real code, not the comments that explain it. There is normally
  # more than one reference (a `[ -r ... ]` guard and the `.` itself); all of
  # them get redirected. Zero means detect_distro has started getting its
  # facts from somewhere this sandbox does not model, and the honest answer
  # is to skip rather than to test a shape that no longer exists.
  n=$(grep -vE '^[[:space:]]*#' "$src" | grep -c '/etc/os-release' || true)
  if [ "${n:-0}" -lt 1 ]; then
    echo "lib/distro.sh no longer reads /etc/os-release in any code line; this sandbox has nothing to redirect (update tests/lib/sandbox.sh for its new shape)" >&2
    return 1
  fi
  DISTRO_SHIM="$SANDBOX/distro.sh"
  sed 's#/etc/os-release#${OS_RELEASE_FILE:-/etc/os-release}#g' "$src" > "$DISTRO_SHIM"
  grep -q 'OS_RELEASE_FILE' "$DISTRO_SHIM" || { echo "patching lib/distro.sh failed" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# probe FIXTURE MACHINE SNIPPET
#
# Sources the patched shim in a fresh subshell under `set -euo pipefail` (which
# is how install.sh sources it, and so is itself part of the contract), runs
# detect_distro against the given os-release fixture and `uname -m` value, then
# evaluates SNIPPET and prints whatever it prints.
#
# PROBE_PATH -- colon-separated opt-in stub directory names, e.g.
#               PROBE_PATH=sudo:firewalld probe rocky-9 x86_64 'firewall_open 443/tcp'
# ---------------------------------------------------------------------------
probe() {
  local fixture=$1 machine=$2 snippet=$3
  local extra="" d
  if [ -n "${PROBE_PATH:-}" ]; then
    local IFS=:
    for d in $PROBE_PATH; do extra="$extra$SANDBOX/extra/$d:"; done
  fi
  (
    set -euo pipefail
    export OS_RELEASE_FILE="$SANDBOX/os/$fixture"
    export STUB_UNAME_M="$machine"
    export CALL_LOG SANDBOX
    PATH="${extra}${HERMETIC_PATH}"
    export PATH
    # shellcheck source=/dev/null
    . "$DISTRO_SHIM"
    detect_distro
    eval "$snippet"
  )
}

# Same, but returns the exit status of the snippet instead of its output --
# for the predicates (distro_supported, selinux_enforcing, node_ok, ...).
probe_rc() { probe "$@" >/dev/null 2>&1; }
