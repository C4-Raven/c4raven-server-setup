#!/bin/bash
# c4raven-server: the whole post-install configuration, for Enterprise Linux 9
# (Rocky / AlmaLinux / RHEL), x86_64 and aarch64.
#
# This is the RPM's answer to debian/c4raven-server.postinst and it mirrors it
# step for step. It is NOT inlined into the %post scriptlet on purpose:
#
#   * %post has no debconf, so the interactive answers the .deb collects before
#     unpacking have to come from somewhere else (see /etc/c4raven-server/setup.conf).
#     Keeping the logic in a real script means the admin can fill that file in
#     *after* the install and re-run everything with `c4raven-setup`.
#   * `rpm -q --scripts` output stays readable.
#
# Like the postinst, every step checks for existing state before creating it, so
# this is safe to run on a fresh install, on `dnf upgrade`, and by hand any
# number of times.
set -euo pipefail

APP_USER="raven"
APP_HOME="/opt/raven"
DATA_DIR="$APP_HOME/data"
DB_NAME="raven"
WEBROOT="/var/www/html/raven"
PKGDATA="/usr/share/c4raven-server"
# Present only in the offline build (see build-rpm.sh OFFLINE_PAYLOAD): prebuilt
# backend wheels, the built UI, mediamtx and the ATAK plugin. When it exists,
# every step below installs from it instead of reaching out to GitHub/PyPI/npm.
OFFLINE_DIR="$PKGDATA/offline"
CONF_FILE="/etc/c4raven-server/setup.conf"
FLASK_ENV="FLASK_APP=raven.app RAVEN_DATA_FOLDER='$DATA_DIR'"

