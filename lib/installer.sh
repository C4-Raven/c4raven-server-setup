# shellcheck shell=bash
# Sourced, never executed.
#
# C4 Raven TAK Server -- install-time helpers shared by install.sh, the .deb
# postinst and the RPM's configure.sh. lib/distro.sh answers "which distro
# is this"; this file answers "can this install work here, and how do we get
# through the flaky parts of it":
#
#   ih_retry          retry a command with exponential backoff (network steps)
#   ih_container_kind is this a container, and which kind
#   ih_systemd_booted is systemd PID 1 (sd_booted(3)'s test)
#   ih_require_systemd  fail early, with the docker/podman flags, if not
#   ih_uri_password   the password out of a SQLAlchemy/libpq URI
#   ih_env_value      KEY's value in a KEY=value file (.raven-secrets.env)
#   ih_git_checkout_ok  is DIR a usable git checkout (not a half-done clone)
#   ih_clone_repo     clone, or re-clone over a broken partial clone
#   ih_own_logs       pre-create/own the service log files (error-log API)
#   ih_heads_match    are the DB's alembic versions exactly the code's heads
#   ih_heads_py       Python that prints the code's alembic heads
#   ih_print_recovery the "what now" text shown when an install stops
#
# Like lib/distro.sh, nothing here changes the system when sourced, every
# function is safe under `set -euo pipefail`, and none of them prompt.
#
# Paths can be re-rooted with IH_ROOT (the unit tests point it at a fixture
# tree); leave it unset in real use.

# ---------------------------------------------------------------------------
# ih_retry [-n ATTEMPTS] [-d FIRST_DELAY] [--] CMD...
#
# Runs CMD until it succeeds, up to ATTEMPTS times (default 5, or
# $IH_RETRY_ATTEMPTS), sleeping FIRST_DELAY seconds (default 3, or
# $IH_RETRY_DELAY) after the first failure and doubling each time, capped at
# 60s. Returns CMD's last exit status. For network steps only (apt/dnf
# mirrors, GitHub, PyPI, the npm registry): a deterministic failure just
# costs a minute of retries before it is reported the same way.
#
# CMD may be a shell function. Note that inside it `set -e` is suspended
# (it runs as the left side of `&&`), so a function wrapped here must check
# its own steps -- `run_as_app "a && b"` style, not a multi-line body.
# ---------------------------------------------------------------------------
ih_retry() {
  local attempts="${IH_RETRY_ATTEMPTS:-5}" delay="${IH_RETRY_DELAY:-3}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -n) attempts=$2; shift 2 ;;
      -d) delay=$2; shift 2 ;;
      --) shift; break ;;
      *)  break ;;
    esac
  done
  local i=1 rc=0
  while :; do
    "$@" && return 0
    rc=$?
    if [ "$i" -ge "$attempts" ]; then
      echo "retry: giving up after $attempts attempts (exit $rc): $*" >&2
      return "$rc"
    fi
    echo "retry: attempt $i/$attempts failed (exit $rc); trying again in ${delay}s: $*" >&2
    sleep "$delay"
    i=$((i + 1))
    delay=$((delay * 2))
    [ "$delay" -gt 60 ] && delay=60
  done
}

# ---------------------------------------------------------------------------
# Containers and systemd
# ---------------------------------------------------------------------------

# Prints the container technology (docker, podman, lxc, wsl, container...)
# and returns 0 when running inside one; prints nothing and returns 1 on a
# VM or bare metal.
ih_container_kind() {
  local root="${IH_ROOT:-}" kind=""
  if [ -z "$root" ] && command -v systemd-detect-virt >/dev/null 2>&1; then
    kind=$(systemd-detect-virt --container 2>/dev/null || true)
    if [ -n "$kind" ] && [ "$kind" != none ]; then
      printf '%s\n' "$kind"
      return 0
    fi
  fi
  if [ -f "$root/.dockerenv" ]; then
    echo docker; return 0
  fi
  if [ -f "$root/run/.containerenv" ]; then
    echo podman; return 0
  fi
  # $container is what systemd itself reads; docker images that run systemd
  # (ours included) set it, and podman/lxc set it in PID 1's environment.
  kind="${IH_CONTAINER_ENV-${container:-}}"
  if [ -n "$kind" ]; then
    printf '%s\n' "$kind"; return 0
  fi
  if [ -r "$root/proc/1/cgroup" ] \
     && grep -qaE '/(docker|kubepods|containerd|libpod|lxc)[/.-]' "$root/proc/1/cgroup"; then
    echo container; return 0
  fi
  if [ -r "$root/proc/sys/kernel/osrelease" ] \
     && grep -qiE 'microsoft|wsl' "$root/proc/sys/kernel/osrelease"; then
    echo wsl; return 0
  fi
  return 1
}

