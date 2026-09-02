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
echo "${GREEN}Backend updated.${NC}"
# Migrations run automatically inside the app on every startup (see
# init_extensions() in raven/app.py), applied when services restart below --
# no separate `flask db upgrade` step here.

if [ -d ~/src/c4raven-ui ]; then
  echo "${GREEN}Updating the C4 Raven UI frontend...${NC}"
  cd ~/src/c4raven-ui
  git fetch origin
  git pull --ff-only origin master
  # This repo pins yarn 4 (see packageManager in package.json) -- npm doesn't
  # understand its lockfile and will silently downgrade/corrupt it if used
  # here instead. `corepack yarn` runs the pinned version directly without
  # needing `corepack enable` (which needs root to symlink into /usr/bin).
  corepack yarn install
  corepack yarn build
  # The webroot directory itself is root-owned but world-writable, so we can
  # write files into it but can't touch the directory entry's own
  # owner/group/permissions/mtime -- rsync -a tries to by default and exits
  # non-zero on that even though every file transfers fine, so skip it.
  rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete dist/ /var/www/html/opentakserver/
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