# ---------------------------------------------------------------------------
# Answers (the debconf replacement).
#
# Precedence: environment > /etc/c4raven-server/setup.conf > default. The
# environment path is what makes an unattended kickstart/Ansible install
# possible without writing a file first:
#
#   RAVEN_DOMAIN=tak.example.org dnf install ./c4raven-server-*.rpm
# ---------------------------------------------------------------------------
if [ -f "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONF_FILE"
fi
RAVEN_DOMAIN="${RAVEN_DOMAIN:-}"
RAVEN_TURNSTILE_ENABLE="${RAVEN_TURNSTILE_ENABLE:-false}"
RAVEN_TURNSTILE_SITE_KEY="${RAVEN_TURNSTILE_SITE_KEY:-}"
RAVEN_TURNSTILE_SECRET_KEY="${RAVEN_TURNSTILE_SECRET_KEY:-}"
RAVEN_CERTBOT_EMAIL="${RAVEN_CERTBOT_EMAIL:-}"
# EL9's /usr/bin/python3 is 3.9; c4raven-server's pyproject.toml requires
# ">=3.10, <3.15". python3.12 is a plain (non-modular) AppStream package on both
# x86_64 and aarch64, so that is what the venv is built with.
RAVEN_PYTHON="${RAVEN_PYTHON:-python3.12}"
RAVEN_OPEN_FIREWALL="${RAVEN_OPEN_FIREWALL:-true}"
RAVEN_SELINUX_FIXUP="${RAVEN_SELINUX_FIXUP:-true}"

DOMAIN="$RAVEN_DOMAIN"

# ---------------------------------------------------------------------------
# Distro shim. Agent-1's lib/distro.sh is shipped at $PKGDATA/lib/distro.sh when
# it exists at package-build time; the fallbacks below keep this script working
# standalone on EL9 if it isn't there. Everything we consume from it is a plain
# variable or function name, so a newer shim can override us wholesale.
# ---------------------------------------------------------------------------
if [ -r "$PKGDATA/lib/distro.sh" ]; then
  # shellcheck source=/dev/null
  . "$PKGDATA/lib/distro.sh"
  detect_distro 2>/dev/null || true
fi

: "${NGINX_CONF:=/etc/nginx/nginx.conf}"
# EL nginx has no sites-available/sites-enabled at all: nginx.conf includes
# /etc/nginx/conf.d/*.conf from inside http{} and nothing else. There is no
# enable/disable symlink dance, so "available" and "enabled" are the same
# directory and the files must end in .conf.
: "${NGINX_SITES_DIR:=/etc/nginx/conf.d}"
# Likewise there is no streams-enabled. nginx-mod-stream only drops a
# load_module line in /usr/share/nginx/modules/mod-stream.conf; the stream{}
# block itself still has to be added to nginx.conf (same as the .deb does).
: "${NGINX_STREAMS_DIR:=/etc/nginx/stream.d}"
: "${PG_SERVICE:=postgresql}"
: "${RABBIT_SERVICE:=rabbitmq-server}"

# Deliberately NOT the shim's firewall_open, and defined unconditionally so it
# shadows the shim's even when one was sourced above.
#
# lib/distro.sh gates on `systemctl is-active --quiet firewalld`, which is right
# for install.sh -- an operator running it on a live box -- but wrong here.
# %post runs during kickstart, image builds and `dnf --installroot` work, where
# firewalld is *enabled but not yet started*. `firewall-cmd --permanent` does
# not need the daemon: it edits /etc/firewalld/zones directly and the rules take
# effect the moment firewalld starts. The shim's gate turns the whole step into
# a silent no-op in exactly the unattended cases the RPM exists to serve, and
# RAVEN_OPEN_FIREWALL=true then lies.
#
# Takes a list, not one port: the shim reloads after every call, so the previous
# one-port-per-call loop reloaded firewalld fourteen times.
firewall_open() {
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "  firewall-cmd not found -- no ports opened. If you run a firewall," >&2
    echo "  open these yourself: $*" >&2
    return 0
  fi
  local p failed=""
  for p in "$@"; do
    firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 || failed="$failed $p"
  done
  if [ -n "$failed" ]; then
    echo "  could not add permanent rule(s) for:$failed -- open them by hand." >&2
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --reload >/dev/null 2>&1 || true
  else
    echo "  firewalld is not running: the permanent rules were written and will"
    echo "  take effect when it starts (systemctl enable --now firewalld)."
  fi
}

if ! declare -F selinux_fixup >/dev/null; then
  selinux_fixup() { :; }
fi

# runuser (util-linux, part of @core) rather than sudo: we're already root and
# sudo isn't guaranteed to exist on a minimal EL image.
run_as_app() {
  runuser -u "$APP_USER" -- bash -lc "$1"
}

# psql as the postgres superuser over the local socket (peer auth). cd /tmp
# first or runuser leaves cwd at /root and psql prints a "could not change
# directory" warning into every captured command's stderr.
psql_super() {
  ( cd /tmp && runuser -u postgres -- psql "$@" )
}

offline() {
  [ -d "$OFFLINE_DIR" ]
}

# Run a command from the backend's environment as the app user: the Poetry venv
# of the source checkout (online build) or the plain venv (offline).
# $1 is one shell word list, e.g. "flask raven create-ca".
raven_exec() {
  if offline; then
    run_as_app "cd '$DATA_DIR' && $FLASK_ENV '$APP_HOME/venv/bin/'$1"
  else
    run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run $1"
  fi
}

node_ok() {
  command -v node >/dev/null 2>&1 && node -e '
    const [a, b] = process.versions.node.split(".").map(Number);
    process.exit((a === 20 && b >= 19) || (a === 22 && b >= 12) || a >= 23 ? 0 : 1);'
}

# Rewrite one key in $DATA_DIR/config.yml as the app user.
#
# Two layers of care, because this handles the Turnstile secret:
#   * the values are passed as argv and never interpolated into the Python
#     source, so YAML/Python quoting can't be broken by their content;
#   * they go through printf %q before being embedded in the string handed to
#     `bash -lc`, so a value containing a single quote can't break out of the
#     shell command either. (The .deb's postinst wraps the same values in plain
#     single quotes and would break on one -- this is the one place the RPM is
#     deliberately stricter than what it mirrors.)
set_config() {
  local key="$1" value="$2" kind="${3:-str}"
  local qkey qvalue qkind
  printf -v qkey '%q' "$key"
  printf -v qvalue '%q' "$value"
  printf -v qkind '%q' "$kind"
  run_as_app "'$RAVEN_PYTHON' - $qkey $qvalue $qkind << 'PYEOF'
import sys, yaml
key, value, kind = sys.argv[1], sys.argv[2], sys.argv[3]
if kind == 'bool':
    value = value.lower() in ('1', 'true', 'yes', 'on')
path = '$DATA_DIR/config.yml'
with open(path) as f:
    conf = yaml.safe_load(f)
conf[key] = value
with open(path, 'w') as f:
    yaml.safe_dump(conf, f)
PYEOF"
}

if [ "$(id -u)" -ne 0 ]; then
  echo "c4raven-setup must run as root." >&2
  exit 1
fi

if ! command -v "$RAVEN_PYTHON" >/dev/null 2>&1; then
  echo "$RAVEN_PYTHON not found. c4raven-server needs Python 3.10+ and EL9's" >&2
  # Same set the spec's Requires: names, so the hint and the dependency list
  # cannot drift apart. python3.12-pyyaml is the one that is easy to forget:
  # set_config() below parses config.yml with it.
  echo "system python3 is 3.9. Install it with:" >&2
  echo "  dnf install python3.12 python3.12-pyyaml python3.12-devel" >&2
  exit 1
fi

echo "Setting up the dedicated '$APP_USER' account..."
if ! id "$APP_USER" &>/dev/null; then
  useradd --system --create-home --home-dir "$APP_HOME" --shell /bin/bash "$APP_USER"
  chmod 750 "$APP_HOME"
fi
run_as_app "mkdir -p '$DATA_DIR/logs'"

# ---------------------------------------------------------------------------
# Backend: clone (first install only) + checkout the exact commit this package
# version was built against, then install. Installing or upgrading this RPM
# installs a specific, reproducible version rather than a floating branch.
# ---------------------------------------------------------------------------
echo "Installing the Raven backend..."
if offline; then
  # Fresh venv per install, then an atomic symlink swap: the running services
  # keep their old venv until they're restarted further down, and a failed
  # install leaves the working one in place. The old venv is only deleted once
  # the new services are up (end of this script).
  PYTAG=$("$RAVEN_PYTHON" -c 'import sys; print("cp%d%d" % sys.version_info[:2])')
  WHEELS="$OFFLINE_DIR/wheelhouse"
  if [ ! -d "$WHEELS/$PYTAG" ]; then
    echo "This package bundles backend wheels for: $(cd "$WHEELS" && ls -d cp* | tr '\n' ' ')" >&2
    echo "but $RAVEN_PYTHON on this system is $PYTAG. Use the offline bundle built for this EL release." >&2
    exit 1
  fi
  NEW_VENV="$APP_HOME/venvs/$(cat "$OFFLINE_DIR/VERSION")-$(date +%Y%m%d%H%M%S)"
  run_as_app "mkdir -p '$APP_HOME/venvs' && '$RAVEN_PYTHON' -m venv '$NEW_VENV'"
  PIP="PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1 '$NEW_VENV/bin/pip' install --quiet --no-index"
  run_as_app "$PIP --find-links '$WHEELS/$PYTAG' --find-links '$WHEELS/common' -r '$OFFLINE_DIR/requirements.txt'"
  run_as_app "$PIP --no-deps '$WHEELS'/common/raven-*.whl"
  ln -sfn "$NEW_VENV" "$APP_HOME/venv.new"
  chown -h "$APP_USER:$APP_USER" "$APP_HOME/venv.new"
  mv -T "$APP_HOME/venv.new" "$APP_HOME/venv"
else
  if [ ! -d "$APP_HOME/c4raven-server" ]; then
    run_as_app "git clone https://github.com/C4-Raven/c4raven-server.git '$APP_HOME/c4raven-server'"
  fi
  if [ -f "$PKGDATA/SERVER_SHA" ]; then
    SERVER_SHA=$(cat "$PKGDATA/SERVER_SHA")
    # raven/__init__.py is a version stamp poetry-dynamic-versioning rewrites on
    # every install; discard it first or git refuses to switch commits.
    run_as_app "cd '$APP_HOME/c4raven-server' && git checkout -- raven/__init__.py 2>/dev/null; git fetch origin && git checkout '$SERVER_SHA'"
  fi

  if ! run_as_app "test -x '$APP_HOME/.local/bin/poetry'"; then
    run_as_app "curl -sSL https://install.python-poetry.org | '$RAVEN_PYTHON' -"
  fi
  run_as_app "poetry config virtualenvs.in-project true"
  # Without this the in-project .venv is built from whatever `python3` poetry
  # finds first, which on EL9 is 3.9 and below the project's floor.
  run_as_app "cd '$APP_HOME/c4raven-server' && poetry env use '$(command -v "$RAVEN_PYTHON")'"
  run_as_app "cd '$APP_HOME/c4raven-server' && poetry install"
fi

raven_exec "flask raven generate-config"
echo "Raven backend installed."

# ---------------------------------------------------------------------------
# PostgreSQL
#
# Two EL-only steps the .deb never needs: Debian's postgresql-common initialises
# a cluster and starts the server from its own postinst, EL ships an empty
# /var/lib/pgsql/data and a stopped, disabled service.
# ---------------------------------------------------------------------------
# The PostgreSQL this resolves against is EL9 AppStream's non-modular
# postgresql 13 (postgresql-13.23-*.el9, x86_64 and aarch64), whose unit is
# plain `postgresql.service` and whose PGDATA is /var/lib/pgsql/data. That is
# what PG_SERVICE/PG_DATA_DIR in lib/distro.sh already say and what
# c4raven-updater/diagnose-login.sh assumes. PGDG is deliberately not used; its
# versioned postgresql-16.service would break both.
echo "Setting up PostgreSQL..."
PGDATA_DIR="${PG_DATA_DIR:-${PGDATA_DIR:-/var/lib/pgsql/data}}"

if declare -F pg_init >/dev/null && [ "${DISTRO_FAMILY:-}" = rhel ]; then
  # The shim does initdb, the pg_hba rewrite and enable/start, idempotently and
  # with a wider rewrite than the fallback below. Prefer it: install.sh runs the
  # same function, so a Rocky box set up by the installer and one set up by the
  # RPM end up with byte-identical pg_hba rules.
  pg_init
else
  if [ ! -f "$PGDATA_DIR/PG_VERSION" ]; then
    echo "Initialising the PostgreSQL data directory..."
    postgresql-setup --initdb
  fi
  systemctl enable "$PG_SERVICE"
  systemctl start "$PG_SERVICE"

  # EL's generated pg_hba.conf authenticates host connections from 127.0.0.1
  # with `ident`, which has no ident daemon to talk to and fails. The backend
  # connects over TCP to 127.0.0.1 with the password generated below, so those
  # two lines have to become scram-sha-256. (Debian's pg_hba already uses
  # scram/md5 for host connections, which is why the .deb has no equivalent.)
  #
  # Anchor on the *address*, not on the method. This used to match `ident`
  # alone, which is what EL's packaging has shipped for years -- but a data
  # directory created by plain `initdb` rather than `postgresql-setup` defaults
  # to `trust`, and `peer` and `md5` both turn up on boxes that have been
  # touched by hand. Leaving `trust` in place is the bad one: the app connects
  # fine, so nothing looks wrong, while every local account on the machine can
  # open the TAK database as any role with no password at all. Same expression
  # as pg_init() in lib/distro.sh.
  PG_HBA="$PGDATA_DIR/pg_hba.conf"
  if [ -f "$PG_HBA" ] \
     && ! grep -qE '^[[:space:]]*host[[:space:]].*[[:space:]]scram-sha-256([[:space:]]|$)' "$PG_HBA"; then
    cp -a "$PG_HBA" "$PG_HBA.c4raven.bak"
    sed -i -E \
      's/^([[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1\/32|::1\/128)[[:space:]]+)(ident|peer|trust|md5|password)([[:space:]]*)$/\1scram-sha-256\4/' \
      "$PG_HBA"
    echo "Switched local TCP authentication to scram-sha-256 (backup: $PG_HBA.c4raven.bak)"
    systemctl reload "$PG_SERVICE" || true
  fi
fi

DB_USER_EXISTS=$(psql_super -tXAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_NAME'")
if [ "$DB_USER_EXISTS" != 1 ]; then
  # Hex only: this goes raw into a URI, where `%` would be percent-decoded by
  # SQLAlchemy/libpq. (Not `tr ... | head -c`: under pipefail, head closing the
  # pipe kills tr with SIGPIPE and this script with it.)
  POSTGRESQL_PASSWORD=$(openssl rand -hex 16)
  psql_super -c "create role $DB_NAME with login password '${POSTGRESQL_PASSWORD}';"
  DB_URI="postgresql+psycopg://$DB_NAME:${POSTGRESQL_PASSWORD}@127.0.0.1/$DB_NAME"
  set_config SQLALCHEMY_DATABASE_URI "$DB_URI"
else
  # Already exists (a previous install or upgrade) -- config.yml already has the
  # right SQLALCHEMY_DATABASE_URI from that run, and we don't have the password
  # to rebuild it here.
  DB_URI=$(run_as_app "'$RAVEN_PYTHON' -c \"import yaml; print(yaml.safe_load(open('$DATA_DIR/config.yml'))['SQLALCHEMY_DATABASE_URI'])\"")
fi

DB_EXISTS=$(psql_super -XtAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")
if [ "$DB_EXISTS" != 1 ]; then
  psql_super -c "create database $DB_NAME;"
fi
psql_super -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO $DB_NAME;"
psql_super -d "$DB_NAME" -c "GRANT ALL ON SCHEMA public TO $DB_NAME;"
# Best-effort: create the extension if a postgis package happens to be
# installed, carry on if not. Nothing in the current schema actually uses it
# (the one migration that mentions it, 8a43097881d7, says it was written
# *without* geoalchemy2), so this must never fail the install.
#
# CORRECTION, verified against live repodata 2026-10-25: the comment that used
# to be here -- "PostGIS is NOT in EL9 AppStream or EPEL9, only in PGDG" --
# is false, and it is repeated in c4raven-server.spec and lib/distro.sh. EL9
# AppStream carries postgis 3.5.3 for x86_64 AND aarch64 (Rocky 9 and
# AlmaLinux 9 both; a non-modular postgis-3.5.3-5.el9 plus module builds for
# the postgresql:15/16/18 streams). EPEL 9 genuinely has none. PGDG is still
# not used, but the reason is only that it replaces the distro PostgreSQL and
# brings a versioned postgresql-16.service -- not scarcity.
if ! psql_super -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgis" >/dev/null 2>&1; then
  echo "Note: the postgis extension is unavailable and was skipped. Nothing in the"
  echo "      current schema needs it. To add it later:"
  echo "        sudo dnf install postgis"
  echo "        sudo -u postgres psql -d $DB_NAME -c 'CREATE EXTENSION postgis'"
fi
echo "Database ready."
# Migrations run automatically inside the app itself on every startup (see
# init_extensions() in raven/app.py) -- no separate `flask db upgrade` here.

# ---------------------------------------------------------------------------
# Cloudflare Turnstile (from setup.conf / the environment)
# ---------------------------------------------------------------------------
case "${RAVEN_TURNSTILE_ENABLE,,}" in
  1|true|yes|on)
    if [ -z "$RAVEN_TURNSTILE_SITE_KEY" ] || [ -z "$RAVEN_TURNSTILE_SECRET_KEY" ]; then
      echo "Turnstile is enabled but RAVEN_TURNSTILE_SITE_KEY/RAVEN_TURNSTILE_SECRET_KEY are empty -- skipping." >&2
    else
      set_config RAVEN_TURNSTILE_ENABLE true bool
      set_config RAVEN_TURNSTILE_SITE_KEY "$RAVEN_TURNSTILE_SITE_KEY"
      set_config RAVEN_TURNSTILE_SECRET_KEY "$RAVEN_TURNSTILE_SECRET_KEY"
      echo "Turnstile configured."
      # Don't leave the secret sitting in setup.conf -- it now lives in
      # config.yml, which is mode 0600 and owned by the app user. (The .deb's
      # equivalent is `db_reset c4raven-server/turnstile-secret-key`.)
      if [ -f "$CONF_FILE" ] && grep -q '^[[:space:]]*RAVEN_TURNSTILE_SECRET_KEY=' "$CONF_FILE"; then
        sed -i 's/^[[:space:]]*RAVEN_TURNSTILE_SECRET_KEY=.*/RAVEN_TURNSTILE_SECRET_KEY=   # consumed; now stored in config.yml/' "$CONF_FILE"
      fi
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Certificate authority
#
# Preflight, EL-only: raven/certificate_authority.py runs
# `openssl pkcs12 -legacy -export ...` whenever `openssl list -providers`
# succeeds, which it does on every OpenSSL 3 build and therefore on EL9. The
# -legacy flag needs the legacy provider to actually load, and RHEL 9's
# crypto-policies can refuse the RC2/3DES ciphers that PKCS12 then uses. If that
# fails, CA creation and every ATAK enrollment data package fail with it, so
# prove it works before create-ca rather than discovering it at the first device
# enrollment. Non-fatal: warn loudly and carry on, because the failure mode is
# recoverable without reinstalling.
# ---------------------------------------------------------------------------
PKCS12_PROBE=$(mktemp -d)
if ! (
      cd "$PKCS12_PROBE" &&
      openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem \
        -days 1 -subj /CN=c4raven-pkcs12-probe >/dev/null 2>&1 &&
      openssl pkcs12 -legacy -export -in c.pem -out probe.p12 \
        -passout pass:atakatak -nokeys -caname probe >/dev/null 2>&1
    ); then
  echo
  echo "WARNING: 'openssl pkcs12 -legacy' does not work on this system." >&2
  echo "  The Raven CA uses it to build the .p12 truststore in every ATAK" >&2
  echo "  enrollment data package, so certificate enrollment will fail." >&2
  echo "  Most likely cause on EL9: the system crypto policy blocks the legacy" >&2
  echo "  provider's RC2/3DES. Check with:  openssl list -providers -provider legacy" >&2
  echo "  and, if your security posture allows it:" >&2
  echo "      sudo update-crypto-policies --set LEGACY && sudo reboot" >&2
  echo
fi
rm -rf "$PKCS12_PROBE"

echo "Creating the certificate authority..."
raven_exec "flask raven create-ca"
# Unlike create-ca, issue-server-certificate is NOT idempotent -- it
# unconditionally wipes and regenerates certs/raven/ if it already exists
# (CertificateAuthority.issue_certificate() does an unconditional
# shutil.rmtree). This script runs on every upgrade, so it needs its own guard
# to avoid silently reissuing (and invalidating) the server's TLS cert.
if [ ! -f "$DATA_DIR/ca/certs/raven/raven.pem" ]; then
  raven_exec "flask raven issue-server-certificate"
fi

# ---------------------------------------------------------------------------
# mediamtx
# ---------------------------------------------------------------------------
echo "Installing mediamtx..."
run_as_app "mkdir -p '$DATA_DIR/mediamtx/recordings'"
# ARCH_MTX from the shim when we have it -- it is the same mapping install.sh
# and the .deb use, and keeping one copy is the whole point of lib/distro.sh.
# (detect_distro returns non-zero on an architecture mediamtx does not build
# for, which is why it is called with `|| true` above; ARCH_MTX is left empty
# in that case and the guard below catches it.)
#
# No catch-all either way. The .deb's postinst was explicitly fixed to drop its
# `*) armv7` fallback, and on EL it would be worse than useless: the spec only
# ever builds noarch, x86_64 and aarch64 (c4raven-server.spec's BuildArch and
# build-rpm.sh's RPM_ARCH mapping), so any other `uname -m` here means the
# package is on a machine it was never built for. Guessing armv7 downloads a
# 32-bit ARM binary that installs and chmods fine and then dies at first boot
# with "Exec format error" from inside a systemd unit -- fail here instead,
# where the message can say why.
MTX_ARCH="${ARCH_MTX:-}"
if [ -z "$MTX_ARCH" ]; then
  case "$(uname -m)" in
    x86_64)        MTX_ARCH=amd64 ;;
    aarch64|arm64) MTX_ARCH=arm64 ;;
  esac