# sd_booted(3): systemd is the running init iff /run/systemd/system exists.
# Also look at PID 1's name when we can see it, because a container image
# that ships a stale /run/systemd/system in a layer would otherwise pass.
# (hidepid can hide /proc/1 from a non-root user; then the directory decides.)
ih_systemd_booted() {
  local root="${IH_ROOT:-}" comm=""
  [ -d "$root/run/systemd/system" ] || return 1
  if [ -r "$root/proc/1/comm" ]; then
    comm=$(cat "$root/proc/1/comm" 2>/dev/null || true)
    case "$comm" in
      ""|systemd|init) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# Fails (returns 1) with an explanation when systemd is not PID 1. Every
# install path creates and starts systemd units, enables PostgreSQL,
# RabbitMQ and nginx through systemctl, and waits on them -- without systemd
# it gets a long way in and then dies, leaving a half-installed box. Say so
# before anything is touched.
#
# Set RAVEN_SKIP_SYSTEMD_CHECK=1 to bypass (you get to keep the pieces).
ih_require_systemd() {
  local kind pid1=""
  [ "${RAVEN_SKIP_SYSTEMD_CHECK:-0}" = 1 ] && return 0
  ih_systemd_booted && return 0
  pid1=$(cat "${IH_ROOT:-}/proc/1/comm" 2>/dev/null || echo unknown)
  echo "This installer needs systemd running as PID 1 (PID 1 here is '$pid1')." >&2
  echo "It installs PostgreSQL, RabbitMQ, nginx and the Raven services as systemd" >&2
  echo "units and starts them with systemctl; without systemd it would fail halfway." >&2
  echo >&2
  if kind=$(ih_container_kind); then
    if [ "$kind" = wsl ]; then
      echo "This looks like WSL. Turn systemd on in /etc/wsl.conf:" >&2
      echo "    [boot]" >&2
      echo "    systemd=true" >&2
      echo "then run 'wsl --shutdown' from Windows, reopen the distro and re-run." >&2
    else
      echo "You are inside a container ($kind) that was not started with systemd as" >&2
      echo "its init. Start one that is -- an image with systemd installed, run as:" >&2
      echo >&2
      echo "    docker run -d --name raven --privileged --cgroupns=host \\" >&2
      echo "      --tmpfs /run --tmpfs /run/lock \\" >&2
      echo "      -v /sys/fs/cgroup:/sys/fs/cgroup:rw \\" >&2
      echo "      -p 80:80 -p 443:443 -p 8443:8443 -p 8446:8446 -p 8089:8089 \\" >&2
      echo "      <image-with-systemd> /sbin/init" >&2
      echo >&2
      echo "(podman: add --systemd=always). c4raven-server-setup's" >&2
      echo "tests/images/Dockerfile.ubuntu-24.04 and Dockerfile.rocky-9 are ready-made" >&2
      echo "images. Then 'docker exec -it raven bash', create a sudo-capable user, and" >&2
      echo "run the installer as that user." >&2
    fi
  else
    echo "systemd does not appear to be running on this machine. Boot it with" >&2
    echo "systemd as init (the default on every supported distro) and re-run." >&2
  fi
  echo "(To try anyway: RAVEN_SKIP_SYSTEMD_CHECK=1.)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Small parsers
# ---------------------------------------------------------------------------

# ih_uri_password URI -- prints the password of
# scheme://user:password@host/db and returns 0; returns 1 when there is none.
# The installers only ever write hex passwords, so no percent-decoding.
ih_uri_password() {
  local u="${1:-}" cred
  case "$u" in *://*@*) ;; *) return 1 ;; esac
  u=${u#*://}
  cred=${u%%@*}
  case "$cred" in
    *:*) printf '%s' "${cred#*:}" ;;
    *) return 1 ;;
  esac
}

