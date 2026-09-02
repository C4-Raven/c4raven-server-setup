#!/bin/bash
# C4 Raven TAK Server -- one-command updater.
#
#   curl -fsSL https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/update.sh | bash
#
# Pulls the latest backend + frontend, applies any new database migrations,
# rebuilds the UI, and restarts every Raven service. Safe to run any time --
# it only pulls and reapplies, it never touches your config.yml or data.
set -euo pipefail

REPO_RAW=https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master
TMP=/tmp/raven_updater
mkdir -p "$TMP"
curl -fsSL "$REPO_RAW/colors.sh" -o "$TMP/colors.sh"
# shellcheck source=/dev/null
. "$TMP/colors.sh"

if [ "$(whoami)" == "root" ]; then
  echo "${RED}Don't run this as root -- run it as the user Raven runs as.${NC}"
  exit 1
fi

if [ ! -d ~/src/c4raven-server ] || [ ! -d ~/.opentakserver_venv ]; then
  echo "${RED}No existing install found at ~/src/c4raven-server. Run install.sh first.${NC}"
  exit 1
fi

echo "${GREEN}Updating the Raven backend...${NC}"
cd ~/src/c4raven-server
git fetch origin
git pull --ff-only origin master

# shellcheck source=/dev/null
source ~/.opentakserver_venv/bin/activate
pip3 install -e ~/src/c4raven-server
flask db upgrade
echo "${GREEN}Backend updated.${NC}"

if [ -d ~/src/c4raven-ui ]; then
  echo "${GREEN}Updating the C4 Raven UI frontend...${NC}"
  cd ~/src/c4raven-ui
  git fetch origin
  git pull --ff-only origin master
  npm install
  npm run build
  rsync -a --delete dist/ /var/www/html/opentakserver/
  echo "${GREEN}Frontend updated and deployed.${NC}"
else
  echo "${YELLOW}No ~/src/c4raven-ui checkout found -- skipping frontend update.${NC}"
fi

echo "${GREEN}Restarting services...${NC}"
sudo systemctl restart opentakserver cot_parser eud_handler eud_handler_ssl mediamtx

if systemctl is-active --quiet federation-hub 2>/dev/null; then
  sudo systemctl restart federation-hub
fi

deactivate
rm -rf "$TMP"

echo "${GREEN}Update complete.${NC}"
