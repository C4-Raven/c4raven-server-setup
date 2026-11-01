#!/bin/bash
# C4 Raven TAK Server -- one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/install.sh | bash
#
# Installs the full stack in one pass, under a dedicated `raven` system
# account rather than whatever user runs this script: system packages,
# PostgreSQL, RabbitMQ, the Raven backend + C4 Raven UI frontend (via
# Poetry and Yarn, matching what each repo actually pins), nginx, mediamtx,
# and systemd units. Also offers Cloudflare Turnstile bot protection, a
# public domain with a real Let's Encrypt certificate, and TAK Federation
# Hub.
#
# Run as your own sudo-capable user, NOT as root and NOT as `raven` itself
# -- this script creates and uses that account via `sudo -u raven`.
#
# Runs on Ubuntu/Debian and on Rocky/Alma/RHEL 9, amd64 or arm64. Everything
# that differs between the two families (package manager and package names,
# nginx layout, PostgreSQL initdb, firewalld, SELinux) goes through
# lib/distro.sh rather than being open-coded here.
#
# Safe to re-run: every step checks for existing state before creating it.
set -euo pipefail

APP_USER="raven"
APP_HOME="/opt/raven"
DATA_DIR="$APP_HOME/data"
DB_NAME="raven"
WEBROOT="/var/www/html/raven"

# mktemp -d, not a fixed /tmp/raven_installer: this directory now holds
# lib/distro.sh, which is sourced straight into this (sudo-capable) shell, and
# on EL also c4raven-el9-repos.sh, which is run as root. With a predictable
# name any local user could create the directory first, own it, and swap either
# file between the curl and the use of it -- arbitrary code as the installing
# admin, and root on Rocky. mktemp gives us a fresh 0700 directory we own.
INSTALLER_DIR=$(mktemp -d -t raven_installer.XXXXXXXX)
cd "$INSTALLER_DIR"

# Overridable so the test harness (and anyone installing from a fork or a
# local checkout: REPO_RAW=file:///path/to/c4raven-server-setup) can point the
# installer at its own copies of the templates fetched below.
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master}"

# Every download goes through curl with retries: a fresh cloud VM's network
# is often not quite up yet, and GitHub's raw host sheds load with 429/5xx.
# --retry-connrefused also retries "connection refused" (a proxy still
# starting); curl's --retry already covers timeouts and transient HTTP codes.
CURL_RETRY="--retry 5 --retry-delay 3 --retry-connrefused"
fetch() {
  # shellcheck disable=SC2086
  curl -fsSL $CURL_RETRY "$@"
}

fetch "$REPO_RAW/colors.sh" -o "$INSTALLER_DIR/colors.sh"
# shellcheck source=/dev/null
. "$INSTALLER_DIR/colors.sh"

# Everything that differs between distro families lives in lib/distro.sh,
# and the retry/container/recovery helpers in lib/installer.sh. This script
# is normally run as `curl ... | bash`, so the repo is NOT on disk -- fetch
# them exactly the way colors.sh is fetched above.
fetch "$REPO_RAW/lib/distro.sh" -o "$INSTALLER_DIR/distro.sh"
# shellcheck source=lib/distro.sh
. "$INSTALLER_DIR/distro.sh"
fetch "$REPO_RAW/lib/installer.sh" -o "$INSTALLER_DIR/installer.sh"
# shellcheck source=lib/installer.sh
. "$INSTALLER_DIR/installer.sh"

# curl -f catches a 404 or a dead connection, but not a captive portal or
# transparent proxy that answers 200 with an HTML body: sourcing that dies
# partway and can leave us with some functions defined and others missing, so
# the install would get as far as `apt upgrade` before failing on the first
# absent one. Check the whole surface we rely on before touching the system.
for _fn in detect_distro distro_supported pkg_refresh pkg_install \
           pkg_install_optional apt_noninteractive stack_packages stack_packages_optional \
           setup_extra_repos pg_init node_install firewall_open \
           selinux_fixup nginx_site_file nginx_disable_default_site \
           nginx_enable_site nginx_remove_site \
           ih_retry ih_require_systemd ih_clone_repo ih_uri_password ih_uri_user \
           ih_env_value ih_heads_match ih_heads_py ih_own_logs ih_print_recovery; do
  command -v "$_fn" >/dev/null 2>&1 || {
    echo "${RED}lib/distro.sh or lib/installer.sh did not load correctly ($_fn is missing) -- aborting before anything on this system is changed.${NC}"
    exit 1
  }
done
unset _fn

detect_distro
if ! distro_supported; then
  read -rp "${YELLOW}This installer is written for Ubuntu/Debian and Rocky/Alma/RHEL 9, but this system is $DISTRO_NAME ${DISTRO_VERSION_ID}. Continue anyway? [y/N] ${NC}" confirm < /dev/tty
  [[ "$confirm" =~ ^[yY]([eE][sS])?$ ]] || exit 1
fi

# setup_extra_repos prefers rpm/c4raven-el9-repos.sh when it can see it: that
# script, not this one, is the source of truth for which repository each EL
# package comes from and for the aarch64 erlang caveat. Same curl-it-down
# reason as above. Empty (and unused) on Debian.
EL_REPOS_SCRIPT=""
if [ "$DISTRO_FAMILY" = rhel ]; then
  if curl -fsSL "$REPO_RAW/rpm/c4raven-el9-repos.sh" -o "$INSTALLER_DIR/c4raven-el9-repos.sh"; then
    EL_REPOS_SCRIPT="$INSTALLER_DIR/c4raven-el9-repos.sh"
  else
    # Don't let this fail quietly. setup_extra_repos' built-in fallback adds
    # EPEL, CRB and the RabbitMQ server repository, but not rabbitmq.com's
    # x86_64 erlang repo or the nodejs module stream that
    # rpm/c4raven-el9-repos.sh sets up (so rabbitmq-server is capped at 4.3.2
    # by EPEL's erlang) -- say which copy of the repo logic is in use.
    echo "${RED}Could not fetch rpm/c4raven-el9-repos.sh.${NC}"
    echo "${YELLOW}Falling back to lib/distro.sh's built-in repository setup (EPEL, CRB,${NC}"
    echo "${YELLOW}RabbitMQ). If a package fails to resolve below, fix your network and re-run.${NC}"
  fi
fi

if [ "$(whoami)" == "root" ]; then
  echo "${RED}Don't run this as root -- run it as your own sudo-capable user. It creates and uses a dedicated '$APP_USER' account itself.${NC}"
  exit 1
fi
if [ "$(whoami)" == "$APP_USER" ]; then
  echo "${RED}Don't run this as '$APP_USER' directly -- run it as your own sudo-capable user instead.${NC}"
  exit 1
fi

# Containers: a plain `docker run ubuntu` has no systemd, and this install is
# nothing but systemd units. Without this check it would apt-install for ten
# minutes and then die at the first `systemctl`, half done.
if ! ih_require_systemd; then
  echo "${RED}Nothing on this system has been changed.${NC}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Progress + failure reporting. step() names what is happening, so that when
# a command fails under `set -e` the EXIT trap can say which part of the
# install stopped and how to resume, rather than leaving a bare error from
# deep inside apt or poetry as the last line on screen.
# ---------------------------------------------------------------------------
CURRENT_STEP="preflight"
FAIL_LINE=""
step() {
  CURRENT_STEP="$1"
  echo "${GREEN}$1...${NC}"
}
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo
    echo "${RED}The install stopped while: ${CURRENT_STEP} (exit $rc${FAIL_LINE:+, install.sh line $FAIL_LINE}).${NC}"
    ih_print_recovery "curl -fsSL https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/install.sh | bash"
  fi
  rm -rf "$INSTALLER_DIR"
}
trap 'FAIL_LINE=$LINENO' ERR
trap on_exit EXIT

