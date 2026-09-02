#!/bin/bash
# C4 Raven TAK Server -- one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/install.sh | bash
#
# Installs the full stack in one pass: system packages, PostgreSQL, RabbitMQ,
# the Raven backend + C4 Raven UI frontend, nginx, mediamtx, systemd units,
# and (optionally) Cloudflare Turnstile bot protection, a public domain with
# a real Let's Encrypt certificate, and TAK Federation Hub.
#
# Safe to re-run: every step checks for existing state before creating it.
set -euo pipefail

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
  echo "${RED}Don't run this as root -- run it as the user Raven should run as.${NC}"
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

mkdir -p ~/ots

echo "${GREEN}Installing system packages via apt. You may be prompted for your sudo password...${NC}"
sudo apt update && sudo NEEDRESTART_MODE=a apt upgrade -y
sudo NEEDRESTART_MODE=a apt install -y \
  curl git openssl \
  python3 python3-pip python3-venv python3-dev \
  postgresql postgresql-postgis pgloader \
  rabbitmq-server \
  nginx libnginx-mod-stream \
  certbot python3-certbot-nginx \
  ffmpeg \
  nodejs npm

# ---------------------------------------------------------------------------
# Backend: clone + install
# ---------------------------------------------------------------------------
echo "${GREEN}Cloning and installing the Raven backend...${NC}"
if [ ! -d ~/src/c4raven-server ]; then
  mkdir -p ~/src
  git clone https://github.com/C4-Raven/c4raven-server.git ~/src/c4raven-server
fi

python3 -m venv --system-site-packages ~/.opentakserver_venv
# shellcheck source=/dev/null
source ~/.opentakserver_venv/bin/activate
python3 -m pip install --upgrade pip setuptools wheel
pip3 install -e ~/src/c4raven-server

# There's no top-level app.py/wsgi.py for Flask's CLI to auto-discover (the
# editable install's real entry point is raven/app.py), so every `flask`
# invocation below needs FLASK_APP set explicitly.
export FLASK_APP=raven.app

cd ~/src/c4raven-server
flask raven generate-config
echo "${GREEN}Raven backend installed.${NC}"

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
echo "${GREEN}Setting up PostgreSQL...${NC}"
sudo su postgres -c "psql -d ots -c 'CREATE EXTENSION IF NOT EXISTS postgis'" 2>/dev/null || true

OTS_USER_EXISTS=$(sudo su postgres -c "psql -tXAc \"SELECT 1 FROM pg_roles WHERE rolname='ots'\"")
if [ "$OTS_USER_EXISTS" != 1 ]; then
  POSTGRESQL_PASSWORD=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 20)
  sudo su postgres -c "psql -c \"create role ots with login password '${POSTGRESQL_PASSWORD}';\""
  python3 - "$POSTGRESQL_PASSWORD" << 'PYEOF'
import sys, yaml
password = sys.argv[1]
path = "/home/%s/ots/config.yml" % __import__("os").environ["USER"]
with open(path) as f:
    conf = yaml.safe_load(f)
conf["SQLALCHEMY_DATABASE_URI"] = f"postgresql+psycopg://ots:{password}@127.0.0.1/ots"
with open(path, "w") as f:
    yaml.safe_dump(conf, f)
PYEOF
else
  read -rp "${GREEN}PostgreSQL user 'ots' already exists -- enter its password: ${NC}" POSTGRESQL_PASSWORD < /dev/tty
  python3 - "$POSTGRESQL_PASSWORD" << 'PYEOF'
import sys, yaml, os
password = sys.argv[1]
path = os.path.expanduser("~/ots/config.yml")
with open(path) as f:
    conf = yaml.safe_load(f)
conf["SQLALCHEMY_DATABASE_URI"] = f"postgresql+psycopg://ots:{password}@127.0.0.1/ots"
with open(path, "w") as f:
    yaml.safe_dump(conf, f)
PYEOF
fi

OTS_DB_EXISTS=$(sudo su postgres -c "psql -XtAc \"SELECT 1 FROM pg_database WHERE datname='ots'\"")
if [ "$OTS_DB_EXISTS" != 1 ]; then
  sudo su postgres -c "psql -c 'create database ots;'"
fi
sudo su postgres -c "psql -c 'GRANT ALL PRIVILEGES ON DATABASE \"ots\" TO ots;'"
sudo su postgres -c "psql -d ots -c 'GRANT ALL ON SCHEMA public TO ots;'"
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
  python3 - "$TURNSTILE_SITE_KEY" "$TURNSTILE_SECRET_KEY" << 'PYEOF'
