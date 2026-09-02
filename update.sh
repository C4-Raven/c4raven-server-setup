#!/bin/bash
# C4 Raven TAK Server -- one-command updater.
#
#   curl -fsSL https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/update.sh | bash
#
# Pulls the latest backend + frontend, rebuilds the UI, and restarts every
# Raven service. Safe to run any time -- it only pulls and reapplies, it
# never touches config.yml, .raven-secrets.env, or data.
set -euo pipefail

APP_USER="raven"
APP_HOME="/opt/raven"
WEBROOT="/var/www/html/raven"

TMP=/tmp/raven_updater
mkdir -p "$TMP"
REPO_RAW=https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master
curl -fsSL "$REPO_RAW/colors.sh" -o "$TMP/colors.sh"
# shellcheck source=/dev/null
. "$TMP/colors.sh"

if [ "$(whoami)" == "root" ] || [ "$(whoami)" == "$APP_USER" ]; then
  echo "${RED}Run this as your own sudo-capable user, not root or '$APP_USER'.${NC}"
  exit 1
fi

if ! sudo test -d "$APP_HOME/c4raven-server"; then
  echo "${RED}No existing install found at $APP_HOME/c4raven-server. Run install.sh first.${NC}"
  exit 1
fi

run_as_app() {
  sudo -u "$APP_USER" -H bash -lc "$1"
}

echo "${GREEN}Updating the Raven backend...${NC}"
# raven/__init__.py is an auto-generated version stamp that `poetry install`
# rewrites on every run -- discard that one file's local drift before
# pulling (confirmed live: a dirty _versions.ts blocks the frontend pull
# below the exact same way) rather than let it silently block future pulls.
run_as_app "cd '$APP_HOME/c4raven-server' && git checkout -- raven/__init__.py 2>/dev/null; git fetch origin && git pull --ff-only origin master"
run_as_app "cd '$APP_HOME/c4raven-server' && poetry install"
echo "${GREEN}Backend updated.${NC}"
# Migrations run automatically inside the app on every startup (see
# init_extensions() in raven/app.py), applied when services restart below --
# no separate `flask db upgrade` step here.

if sudo test -d "$APP_HOME/c4raven-ui"; then
  echo "${GREEN}Updating the C4 Raven UI frontend...${NC}"
  # src/_versions.ts is an auto-generated build stamp that `yarn build`
  # rewrites every time -- confirmed live: without discarding it first, the
  # very next pull fails outright ("local changes would be overwritten").
  run_as_app "cd '$APP_HOME/c4raven-ui' && git checkout -- src/_versions.ts 2>/dev/null; git fetch origin && git pull --ff-only origin master"
  # c4raven-ui pins yarn 4 (packageManager in package.json) -- npm doesn't
  # understand its lockfile and will silently downgrade/corrupt it if used
  # here instead. `corepack yarn` runs the pinned version directly without
  # needing `corepack enable` (which needs root to symlink into /usr/bin).
  run_as_app "cd '$APP_HOME/c4raven-ui' && corepack yarn install"
  run_as_app "cd '$APP_HOME/c4raven-ui' && corepack yarn build"
  # Deploy as root, not as $APP_USER: whatever previously owned files are in
  # the webroot might not be deletable by $APP_USER even though the
  # directory itself is world-writable -- confirmed live against a server
  # whose webroot had www-data-owned files, where `--delete` failed outright
  # with Permission denied under the app user. Root can always write/delete
  # regardless of prior ownership. --no-perms/--no-owner/--no-group/
  # --omit-dir-times: skip metadata rsync -a would otherwise try to set on
  # the destination directory entry itself, which fails even as root once
  # anything has left it non-writable by its own uid/gid.
  sudo rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete "$APP_HOME/c4raven-ui/dist/" "$WEBROOT/"
  sudo chown -R "$APP_USER:$APP_USER" "$WEBROOT"
  echo "${GREEN}Frontend updated and deployed.${NC}"
else
  echo "${YELLOW}No $APP_HOME/c4raven-ui checkout found -- skipping frontend update.${NC}"
fi

echo "${GREEN}Restarting services...${NC}"
sudo systemctl restart opentakserver cot_parser eud_handler eud_handler_ssl mediamtx

if systemctl is-active --quiet federation-hub 2>/dev/null; then
  sudo systemctl restart federation-hub
fi

rm -rf "$TMP"

echo "${GREEN}Update complete.${NC}"