fi
case "$MTX_ARCH" in
  amd64|arm64) ;;
  *)
    echo "Unsupported architecture '$(uname -m)'. c4raven-server is packaged for" >&2
    echo "x86_64 and aarch64 only; there is no mediamtx build to install here." >&2
    exit 1
    ;;
esac
if offline; then
  # Always re-extract: a newer package may bundle a newer mediamtx. Unlike the
  # .deb's postinst this globs the arch out of the filename instead of
  # hardcoding amd64, because the offline RPM is built per-arch.
  MTX_TARBALL=$(ls "$OFFLINE_DIR"/mediamtx/mediamtx_*_linux_"$MTX_ARCH".tar.gz 2>/dev/null | head -1 || true)
  if [ -z "$MTX_TARBALL" ]; then
    echo "The offline payload has no mediamtx build for linux_$MTX_ARCH." >&2
    exit 1
  fi
  run_as_app "tar -xzf '$MTX_TARBALL' -C '$DATA_DIR/mediamtx' mediamtx LICENSE"
elif [ ! -f "$DATA_DIR/mediamtx/mediamtx" ]; then
  # lastversion is one of the backend's own dependencies, so it's in the Poetry
  # venv already; run it from there (`poetry run` needs the cwd).
  run_as_app "cd '$APP_HOME/c4raven-server' && poetry run lastversion --filter '~*linux_$MTX_ARCH' --only 1.13.0 -o '$DATA_DIR/mediamtx/mediamtx.tar.gz' --assets download bluenviron/mediamtx"
  run_as_app "cd '$DATA_DIR/mediamtx' && tar -xf mediamtx.tar.gz && rm -f mediamtx.tar.gz"
