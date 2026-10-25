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

REPO_RAW=https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master
curl -fsSL "$REPO_RAW/colors.sh" -o "$INSTALLER_DIR/colors.sh"
# shellcheck source=/dev/null
. "$INSTALLER_DIR/colors.sh"

# Everything that differs between distro families lives in lib/distro.sh.
# This script is normally run as `curl ... | bash`, so the repo is NOT on
# disk -- fetch the shim exactly the way colors.sh is fetched above.
curl -fsSL "$REPO_RAW/lib/distro.sh" -o "$INSTALLER_DIR/distro.sh"
# shellcheck source=lib/distro.sh
. "$INSTALLER_DIR/distro.sh"

# curl -f catches a 404 or a dead connection, but not a captive portal or
# transparent proxy that answers 200 with an HTML body: sourcing that dies
# partway and can leave us with some functions defined and others missing, so
# the install would get as far as `apt upgrade` before failing on the first
# absent one. Check the whole surface we rely on before touching the system.
for _fn in detect_distro distro_supported pkg_refresh pkg_install \
           pkg_install_optional stack_packages stack_packages_optional \
           setup_extra_repos pg_init node_install firewall_open \
           selinux_fixup nginx_site_file nginx_disable_default_site; do
  command -v "$_fn" >/dev/null 2>&1 || {
    echo "${RED}lib/distro.sh did not load correctly ($_fn is missing) -- aborting before anything on this system is changed.${NC}"
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

ask_yn() {
  # ask_yn "question" -> returns 0 for yes, 1 for no
  local reply
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
run_as_app() {
  sudo -u "$APP_USER" -H bash -lc "$1"
}

echo "${GREEN}Installing system packages via ${PKG_MGR}. You may be prompted for your sudo password...${NC}"
# EL only: EPEL + CRB (certbot, erlang, ffmpeg-free) and the RabbitMQ repo,
# none of which the names below resolve without. No-op on Debian, where
# everything is in main/universe.
setup_extra_repos "$EL_REPOS_SCRIPT"
pkg_refresh
# Word splitting is the point here -- stack_packages returns a list.
# shellcheck disable=SC2046
pkg_install $(stack_packages)

# Packages we'd like but can live without (EL only today: there is no plain
# ffmpeg outside RPM Fusion and no PostGIS outside PGDG). Losing one of these
# costs a feature; losing the install to `set -e` over it costs the server.
for pkg in $(stack_packages_optional); do
  case "$pkg" in
    ffmpeg|ffmpeg-free) degraded="stream thumbnails and recording metadata" ;;
    postgis)            degraded="PostGIS geospatial columns" ;;
    *)                  degraded="anything that needs $pkg" ;;
  esac
  pkg_install_optional "$pkg" || \
    echo "${YELLOW}Could not install '$pkg' -- continuing without it. $degraded will be unavailable.${NC}"
done

# Node.js: the UI build (vite 8) needs Node 20.19+ / 22.12+, and neither
# family's own package is new enough -- Ubuntu 24.04's `nodejs` is 18.x with
# no corepack at all, and EL9's nodejs module stream defaults to 18 too.
# node_install uses the NodeSource 22.x LTS repo (deb.nodesource.com or
# rpm.nodesource.com, both of which publish amd64 and arm64) unless a
# new-enough node is already installed.
if ! node_ok; then
  echo "${GREEN}Installing Node.js 22 (NodeSource)...${NC}"
fi
node_install
# corepack runs the yarn version c4raven-ui pins; NodeSource ships it, but
# make sure, since a distro node may not -- and on EL the distro node splits
# npm into its own package, so `sudo npm` may not exist to install it with.
if ! command -v corepack >/dev/null 2>&1; then
  command -v npm >/dev/null 2>&1 || pkg_install npm
  sudo npm install -g corepack
fi

