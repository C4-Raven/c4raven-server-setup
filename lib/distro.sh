# shellcheck shell=bash
# Sourced, never executed, so no shebang -- and the variables detect_distro
# sets are all read by the caller, not here.
# shellcheck disable=SC2034
#
# C4 Raven TAK Server -- distro/architecture shim.
#
# Sourced by install.sh (and by the RPM's scriptlets) so that everything else
# can say "install these packages", "open this port" or "drop the nginx site
# here" without caring whether it's running on Ubuntu/Debian or Rocky/RHEL, on
# amd64 or arm64.
#
#   . lib/distro.sh
#   detect_distro
#   pkg_refresh
#   pkg_install nginx openssl
#
# Nothing in this file changes the system on its own: detect_distro() only
# reads. Every function below is safe to source under `set -euo pipefail` and
# safe to run twice.
#
# Supported today:
#   debian family -- Ubuntu 22.04/24.04, Debian 12  (amd64, arm64)
#   rhel   family -- Rocky/Alma/RHEL 9              (x86_64, aarch64)

# Run privileged commands through sudo when we're not already root: install.sh
# runs as an ordinary sudo-capable user, but RPM/DEB scriptlets run as root on
# systems that may not even have sudo installed.
# Note that every caller passes a plain argv -- no `VAR=value cmd` prefixes
# and no sudo flags. Those only work when sudo is really in front: as root
# `"$@"` runs the first word as the command name, so `_sudo FOO=1 apt ...`
# would look for a program literally called "FOO=1". Use `_sudo env FOO=1 ...`
# instead, which behaves the same either way.
_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Same, but keeps the invoking user's environment (`sudo -E`) -- the
# NodeSource bootstrap scripts need http_proxy/https_proxy to survive if the
# box has one. As root there is no sudo to strip anything, so it's a no-op.
_sudo_E() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -E "$@"
  fi
}