fi
# Cert/data paths were substituted at package-build time (build-rpm.sh runs the
# same sed over the same templates; APP_HOME/DATA_DIR are constants). Only the
# public host for WebRTC is machine-specific.
install -o "$APP_USER" -g "$APP_USER" -m 644 "$PKGDATA/mediamtx.yml" "$DATA_DIR/mediamtx/mediamtx.yml"
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$HOST_IP" ] || HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
sed -i "s~^webrtcAdditionalHosts: \[\]~webrtcAdditionalHosts: [${DOMAIN:-$HOST_IP}]~" \
  "$DATA_DIR/mediamtx/mediamtx.yml"

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
echo "Configuring nginx..."
mkdir -p "$NGINX_SITES_DIR" "$NGINX_STREAMS_DIR"

# Debian's nginx ships /etc/nginx/proxy_params; EL's does not, and both
# raven_http and raven_https `include proxy_params;` in their /socket.io block.
# Without this file nginx refuses to load its configuration at all.
if [ ! -f /etc/nginx/proxy_params ]; then
  install -m 644 "$PKGDATA/proxy_params" /etc/nginx/proxy_params
fi

# nginx-mod-stream only drops a load_module line under
# /usr/share/nginx/modules/; the stream{} block is still ours to add.
#
# The guard is anchored, unlike the `grep -q "stream {"` the .deb and install.sh
# use. That substring matches a commented-out `#stream {` example and, worse,
# the tail of `upstream foo {` -- either one makes us skip the append, our
# stream.d/*.conf never gets included, and the RTSPS/RTMPS/MQTTS proxies are
# simply absent with nothing logged. Anchoring on the start of a line is the
# cheap fix; a real parse is overkill for a block nginx only allows at top
# level anyway.
STREAM_INCLUDE="$NGINX_STREAMS_DIR/*.conf"
if declare -F nginx_stream_include >/dev/null; then
  STREAM_INCLUDE=$(nginx_stream_include)