ask_yn() {
  # ask_yn "question" [ENV_VAR] -> returns 0 for yes, 1 for no.
  # If ENV_VAR is set (to anything, even empty), it is the answer and the tty
  # is never touched: y/yes/true/1 mean yes, anything else no. That is what
  # makes an unattended run possible -- with no tty, `read < /dev/tty` fails
  # and `set -e` ends the install. The variable names match the .deb/.rpm
  # ones (RAVEN_TURNSTILE_ENABLE, ...).
  local reply var="${2:-}"
  if [ -n "$var" ] && [ -n "${!var+x}" ]; then
    case "${!var}" in
      [yY]|[yY][eE][sS]|[tT][rR][uU][eE]|1) return 0 ;;
      *) return 1 ;;
    esac
  fi
  while true; do
    read -rp "${GREEN}$1${NC} [y/n] " reply < /dev/tty
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]) return 1 ;;
      *) echo "${RED}Please answer y or n.${NC}" ;;
    esac
  done
}

# Runs a command as the dedicated app user, through a login shell so the
# skeleton profile puts ~/.local/bin (poetry, yarn via corepack) on PATH --
# ~/.profile on Debian/Ubuntu, ~/.bash_profile on EL; both /etc/skel copies
# prepend it.
#
# `cd ~` first: sudo keeps our cwd, which is $INSTALLER_DIR -- a 0700
# directory the app user cannot read. Commands that don't cd themselves
# (`poetry config`) look for a pyproject.toml there and die with
# "Permission denied: '/tmp/raven_installer.XXXXXXXX'".
run_as_app() {
  sudo -u "$APP_USER" -H bash -lc "cd ~ && $1"
}

# Same cwd problem for the postgres account: without `cd ~`, every psql call
# first prints `could not change directory to "/tmp/raven_installer.XXXXXXXX":
# Permission denied`.
run_as_pg() {
  sudo su postgres -c "cd ~ && $1"
}

step "Installing system packages via ${PKG_MGR} (you may be prompted for your sudo password)"
# EL only: EPEL + CRB (certbot, erlang, ffmpeg-free) and the RabbitMQ repo,
# none of which the names below resolve without. No-op on Debian, where
# everything is in main/universe.
ih_retry setup_extra_repos "$EL_REPOS_SCRIPT"
# Retried: a mirror mid-sync (hash sum mismatch), a dropped connection, or
# on a freshly booted cloud image unattended-upgrades holding the dpkg lock
# (apt_noninteractive also waits up to 10 minutes for that lock itself).
ih_retry pkg_refresh
# Word splitting is the point here -- stack_packages returns a list.
# shellcheck disable=SC2046
ih_retry pkg_install $(stack_packages)

# Packages we'd like but can live without (EL only today: there is no plain
# ffmpeg outside RPM Fusion and no PostGIS outside PGDG). Losing one of these
# costs a feature; losing the install to `set -e` over it costs the server.
for pkg in $(stack_packages_optional); do
  case "$pkg" in
    ffmpeg|ffmpeg-free) degraded="stream thumbnails and recording metadata" ;;
    postgis)            degraded="PostGIS geospatial columns" ;;
    *)                  degraded="anything that needs $pkg" ;;
  esac
  ih_retry -n 2 pkg_install_optional "$pkg" || \
    echo "${YELLOW}Could not install '$pkg' -- continuing without it. $degraded will be unavailable.${NC}"
done

# Node.js: the UI build (vite 8) needs Node 20.19+ / 22.12+, and neither
# family's own package is new enough -- Ubuntu 24.04's `nodejs` is 18.x with
# no corepack at all, and EL9's nodejs module stream defaults to 18 too.
# node_install uses the NodeSource 22.x LTS repo (deb.nodesource.com or
# rpm.nodesource.com, both of which publish amd64 and arm64) unless a
# new-enough node is already installed.
if ! node_ok; then
  step "Installing Node.js 22 (NodeSource)"
fi
ih_retry node_install
# corepack runs the yarn version c4raven-ui pins; NodeSource ships it, but
# make sure, since a distro node may not -- and on EL the distro node splits
# npm into its own package, so `sudo npm` may not exist to install it with.
COREPACK=$(command -v corepack 2>/dev/null || true)
if [ -z "$COREPACK" ]; then
  command -v npm >/dev/null 2>&1 || ih_retry pkg_install npm
  ih_retry sudo npm install -g corepack
  # By its full path: npm's global prefix is /usr/local, and EL's sudo
  # secure_path (which run_as_app runs under) leaves /usr/local/bin out.
  COREPACK="$(sudo npm prefix -g)/bin/corepack"
fi

step "Setting up the dedicated '$APP_USER' account"
if ! id "$APP_USER" &>/dev/null; then
  sudo useradd --system --create-home --home-dir "$APP_HOME" --shell /bin/bash "$APP_USER"
  sudo chmod 750 "$APP_HOME"
fi
run_as_app "mkdir -p '$DATA_DIR/logs'"

# ---------------------------------------------------------------------------
# Backend: clone + install (Poetry, in-project .venv -- this repo pins its
# dependency versions in poetry.lock, so `pip install -e` (which ignores
# the lockfile) is not equivalent)
# ---------------------------------------------------------------------------
step "Cloning and installing the Raven backend"
# An existing checkout is used as it is (never pulled or reset: updating it
# is c4raven-updater's job, and a re-run must not move it under a database
# migrated by the code that is there). A clone a network drop cut short is
# detected and redone.
ih_clone_repo run_as_app https://github.com/C4-Raven/c4raven-server.git "$APP_HOME/c4raven-server"

if ! sudo test -x "$APP_HOME/.local/bin/poetry"; then
  ih_retry run_as_app "set -o pipefail; curl -fsSL $CURL_RETRY https://install.python-poetry.org | $PYTHON_BIN -"
fi
run_as_app "poetry config virtualenvs.in-project true"
# c4raven-server pins python = ">=3.10, <3.15". EL9's `python3` is 3.9, so
# PYTHON_BIN is python3.12 there and poetry has to be told about it
# explicitly -- left to itself it builds .venv against 3.9 and `poetry
# install` then fails the constraint. Debian's python3 is already in range,
# and poetry picks it on its own, so leave that path exactly as it was.
if [ "$DISTRO_FAMILY" = rhel ]; then
  run_as_app "cd '$APP_HOME/c4raven-server' && poetry env use \$(command -v $PYTHON_BIN)"
fi
# Retried: PyPI and files.pythonhosted.org time out often enough on a
# fresh VM to matter. Re-running resumes; poetry skips what is installed.
ih_retry run_as_app "cd '$APP_HOME/c4raven-server' && poetry install"

# There's no top-level app.py/wsgi.py for Flask's CLI to auto-discover, and
# RAVEN_DATA_FOLDER has to be set for every ad-hoc `flask raven ...` call
# below (the app itself gets it from EnvironmentFile at runtime, but that
# file doesn't exist yet the first time we run these).
FLASK_ENV="FLASK_APP=raven.app RAVEN_DATA_FOLDER='$DATA_DIR'"

# Writes config.yml only if there isn't one: an existing config.yml (a
# re-run, or a reinstall over a working server) is kept exactly as it is.
run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run flask raven generate-config"

# New settings (RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH in 2.3.0, ...) come with
# the fresh config.yml generate-config writes. An existing config.yml is
# deliberately NOT given them: a key written into config.yml overrides the
# environment variable of the same name, and the app already falls back to
# DefaultConfig's value for any key that is absent.
echo "${GREEN}Raven backend installed.${NC}"

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
step "Setting up PostgreSQL"
# Debian's packaging creates a cluster and starts it at install time; EL's
# leaves the data directory empty and the service refusing to start until
# `postgresql-setup --initdb` has run, and then defaults host connections to
# `ident`, which rejects the password auth the app's 127.0.0.1 URI needs.
# pg_init does whichever of those apply, idempotently, and leaves the
# run_as_pg (`sudo su postgres`) calls below working unchanged on both.
pg_init
# pg_init has just (re)started the server; give it a moment to accept
# connections rather than failing the first psql on a slow box.
for _ in $(seq 30); do
  run_as_pg "pg_isready -q" 2>/dev/null && break
  sleep 1