# ---------------------------------------------------------------------------
# detect_distro -- sets everything else in this file depends on.
#
#   DISTRO_FAMILY     debian | rhel
#   DISTRO_ID         ubuntu, debian, rocky, rhel, almalinux, ...
#   DISTRO_NAME       pretty name, for messages
#   DISTRO_VERSION_ID 24.04, 9.5, ...
#   DISTRO_MAJOR      24, 9, ...
#   ARCH_DEB          amd64 | arm64 | armhf      (dpkg/debian spelling)
#   ARCH_MTX          amd64 | arm64 | armv7      (mediamtx release asset)
#   PKG_MGR           apt | dnf
#   PYTHON_BIN        python3 | python3.12       (see below)
#   NGINX_*           see below
#   PG_SERVICE, PG_DATA_DIR, RABBIT_SERVICE
# ---------------------------------------------------------------------------
detect_distro() {
  # Guarded: a bare `. /etc/os-release` on a box that hasn't got one (some
  # minimal container images) fails, and under `set -e` that kills the whole
  # installer with no message at all. Falling through leaves DISTRO_ID
  # "unknown" -> DISTRO_FAMILY "unknown", which distro_supported() reports.
  #
  # Caveat for callers: this *does* dump os-release's own variables (NAME,
  # VERSION, ID, CPE_NAME, HOME_URL, ...) into the caller's scope. Nothing in
  # install.sh or rpm/configure.sh uses those names today, but don't start.
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
  fi
  DISTRO_ID="${ID:-unknown}"
  DISTRO_NAME="${NAME:-$DISTRO_ID}"
  DISTRO_VERSION_ID="${VERSION_ID:-}"
  DISTRO_MAJOR="${DISTRO_VERSION_ID%%.*}"

  case " $DISTRO_ID ${ID_LIKE:-} " in
    *" ubuntu "*|*" debian "*) DISTRO_FAMILY=debian ;;
    *" rhel "*|*" fedora "*|*" centos "*) DISTRO_FAMILY=rhel ;;
    *) DISTRO_FAMILY=unknown ;;
  esac

  # ARCH_MTX names this machine the way mediamtx names its release tarballs
  # (mediamtx_v<ver>_linux_{amd64,arm64,armv6,armv7}.tar.gz); ARCH_DEB is the
  # same split in dpkg's spelling, for .deb names and NodeSource paths.
  #
  # install.sh:275 feeds ARCH_MTX straight into `lastversion --filter
  # '~*linux_$ARCH_MTX'`, so a wrong answer here downloads a binary that
  # unpacks cleanly and then dies with "Exec format error" the first time
  # mediamtx.service starts. This is the same mapping, with the same two
  # rules, as debian/c4raven-server.postinst:
  #
  #   1. Ask dpkg when dpkg is there. A 32-bit armhf userland on a 64-bit
  #      kernel -- the stock Raspberry Pi OS layout -- has `uname -m` report
  #      aarch64, and the arm64 build will not run on it. dpkg knows what the
  #      userland is; uname only knows what the kernel is. EL has no dpkg and
  #      no 32-bit EL9, so the question does not arise there.
  #   2. No catch-all. The old `*) ARCH_MTX=armv7` handed riscv64, ppc64el and
  #      s390x a 32-bit ARM binary. mediamtx publishes nothing for any of
  #      them, so say so now rather than at first boot. Reported by returning
  #      non-zero at the end of this function, once every other variable has
  #      been set -- callers that only want the nginx/pkg layout (see
  #      rpm/configure.sh, which runs `detect_distro || true`) still get it.
  local _dpkg_arch="" _arch_bad=""
  if command -v dpkg >/dev/null 2>&1; then
    _dpkg_arch=$(dpkg --print-architecture 2>/dev/null) || _dpkg_arch=""
  fi
  if [ -n "$_dpkg_arch" ]; then
    # dpkg answered, so that answer is the whole story -- do not second-guess
    # it with uname, which is exactly the disagreement rule 1 exists to settle.
    case "$_dpkg_arch" in
      amd64) ARCH_DEB=amd64; ARCH_MTX=amd64 ;;
      arm64) ARCH_DEB=arm64; ARCH_MTX=arm64 ;;
      armhf) ARCH_DEB=armhf; ARCH_MTX=armv7 ;;
      armel) ARCH_DEB=armel; ARCH_MTX=armv6 ;;
      *)     ARCH_DEB=""; ARCH_MTX=""; _arch_bad="$_dpkg_arch" ;;
    esac
  else
    # No dpkg: the kernel's answer is all EL ever has.
    case "$(uname -m)" in
      x86_64)        ARCH_DEB=amd64; ARCH_MTX=amd64 ;;
      aarch64|arm64) ARCH_DEB=arm64; ARCH_MTX=arm64 ;;
      # armv8l is a 32-bit userland on a 64-bit core -- the armv7 build.
      armv7l|armv8l) ARCH_DEB=armhf; ARCH_MTX=armv7 ;;
      armv6l)        ARCH_DEB=armel; ARCH_MTX=armv6 ;;
      *)             ARCH_DEB=""; ARCH_MTX=""; _arch_bad="$(uname -m)" ;;
    esac
  fi

  case "${DISTRO_FAMILY:-}" in
    rhel)
      PKG_MGR=dnf
      # c4raven-server's pyproject pins python = ">=3.10, <3.15" and EL9's
      # `python3` is 3.9 -- poetry pointed at it fails the constraint outright.
      # python3.12 is a plain (non-modular) AppStream package on both x86_64
      # and aarch64, so it is the one everything python-ish must be run with.
      PYTHON_BIN=python3.12
      NGINX_CONF=/etc/nginx/nginx.conf
      # EL nginx has no sites-available/sites-enabled at all: everything in
      # /etc/nginx/conf.d/*.conf is included from inside http{} directly, so
      # there is nothing to symlink and the filenames must end in .conf.
      NGINX_SITES_DIR=/etc/nginx/conf.d
      NGINX_SITES_ENABLED_DIR=""
      # No EL equivalent exists for the stream block, so we make one and point
      # our own `stream { include ...; }` at it (see nginx_stream_include).
      NGINX_STREAMS_DIR=/etc/nginx/stream.d
      NGINX_STREAMS_ENABLED_DIR=""
      NGINX_CONF_SUFFIX=".conf"
      NGINX_USER=nginx
      PG_SERVICE=postgresql
      PG_DATA_DIR=/var/lib/pgsql/data
      RABBIT_SERVICE=rabbitmq-server
      ;;
    *)
      # debian, and anything unrecognised: Ubuntu's layout is the historical
      # default and the one the nginx_configs/ files were written for.
      PKG_MGR=apt
      PYTHON_BIN=python3
      NGINX_CONF=/etc/nginx/nginx.conf
      NGINX_SITES_DIR=/etc/nginx/sites-available
      NGINX_SITES_ENABLED_DIR=/etc/nginx/sites-enabled
      NGINX_STREAMS_DIR=/etc/nginx/streams-available
      NGINX_STREAMS_ENABLED_DIR=/etc/nginx/streams-enabled
      NGINX_CONF_SUFFIX=""
      NGINX_USER=www-data
      PG_SERVICE=postgresql
      PG_DATA_DIR=""   # Debian keeps per-cluster dirs; nothing here needs it
      RABBIT_SERVICE=rabbitmq-server
      ;;
  esac

  if [ -n "$_arch_bad" ]; then
    echo "distro.sh: mediamtx publishes no Linux build for $_arch_bad --" >&2
    echo "  video streaming cannot be installed on this architecture." >&2
    return 1
  fi
  return 0
}