echo "${GREEN}Setting up the dedicated '$APP_USER' account...${NC}"
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
echo "${GREEN}Cloning and installing the Raven backend...${NC}"
if ! sudo test -d "$APP_HOME/c4raven-server"; then
  run_as_app "git clone https://github.com/C4-Raven/c4raven-server.git '$APP_HOME/c4raven-server'"
fi

if ! sudo test -x "$APP_HOME/.local/bin/poetry"; then
  run_as_app "curl -sSL https://install.python-poetry.org | $PYTHON_BIN -"
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
run_as_app "cd '$APP_HOME/c4raven-server' && poetry install"

# There's no top-level app.py/wsgi.py for Flask's CLI to auto-discover, and
# RAVEN_DATA_FOLDER has to be set for every ad-hoc `flask raven ...` call
# below (the app itself gets it from EnvironmentFile at runtime, but that
# file doesn't exist yet the first time we run these).
FLASK_ENV="FLASK_APP=raven.app RAVEN_DATA_FOLDER='$DATA_DIR'"

run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run flask raven generate-config"
echo "${GREEN}Raven backend installed.${NC}"

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
echo "${GREEN}Setting up PostgreSQL...${NC}"
# Debian's packaging creates a cluster and starts it at install time; EL's
# leaves the data directory empty and the service refusing to start until
# `postgresql-setup --initdb` has run, and then defaults host connections to
# `ident`, which rejects the password auth the app's 127.0.0.1 URI needs.
# pg_init does whichever of those apply, idempotently, and leaves the
# `sudo su postgres` calls below working unchanged on both.
pg_init
DB_USER_EXISTS=$(sudo su postgres -c "psql -tXAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_NAME'\"")
if [ "$DB_USER_EXISTS" != 1 ]; then
  # Hex only: this goes raw into a URI, where `%` would be percent-decoded
  # by SQLAlchemy/libpq. (Not `tr ... | head -c`: under pipefail, head
  # closing the pipe kills tr with SIGPIPE and the whole script with it.)
  POSTGRESQL_PASSWORD=$(openssl rand -hex 16)
  sudo su postgres -c "psql -c \"create role $DB_NAME with login password '${POSTGRESQL_PASSWORD}';\""
else
  read -rp "${GREEN}PostgreSQL user '$DB_NAME' already exists -- enter its password: ${NC}" POSTGRESQL_PASSWORD < /dev/tty
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