done
DB_USER_EXISTS=$(run_as_pg "psql -tXAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_NAME'\"")
# The role's password works iff libpq can log in with it over TCP, exactly
# the way the app does.
db_password_works() {
  [ -n "$1" ] && PGPASSWORD="$1" PGCONNECT_TIMEOUT=5 \
    psql -h 127.0.0.1 -U "$DB_NAME" -d postgres -XtAc 'SELECT 1' >/dev/null 2>&1
}
POSTGRESQL_PASSWORD=""
if [ "$DB_USER_EXISTS" != 1 ]; then
  # Hex only: this goes raw into a URI, where `%` would be percent-decoded
  # by SQLAlchemy/libpq. (Not `tr ... | head -c`: under pipefail, head
  # closing the pipe kills tr with SIGPIPE and the whole script with it.)
  POSTGRESQL_PASSWORD=$(openssl rand -hex 16)
  run_as_pg "psql -c \"create role $DB_NAME with login password '${POSTGRESQL_PASSWORD}';\""
else
  # A re-run (or a reinstall over a working server): the role is there, and
  # its password is in config.yml and/or .raven-secrets.env from that run.
  # Recover it rather than asking -- a prompt here used to stall unattended
  # re-runs, and a mistyped answer broke the server's DB login.
  for _uri in \
      "$(sudo sed -n 's/^SQLALCHEMY_DATABASE_URI: *//p' "$DATA_DIR/config.yml" 2>/dev/null | tr -d "'\"" || true)" \
      "$(sudo cat "$APP_HOME/.raven-secrets.env" 2>/dev/null | sed -n 's/^SQLALCHEMY_DATABASE_URI=//p' | tr -d "'\"" || true)" \
      "postgresql://$DB_NAME:${RAVEN_DB_PASSWORD:-}@127.0.0.1/$DB_NAME"; do
    [ "$(ih_uri_user "$_uri" 2>/dev/null || true)" = "$DB_NAME" ] || continue
    _pw=$(ih_uri_password "$_uri" 2>/dev/null || true)
    if db_password_works "$_pw"; then
      POSTGRESQL_PASSWORD="$_pw"
      break
    fi
  done
  unset _uri _pw
  if [ -n "$POSTGRESQL_PASSWORD" ]; then
    echo "${GREEN}PostgreSQL role '$DB_NAME' already exists; reusing its password from the previous install.${NC}"
  else
    # Nothing on disk logs in. The role belongs to this install alone (its
    # only consumers are config.yml and .raven-secrets.env, both rewritten
    # below), so give it a fresh password instead of failing. The data in
    # the database is untouched.
    echo "${YELLOW}PostgreSQL role '$DB_NAME' exists but no saved password works for it; setting a new one (database contents are untouched).${NC}"
    POSTGRESQL_PASSWORD=$(openssl rand -hex 16)
    run_as_pg "psql -c \"alter role $DB_NAME with login password '${POSTGRESQL_PASSWORD}';\""
  fi
fi
DB_URI="postgresql+psycopg://$DB_NAME:${POSTGRESQL_PASSWORD}@127.0.0.1/$DB_NAME"
run_as_app "$PYTHON_BIN - '$DB_URI' << 'PYEOF'
import sys, yaml
uri = sys.argv[1]
path = '$DATA_DIR/config.yml'
with open(path) as f:
    conf = yaml.safe_load(f)
conf['SQLALCHEMY_DATABASE_URI'] = uri
with open(path, 'w') as f:
    yaml.safe_dump(conf, f)
PYEOF"