import sys, yaml, os
site_key, secret_key = sys.argv[1], sys.argv[2]
path = os.path.expanduser("~/ots/config.yml")
with open(path) as f:
    conf = yaml.safe_load(f)
conf["RAVEN_TURNSTILE_ENABLE"] = True
conf["RAVEN_TURNSTILE_SITE_KEY"] = site_key
conf["RAVEN_TURNSTILE_SECRET_KEY"] = secret_key
with open(path, "w") as f:
    yaml.safe_dump(conf, f)
PYEOF
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
mkdir -p ~/ots/ca
cd ~/src/c4raven-server
flask raven create-ca
flask raven issue-server-certificate

# ---------------------------------------------------------------------------
# mediamtx
# ---------------------------------------------------------------------------
echo "${GREEN}Installing mediamtx...${NC}"
mkdir -p ~/ots/mediamtx/recordings
cd ~/ots/mediamtx
if [ ! -f ./mediamtx ]; then
  pip3 install --quiet lastversion
  ARCH=$(uname -m)
  if [ "$ARCH" == "x86_64" ]; then
    lastversion --filter '~*linux_amd64' --assets download bluenviron/mediamtx --only 1.13.0
  elif [ "$ARCH" == "aarch64" ]; then
    lastversion --filter '~*linux_arm64' --assets download bluenviron/mediamtx --only 1.13.0
  else
    lastversion --filter '~*linux_armv7' --assets download bluenviron/mediamtx --only 1.13.0
  fi
  tar -xf ./*.tar.gz
fi
curl -fsSL "$REPO_RAW/mediamtx.yml" -o ~/ots/mediamtx/mediamtx.yml
sed -i \
  -e "s~OTS_FOLDER~${HOME}/ots~g" \
  -e "s~SERVER_CERT_FILE~${HOME}/ots/ca/certs/opentakserver/opentakserver.pem~g" \
  -e "s~SERVER_KEY_FILE~${HOME}/ots/ca/certs/opentakserver/opentakserver.nopass.key~g" \
  ~/ots/mediamtx/mediamtx.yml

sudo tee /etc/systemd/system/mediamtx.service >/dev/null << EOF
[Unit]
Wants=network.target
[Service]
User=$(whoami)
ExecStart=${HOME}/ots/mediamtx/mediamtx ${HOME}/ots/mediamtx/mediamtx.yml
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

for f in ots_http ots_https ots_certificate_enrollment; do
  sudo curl -fsSL "$REPO_RAW/nginx_configs/$f" -o "/etc/nginx/sites-available/$f"
done
for f in rabbitmq mediamtx; do
  sudo curl -fsSL "$REPO_RAW/nginx_configs/$f" -o "/etc/nginx/streams-available/$f"
done

for f in /etc/nginx/sites-available/ots_https /etc/nginx/sites-available/ots_certificate_enrollment \
         /etc/nginx/streams-available/rabbitmq /etc/nginx/streams-available/mediamtx; do
  sudo sed -i \
    -e "s~SERVER_CERT_FILE~${HOME}/ots/ca/certs/opentakserver/opentakserver.pem~g" \
    -e "s~SERVER_KEY_FILE~${HOME}/ots/ca/certs/opentakserver/opentakserver.nopass.key~g" \
    -e "s~CA_CERT_FILE~${HOME}/ots/ca/ca.pem~g" \
    "$f"
done

sudo ln -sf /etc/nginx/sites-available/ots_* /etc/nginx/sites-enabled/
sudo ln -sf /etc/nginx/streams-available/rabbitmq /etc/nginx/streams-enabled/
sudo ln -sf /etc/nginx/streams-available/mediamtx /etc/nginx/streams-enabled/

sudo mkdir -p /var/www/html/opentakserver
sudo chmod a+rw /var/www/html/opentakserver

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
if [ ! -d ~/src/c4raven-ui ]; then
  git clone https://github.com/C4-Raven/c4raven-ui.git ~/src/c4raven-ui
fi
cd ~/src/c4raven-ui
# This repo pins yarn 4 (see packageManager in package.json) -- npm doesn't
# understand its lockfile and will silently downgrade/corrupt it if used
# here instead. `corepack yarn` runs the pinned version directly without
# needing `corepack enable` (which needs root to symlink into /usr/bin).
corepack yarn install
corepack yarn build
# The webroot directory itself is root-owned but world-writable (see chmod
# a+rw above), so we can write files into it but can't touch the directory
# entry's own owner/group/permissions/mtime -- rsync -a tries to by default
# and exits non-zero on that even though every file transfers fine, so tell
# it not to bother.
rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete dist/ /var/www/html/opentakserver/

# ---------------------------------------------------------------------------
# systemd units for the Raven services
# ---------------------------------------------------------------------------
echo "${GREEN}Installing systemd services...${NC}"
mkdir -p ~/ots/logs

sudo tee /etc/systemd/system/opentakserver.service >/dev/null << EOF
[Unit]
Wants=network.target rabbitmq-server.service
After=network.target rabbitmq-server.service
Requires=eud_handler eud_handler_ssl cot_parser
[Service]
User=$(whoami)
WorkingDirectory=${HOME}/ots
ExecStart=${HOME}/.opentakserver_venv/bin/raven
Restart=on-failure
RestartSec=5s
StandardOutput=append:${HOME}/ots/logs/opentakserver.log
StandardError=append:${HOME}/ots/logs/opentakserver.log
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
PartOf=opentakserver.service
[Service]
User=$(whoami)
WorkingDirectory=${HOME}/ots
ExecStart=${HOME}/.opentakserver_venv/bin/${BIN}${EXTRA_ARGS}
Restart=on-failure
RestartSec=5s
StandardOutput=append:${HOME}/ots/logs/opentakserver.log
StandardError=append:${HOME}/ots/logs/opentakserver.log
[Install]
WantedBy=multi-user.target
EOF
done

sudo systemctl daemon-reload
sudo systemctl enable mediamtx opentakserver cot_parser eud_handler eud_handler_ssl
sudo systemctl start mediamtx opentakserver cot_parser eud_handler eud_handler_ssl

# ---------------------------------------------------------------------------
# RabbitMQ
# ---------------------------------------------------------------------------
echo "${GREEN}Configuring RabbitMQ...${NC}"
sudo curl -fsSL "$REPO_RAW/rabbitmq.conf" -o /etc/rabbitmq/rabbitmq.conf

RABBITMQ_VERSION=$(sudo rabbitmqadmin --version 2>/dev/null | awk '{print $2}' || true)
if [ -n "$RABBITMQ_VERSION" ]; then
  echo "PLUGINS_DIR=\"/usr/lib/rabbitmq/plugins:/usr/lib/rabbitmq/lib/rabbitmq_server-${RABBITMQ_VERSION}/plugins\"" | sudo tee -a /etc/rabbitmq/rabbitmq-env.conf > /dev/null
fi
sudo systemctl restart rabbitmq-server
sudo rabbitmq-plugins enable rabbitmq_mqtt rabbitmq_auth_backend_http || true
sudo systemctl restart rabbitmq-server

# ---------------------------------------------------------------------------
# Federation Hub (optional -- requires a licensed TAK.gov account)
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

    echo "${GREEN}Federation Hub package installed.${NC}"
    echo "It still needs its TLS keystore, truststore, and federation policy set"
    echo "up before it will accept connections -- see /opt/tak/federation-hub/docs"
    echo "for the official setup guide. Once its cert covers your domain, set"
    echo "RAVEN_FEDHUB_API_ADDRESS in ~/ots/config.yml to match."
  else
    echo "${RED}File not found at $FEDHUB_DEB -- skipping Federation Hub. Re-run this script, or install it manually, once you have the .deb.${NC}"
  fi
else
  echo "Skipping Federation Hub. You can install it later by downloading the .deb from your TAK.gov account and running this section manually."
fi

# ---------------------------------------------------------------------------
# First admin account
# ---------------------------------------------------------------------------
echo "${GREEN}Creating the first administrator account...${NC}"
curl -fsSL "https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/seed_admin.py" -o "$INSTALLER_DIR/seed_admin.py"
cd ~/src/c4raven-server
python3 "$INSTALLER_DIR/seed_admin.py" || echo "${YELLOW}Skipped -- an admin account already exists.${NC}"

rm -rf "$INSTALLER_DIR"
deactivate

echo
echo "${GREEN}Setup complete.${NC}"
if [ -n "$DOMAIN" ]; then
  echo "${GREEN}Web UI: https://${DOMAIN}${NC}"
else
  echo "${GREEN}Web UI: https://$(hostname -I | awk '{print $1}')${NC}"
fi
echo "${GREEN}First login: username 'admin', password 'password' -- you'll be forced to set a real password and 2FA immediately.${NC}"