fi
if ! grep -qE '^[[:space:]]*stream[[:space:]]*\{' "$NGINX_CONF"; then
  cat >> "$NGINX_CONF" << EOF

# Added by c4raven-server
stream {
        include $STREAM_INCLUDE;
}
EOF
elif ! grep -qF "$NGINX_STREAMS_DIR/" "$NGINX_CONF"; then
  # Somebody else's stream block is already there. Appending a second one makes
  # nginx refuse to start ("stream" directive is duplicate), so don't -- but say
  # so, because otherwise the stream proxies vanish silently.
  echo "WARNING: $NGINX_CONF already has a stream{} block that does not include" >&2
  echo "  $NGINX_STREAMS_DIR/*.conf. Add that include to it by hand, or the" >&2
  echo "  RTSPS (8322), RTMPS (1936) and MQTTS (8883) proxies will not be served." >&2
fi

# EL's stock nginx.conf carries a default_server for port 80 *inline*, serving
# /usr/share/nginx/html. Debian's does not (its default site is a file in
# sites-enabled, which install.sh/postinst simply never enable). Left in place
# it answers every request on port 80 whose Host doesn't match, instead of
# raven_http's redirect to HTTPS -- so comment it out, once, reversibly.
#
# This used to be a third inline copy of the same brace-matching snippet that
# lives in lib/distro.sh. It is now nginx_default_server.py, shipped in
# $PKGDATA: a real (small) nginx parser that is comment- and quote-aware and
# re-parses its own output to prove the block is really gone before writing.
# That post-condition is the point -- it is what catches a locator that matched
# the wrong range, which is precisely how the original rfind() bug shipped: the
# file still had a live `server { listen 80; }`, only its body commented, so
# nginx loaded cleanly and the stock default_server went on shadowing
# raven_http's redirect. Quiet and wrong beats loud and broken, every time.
NGINX_DEFSRV="$PKGDATA/nginx_default_server.py"
if [ -f "$NGINX_DEFSRV" ]; then
  # Exit codes: 0 = disabled it, 10 = nothing to do, anything else = error.
  DEFSRV_RC=0
  "$RAVEN_PYTHON" "$NGINX_DEFSRV" --disable "$NGINX_CONF" \
    --backup-suffix .c4raven.bak || DEFSRV_RC=$?
  case "$DEFSRV_RC" in
    0)
      echo "Commented out nginx.conf's stock default server (backup: $NGINX_CONF.c4raven.bak)"
      # The parser guarantees a *parseable* file; nginx -t is the only thing
      # that can say it is a file nginx will actually load. configure.sh
      # restarts nginx a few lines down, so a bad rewrite here is fatal --
      # roll back rather than leave a box whose web server will not start.
      if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
        cp -a "$NGINX_CONF.c4raven.bak" "$NGINX_CONF"
        rm -f "$NGINX_CONF.c4raven.bak"
        echo "WARNING: that rewrite did not pass 'nginx -t'; $NGINX_CONF was restored." >&2
        echo "  Comment out its 'server { listen 80; ... }' block by hand, or" >&2
        echo "  raven_http will not answer on port 80." >&2
      fi
      ;;
    10) ;;  # already disabled, or this nginx.conf has no stock default server
    *)
      echo "WARNING: could not disable nginx's stock default_server (exit $DEFSRV_RC)." >&2
      echo "  $NGINX_CONF is unchanged. Until its 'server { listen 80; ... }'" >&2
      echo "  block is commented out, it answers port 80 ahead of raven_http" >&2
      echo "  and the redirect to HTTPS never happens." >&2
      ;;
  esac