step "Creating the database"
DB_EXISTS=$(run_as_pg "psql -XtAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"")
if [ "$DB_EXISTS" != 1 ]; then
  run_as_pg "psql -c 'create database $DB_NAME;'"
fi
run_as_pg "psql -c 'GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO $DB_NAME;'"
run_as_pg "psql -d $DB_NAME -c 'GRANT ALL ON SCHEMA public TO $DB_NAME;'"
# PostGIS is best-effort, not fatal: EL9 has no PostGIS package in AppStream
# or EPEL at all (it only exists in PGDG), so this statement WILL fail there
# on a stock box -- and under `set -e` that would end the install right here,
# before any of the services below are created. Nothing in the current schema
# needs it.
run_as_pg "psql -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgis'" || \
  echo "${YELLOW}Could not create the postgis extension -- continuing without it. Geospatial columns will be unavailable; install PostGIS for this PostgreSQL (on EL that means the PGDG repo) and re-run this script to add it.${NC}"
echo "${GREEN}Database ready.${NC}"
# Migrations run automatically inside the app itself on every startup
# (see init_extensions() in raven/app.py) -- no separate `flask db upgrade`
# step here. The final health check below confirms the database actually
# reached the code's alembic head(s), and says so loudly if it did not.

# ---------------------------------------------------------------------------
# Cloudflare Turnstile (bot protection on login)
# ---------------------------------------------------------------------------
# Unattended: RAVEN_TURNSTILE_ENABLE=true plus RAVEN_TURNSTILE_SITE_KEY and
# RAVEN_TURNSTILE_SECRET_KEY (a key left unset is still asked for).
# On a re-run where Turnstile is already on (and the environment does not
# say otherwise), leave it be rather than asking again.
TURNSTILE_ALREADY=$(sudo sed -n 's/^RAVEN_TURNSTILE_ENABLE: *//p' "$DATA_DIR/config.yml" 2>/dev/null || true)
if [ -z "${RAVEN_TURNSTILE_ENABLE+x}" ] && [ "$TURNSTILE_ALREADY" = true ]; then
  echo "${GREEN}Cloudflare Turnstile is already enabled in config.yml; keeping its keys.${NC}"
elif ask_yn "Enable Cloudflare Turnstile (the human-verification checkbox) on the login page?" RAVEN_TURNSTILE_ENABLE; then
  TURNSTILE_SITE_KEY="${RAVEN_TURNSTILE_SITE_KEY:-}"
  TURNSTILE_SECRET_KEY="${RAVEN_TURNSTILE_SECRET_KEY:-}"
  if [ -z "$TURNSTILE_SITE_KEY" ] || [ -z "$TURNSTILE_SECRET_KEY" ]; then
    echo "Get a site key + secret key from the Cloudflare dashboard -> Turnstile first, if you haven't already."
  fi
  [ -n "$TURNSTILE_SITE_KEY" ] || read -rp "${GREEN}Turnstile site key: ${NC}" TURNSTILE_SITE_KEY < /dev/tty
  [ -n "$TURNSTILE_SECRET_KEY" ] || read -rp "${GREEN}Turnstile secret key: ${NC}" TURNSTILE_SECRET_KEY < /dev/tty
  run_as_app "$PYTHON_BIN - '$TURNSTILE_SITE_KEY' '$TURNSTILE_SECRET_KEY' << 'PYEOF'
import sys, yaml
site_key, secret_key = sys.argv[1], sys.argv[2]
path = '$DATA_DIR/config.yml'
with open(path) as f:
    conf = yaml.safe_load(f)
conf['RAVEN_TURNSTILE_ENABLE'] = True
conf['RAVEN_TURNSTILE_SITE_KEY'] = site_key
conf['RAVEN_TURNSTILE_SECRET_KEY'] = secret_key
with open(path, 'w') as f:
    yaml.safe_dump(conf, f)
PYEOF"
  echo "${GREEN}Turnstile configured.${NC}"
fi

# ---------------------------------------------------------------------------
# Domain (optional -- gets you a real, trusted cert for the web UI instead
# of a self-signed one, and is required if you want Federation Hub to be
# reachable by a hostname rather than a raw IP)
# ---------------------------------------------------------------------------
# Unattended: RAVEN_DOMAIN=tak.example.org, or RAVEN_DOMAIN= (set but empty)
# for no domain. Either way the question is not asked.
#
# The answer is remembered in $APP_HOME/.install-answers, so a re-run after a
# failure resumes with the same domain instead of asking again (and, if the
# question were answered differently, tearing down the domain's 8446 block).
# RAVEN_DOMAIN in the environment always wins.
ANSWERS_FILE="$APP_HOME/.install-answers"
PREV_DOMAIN=""
if sudo test -f "$ANSWERS_FILE"; then
  PREV_DOMAIN=$(sudo sed -n 's/^RAVEN_DOMAIN=//p' "$ANSWERS_FILE" | tail -n 1)
fi
DOMAIN="${RAVEN_DOMAIN:-}"
if [ -z "${RAVEN_DOMAIN+x}" ] && sudo test -f "$ANSWERS_FILE" && sudo grep -q '^RAVEN_DOMAIN=' "$ANSWERS_FILE"; then
  DOMAIN="$PREV_DOMAIN"
  echo "${GREEN}Using the domain from the previous run: ${DOMAIN:-(none)}. Set RAVEN_DOMAIN=... (or RAVEN_DOMAIN= for none) to change it.${NC}"
elif [ -z "${RAVEN_DOMAIN+x}" ] && ask_yn "Do you want to configure a public domain name for this server?"; then
  read -rp "${GREEN}Domain (e.g. tak.example.com, must already point at this server's IP): ${NC}" DOMAIN < /dev/tty
fi
printf 'RAVEN_DOMAIN=%s\n' "$DOMAIN" | sudo tee "$ANSWERS_FILE" >/dev/null
sudo chmod 600 "$ANSWERS_FILE"

# ---------------------------------------------------------------------------
# Certificate authority
# ---------------------------------------------------------------------------
step "Creating the certificate authority"
# create-ca is a no-op when the CA exists. issue-server-certificate is NOT:
# it wipes and regenerates certs/raven/ (CertificateAuthority.issue_certificate
# does an unconditional rmtree), so only run it when there is no server
# certificate yet -- a re-run must not swap the cert nginx and mediamtx use.
# Same guard as debian/c4raven-server.postinst and rpm/configure.sh.
run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run flask raven create-ca"
if ! sudo test -s "$DATA_DIR/ca/certs/raven/raven.pem" || ! sudo test -s "$DATA_DIR/ca/certs/raven/raven.nopass.key"; then
  run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run flask raven issue-server-certificate"
else
  echo "${GREEN}Keeping the existing server certificate.${NC}"
fi
if ! sudo test -s "$DATA_DIR/ca/ca.pem" || ! sudo test -s "$DATA_DIR/ca/certs/raven/raven.pem"; then
  echo "${RED}The certificate authority or server certificate was not created (no $DATA_DIR/ca/ca.pem or certs/raven/raven.pem).${NC}"
  exit 1
fi

# ---------------------------------------------------------------------------
# mediamtx
# ---------------------------------------------------------------------------
step "Installing mediamtx"
MEDIAMTX_VERSION=1.13.0
run_as_app "mkdir -p '$DATA_DIR/mediamtx/recordings'"
if ! sudo test -x "$DATA_DIR/mediamtx/mediamtx"; then
  # ARCH_MTX is this machine in mediamtx's release-asset spelling
  # (amd64/arm64/armv7), from detect_distro. The version is pinned, so the
  # asset URL is known: fetch it directly (with retries) rather than asking
  # the GitHub API, whose 60-requests/hour anonymous limit is easy to hit
  # from a shared NAT. lastversion (a backend dependency, already in the
  # Poetry venv) remains the fallback. Downloaded to a temporary name and
  # checked before extraction, so an interrupted download is redone on the
  # next run instead of leaving a corrupt archive behind.
  MTX_TGZ="$DATA_DIR/mediamtx/mediamtx.tar.gz.part"
  MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_linux_${ARCH_MTX}.tar.gz"
  if ! ih_retry run_as_app "curl -fsSL $CURL_RETRY '$MTX_URL' -o '$MTX_TGZ' && tar -tzf '$MTX_TGZ' >/dev/null"; then
    echo "${YELLOW}Direct mediamtx download failed; trying lastversion...${NC}"
    ih_retry run_as_app "cd '$APP_HOME/c4raven-server' && rm -f '$MTX_TGZ' && poetry run lastversion --filter '~*linux_$ARCH_MTX' --only $MEDIAMTX_VERSION -o '$MTX_TGZ' --assets download bluenviron/mediamtx && tar -tzf '$MTX_TGZ' >/dev/null"
  fi
  run_as_app "cd '$DATA_DIR/mediamtx' && tar -xzf '$MTX_TGZ' mediamtx && rm -f '$MTX_TGZ'"
fi
# Kept when present: mediamtx.yml is the admin's (and Raven rewrites parts of
# it at runtime). The substitutions below only touch placeholders, so they
# are no-ops on a file a previous run already filled in.
if ! sudo test -s "$DATA_DIR/mediamtx/mediamtx.yml"; then
  run_as_app "curl -fsSL $CURL_RETRY '$REPO_RAW/mediamtx.yml' -o '$DATA_DIR/mediamtx/mediamtx.yml.part' && mv '$DATA_DIR/mediamtx/mediamtx.yml.part' '$DATA_DIR/mediamtx/mediamtx.yml'"
fi
sudo sed -i \
  -e "s~OTS_FOLDER~$DATA_DIR~g" \
  -e "s~SERVER_CERT_FILE~$DATA_DIR/ca/certs/raven/raven.pem~g" \
  -e "s~SERVER_KEY_FILE~$DATA_DIR/ca/certs/raven/raven.nopass.key~g" \
  "$DATA_DIR/mediamtx/mediamtx.yml"
# WebRTC clients outside the LAN can only reach us if mediamtx advertises a
# public host in its ICE candidates, not just the interface IPs.
sudo sed -i "s~^webrtcAdditionalHosts: \[\]~webrtcAdditionalHosts: [${DOMAIN:-$(hostname -I | awk '{print $1}')}]~" \
  "$DATA_DIR/mediamtx/mediamtx.yml"
# Fill in MediaMTX's webhook token now, from the config.yml generate-config
# wrote. Otherwise the first Raven process to start rewrites mediamtx.yml
# while mediamtx is already running; mediamtx hot-reloads, collides with its
# own RTSP listener ("bind: address already in use") and exits.
MTX_TOKEN_VALUE=$(sudo sed -n "s/^RAVEN_MEDIAMTX_TOKEN: *//p" "$DATA_DIR/config.yml" | tr -d "'\"")
if [ -n "$MTX_TOKEN_VALUE" ]; then
  sudo sed -i "s~MTX_TOKEN~$MTX_TOKEN_VALUE~g" "$DATA_DIR/mediamtx/mediamtx.yml"
fi

# Restart=always, not on-failure: mediamtx exits 0 when a hot reload of
# mediamtx.yml fails, which on-failure treats as a clean stop.
sudo tee /etc/systemd/system/mediamtx.service >/dev/null << EOF
[Unit]
Wants=network.target
After=network.target
[Service]
User=$APP_USER
ExecStart=$DATA_DIR/mediamtx/mediamtx $DATA_DIR/mediamtx/mediamtx.yml
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
step "Configuring nginx"
# Where these files go differs per family and is decided by lib/distro.sh:
# Debian has sites-available + a sites-enabled symlink farm, EL includes
# /etc/nginx/conf.d/*.conf straight from http{} with nothing to symlink and a
# mandatory .conf suffix. nginx_site_file/nginx_stream_file spell the path,
# nginx_enable_site/nginx_enable_stream do the symlink where there is one.
sudo mkdir -p "$NGINX_SITES_DIR" "$NGINX_STREAMS_DIR"
if [ -n "$NGINX_SITES_ENABLED_DIR" ]; then
  sudo mkdir -p "$NGINX_SITES_ENABLED_DIR"
fi
if [ -n "$NGINX_STREAMS_ENABLED_DIR" ]; then
  sudo mkdir -p "$NGINX_STREAMS_ENABLED_DIR"
fi

# stream{} is a top-level block, so it can't come from an http{} include --
# on both families it has to be appended to nginx.conf itself. The stream
# module packages (libnginx-mod-stream / nginx-mod-stream) only supply the
# load_module line.
if ! grep -q "stream {" "$NGINX_CONF"; then
  echo "
stream {
        include $(nginx_stream_include);
}" | sudo tee -a "$NGINX_CONF" > /dev/null
fi

# Get the distro's own welcome page out of raven_http's way: on Debian that's
# the default file in sites-enabled, on EL an inline `listen 80 default_server`
# block in nginx.conf (commented out in place, with a .c4raven.bak beside it).
# Non-fatal: on failure it restores nginx.conf and prints the by-hand fix;
# aborting the whole install here would only leave less of it done.
nginx_disable_default_site || true

# Both raven_http and raven_https do `include proxy_params;` in their
# /socket.io block. Debian's nginx package ships that file; EL's does not,
# and nginx refuses to load its entire configuration over a missing include.
if [ ! -f /etc/nginx/proxy_params ]; then
  fetch "$REPO_RAW/rpm/proxy_params" -o "$INSTALLER_DIR/proxy_params"
  sudo install -m 644 "$INSTALLER_DIR/proxy_params" /etc/nginx/proxy_params
fi

# Fetched to the installer's temp dir first and only then moved into place:
# a download that dies halfway must not leave nginx a truncated site file.
# (These templates are refreshed on every run -- that is how a re-run picks
# up fixes such as the X-Ssl-Cert clearing. certbot's edits to raven_https
# are redone by the certbot step below.)
for f in raven_http raven_https raven_certificate_enrollment rabbitmq mediamtx; do
  fetch "$REPO_RAW/nginx_configs/$f" -o "$INSTALLER_DIR/nginx_$f"
done
for f in raven_http raven_https raven_certificate_enrollment; do
  sudo install -m 644 "$INSTALLER_DIR/nginx_$f" "$(nginx_site_file "$f")"
done
for f in rabbitmq mediamtx; do
  sudo install -m 644 "$INSTALLER_DIR/nginx_$f" "$(nginx_stream_file "$f")"
done

for f in "$(nginx_site_file raven_https)" "$(nginx_site_file raven_certificate_enrollment)" \
         "$(nginx_stream_file rabbitmq)" "$(nginx_stream_file mediamtx)"; do
  sudo sed -i \
    -e "s~SERVER_CERT_FILE~$DATA_DIR/ca/certs/raven/raven.pem~g" \
    -e "s~SERVER_KEY_FILE~$DATA_DIR/ca/certs/raven/raven.nopass.key~g" \
    -e "s~CA_CERT_FILE~$DATA_DIR/ca/ca.pem~g" \
    "$f"
done

for f in raven_http raven_https raven_certificate_enrollment; do
  nginx_enable_site "$f"
done
nginx_enable_stream rabbitmq
nginx_enable_stream mediamtx

# Owned by the app user, not world-writable: any local account could
# otherwise swap out the served JavaScript.
sudo install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$WEBROOT"

# SELinux, EL only and a no-op everywhere else. Without this nginx (httpd_t)
# cannot open a socket to the backend at all -- every proxy_pass 502s while
# the backend tests perfectly healthy on localhost -- cannot bind 8080/8446
# or the TLS media proxies, 403s every file in the webroot, and cannot read
# the CA's server cert out of /opt. See lib/distro.sh for the detail.
selinux_fixup
selinux_fix_webroot "$WEBROOT"
selinux_fix_certs "$DATA_DIR/ca"

# firewalld runs enforcing and default-deny on Rocky/RHEL, where none of this
# is reachable until the ports are opened; on Ubuntu ufw ships inactive and
# this is a no-op (and firewall_open will never *enable* a firewall that is
# off -- doing that mid-install would drop the installer's own SSH session).
#
# The list is exactly what this stack listens on from off-box. Every `listen`
# in nginx_configs/: 80 + 8080 (raven_http), 443 + 8443 (raven_https), 8446
# (raven_certificate_enrollment), and the three TLS stream proxies 8322 RTSPS,
# 1936 RTMPS, 8883 MQTTS. Plus mediamtx.yml's own listeners that nothing
# proxies: 8554 RTSP and 1935 RTMP ingest (it has encryption "no" /
# rtmpEncryption "no", so it leaves 8322 and 1936 to nginx), 8189/udp WebRTC
# ICE and 8890/udp SRT. mediamtx's HLS (8888) and WebRTC HTTP (8889) stay
# shut: nginx only ever reaches those over 127.0.0.1.
#
# And the EUD ports, which are the whole point of the server: eud_handler and
# eud_handler_ssl bind these directly, not through nginx, so they are easy to
# miss when reading nginx_configs/ alone. raven/defaultconfig.py defaults them
# to 8087/udp, 8088/tcp and 8089/tcp on 0.0.0.0 with the TCP listener enabled
# out of the box -- leave them shut and a firewalld box comes up looking
# perfectly healthy in the web UI while no ATAK client can connect to it.
firewall_open 80/tcp 443/tcp 8080/tcp 8443/tcp 8446/tcp 8322/tcp 1936/tcp 8883/tcp \
              8554/tcp 1935/tcp 8189/udp 8890/udp \
              8088/tcp 8089/tcp 8087/udp

# Take the 8446 domain block (written below on a previous run) out of
# nginx's sight first, and unconditionally: with a domain, it has
# `server_name $DOMAIN`, and certbot installs into the FIRST ssl block whose
# server_name matches -- which would be that one, so the web UI on 443 would
# never get its own LE block; without one (domain cleared on a re-run), it
# must not keep serving a stale name. The restart below picks this up.
nginx_remove_site raven_certificate_enrollment_domain

sudo systemctl enable nginx
if ! NGINX_T=$(sudo nginx -t 2>&1); then
  printf '%s\n' "$NGINX_T"
  echo "${RED}nginx rejected its configuration (above). A leftover or hand-edited file in $NGINX_SITES_DIR is the usual cause.${NC}"
  exit 1
fi
if ! sudo systemctl restart nginx; then
  sudo journalctl -u nginx -n 20 --no-pager || true
  echo "${RED}nginx would not start (log above). If it says 'Address already in use', another web server (apache2, caddy, a second nginx) holds port 80/443 -- see: sudo ss -ltnp${NC}"
  exit 1
fi

if [ -n "$DOMAIN" ]; then
  echo "${GREEN}Requesting a Let's Encrypt certificate for ${DOMAIN}...${NC}"
  # Not `certbot --nginx` by hand on failure: that would pick its own block
  # (possibly the 8446 one) -- re-running the installer redoes it in order.
  sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@${DOMAIN}" --redirect || \
    echo "${YELLOW}certbot failed -- check that ${DOMAIN} already resolves to this server's public IP, then re-run this installer.${NC}"

  # Port 8446 for domain users (ATAK Quick Connect): a `server_name $DOMAIN`
  # block with the LE certificate, next to raven_certificate_enrollment's
  # default block that keeps Raven's own cert for VPN/bare-IP users. Only once
  # a certificate actually exists -- a block pointing at a missing file would
  # stop nginx from loading at all. A certificate from an earlier run counts:
  # a transient certbot failure here should not take Quick Connect away.
  # The lineage is certbot's to name (live/<domain>-0001 after a re-issue
  # with a changed domain set), so ask it, falling back to live/<domain>;
  # and an expired certificate is no better than none.
  # KEEP IN STEP with debian/c4raven-server.postinst and rpm/configure.sh.
  LE_DIR="/etc/letsencrypt/live/$DOMAIN"
  LE_CERT=$(sudo certbot certificates -d "$DOMAIN" 2>/dev/null \
            | sed -n 's/^[[:space:]]*Certificate Path:[[:space:]]*//p' | sed -n 1p || true)
  [ -n "$LE_CERT" ] && LE_DIR=$(dirname "$LE_CERT")
  if sudo openssl x509 -checkend 0 -noout -in "$LE_DIR/fullchain.pem" >/dev/null 2>&1; then
    fetch "$REPO_RAW/nginx_configs/raven_certificate_enrollment_domain" \
      -o "$INSTALLER_DIR/nginx_raven_certificate_enrollment_domain"
    sudo install -m 644 "$INSTALLER_DIR/nginx_raven_certificate_enrollment_domain" \
      "$(nginx_site_file raven_certificate_enrollment_domain)"
    sudo sed -i -e "s~/etc/letsencrypt/live/DOMAIN_NAME~$LE_DIR~g" -e "s~DOMAIN_NAME~$DOMAIN~g" \
      "$(nginx_site_file raven_certificate_enrollment_domain)"
    nginx_enable_site raven_certificate_enrollment_domain
    # Renewal repoints the live/ symlinks; nginx only reads them on (re)load.
    # certbot's nginx installer already reloads after a renewal, but this
    # block is not one certbot manages, so don't depend on that.
    sudo install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\n# c4raven-server: reload nginx so port 8446 serves the renewed certificate.\nsystemctl reload nginx\n' | \
      sudo tee /etc/letsencrypt/renewal-hooks/deploy/raven-nginx-reload >/dev/null
    sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/raven-nginx-reload
    if sudo nginx -t >/dev/null 2>&1; then
      sudo systemctl reload nginx
    else
      echo "${YELLOW}nginx rejected the port-8446 domain block; removed it again. Domain users on 8446 will get Raven's own certificate.${NC}"
      nginx_remove_site raven_certificate_enrollment_domain
      sudo systemctl reload nginx || true
    fi
  else
    echo "${YELLOW}No valid Let's Encrypt certificate for ${DOMAIN} yet, so port 8446 serves only Raven's own certificate (VPN/IP onboarding works; domain Quick Connect does not). Re-run this installer once certbot succeeds.${NC}"
  fi
fi

# ---------------------------------------------------------------------------
# Frontend
# ---------------------------------------------------------------------------
step "Building and deploying the C4 Raven UI frontend"
ih_clone_repo run_as_app https://github.com/C4-Raven/c4raven-ui.git "$APP_HOME/c4raven-ui"
# c4raven-ui pins yarn 4 (packageManager in package.json) -- npm doesn't
# understand its lockfile and will silently downgrade/corrupt it. `corepack
# yarn` runs the pinned version directly without needing `corepack enable`
# (which needs root to symlink into /usr/bin).
# COREPACK_ENABLE_DOWNLOAD_PROMPT=0: never stop to ask before downloading
# the pinned yarn (a prompt here would read from the piped script).
# Retried: corepack downloads yarn itself from the npm registry, and yarn
# then fetches a few hundred packages -- the most network-hungry step here.
ih_retry run_as_app "cd '$APP_HOME/c4raven-ui' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 '$COREPACK' yarn install --immutable"
# Not retried: a build failure is deterministic. The usual cause is memory
# (tsc + vite want roughly 2 GB); say so.
if ! run_as_app "cd '$APP_HOME/c4raven-ui' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 '$COREPACK' yarn build"; then
  echo "${RED}The UI build failed. If the log above ends in 'Killed' or 'heap out of memory', this machine needs about 2 GB of free memory (add swap) for the build.${NC}"
  exit 1
fi
# Deploy as root, not as $APP_USER: whatever previously owned files are in
# the webroot (a from-scratch install won't have any, but a re-run or a
# webroot that predates this script easily can, e.g. www-data from a
# manually-deployed nginx default site) might not be deletable by
# $APP_USER even though the directory itself is world-writable --
# confirmed live against a server whose webroot had www-data-owned files,
# where `--delete` failed outright with Permission denied under the app
# user. Root can always write/delete here regardless of prior ownership.
# --no-perms/--no-owner/--no-group/--omit-dir-times: skip metadata rsync -a
# would otherwise try to set on the destination directory entry itself,
# which fails even as root once anything (e.g. this same command, earlier)
# has left it non-writable by its own uid/gid.
sudo rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete "$APP_HOME/c4raven-ui/dist/" "$WEBROOT/"
sudo chown -R "$APP_USER:$APP_USER" "$WEBROOT"
# Relabel again: rsync creates each file fresh, so under SELinux the new
# build arrives as var_t (inherited from /var/www) and nginx 403s every
# asset until restorecon has run over it. No-op off EL.
selinux_fix_webroot "$WEBROOT"

# ---------------------------------------------------------------------------
# RabbitMQ (before the Raven services start: they connect to it on boot)
# ---------------------------------------------------------------------------
step "Configuring RabbitMQ"
# Enable the plugins BEFORE rabbitmq.conf mentions their settings (mqtt.*,
# auth_http.*): RabbitMQ refuses to start on a setting it has no schema for
# ("Conf file attempted to set unknown variable"), and with `set -e` that
# failed restart used to end the whole install right here -- before the
# raven services below were ever created, leaving a server nobody can log
# in to. --offline works whether or not the broker is running.
sudo rabbitmq-plugins enable --offline rabbitmq_mqtt rabbitmq_auth_backend_http
fetch "$REPO_RAW/rabbitmq.conf" -o "$INSTALLER_DIR/rabbitmq.conf"
sudo install -D -m 644 "$INSTALLER_DIR/rabbitmq.conf" /etc/rabbitmq/rabbitmq.conf
# RabbitMQ 4.x (EL always gets it from rabbitmq.com; newer Debian/Ubuntu ship
# it too) refuses transient non-exclusive queues by default -- the ones
# cot_parser, eud_handler and the Marti APIs declare -- with
# "541 INTERNAL_ERROR - Feature `transient_nonexcl_queues` is deprecated", so
# cot_parser crash-loops and no CoT is ever routed. Re-permit it. Only on 4+:
# 3.12 (Ubuntu 24.04) predates the setting, and RabbitMQ refuses to start on
# a rabbitmq.conf key it has no schema for.
case "${DISTRO_FAMILY:-}" in
  rhel) RABBIT_PKG_VERSION=$(rpm -q --qf '%{VERSION}' rabbitmq-server 2>/dev/null || true) ;;
  *)    RABBIT_PKG_VERSION=$(dpkg-query -W -f='${Version}' rabbitmq-server 2>/dev/null || true) ;;
