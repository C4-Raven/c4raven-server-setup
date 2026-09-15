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
# Safe to re-run: every step checks for existing state before creating it.
set -euo pipefail

APP_USER="raven"
APP_HOME="/opt/raven"
DATA_DIR="$APP_HOME/data"
DB_NAME="raven"
WEBROOT="/var/www/html/raven"

INSTALLER_DIR=/tmp/raven_installer
mkdir -p "$INSTALLER_DIR"
cd "$INSTALLER_DIR"

REPO_RAW=https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master
curl -fsSL "$REPO_RAW/colors.sh" -o "$INSTALLER_DIR/colors.sh"
# shellcheck source=/dev/null
. "$INSTALLER_DIR/colors.sh"

. /etc/os-release
if [ "$NAME" != "Ubuntu" ]; then
  read -rp "${YELLOW}This installer is written for Ubuntu but this system is $NAME. Continue anyway? [y/N] ${NC}" confirm < /dev/tty
  [[ "$confirm" =~ ^[yY]([eE][sS])?$ ]] || exit 1
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

# Runs a command as the dedicated app user, through a login shell so
# ~/.profile puts ~/.local/bin (poetry, yarn via corepack) on PATH.
run_as_app() {
  sudo -u "$APP_USER" -H bash -lc "$1"
}

echo "${GREEN}Installing system packages via apt. You may be prompted for your sudo password...${NC}"
sudo apt update && sudo NEEDRESTART_MODE=a apt upgrade -y
sudo NEEDRESTART_MODE=a apt install -y \
  curl git openssl rsync \
  python3 python3-pip python3-venv python3-dev python3-yaml build-essential \
  postgresql postgresql-postgis pgloader \
  rabbitmq-server \
  nginx libnginx-mod-stream \
  certbot python3-certbot-nginx \
  ffmpeg

# Node.js: the UI build (vite 8) needs Node 20.19+ / 22.12+, and Ubuntu
# 24.04's own `nodejs` package is 18.x with no corepack at all. Use the
# NodeSource 22.x LTS repo unless a new-enough node is already installed.
node_ok() {
  command -v node >/dev/null 2>&1 && node -e '
    const [a, b] = process.versions.node.split(".").map(Number);
    process.exit((a === 20 && b >= 19) || (a === 22 && b >= 12) || a >= 23 ? 0 : 1);'
}
if ! node_ok; then
  echo "${GREEN}Installing Node.js 22 (NodeSource)...${NC}"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo NEEDRESTART_MODE=a apt install -y nodejs
fi
# corepack runs the yarn version c4raven-ui pins; NodeSource ships it, but
# make sure, since a distro node may not.
command -v corepack >/dev/null 2>&1 || sudo npm install -g corepack

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
  run_as_app "curl -sSL https://install.python-poetry.org | python3 -"
fi
run_as_app "poetry config virtualenvs.in-project true"
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
run_as_app "python3 - '$DB_URI' << 'PYEOF'
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
sudo su postgres -c "psql -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgis'"
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
  run_as_app "python3 - '$TURNSTILE_SITE_KEY' '$TURNSTILE_SECRET_KEY' << 'PYEOF'
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
  case "$(uname -m)" in
    x86_64)  MTX_ARCH=amd64 ;;
    aarch64) MTX_ARCH=arm64 ;;
    *)       MTX_ARCH=armv7 ;;
  esac
  run_as_app "cd '$APP_HOME/c4raven-server' && poetry run lastversion --filter '~*linux_$MTX_ARCH' --only 1.13.0 -o '$DATA_DIR/mediamtx/mediamtx.tar.gz' --assets download bluenviron/mediamtx"
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
if ! grep -q "stream {" /etc/nginx/nginx.conf; then
  echo "
stream {
        include /etc/nginx/streams-enabled/*;
}" | sudo tee -a /etc/nginx/nginx.conf > /dev/null
fi

sudo rm -f /etc/nginx/sites-enabled/*
sudo mkdir -p /etc/nginx/streams-available /etc/nginx/streams-enabled

for f in raven_http raven_https raven_certificate_enrollment; do
  sudo curl -fsSL "$REPO_RAW/nginx_configs/$f" -o "/etc/nginx/sites-available/$f"
done
for f in rabbitmq mediamtx; do
  sudo curl -fsSL "$REPO_RAW/nginx_configs/$f" -o "/etc/nginx/streams-available/$f"
done

for f in /etc/nginx/sites-available/raven_https /etc/nginx/sites-available/raven_certificate_enrollment \
         /etc/nginx/streams-available/rabbitmq /etc/nginx/streams-available/mediamtx; do
  sudo sed -i \
    -e "s~SERVER_CERT_FILE~$DATA_DIR/ca/certs/raven/raven.pem~g" \
    -e "s~SERVER_KEY_FILE~$DATA_DIR/ca/certs/raven/raven.nopass.key~g" \
    -e "s~CA_CERT_FILE~$DATA_DIR/ca/ca.pem~g" \
    "$f"
done

sudo ln -sf /etc/nginx/sites-available/raven_* /etc/nginx/sites-enabled/
sudo ln -sf /etc/nginx/streams-available/rabbitmq /etc/nginx/streams-enabled/
sudo ln -sf /etc/nginx/streams-available/mediamtx /etc/nginx/streams-enabled/

# Owned by the app user, not world-writable: any local account could
# otherwise swap out the served JavaScript.
sudo install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$WEBROOT"

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
run_as_app "cd '$APP_HOME/c4raven-ui' && corepack yarn install"
run_as_app "cd '$APP_HOME/c4raven-ui' && corepack yarn build"
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

# ---------------------------------------------------------------------------
# RabbitMQ (before the Raven services start: they connect to it on boot)
# ---------------------------------------------------------------------------
echo "${GREEN}Configuring RabbitMQ...${NC}"
sudo curl -fsSL "$REPO_RAW/rabbitmq.conf" -o /etc/rabbitmq/rabbitmq.conf

RABBITMQ_VERSION=$(sudo rabbitmqadmin --version 2>/dev/null | awk '{print $2}' || true)
if [ -n "$RABBITMQ_VERSION" ] && ! sudo grep -qs PLUGINS_DIR /etc/rabbitmq/rabbitmq-env.conf; then
  echo "PLUGINS_DIR=\"/usr/lib/rabbitmq/plugins:/usr/lib/rabbitmq/lib/rabbitmq_server-${RABBITMQ_VERSION}/plugins\"" | sudo tee -a /etc/rabbitmq/rabbitmq-env.conf > /dev/null
fi
sudo systemctl restart rabbitmq-server
sudo rabbitmq-plugins enable rabbitmq_mqtt rabbitmq_auth_backend_http || true
sudo systemctl restart rabbitmq-server

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
Wants=network.target rabbitmq-server.service postgresql.service
After=network.target rabbitmq-server.service postgresql.service
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
Wants=network.target rabbitmq-server.service
After=network.target rabbitmq-server.service
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
echo "${YELLOW}Federation Hub requires a takserver-fed-hub_*.deb package, which is only${NC}"
echo "${YELLOW}available from a licensed TAK.gov account -- this installer can't download${NC}"
echo "${YELLOW}it for you.${NC}"
if ask_yn "Do you already have a takserver-fed-hub_*.deb downloaded and ready to install?"; then
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

    run_as_app "python3 - << 'PYEOF'
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
else
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