elif declare -F nginx_disable_default_site >/dev/null; then
  # Older package, or configure.sh run straight out of a checkout: fall back to
  # the shim's implementation rather than growing another copy here.
  nginx_disable_default_site || true
else
  echo "WARNING: neither $NGINX_DEFSRV nor lib/distro.sh is available; nginx's" >&2
  echo "  stock default_server was left in place and will shadow raven_http." >&2
fi

# On upgrade, don't overwrite a site file certbot has already rewritten (LE cert
# paths, redirects) -- that would put the server back on the self-signed cert
# until certbot's re-run below succeeds, and lose any local edits for good.
# Fresh files and untouched ones are replaced.
#
# Note the .conf suffix: /etc/nginx/conf.d only includes *.conf, and there is no
# available/enabled split to symlink across, so writing the file *is* enabling
# it. The .deb's `ln -sf sites-available -> sites-enabled` steps have no
# counterpart here, and neither does its "don't blow away unrelated
# sites-enabled entries" caution -- we only ever write our own four filenames.
for f in raven_http raven_https raven_certificate_enrollment; do
  dst="$NGINX_SITES_DIR/$f.conf"
  if [ -f "$dst" ] && grep -q "managed by Certbot" "$dst"; then
    echo "Leaving $dst alone (modified by certbot); new template is at $PKGDATA/nginx_configs/$f"
  else
    install -m 644 "$PKGDATA/nginx_configs/$f" "$dst"
  fi
done
for f in rabbitmq mediamtx; do
  install -m 644 "$PKGDATA/nginx_configs/$f" "$NGINX_STREAMS_DIR/$f.conf"
done

# Owned by the app user, not world-writable: any local account could otherwise
# swap out the served JavaScript. /var/www does not exist on EL at all (nginx's
# own docroot is /usr/share/nginx/html), so this creates the whole path.
install -d -m 755 /var/www /var/www/html
install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$WEBROOT"

# ---------------------------------------------------------------------------
# SELinux. Nothing in the .deb corresponds to this: Ubuntu ships AppArmor with
# no nginx profile enforced. On EL9 SELinux is Enforcing out of the box and
# every one of these would otherwise be a silent 502 or a refused bind.
# ---------------------------------------------------------------------------
if [ "${RAVEN_SELINUX_FIXUP,,}" = "true" ] && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  echo "Applying SELinux policy..."
  # Every proxy_pass in raven_http/raven_https/raven_certificate_enrollment
  # (8081 for the API, 8888/8889 for MediaMTX) is httpd_t opening a TCP socket.
  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 || true
  fi

  if command -v semanage >/dev/null 2>&1; then
    # Ports nginx binds that are not already http_port_t: 8446 (cert
    # enrollment), and the three stream proxies 8322/1936/8883. 80, 443, 8443
    # are http_port_t and 8080 is http_cache_port_t, both of which the targeted
    # httpd policy already permits name_bind on.
    for p in 8446 8322 1936 8883; do
      semanage port -a -t http_port_t -p tcp "$p" 2>/dev/null \
        || semanage port -m -t http_port_t -p tcp "$p" 2>/dev/null \
        || echo "  (could not label tcp/$p as http_port_t -- check 'semanage port -l | grep $p')"
    done
    # nginx terminates TLS for every one of those listeners using the CA's own
    # certificates under /opt/raven/data/ca. Files created under /opt get
    # default_t, which httpd_t cannot read; cert_t it can.
    semanage fcontext -a -t cert_t '/opt/raven/data/ca(/.*)?' 2>/dev/null \
      || semanage fcontext -m -t cert_t '/opt/raven/data/ca(/.*)?' 2>/dev/null || true
  fi

  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF /opt/raven/data/ca 2>/dev/null || true
    # /var/www/html(/.*)? is httpd_sys_content_t in the shipped policy even
    # though EL's nginx doesn't use it, so this is just a relabel of what we
    # created above.
    restorecon -RF /var/www/html 2>/dev/null || true
  fi

  # Hand control back to the shim if it wants the last word.
  selinux_fixup || true