esac
RABBIT_MAJOR=$(printf '%s' "${RABBIT_PKG_VERSION#*:}" | cut -d. -f1)
case "$RABBIT_MAJOR" in ''|*[!0-9]*) RABBIT_MAJOR=0 ;; esac
if [ "$RABBIT_MAJOR" -ge 4 ]; then
  echo "deprecated_features.permit.transient_nonexcl_queues = true" | sudo tee -a /etc/rabbitmq/rabbitmq.conf > /dev/null
fi

RABBITMQ_VERSION=$(sudo rabbitmqadmin --version 2>/dev/null | awk '{print $2}' || true)
if [ -n "$RABBITMQ_VERSION" ] && ! sudo grep -qs PLUGINS_DIR /etc/rabbitmq/rabbitmq-env.conf; then
  echo "PLUGINS_DIR=\"/usr/lib/rabbitmq/plugins:/usr/lib/rabbitmq/lib/rabbitmq_server-${RABBITMQ_VERSION}/plugins\"" | sudo tee -a /etc/rabbitmq/rabbitmq-env.conf > /dev/null
fi
# Debian's package enables the unit at install time; EL's does not, so
# without this the broker comes back from a reboot dead and every Raven
# service with it. Harmless to repeat on Debian.
sudo systemctl enable "$RABBIT_SERVICE"
if ! sudo systemctl restart "$RABBIT_SERVICE"; then
  sudo journalctl -u "$RABBIT_SERVICE" -n 40 --no-pager
  echo "${RED}RabbitMQ would not start (log above). Fix that, then finish with c4raven-updater's finish-install.sh.${NC}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Secrets env file + systemd units for the Raven services