# True when this is a combination we actually test. Anything else still
# installs, but the caller should warn first.
distro_supported() {
  case "${DISTRO_FAMILY:-}" in
    debian) [ "${DISTRO_ID:-}" = ubuntu ] || [ "${DISTRO_ID:-}" = debian ] ;;
    rhel)   [ "${DISTRO_MAJOR:-0}" -ge 9 ] 2>/dev/null ;;
    *)      return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

# Refresh metadata and bring the system up to date -- same intent on both
# families (apt update && apt upgrade).
pkg_refresh() {
  case "${DISTRO_FAMILY:-}" in
    rhel) _sudo dnf -y upgrade --refresh ;;
    # NEEDRESTART_MODE=a: never stop to ask which services to restart, which
    # would read from the piped script and hang the install.
    *)    _sudo env DEBIAN_FRONTEND=noninteractive apt update && _sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt upgrade -y ;;
  esac
}

pkg_install() {
  case "${DISTRO_FAMILY:-}" in
    rhel) _sudo dnf install -y "$@" ;;
    *)    _sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y "$@" ;;
  esac
}

# Like pkg_install, but for packages the install can survive without (see
# ffmpeg-free / postgis on EL).
#
# NOTE FOR CALLERS: returning non-zero does NOT make this non-fatal on its
# own. Under `set -e` a bare `pkg_install_optional foo` still aborts the
# caller exactly like pkg_install would -- the name is the only difference.
# The call site has to neutralise it:
#
#     pkg_install_optional ffmpeg-free || warn "no ffmpeg: thumbnails off"
#
# It prints its own warning so a skipped package is never silent.
pkg_install_optional() {
  if ! case "${DISTRO_FAMILY:-}" in
         rhel) _sudo dnf install -y "$@" ;;
         *)    _sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y "$@" ;;
       esac
  then
    echo "distro.sh: optional package(s) not installed: $*" >&2
    return 1
  fi
}

pkg_installed() {
  case "${DISTRO_FAMILY:-}" in
    rhel) rpm -q "$1" >/dev/null 2>&1 ;;
    *)    dpkg -s "$1" >/dev/null 2>&1 ;;
  esac
}

# ---------------------------------------------------------------------------
# nginx layout helpers
# ---------------------------------------------------------------------------

# Absolute path of the site/stream config named $1, with the suffix this
# distro's include glob requires.
nginx_site_file()   { printf '%s/%s%s' "$NGINX_SITES_DIR" "$1" "$NGINX_CONF_SUFFIX"; }
nginx_stream_file() { printf '%s/%s%s' "$NGINX_STREAMS_DIR" "$1" "$NGINX_CONF_SUFFIX"; }

# The glob our `stream { include ...; }` block in nginx.conf points at.
nginx_stream_include() {
  if [ -n "$NGINX_STREAMS_ENABLED_DIR" ]; then
    printf '%s/*' "$NGINX_STREAMS_ENABLED_DIR"
  else
    printf '%s/*%s' "$NGINX_STREAMS_DIR" "${NGINX_CONF_SUFFIX:-}"
  fi
}