DB_EXISTS=$(sudo su postgres -c "psql -XtAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"")
if [ "$DB_EXISTS" != 1 ]; then
  sudo su postgres -c "psql -c 'create database $DB_NAME;'"
fi
sudo su postgres -c "psql -c 'GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO $DB_NAME;'"
sudo su postgres -c "psql -d $DB_NAME -c 'GRANT ALL ON SCHEMA public TO $DB_NAME;'"
# PostGIS is best-effort, not fatal: EL9 has no PostGIS package in AppStream
# or EPEL at all (it only exists in PGDG), so this statement WILL fail there
# on a stock box -- and under `set -e` that would end the install right here,
# before any of the services below are created. Nothing in the current schema
# needs it.
sudo su postgres -c "psql -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgis'" || \
  echo "${YELLOW}Could not create the postgis extension -- continuing without it. Geospatial columns will be unavailable; install PostGIS for this PostgreSQL (on EL that means the PGDG repo) and re-run this script to add it.${NC}"
echo "${GREEN}Database ready.${NC}"
# Migrations run automatically inside the app itself on every startup
# (see init_extensions() in raven/app.py) -- no separate `flask db upgrade`
# step needed or wanted here.

# ---------------------------------------------------------------------------
# Cloudflare Turnstile (bot protection on login)
# ---------------------------------------------------------------------------
if ask_yn "Enable Cloudflare Turnstile (the human-verification checkbox) on the login page?"; then
  echo "Get a site key + secret key from the Cloudflare dashboard -> Turnstile first, if you haven't already."
  read -rp "${GREEN}Turnstile site key: ${NC}" TURNSTILE_SITE_KEY < /dev/tty
  read -rp "${GREEN}Turnstile secret key: ${NC}" TURNSTILE_SECRET_KEY < /dev/tty
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
DOMAIN=""
if ask_yn "Do you want to configure a public domain name for this server?"; then
  read -rp "${GREEN}Domain (e.g. tak.example.com, must already point at this server's IP): ${NC}" DOMAIN < /dev/tty
fi

# ---------------------------------------------------------------------------
# Certificate authority
# ---------------------------------------------------------------------------
echo "${GREEN}Creating the certificate authority...${NC}"
run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run flask raven create-ca"
run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run flask raven issue-server-certificate"

# ---------------------------------------------------------------------------
# mediamtx
# ---------------------------------------------------------------------------
echo "${GREEN}Installing mediamtx...${NC}"
run_as_app "mkdir -p '$DATA_DIR/mediamtx/recordings'"
if ! sudo test -f "$DATA_DIR/mediamtx/mediamtx"; then
  # lastversion is one of the backend's own dependencies, so it's already in
  # the Poetry venv; run it from there (`poetry run` needs the project cwd).
  # ARCH_MTX is this machine in mediamtx's release-asset spelling
  # (amd64/arm64/armv7) -- same mapping this script has always used, now in
  # detect_distro so the RPM/DEB scriptlets get it too.
  run_as_app "cd '$APP_HOME/c4raven-server' && poetry run lastversion --filter '~*linux_$ARCH_MTX' --only 1.13.0 -o '$DATA_DIR/mediamtx/mediamtx.tar.gz' --assets download bluenviron/mediamtx"
  run_as_app "cd '$DATA_DIR/mediamtx' && tar -xf mediamtx.tar.gz && rm -f mediamtx.tar.gz"
fi
run_as_app "curl -fsSL '$REPO_RAW/mediamtx.yml' -o '$DATA_DIR/mediamtx/mediamtx.yml'"
sudo sed -i \
  -e "s~OTS_FOLDER~$DATA_DIR~g" \
  -e "s~SERVER_CERT_FILE~$DATA_DIR/ca/certs/raven/raven.pem~g" \
  -e "s~SERVER_KEY_FILE~$DATA_DIR/ca/certs/raven/raven.nopass.key~g" \
  "$DATA_DIR/mediamtx/mediamtx.yml"
# WebRTC clients outside the LAN can only reach us if mediamtx advertises a
# public host in its ICE candidates, not just the interface IPs.
sudo sed -i "s~^webrtcAdditionalHosts: \[\]~webrtcAdditionalHosts: [${DOMAIN:-$(hostname -I | awk '{print $1}')}]~" \
  "$DATA_DIR/mediamtx/mediamtx.yml"

sudo tee /etc/systemd/system/mediamtx.service >/dev/null << EOF
[Unit]
Wants=network.target
After=network.target
[Service]
User=$APP_USER
ExecStart=$DATA_DIR/mediamtx/mediamtx $DATA_DIR/mediamtx/mediamtx.yml
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
echo "${GREEN}Configuring nginx...${NC}"
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
  sudo curl -fsSL "$REPO_RAW/rpm/proxy_params" -o /etc/nginx/proxy_params
fi

for f in raven_http raven_https raven_certificate_enrollment; do
  sudo curl -fsSL "$REPO_RAW/nginx_configs/$f" -o "$(nginx_site_file "$f")"
done
for f in rabbitmq mediamtx; do
  sudo curl -fsSL "$REPO_RAW/nginx_configs/$f" -o "$(nginx_stream_file "$f")"
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

sudo systemctl enable nginx
sudo systemctl restart nginx

if [ -n "$DOMAIN" ]; then
  echo "${GREEN}Requesting a Let's Encrypt certificate for ${DOMAIN}...${NC}"
  sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@${DOMAIN}" --redirect || \
    echo "${YELLOW}certbot failed -- check that ${DOMAIN} already resolves to this server's public IP, then run: sudo certbot --nginx -d ${DOMAIN}${NC}"
fi

# ---------------------------------------------------------------------------
# Frontend
# ---------------------------------------------------------------------------
echo "${GREEN}Building and deploying the C4 Raven UI frontend...${NC}"
if ! sudo test -d "$APP_HOME/c4raven-ui"; then
  run_as_app "git clone https://github.com/C4-Raven/c4raven-ui.git '$APP_HOME/c4raven-ui'"
fi
# c4raven-ui pins yarn 4 (packageManager in package.json) -- npm doesn't
# understand its lockfile and will silently downgrade/corrupt it. `corepack
# yarn` runs the pinned version directly without needing `corepack enable`
# (which needs root to symlink into /usr/bin).
# COREPACK_ENABLE_DOWNLOAD_PROMPT=0: never stop to ask before downloading
# the pinned yarn (a prompt here would read from the piped script).
run_as_app "cd '$APP_HOME/c4raven-ui' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn install --immutable"
run_as_app "cd '$APP_HOME/c4raven-ui' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn build"
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
echo "${GREEN}Configuring RabbitMQ...${NC}"
# Enable the plugins BEFORE rabbitmq.conf mentions their settings (mqtt.*,
# auth_http.*): RabbitMQ refuses to start on a setting it has no schema for
# ("Conf file attempted to set unknown variable"), and with `set -e` that
# failed restart used to end the whole install right here -- before the
# raven services below were ever created, leaving a server nobody can log
# in to. --offline works whether or not the broker is running.
sudo rabbitmq-plugins enable --offline rabbitmq_mqtt rabbitmq_auth_backend_http
sudo curl -fsSL "$REPO_RAW/rabbitmq.conf" -o /etc/rabbitmq/rabbitmq.conf

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
echo "${GREEN}Installing systemd services...${NC}"

sudo tee "$APP_HOME/.raven-secrets.env" >/dev/null << EOF
RAVEN_DATA_FOLDER=$DATA_DIR
SQLALCHEMY_DATABASE_URI=$DB_URI
RAVEN_RABBITMQ_USERNAME=guest
RAVEN_RABBITMQ_PASSWORD=guest
RAVEN_FEDHUB_ENABLE=False
RAVEN_MEDIAMTX_ENABLE=True
EOF
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
sudo systemctl start mediamtx raven cot_parser eud_handler eud_handler_ssl

# The database schema is created by the migrations the server runs on
# startup, so wait for it to answer before anything touches the database.
echo "${GREEN}Waiting for the Raven server to come up...${NC}"
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null http://127.0.0.1:8081/api/health 2>/dev/null; then break; fi
  if [ "$i" -eq 60 ]; then
    echo "${YELLOW}raven did not answer on 127.0.0.1:8081 after 2 minutes -- check $DATA_DIR/logs/raven.log${NC}"
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
if [ "$FEDHUB_AVAILABLE" = true ] && ask_yn "Do you already have a takserver-fed-hub_*.deb downloaded and ready to install?"; then
  read -rp "${GREEN}Full path to the .deb file: ${NC}" FEDHUB_DEB < /dev/tty
  if [ -f "$FEDHUB_DEB" ]; then
    echo "${GREEN}Installing MongoDB (Federation Hub's policy/mission store)...${NC}"
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" | \
      sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list > /dev/null
    sudo apt update
    sudo apt install -y mongodb-org
    sudo systemctl enable --now mongod

    echo "${GREEN}Installing Federation Hub...${NC}"
    sudo apt install -y "$FEDHUB_DEB"

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
echo "${GREEN}Hardening the first administrator account...${NC}"
run_as_app "curl -fsSL '$REPO_RAW/seed_admin.py' -o '$APP_HOME/seed_admin.py'"
SEEDED=0
run_as_app "cd '$APP_HOME/c4raven-server' && $FLASK_ENV poetry run python '$APP_HOME/seed_admin.py'" || SEEDED=$?

rm -rf "$INSTALLER_DIR"

echo
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