# ---------------------------------------------------------------------------
step "Installing systemd services"

# Merged, not overwritten: on a re-run keep what an earlier run or the admin
# set (Federation Hub on, changed RabbitMQ credentials, extra variables);
# only the data folder and the database URI are always (re)written.
SECRETS_OLD=$(sudo cat "$APP_HOME/.raven-secrets.env" 2>/dev/null || true)
secret_or() {
  local v
  v=$(printf '%s\n' "$SECRETS_OLD" | sed -n "s/^$1=//p" | tail -n 1)
  printf '%s' "${v:-$2}"
}
{
  echo "RAVEN_DATA_FOLDER=$DATA_DIR"
  echo "SQLALCHEMY_DATABASE_URI=$DB_URI"
  echo "RAVEN_RABBITMQ_USERNAME=$(secret_or RAVEN_RABBITMQ_USERNAME guest)"
  echo "RAVEN_RABBITMQ_PASSWORD=$(secret_or RAVEN_RABBITMQ_PASSWORD guest)"
  echo "RAVEN_FEDHUB_ENABLE=$(secret_or RAVEN_FEDHUB_ENABLE False)"
  echo "RAVEN_MEDIAMTX_ENABLE=$(secret_or RAVEN_MEDIAMTX_ENABLE True)"
  printf '%s\n' "$SECRETS_OLD" | grep -vE '^(RAVEN_DATA_FOLDER|SQLALCHEMY_DATABASE_URI|RAVEN_RABBITMQ_USERNAME|RAVEN_RABBITMQ_PASSWORD|RAVEN_FEDHUB_ENABLE|RAVEN_MEDIAMTX_ENABLE)=' | sed '/^$/d' || true
} | sudo tee "$APP_HOME/.raven-secrets.env" >/dev/null
unset SECRETS_OLD
sudo chown "$APP_USER:$APP_USER" "$APP_HOME/.raven-secrets.env"
sudo chmod 600 "$APP_HOME/.raven-secrets.env"