# Enable a site/stream. On Debian that's the sites-enabled symlink; on EL the
# file is already inside an included directory, so there is nothing to do.
nginx_enable_site() {
  [ -n "$NGINX_SITES_ENABLED_DIR" ] || return 0
  _sudo ln -sf "$(nginx_site_file "$1")" "$NGINX_SITES_ENABLED_DIR/"
}
nginx_enable_stream() {
  [ -n "$NGINX_STREAMS_ENABLED_DIR" ] || return 0
  _sudo ln -sf "$(nginx_stream_file "$1")" "$NGINX_STREAMS_ENABLED_DIR/"
}

# The inverse of writing a site file + nginx_enable_site: remove both. On EL
# removing the conf.d file is the whole job; on Debian the sites-enabled
# symlink goes too, so nginx is not left with a dangling include. Safe to run
# when neither exists.
nginx_remove_site() {
  if [ -n "$NGINX_SITES_ENABLED_DIR" ]; then
    _sudo rm -f "$NGINX_SITES_ENABLED_DIR/$1"
  fi
  _sudo rm -f "$(nginx_site_file "$1")"
}

# Get the stock distro welcome page out of the way of raven_http.
#
# Debian ships it as a file in sites-enabled, so clearing that directory is
# enough (and is what install.sh has always done). EL has no sites-enabled:
# its welcome page is a `listen 80 default_server` block written *inline* in
# nginx.conf, serving /usr/share/nginx/html. Left there it answers every
# port-80 request whose Host doesn't match -- which is all of them, since
# raven_http matches on `server_name raven_8080` -- instead of raven_http's
# redirect to HTTPS. Comment it out once, reversibly, keeping a backup.
nginx_disable_default_site() {
  if [ -n "$NGINX_SITES_ENABLED_DIR" ]; then
    _sudo rm -f "$NGINX_SITES_ENABLED_DIR"/*
    return 0
  fi
  grep -q '/usr/share/nginx/html' "$NGINX_CONF" 2>/dev/null || return 0
  if grep -q 'c4raven: stock default_server disabled' "$NGINX_CONF" 2>/dev/null; then
    return 0
  fi

  # Brace-matching in python rather than sed: the block spans lines and
  # nginx.conf's exact wording has changed between EL point releases.
  local tmp
  tmp=$(mktemp)
  if ! "${PYTHON_BIN:-python3}" - "$NGINX_CONF" > "$tmp" << 'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
hit = src.find('/usr/share/nginx/html')
# The *keyword* that opens the block, not just the substring: a plain
# rfind('server') lands on the `server_name _;` line inside it and the
# brace match below then runs off the end, leaving nginx.conf unbalanced.
opens = [m for m in re.finditer(r'\bserver\s*\{', src) if m.start() < hit] if hit != -1 else []
start = opens[-1].start() if opens else -1
end = None
if start != -1:
    depth = 0
    for j in range(src.index('{', start), len(src)):
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
            if depth == 0:
                end = j + 1
                break
if end is None:
    sys.stdout.write(src)
else:
    commented = '\n'.join('#' + line for line in src[start:end].split('\n'))
    sys.stdout.write(src[:start]
                     + '# c4raven: stock default_server disabled (raven_http owns port 80)\n'
                     + commented + src[end:])
PYEOF
  then
    rm -f "$tmp"
    return 0
  fi
  # Only touch nginx.conf once we have a complete rewrite in hand, and keep
  # the original next to it so the change can be undone by hand.
  if [ -s "$tmp" ] && ! cmp -s "$tmp" "$NGINX_CONF"; then
    _sudo cp -a "$NGINX_CONF" "$NGINX_CONF.c4raven.bak"
    _sudo cp "$tmp" "$NGINX_CONF"
    # This is the one place the installer rewrites a file it did not author,
    # by brace-matching text whose wording changes between EL point releases.
    # If the result does not parse, put the original back rather than leaving
    # a box whose nginx will not start -- and leave no marker comment behind,
    # so a later run with a fixed matcher tries again.
    if command -v nginx >/dev/null 2>&1 && ! _sudo nginx -t >/dev/null 2>&1; then
      _sudo cp -a "$NGINX_CONF.c4raven.bak" "$NGINX_CONF"
      _sudo rm -f "$NGINX_CONF.c4raven.bak"
      rm -f "$tmp"
      echo "distro.sh: could not disable nginx's stock default_server (the" >&2
      echo "  rewrite did not pass 'nginx -t'); $NGINX_CONF left untouched." >&2
      echo "  Comment out the 'server { listen 80 default_server; ... }' block" >&2
      echo "  in it by hand, or raven_http will not answer on port 80." >&2
      return 1
    fi
  fi
  rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# firewall_open 443/tcp 8189/udp ...
#
# A no-op unless a firewall is actually running, which is the normal case on
# Ubuntu Server (ufw ships disabled) and never the case in a container. Rocky
# runs firewalld enforcing by default, where the whole stack is unreachable
# until these are opened.
#
# This only ever *adds* allow rules. It will not enable a firewall that is
# switched off -- turning ufw on mid-install would drop the SSH session the
# installer is running in.
# ---------------------------------------------------------------------------
firewall_open() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    local p
    for p in "$@"; do
      _sudo firewall-cmd --permanent --add-port="$p" >/dev/null || true
    done
    _sudo firewall-cmd --reload >/dev/null || true
    return 0
  fi
  if command -v ufw >/dev/null 2>&1; then
    # NOT `ufw status | head -1 | grep -q active`. That is wrong twice over:
    #   - "Status: inactive" contains the substring "active", so a disabled
    #     ufw was read as enabled; and
    #   - under `set -o pipefail` head can close the pipe before ufw finishes
    #     writing, killing it with SIGPIPE and failing the test even when it
    #     did match (the same trap as the `tr ... | head -c` note in
    #     install.sh).
    # A command substitution reads the whole output, so neither can happen.
    local st
    st=$(_sudo ufw status 2>/dev/null) || st=""
    case "$st" in
      "Status: active"*)
        local p
        for p in "$@"; do
          # ufw wants 443/tcp too, same spelling.
          _sudo ufw allow "$p" >/dev/null || true
        done
        ;;
    esac
    return 0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# SELinux
#
# Rocky/RHEL ship targeted policy in enforcing mode. Three things bite us:
#
#   1. nginx (httpd_t) may not open outbound sockets at all unless
#      httpd_can_network_connect is on -- without it every proxy_pass to
#      127.0.0.1:8081 / :8888 / :8889 and every stream proxy returns 502 while
#      the backend itself tests perfectly healthy on localhost.
#   2. nginx may only bind ports labelled http_port_t. 80/443/8443 already are;
#      8080, 8446 and the TLS media proxies (8322 rtsps, 1936 rtmps,
#      8883 mqtts) are not.
#   3. Files only get the right label if something sets it. A webroot created
#      under /var/www inherits var_t from its parent at creation time rather
#      than the httpd_sys_content_t the policy maps it to, so nginx 403s every
#      asset until it's relabelled -- and the same is true again after every
#      rsync of a new UI build.
#
# All of this is a no-op on Debian and on any EL box with SELinux disabled.
# ---------------------------------------------------------------------------
selinux_enforcing() {
  [ "${DISTRO_FAMILY:-}" = rhel ] || return 1
  command -v getenforce >/dev/null 2>&1 || return 1
  [ "$(getenforce 2>/dev/null)" != "Disabled" ]
}

selinux_fixup() {
  selinux_enforcing || return 0

  _sudo setsebool -P httpd_can_network_connect 1 || true

  if command -v semanage >/dev/null 2>&1; then
    local p
    for p in 8080 8443 8446 8322 1936 8883; do
      _sudo semanage port -a -t http_port_t -p tcp "$p" 2>/dev/null \
        || _sudo semanage port -m -t http_port_t -p tcp "$p" 2>/dev/null \
        || true
    done
  fi

  [ -n "${WEBROOT:-}" ] && selinux_fix_webroot "$WEBROOT"
  return 0
}

# Label (and re-label) the directory nginx serves the UI out of.
selinux_fix_webroot() {
  local dir="$1"
  selinux_enforcing || return 0
  [ -d "$dir" ] || return 0
  if command -v semanage >/dev/null 2>&1; then
    _sudo semanage fcontext -a -t httpd_sys_content_t "${dir}(/.*)?" 2>/dev/null \
      || _sudo semanage fcontext -m -t httpd_sys_content_t "${dir}(/.*)?" 2>/dev/null \
      || true
  fi
  command -v restorecon >/dev/null 2>&1 && _sudo restorecon -R "$dir" || true
  return 0
}

# nginx terminates TLS with the CA's own server cert/key, which live under the
# app user's home in /opt -- not a place httpd_t is granted by default. cert_t
# is, and new files the CA writes into the directory later inherit it.
selinux_fix_certs() {
  local dir="$1"
  selinux_enforcing || return 0
  [ -d "$dir" ] || return 0
  if command -v semanage >/dev/null 2>&1; then
    _sudo semanage fcontext -a -t cert_t "${dir}(/.*)?" 2>/dev/null \
      || _sudo semanage fcontext -m -t cert_t "${dir}(/.*)?" 2>/dev/null \
      || true
  fi
  command -v restorecon >/dev/null 2>&1 && _sudo restorecon -R "$dir" || true
  return 0
}

# ---------------------------------------------------------------------------
# Package names
#
# The same component is spelled differently on each family. `stack_packages`
# echoes the full list for this distro; anything genuinely optional (i.e. the
# install still succeeds without it) is returned by `stack_packages_optional`
# instead, so the caller can warn rather than abort.
#
# Deliberately NOT here: pgloader. The old installer pulled it in, but nothing
# in any C4 Raven repo has ever invoked it -- it was a leftover from the
# upstream project's sqlite-to-postgres migration path.
# ---------------------------------------------------------------------------
stack_packages() {
  case "${DISTRO_FAMILY:-}" in
    rhel)
      # gcc/gcc-c++/make plus the three -devel packages are the EL equivalent
      # of build-essential + python3-dev: mutf8 and unishox2-py3 have no wheel
      # for python 3.12/3.13 on any arch, and psycopg/cryptography/cffi want
      # libpq, openssl and libffi headers, so a working toolchain is mandatory
      # here, not a nicety.
      #
      # python3.12*, not python3*: see PYTHON_BIN in detect_distro.
      #
      # rabbitmq-server comes from yum1/yum2.rabbitmq.com (noarch, so one
      # repository serves both arches) -- setup_extra_repos has to have run
      # first. Debian gets it from main.
      #
      # hostname and tar are not in an EL9 minimal install, and install.sh
      # needs both (`hostname -I`, untarring the mediamtx release).
      # curl only when nothing provides it: EL9 minimal/cloud/UBI images ship
      # curl-minimal, which Provides curl but Conflicts with the package
      # named curl, so `dnf install curl` fails there.
      echo "$(rpm -q --whatprovides curl >/dev/null 2>&1 || echo curl) git openssl rsync tar hostname
            python3.12 python3.12-pip python3.12-devel python3.12-pyyaml
            gcc gcc-c++ make libpq-devel libffi-devel openssl-devel
            postgresql-server postgresql-contrib
            rabbitmq-server
            nginx nginx-mod-stream
            certbot python3-certbot-nginx
            policycoreutils-python-utils"
      ;;
    *)
      echo "curl git openssl rsync
            python3 python3-pip python3-venv python3-dev python3-yaml
            build-essential
            postgresql postgresql-postgis
            rabbitmq-server
            nginx libnginx-mod-stream
            certbot python3-certbot-nginx
            ffmpeg"
      ;;
  esac
}

# Packages whose absence costs a feature but not the install.
#
#   ffmpeg-free -- EL has no plain `ffmpeg` in AppStream or EPEL (that is RPM
#              Fusion only); EPEL9's ffmpeg-free covers the one use the server
#              has, a `-c:v copy -f rtsp` remux. Every call site in
#              mediamtx_api.py sits inside try/except that logs and continues,
#              so missing it costs stream thumbnails and recording metadata;
#              the webhook still returns 200.
#   postgis -- in EL AppStream (3.5.3), but nothing in the schema uses it.
#              The backend creates the extension if it can and runs without it.
stack_packages_optional() {
  case "${DISTRO_FAMILY:-}" in
    rhel) echo "ffmpeg-free postgis" ;;
    *)    echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# Third-party repositories (EL only -- Ubuntu has everything in main/universe)
#
# EPEL 9 carries certbot, erlang and ffmpeg-free (7.1.5, x86_64 AND aarch64 --
# verified against EPEL repodata for both), but NOT rabbitmq-server (postgis is in AppStream).
#
# ffmpeg-free is the package name to install: EPEL has no plain `ffmpeg`, and
# `dnf install ffmpeg` on an EPEL-only box fails. RPM Fusion is the only source
# of the full ffmpeg and is deliberately not used -- the server's single
# ffmpeg call is a `-c:v copy -f rtsp` remux, which needs no patent-encumbered
# codec. (rpm/c4raven-server.spec says `Recommends: ffmpeg-free` for the same
# reason. Don't "fix" either back to a bare `ffmpeg`.)
#
# rpm/c4raven-el9-repos.sh is the single source of truth for which repo each
# one comes from and for the aarch64 erlang caveat; reuse it rather than
# duplicating the baseurls here.
# ---------------------------------------------------------------------------
setup_extra_repos() {
  [ "${DISTRO_FAMILY:-}" = rhel ] || return 0
  local script="${1:-}"
  if [ -n "$script" ] && [ -f "$script" ]; then
    _sudo bash "$script"
    return $?
  fi
  # Fallback when the helper isn't on disk (curl|bash install): the two bits
  # install.sh cannot proceed without.
  # dnf-plugins-core first: it is what provides `dnf config-manager`, and it
  # is NOT in an EL9 minimal install. Without it both --set-enabled calls
  # below fail, the `|| true` swallows it, CRB stays disabled and the -devel
  # packages that only live there fail much later with an unrelated message.
  _sudo dnf -y install dnf-plugins-core epel-release
  _sudo dnf config-manager --set-enabled crb 2>/dev/null \
    || _sudo dnf config-manager --set-enabled powertools 2>/dev/null \
    || echo "distro.sh: could not enable the CRB/PowerTools repo -- some" \
            "-devel packages may be unavailable." >&2

  # EPEL + CRB is not enough on its own. stack_packages lists rabbitmq-server
  # as *mandatory*, and it is in neither BaseOS, nor AppStream, nor EPEL 9 --
  # only rabbitmq.com publishes an EL9 build (verified against the live
  # repodata for both arches). Without this file `pkg_install $(stack_packages)`
  # dies on "No match for argument: rabbitmq-server" with nothing to say why.
  #
  # A mirror of the [rabbitmq-server] stanza in rpm/c4raven-el9-repos.sh, which
  # stays the source of truth -- keep the two in step. Only the noarch server
  # repo is duplicated: it is the one install.sh cannot proceed without, it is
  # noarch so one URL serves both arches, and erlang comes from EPEL (26.2.5,
  # x86_64 and aarch64), which caps rabbitmq-server at 4.3.2 -- excluded above
  # it, because EL9's dnf (best=True) fails rather than backtrack. Run the
  # helper script instead if you want the x86_64-only erlang repo that lifts
  # the cap.
  if [ ! -f /etc/yum.repos.d/rabbitmq.repo ]; then
    _sudo tee /etc/yum.repos.d/rabbitmq.repo >/dev/null << 'EOF'
[rabbitmq-server]
name=RabbitMQ server (noarch)
baseurl=https://yum1.rabbitmq.com/rabbitmq/el/9/noarch
        https://yum2.rabbitmq.com/rabbitmq/el/9/noarch
excludepkgs=rabbitmq-server-4.3.[3-9]* rabbitmq-server-4.3.[1-9][0-9]* rabbitmq-server-4.[4-9]* rabbitmq-server-[5-9]*
repo_gpgcheck=0
enabled=1
gpgcheck=0
sslverify=1
metadata_expire=300
EOF
  fi
}

# ---------------------------------------------------------------------------
# PostgreSQL
#
# Debian's packaging initialises a cluster and starts it on install. EL's does
# neither: the data directory is empty until postgresql-setup --initdb runs,
# and the service will not start before that. Both are idempotent here.
#
# EL's generated pg_hba.conf also defaults to `ident` for host connections,
# which rejects the password auth the app's 127.0.0.1 URI relies on. We switch
# the two host lines to md5 and leave local/peer alone, so the
# `sudo -u postgres psql` calls in install.sh keep working untouched.
#
# md5, not scram-sha-256: EL9 AppStream's PostgreSQL is 13, whose
# password_encryption still defaults to md5, so the role's password is stored
# as an MD5 hash and a scram-sha-256 line can never verify it. The md5 method
# accepts both kinds of stored password (it does SCRAM when the stored one is).
# ---------------------------------------------------------------------------
pg_init() {
  if [ "${DISTRO_FAMILY:-}" = rhel ]; then
    # _sudo: /var/lib/pgsql is 0700 postgres, so as install.sh's ordinary user
    # a plain test never sees PG_VERSION and every re-run would initdb again
    # ("Data directory ... is not empty!") and abort.
    if [ -n "$PG_DATA_DIR" ] && ! _sudo test -f "$PG_DATA_DIR/PG_VERSION"; then
      _sudo postgresql-setup --initdb
    fi
    local hba="$PG_DATA_DIR/pg_hba.conf"
    # The "already done?" guard has to look at an *active* host line. Every
    # stock pg_hba.conf carries the header comment
    #     # METHOD can be "trust", "reject", "md5", "password",
    #     # "scram-sha-256", "gss", ..., "ident", "peer", ...
    # so a bare `grep -q scram-sha-256` matches a freshly initdb'd file and
    # the rewrite below never runs -- leaving `ident` in place, which is
    # exactly the failure this function exists to prevent.
    if _sudo test -f "$hba" \
       && ! _sudo grep -qE '^[[:space:]]*host[[:space:]].*[[:space:]](md5|scram-sha-256)([[:space:]]|$)' "$hba"; then
      # Anchor on the address rather than the method: EL's packaging has
      # shipped `ident` for years, but plain initdb's own default is `trust`,
      # and both are wrong for the app's password-authenticated 127.0.0.1
      # URI. Trailing whitespace is tolerated. Re-running is a no-op because
      # the guard above then matches.
      _sudo sed -i -E \
        's/^([[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1\/32|::1\/128)[[:space:]]+)(ident|peer|trust|password)([[:space:]]*)$/\1md5\4/' \
        "$hba"
      # On a re-run postgres is already up, so the `systemctl start` below is
      # a no-op and the rewritten rules would not take effect until reboot.
      if _sudo systemctl is-active --quiet "$PG_SERVICE" 2>/dev/null; then
        _sudo systemctl reload "$PG_SERVICE" || true
      fi
    fi
  fi
  _sudo systemctl enable "$PG_SERVICE"
  _sudo systemctl start "$PG_SERVICE"
}

# ---------------------------------------------------------------------------
# Node.js
#
# The UI build (vite 8) needs Node 20.19+ / 22.12+. Ubuntu 24.04 ships 18.x
# with no corepack, and EL 9's module streams top out below that too, so both
# families need NodeSource unless a new-enough node is already present.
# NodeSource publishes amd64 and arm64 for both.
# ---------------------------------------------------------------------------
node_ok() {
  command -v node >/dev/null 2>&1 && node -e '
    const [a, b] = process.versions.node.split(".").map(Number);
    process.exit((a === 20 && b >= 19) || (a === 22 && b >= 12) || a >= 23 ? 0 : 1);'
}

node_install() {
  node_ok && return 0
  case "${DISTRO_FAMILY:-}" in
    rhel)
      # EL9 ships nodejs as a *module* whose default stream is 18. A modular
      # package outranks a plain one, so without resetting the module first
      # `dnf install nodejs` picks AppStream's 18 and ignores the NodeSource
      # repo entirely -- and 18 has no corepack and cannot build vite 8.
      _sudo dnf -y module reset nodejs 2>/dev/null || true
      curl -fsSL https://rpm.nodesource.com/setup_22.x | _sudo_E bash -
      _sudo dnf install -y nodejs
      ;;
    *)
      curl -fsSL https://deb.nodesource.com/setup_22.x | _sudo_E bash -
      _sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y nodejs
      ;;
  esac
}