# ih_uri_user URI -- the user part of scheme://user:password@host/db.
ih_uri_user() {
  local u="${1:-}" cred
  case "$u" in *://*@*) ;; *) return 1 ;; esac
  u=${u#*://}
  cred=${u%%@*}
  printf '%s' "${cred%%:*}"
}

# ih_env_value FILE KEY -- value of the last KEY=... line in FILE (quotes
# stripped); returns 1 when FILE or KEY is missing. Reads FILE directly:
# the caller wraps it in sudo when the file is not readable as itself.
ih_env_value() {
  local file="$1" key="$2" line
  [ -r "$file" ] || return 1
  line=$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1) || return 1
  [ -n "$line" ] || return 1
  line=${line#*=}
  line=${line%\"}; line=${line#\"}
  line=${line%\'}; line=${line#\'}
  printf '%s' "$line"
}

# ---------------------------------------------------------------------------
# Git checkouts
# ---------------------------------------------------------------------------

# ih_git_checkout_ok RUNNER DIR -- 0 if DIR is a git checkout with a HEAD.
# RUNNER runs one shell string as the owner of DIR (install.sh's
# run_as_app); a clone killed by a network drop leaves a directory with a
# .git that has no commits, which a plain `test -d` would happily accept.
ih_git_checkout_ok() {
  local runner="$1" dir="$2"
  "$runner" "git -C '$dir' rev-parse --verify --quiet HEAD >/dev/null"
}

# ih_clone_repo RUNNER URL DIR -- clone URL into DIR unless a usable
# checkout is already there (kept as-is: never pulled, never reset -- the
# updater owns updates). A broken partial clone is moved aside to
# DIR.broken.<epoch>, not deleted, and the clone retried with backoff.
ih_clone_repo() {
  local runner="$1" url="$2" dir="$3" aside
  if "$runner" "test -e '$dir'"; then
    if ih_git_checkout_ok "$runner" "$dir"; then
      return 0
    fi
    aside="$dir.broken.$(date +%s)"
    echo "$dir exists but is not a complete git checkout (an interrupted clone?);" >&2
    echo "moving it aside to $aside and cloning again." >&2
    "$runner" "mv '$dir' '$aside'" || return 1
  fi
  ih_retry "$runner" "rm -rf '$dir.partial' && git clone --quiet '$url' '$dir.partial' && mv '$dir.partial' '$dir'"
}

# ---------------------------------------------------------------------------
# Service log files
# ---------------------------------------------------------------------------

# ih_own_logs LOG_DIR APP_USER -- make sure raven.log exists and every log in
# LOG_DIR belongs to APP_USER. The units append their stdout/stderr there
# (StandardOutput=append:), and systemd -- PID 1, i.e. root -- creates a
# missing file itself, root-owned. Since 2.3.0 the server's error-log API
# reads these files as the app user, and skips any it cannot read. Run
# before the services are (re)started. Needs root or sudo.
ih_own_logs() {
  local dir="$1" user="$2" s=""
  [ "$(id -u)" -eq 0 ] || s=sudo
  $s install -d -o "$user" -g "$user" -m 750 "$dir" || return 1
  if ! $s test -e "$dir/raven.log"; then
    $s install -o "$user" -g "$user" -m 640 /dev/null "$dir/raven.log" || return 1
  fi
  $s find "$dir" -maxdepth 1 -type f -name '*.log*' ! -user "$user" \
    -exec chown "$user:$user" {} + || return 1
}

# ---------------------------------------------------------------------------
# Migrations
# ---------------------------------------------------------------------------

# ih_heads_match "DB_VERSIONS" "CODE_HEADS" -- both whitespace-separated
# alembic revision ids. 0 when they are the same non-empty set (the DB is
# at head), 1 otherwise. Order and duplicates do not matter.
ih_heads_match() {
  local a b
  a=$(printf '%s\n' "$1" | tr -s ' \t' '\n\n' | sed '/^$/d' | sort -u)
  b=$(printf '%s\n' "$2" | tr -s ' \t' '\n\n' | sed '/^$/d' | sort -u)
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# ih_heads_py -- prints a Python program that prints the alembic head(s) of
# the raven package it is run with (space-separated). Pipe it into the
# backend's own interpreter, as the app user:
#     ih_heads_py | run_as_app "cd .../c4raven-server && .venv/bin/python -"
# It finds raven/migrations from the installed package (the same directory
# init_extensions() upgrades from), so it works for the Poetry checkout and
# the offline .deb's plain venv alike, and it never loads env.py or the app.
ih_heads_py() {
  cat <<'PYEOF'
import os
import raven
from alembic.config import Config
from alembic.script import ScriptDirectory
cfg = Config()
cfg.set_main_option("script_location", os.path.join(os.path.dirname(os.path.realpath(raven.__file__)), "migrations"))
print(" ".join(ScriptDirectory.from_config(cfg).get_heads()))
PYEOF
}

# ---------------------------------------------------------------------------
# What to do when an install stops
# ---------------------------------------------------------------------------

# ih_print_recovery RERUN_HINT -- RERUN_HINT is the command that resumes
# this install path (install.sh: the curl|bash line; .deb: dpkg --configure
# -a; RPM: c4raven-setup).
ih_print_recovery() {
  local rerun="$1"
  cat >&2 <<EOF

Everything done so far has been kept: the database and its users, the
certificate authority, config.yml and the source checkouts are never
recreated on a re-run. Fix the cause shown above, then resume with:

    $rerun

If the web UI comes up but nobody can log in, or raven.service is missing,
the updater's recovery tools diagnose and finish a half-done install:

    git clone https://github.com/C4-Raven/c4raven-updater.git
    cd c4raven-updater
    ./diagnose-login.sh      # says what is wrong
    ./finish-install.sh      # redoes the service setup steps

Backend log: /opt/raven/data/logs/raven.log
EOF
}