sudo tee /etc/systemd/system/raven.service >/dev/null << EOF
[Unit]
Wants=network.target ${RABBIT_SERVICE}.service ${PG_SERVICE}.service
After=network.target ${RABBIT_SERVICE}.service ${PG_SERVICE}.service
Requires=eud_handler.service eud_handler_ssl.service cot_parser.service
[Service]
User=$APP_USER
WorkingDirectory=$APP_HOME/c4raven-server
EnvironmentFile=$APP_HOME/.raven-secrets.env
ExecStart=$APP_HOME/c4raven-server/.venv/bin/raven
Restart=always
RestartSec=5s
StandardOutput=append:$DATA_DIR/logs/raven.log
StandardError=append:$DATA_DIR/logs/raven.log
[Install]
WantedBy=multi-user.target
EOF

for svc in cot_parser eud_handler eud_handler_ssl; do
  EXTRA_ARGS=""
  [ "$svc" == "eud_handler_ssl" ] && EXTRA_ARGS=" --ssl"
  BIN="${svc%_ssl}"
  sudo tee /etc/systemd/system/${svc}.service >/dev/null << EOF
[Unit]
Wants=network.target ${RABBIT_SERVICE}.service
After=network.target ${RABBIT_SERVICE}.service
PartOf=raven.service
[Service]
User=$APP_USER
WorkingDirectory=$APP_HOME/c4raven-server
EnvironmentFile=$APP_HOME/.raven-secrets.env
ExecStart=$APP_HOME/c4raven-server/.venv/bin/${BIN}${EXTRA_ARGS}
Restart=always
RestartSec=5s
StandardOutput=append:$DATA_DIR/logs/raven.log
StandardError=append:$DATA_DIR/logs/raven.log
[Install]
WantedBy=multi-user.target
EOF
done

sudo systemctl daemon-reload
sudo systemctl enable mediamtx raven cot_parser eud_handler eud_handler_ssl
ih_own_logs "$DATA_DIR/logs" "$APP_USER"
# restart, not start: on a re-run they are already running, with whatever
# config (database password, secrets file, units) the previous run left.
sudo systemctl restart mediamtx raven cot_parser eud_handler eud_handler_ssl

# The database schema is created by the migrations the server runs on
# startup, so wait for it to answer before anything touches the database.
# Up to 5 minutes: a first start runs every migration from scratch, which
# on a small VM or an SD card takes a while.
step "Waiting for the Raven server to come up (runs database migrations)"

for i in $(seq 1 150); do
  if curl -fsS -o /dev/null http://127.0.0.1:8081/api/health 2>/dev/null; then break; fi
  if [ "$i" -eq 150 ]; then
    echo "${YELLOW}raven did not answer on 127.0.0.1:8081 after 5 minutes. Last lines of $DATA_DIR/logs/raven.log:${NC}"
    sudo tail -n 30 "$DATA_DIR/logs/raven.log" 2>/dev/null || true
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# Federation Hub (optional -- requires a licensed TAK.gov account, and
# still runs as its own `tak` system user, which its .deb creates itself --
# it's a separate vendored component, not part of the raven-user layout
# above)
# ---------------------------------------------------------------------------
echo
# Debian/Ubuntu only, deliberately. TAK.gov publishes Federation Hub as a
# .deb and nothing else, and MongoDB's repo below is an Ubuntu apt repo keyed
# off `lsb_release -cs` -- there is no EL artefact here to port to, so don't
# pretend there is. Everything else on the server is unaffected.
FEDHUB_AVAILABLE=false
if [ "$DISTRO_FAMILY" = debian ]; then
  FEDHUB_AVAILABLE=true
  echo "${YELLOW}Federation Hub requires a takserver-fed-hub_*.deb package, which is only${NC}"
  echo "${YELLOW}available from a licensed TAK.gov account -- this installer can't download${NC}"
  echo "${YELLOW}it for you.${NC}"
else
  echo "${YELLOW}Federation Hub is not available on $DISTRO_NAME: TAK.gov ships it only as a${NC}"
  echo "${YELLOW}Debian/Ubuntu .deb, and its MongoDB dependency likewise. Skipping it --${NC}"
  echo "${YELLOW}nothing else in this install is affected.${NC}"