fi

# ---------------------------------------------------------------------------
# firewalld. Also absent from the .deb: Ubuntu's ufw is installed but inactive,
# EL9's firewalld is running and default-deny for anything but ssh.
# ---------------------------------------------------------------------------
if [ "${RAVEN_OPEN_FIREWALL,,}" = "true" ]; then
  echo "Opening firewall ports..."
  # nginx: web UI (80/443), the insecure Marti listener (8080), the
  # client-cert-verified Marti listener (8443), certificate enrollment (8446),
  # and the three TLS stream proxies (RTSPS 8322, RTMPS 1936, MQTTS 8883).
  #
  # mediamtx's own plaintext ingest listeners and WebRTC/SRT media paths are in
  # here too. HLS (8888) and WebRTC HTTP (8889) stay closed: they are only ever
  # reached through nginx on 127.0.0.1.
  #
  # 8087/udp, 8088/tcp and 8089/tcp are the EUD ports, which are the whole point
  # of the server. eud_handler and eud_handler_ssl bind them directly rather
  # than through nginx, so they are invisible if you derive this list from
  # nginx_configs/ alone -- which is exactly how they came to be missing here.
  # raven/defaultconfig.py defaults them to 0.0.0.0 with TCP enabled out of the
  # box. Leave them shut and the box comes up green in the web UI while no ATAK
  # client can connect to it.
  #
  # KEEP IN STEP with the removal list in rpm/c4raven-server.spec's %postun and
  # the comment on RAVEN_OPEN_FIREWALL in rpm/setup.conf.
  firewall_open 80/tcp 443/tcp 8080/tcp 8443/tcp 8446/tcp 8322/tcp 1936/tcp \
                8883/tcp 8554/tcp 1935/tcp 8088/tcp 8089/tcp \
                8189/udp 8890/udp 8087/udp
fi

systemctl enable nginx
systemctl restart nginx

if [ -n "$DOMAIN" ]; then
  echo "Requesting a Let's Encrypt certificate for ${DOMAIN}..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
    -m "${RAVEN_CERTBOT_EMAIL:-admin@${DOMAIN}}" --redirect || \
    echo "certbot failed -- check that ${DOMAIN} already resolves to this server's public IP, then run: sudo certbot --nginx -d ${DOMAIN}"
fi

# ---------------------------------------------------------------------------
# Frontend
# ---------------------------------------------------------------------------
if offline; then
  echo "Deploying the bundled C4 Raven UI frontend..."
  install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$WEBROOT"
  rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete "$OFFLINE_DIR/ui/" "$WEBROOT/"
  chown -R "$APP_USER:$APP_USER" "$WEBROOT"
else
  echo "Building and deploying the C4 Raven UI frontend..."
  if [ ! -d "$APP_HOME/c4raven-ui" ]; then
    run_as_app "git clone https://github.com/C4-Raven/c4raven-ui.git '$APP_HOME/c4raven-ui'"
  fi
  if [ -f "$PKGDATA/UI_SHA" ]; then
    UI_SHA=$(cat "$PKGDATA/UI_SHA")
    # src/_versions.ts is a build stamp `yarn build` rewrites; discard it first
    # or git refuses to switch commits.
    run_as_app "cd '$APP_HOME/c4raven-ui' && git checkout -- src/_versions.ts 2>/dev/null; git fetch origin && git checkout '$UI_SHA'"
  fi
  # The UI build (vite 8) needs Node 20.19+ / 22.12+. Unlike the .deb this is
  # not expressible as a hard Requires: EL9's nodejs is a DNF module whose
  # default stream is still 18, so `Requires: nodejs >= 20.19` makes the package
  # uninstallable on a stock box rather than pulling in a newer node. It is a
  # Recommends plus this runtime check instead.
  if ! node_ok; then
    echo "Node.js 20.19+ is required to build the UI but $(node --version 2>/dev/null || echo 'no node') is installed." >&2
    echo "Enable a newer stream and re-run the setup:" >&2
    echo "  sudo dnf module reset nodejs && sudo dnf module enable nodejs:22 && sudo dnf install nodejs" >&2
    echo "  sudo c4raven-setup" >&2
    exit 1
  fi
  command -v corepack >/dev/null 2>&1 || npm install -g corepack
  # c4raven-ui pins yarn 4 (packageManager in package.json) -- npm doesn't
  # understand its lockfile and will silently downgrade/corrupt it.
  # `corepack yarn` runs the pinned version directly.
  run_as_app "cd '$APP_HOME/c4raven-ui' && corepack yarn install"
  run_as_app "cd '$APP_HOME/c4raven-ui' && corepack yarn build"
  # Deploy as root: whatever previously owned files are in the webroot might not
  # be deletable by $APP_USER even though the directory is world-writable
  # (confirmed live against a server whose webroot had www-data-owned files).
  # Root can always write/delete here regardless of prior ownership.
  rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete "$APP_HOME/c4raven-ui/dist/" "$WEBROOT/"
  chown -R "$APP_USER:$APP_USER" "$WEBROOT"
fi
if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF "$WEBROOT" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# RabbitMQ (before the Raven services start: they connect to it on boot)
# ---------------------------------------------------------------------------
echo "Configuring RabbitMQ..."
mkdir -p /etc/rabbitmq
# Plugins first: RabbitMQ refuses to start on mqtt.*/auth_http.* settings whose
# plugins aren't enabled yet.
rabbitmq-plugins enable --offline rabbitmq_mqtt rabbitmq_auth_backend_http
install -m 644 "$PKGDATA/rabbitmq.conf" /etc/rabbitmq/rabbitmq.conf