fi
# Unattended: RAVEN_FEDHUB_DEB=/path/to/takserver-fed-hub_*.deb, or
# RAVEN_FEDHUB_DEB= (set but empty) to skip it without being asked.
FEDHUB_DEB="${RAVEN_FEDHUB_DEB:-}"
if [ "$FEDHUB_AVAILABLE" = true ] && { [ -n "$FEDHUB_DEB" ] || { [ -z "${RAVEN_FEDHUB_DEB+x}" ] && ask_yn "Do you already have a takserver-fed-hub_*.deb downloaded and ready to install?"; }; }; then
  [ -n "$FEDHUB_DEB" ] || read -rp "${GREEN}Full path to the .deb file: ${NC}" FEDHUB_DEB < /dev/tty
  if [ -f "$FEDHUB_DEB" ]; then
    echo "${GREEN}Installing MongoDB (Federation Hub's policy/mission store)...${NC}"
    # MongoDB publishes 7.0 for jammy and bookworm but nothing older than 8.0
    # for noble (24.04), and Debian lives under apt/debian with `main`.
    MONGO_CODENAME=$(lsb_release -cs)
    MONGO_VER=7.0
    [ "$MONGO_CODENAME" = noble ] && MONGO_VER=8.0
    if [ "$DISTRO_ID" = debian ]; then
      MONGO_REPO="https://repo.mongodb.org/apt/debian $MONGO_CODENAME/mongodb-org/$MONGO_VER main"
    else
      MONGO_REPO="https://repo.mongodb.org/apt/ubuntu $MONGO_CODENAME/mongodb-org/$MONGO_VER multiverse"
    fi
    fetch "https://www.mongodb.org/static/pgp/server-$MONGO_VER.asc" | sudo gpg --dearmor --yes -o "/usr/share/keyrings/mongodb-server-$MONGO_VER.gpg"
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VER.gpg] $MONGO_REPO" | \
      sudo tee "/etc/apt/sources.list.d/mongodb-org-$MONGO_VER.list" > /dev/null
    ih_retry apt_noninteractive update
    ih_retry pkg_install mongodb-org
    sudo systemctl enable --now mongod

    echo "${GREEN}Installing Federation Hub...${NC}"
    pkg_install "$FEDHUB_DEB"

    run_as_app "$PYTHON_BIN - << 'PYEOF'
import yaml
path = '$DATA_DIR/config.yml'
with open(path) as f:
    conf = yaml.safe_load(f)
conf['RAVEN_FEDHUB_ENABLE'] = True
with open(path, 'w') as f:
    yaml.safe_dump(conf, f)
PYEOF"
    sudo sed -i 's/^RAVEN_FEDHUB_ENABLE=.*/RAVEN_FEDHUB_ENABLE=True/' "$APP_HOME/.raven-secrets.env"

    echo "${GREEN}Federation Hub package installed.${NC}"
    echo "It still needs its TLS keystore, truststore, and federation policy set"
    echo "up before it will accept connections -- see /opt/tak/federation-hub/docs"
    echo "for the official setup guide. Once its cert covers your domain, set"
    echo "RAVEN_FEDHUB_API_ADDRESS in $DATA_DIR/config.yml to match."
  else
    echo "${RED}File not found at $FEDHUB_DEB -- skipping Federation Hub. Re-run this script, or install it manually, once you have the .deb.${NC}"
  fi
elif [ "$FEDHUB_AVAILABLE" = true ]; then
  echo "Skipping Federation Hub. You can install it later by downloading the .deb from your TAK.gov account and running this section manually."
fi

# ---------------------------------------------------------------------------
# First admin account. The server creates `administrator`/`password` itself
# on first start; seed_admin.py makes that account change its password on
# first login (or creates it that way if it doesn't exist yet). Exit 3 =
# real accounts already exist, nothing touched.
# ---------------------------------------------------------------------------
step "Hardening the first administrator account"
run_as_app "curl -fsSL $CURL_RETRY '$REPO_RAW/seed_admin.py' -o '$APP_HOME/seed_admin.py'"
SEEDED=0
run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run python '$APP_HOME/seed_admin.py'" || SEEDED=$?

# ---------------------------------------------------------------------------
# Final health check: prove the install works instead of assuming it. Every
# check runs (none stops the others) and the summary says which failed.
# ---------------------------------------------------------------------------
step "Final health check"
HC_FAILED=()
hc_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$NC" "$1"; }
hc_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$1"; HC_FAILED+=("$1"); }
hc_warn() { printf '  %sWARN%s  %s\n' "$YELLOW" "$NC" "$1"; }

# Services: allow ~20s, since Restart=always units that just (re)started can
# be between attempts at the instant we look.
for svc in "$PG_SERVICE" "$RABBIT_SERVICE" nginx mediamtx raven cot_parser eud_handler eud_handler_ssl; do
  ok=""
  for _ in $(seq 10); do
    if sudo systemctl is-active --quiet "$svc"; then ok=1; break; fi
    sleep 2
  done
  if [ -n "$ok" ]; then hc_pass "service $svc is active"; else hc_fail "service $svc is active (see: sudo journalctl -u $svc -n 50)"; fi
done

if sudo nginx -t >/dev/null 2>&1; then hc_pass "nginx -t"; else hc_fail "nginx -t (run it to see why)"; fi

http_code() { curl -sk -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null || true; }
code=$(http_code http://127.0.0.1:8081/api/health)
if [ "$code" = 200 ]; then hc_pass "backend /api/health answers 200"; else hc_fail "backend /api/health answers 200 (got ${code:-nothing}; see $DATA_DIR/logs/raven.log)"; fi
code=$(http_code -H 'Accept: application/json' https://127.0.0.1/api/login)
if [ "$code" = 200 ]; then hc_pass "login endpoint via nginx (https://127.0.0.1/api/login) answers 200"; else hc_fail "login endpoint via nginx (https://127.0.0.1/api/login) answers 200 (got ${code:-nothing})"; fi
code=$(http_code https://127.0.0.1/)
if [ "$code" = 200 ]; then hc_pass "web UI via nginx answers 200"; else hc_fail "web UI via nginx answers 200 (got ${code:-nothing}; is $WEBROOT/index.html there?)"; fi

# Migrations: the database's alembic version(s) must be exactly the code's
# head(s). The app upgrades on every start, so anything else means that
# upgrade failed (its traceback is in raven.log).
DB_REVS=$(run_as_pg "psql -d $DB_NAME -XtAc 'SELECT version_num FROM alembic_version'" 2>/dev/null || true)
CODE_HEADS=$(ih_heads_py | run_as_app "cd '$APP_HOME/c4raven-server' && .venv/bin/python -" 2>/dev/null || true)
if [ -z "$CODE_HEADS" ]; then
  hc_warn "could not read the code's migration heads; database is at: ${DB_REVS:-nothing}"
elif ih_heads_match "$DB_REVS" "$CODE_HEADS"; then
  hc_pass "database migrations at head ($(echo $CODE_HEADS))"
else
  hc_fail "database migrations at head (database: $(echo ${DB_REVS:-none}), code: $(echo $CODE_HEADS); the upgrade's error is in $DATA_DIR/logs/raven.log)"
fi

if [ "$SEEDED" = 0 ] || [ "$SEEDED" = 3 ]; then hc_pass "administrator account checked"; else hc_fail "administrator account checked (seed_admin.py exit $SEEDED)"; fi

echo
if [ "${#HC_FAILED[@]}" -gt 0 ]; then
  CURRENT_STEP="the final health check (${#HC_FAILED[@]} check(s) failed: ${HC_FAILED[*]})"
  echo "${RED}The install ran to the end, but ${#HC_FAILED[@]} health check(s) failed (above).${NC}"
  exit 1
fi

echo "${GREEN}Setup complete.${NC}"
if [ -n "$DOMAIN" ]; then
  echo "${GREEN}Web UI: https://${DOMAIN}${NC}"
else
  echo "${GREEN}Web UI: https://$(hostname -I | awk '{print $1}')${NC}"
fi
case "$SEEDED" in
  0) echo "${GREEN}First login: username 'administrator', password 'password' -- you'll be required to set a real password immediately.${NC}" ;;
  3) echo "${YELLOW}Existing accounts were left untouched -- log in with your usual administrator credentials.${NC}" ;;
  *) echo "${RED}Could not verify the administrator account (seed_admin.py exit $SEEDED). Once raven is running: sudo -u $APP_USER -H bash -lc \"cd $APP_HOME/c4raven-server && $FLASK_ENV poetry run python $APP_HOME/seed_admin.py\"${NC}" ;;
esac