# The .deb reads the version out of `rabbitmqadmin --version`. RabbitMQ 4.x
# dropped the bundled python rabbitmqadmin in favour of a separate download, so
# take the version straight off the installed tree instead and fall back to
# rabbitmqadmin if that ever stops working.
RABBITMQ_VERSION=$(basename "$(ls -d /usr/lib/rabbitmq/lib/rabbitmq_server-* 2>/dev/null | sort -V | tail -1)" 2>/dev/null | sed 's/^rabbitmq_server-//')
if [ -z "$RABBITMQ_VERSION" ] || [ "$RABBITMQ_VERSION" = "*" ]; then
  RABBITMQ_VERSION=$(rabbitmqadmin --version 2>/dev/null | awk '{print $2}' || true)
fi
if [ -n "$RABBITMQ_VERSION" ] && ! grep -q PLUGINS_DIR /etc/rabbitmq/rabbitmq-env.conf 2>/dev/null; then
  echo "PLUGINS_DIR=\"/usr/lib/rabbitmq/plugins:/usr/lib/rabbitmq/lib/rabbitmq_server-${RABBITMQ_VERSION}/plugins\"" >> /etc/rabbitmq/rabbitmq-env.conf
fi
systemctl enable "$RABBIT_SERVICE"
systemctl restart "$RABBIT_SERVICE"

# ---------------------------------------------------------------------------
# Secrets env file + systemd units (the units themselves are shipped statically
# by the package at /usr/lib/systemd/system/ -- nothing to template, just
# enable/start them)
# ---------------------------------------------------------------------------
echo "Starting services..."
if [ ! -f "$APP_HOME/.raven-secrets.env" ]; then
  cat > "$APP_HOME/.raven-secrets.env" << EOF
RAVEN_DATA_FOLDER=$DATA_DIR
SQLALCHEMY_DATABASE_URI=$DB_URI
RAVEN_RABBITMQ_USERNAME=guest
RAVEN_RABBITMQ_PASSWORD=guest
RAVEN_FEDHUB_ENABLE=False
RAVEN_MEDIAMTX_ENABLE=True
EOF
  chown "$APP_USER:$APP_USER" "$APP_HOME/.raven-secrets.env"
  chmod 600 "$APP_HOME/.raven-secrets.env"
fi

systemctl daemon-reload
systemctl enable mediamtx raven cot_parser eud_handler eud_handler_ssl
systemctl restart mediamtx raven cot_parser eud_handler eud_handler_ssl

# The database schema is created by the migrations the server runs on startup,
# so wait for it to answer before anything touches the database.
echo "Waiting for the Raven server to come up..."
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null http://127.0.0.1:8081/api/health 2>/dev/null; then break; fi
  if [ "$i" -eq 60 ]; then
    echo "raven did not answer on 127.0.0.1:8081 after 2 minutes -- check $DATA_DIR/logs/raven.log"
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# Federation Hub -- requires a licensed TAK.gov account, so this can't be
# prompted for or downloaded automatically. (It is also only published as a
# .deb upstream, which is a second reason it can't be wired in here.)
# ---------------------------------------------------------------------------
echo
echo "Federation Hub requires a takserver-fed-hub package, only available from"
echo "a licensed TAK.gov account and only published as a .deb -- this package"
echo "can't include it. See https://github.com/C4-Raven/federation-hub-setup"
echo "if you have one and want to install it."

# ---------------------------------------------------------------------------
# First admin account. The server creates `administrator`/`password` itself on
# first start; seed_admin.py makes that account change its password on first
# login (or creates it that way if it doesn't exist yet). Exit 3 = real accounts
# already exist, nothing touched.
# ---------------------------------------------------------------------------
echo "Hardening the first administrator account..."
SEEDED=0
raven_exec "python '$PKGDATA/seed_admin.py'" || SEEDED=$?

# ---------------------------------------------------------------------------
# Bundled ATAK plugin(s) (offline build): publish into the package repo so
# enrolling devices are offered them. Never downgrades a newer APK someone
# already uploaded; exit 3 = already published.
# ---------------------------------------------------------------------------
if offline; then
  for apk in "$OFFLINE_DIR"/plugins/*.apk; do
    [ -f "$apk" ] || continue
    echo "Publishing $(basename "$apk") to the ATAK package repository..."
    PUBLISHED=0
    raven_exec "python '$PKGDATA/seed_plugin.py' '$apk'" || PUBLISHED=$?
    case "$PUBLISHED" in
      0|3) ;;
      *) echo "Could not publish $(basename "$apk") (seed_plugin.py exit $PUBLISHED). Once raven is running: sudo -u $APP_USER -H bash -lc \"cd $DATA_DIR && $FLASK_ENV $APP_HOME/venv/bin/python $PKGDATA/seed_plugin.py $apk\"" ;;
    esac
  done

  # The new services are running from the new venv; drop older ones.
  CURRENT_VENV=$(readlink -f "$APP_HOME/venv")
  for d in "$APP_HOME"/venvs/*; do
    if [ -d "$d" ] && [ "$(readlink -f "$d")" != "$CURRENT_VENV" ]; then
      rm -rf "$d"
    fi
  done
fi

echo
echo "Setup complete."
if [ -n "$DOMAIN" ]; then
  echo "Web UI: https://${DOMAIN}"
else
  echo "Web UI: https://${HOST_IP}"
fi
case "$SEEDED" in
  0) echo "First login: username 'administrator', password 'password' -- you'll be required to set a real password immediately." ;;
  3) echo "Existing accounts were left untouched -- log in with your usual administrator credentials." ;;
  *)
    if offline; then
      echo "Could not verify the administrator account (seed_admin.py exit $SEEDED). Once raven is running: sudo -u $APP_USER -H bash -lc \"cd $DATA_DIR && $FLASK_ENV $APP_HOME/venv/bin/python $PKGDATA/seed_admin.py\""
    else
      echo "Could not verify the administrator account (seed_admin.py exit $SEEDED). Once raven is running: sudo -u $APP_USER -H bash -lc \"cd $APP_HOME/c4raven-server && $FLASK_ENV poetry run python $PKGDATA/seed_admin.py\""
    fi
    ;;
esac

exit 0
