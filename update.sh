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

# The offline .deb installs a plain venv (/opt/raven/venv) and no source
# checkout; it's upgraded by installing a newer offline bundle, not by pulling.
if sudo test -L "$APP_HOME/venv"; then
  echo "${RED}This server was installed from the offline package. To update it, run install.sh from a newer c4raven-server-offline bundle (or sudo apt install ./c4raven-server_<version>_<arch>.deb).${NC}"
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
run_as_app "cd '$APP_HOME/c4raven-server' && git checkout -- raven/__init__.py 2>/dev/null; git fetch origin && git pull --ff-only origin main"
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
  run_as_app "cd '$APP_HOME/c4raven-ui' && git checkout -- src/_versions.ts 2>/dev/null; git fetch origin && git pull --ff-only origin main"
  # c4raven-ui pins yarn 4 (packageManager in package.json) -- npm doesn't
  # understand its lockfile and will silently downgrade/corrupt it if used
  # here instead. `corepack yarn` runs the pinned version directly without
  # needing `corepack enable` (which needs root to symlink into /usr/bin).
  run_as_app "cd '$APP_HOME/c4raven-ui' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn install --immutable"
  run_as_app "cd '$APP_HOME/c4raven-ui' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn build"
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
  # Relabel for SELinux: rsync creates every file fresh, and a file born under
  # /var/www inherits var_t rather than the httpd_sys_content_t the policy maps
  # it to, so nginx 403s the whole UI after an otherwise clean update. install.sh
  # and the RPM's configure.sh both relabel right after this same rsync; without
  # it here, updating an EL box breaks the UI every single time. No-op on
  # Debian/Ubuntu, where restorecon doesn't exist.
  command -v restorecon >/dev/null 2>&1 && sudo restorecon -RF "$WEBROOT" >/dev/null 2>&1
  echo "${GREEN}Frontend updated and deployed.${NC}"
else
  echo "${YELLOW}No $APP_HOME/c4raven-ui checkout found -- skipping frontend update.${NC}"
fi

# nginx: blocks that do not verify client certificates must not pass on a
# client-supplied X-Ssl-Cert header (Raven would take it as a verified cert).
# Patched in place, since certbot may have edited these files; backed up,
# checked with nginx -t, and restored if nginx rejects the result.
NGINX_FILES=()
for f in raven_http raven_certificate_enrollment raven_certificate_enrollment_domain; do
  for cand in "/etc/nginx/sites-available/$f" "/etc/nginx/conf.d/$f.conf"; do
    sudo test -f "$cand" && NGINX_FILES+=("$cand")
  done
done
if [ "${#NGINX_FILES[@]}" -gt 0 ] \
   && curl -fsSL --retry 5 --retry-delay 3 "$REPO_RAW/lib/nginx_clear_ssl_cert.py" -o "$TMP/nginx_clear_ssl_cert.py" \
   && grep -q '^def patch' "$TMP/nginx_clear_ssl_cert.py"; then
  echo "${GREEN}Checking nginx's X-Ssl-Cert handling...${NC}"
  TS=$(date +%Y%m%d-%H%M%S)
  for f in "${NGINX_FILES[@]}"; do sudo cp -a "$f" "$f.bak-$TS"; done
  sudo python3 "$TMP/nginx_clear_ssl_cert.py" "${NGINX_FILES[@]}"
  if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx
    for f in "${NGINX_FILES[@]}"; do
      if sudo cmp -s "$f" "$f.bak-$TS"; then sudo rm -f "$f.bak-$TS"; fi
    done
  else
    echo "${RED}nginx rejected the X-Ssl-Cert change; restoring the previous files.${NC}"
    for f in "${NGINX_FILES[@]}"; do sudo cp -a "$f.bak-$TS" "$f"; done
  fi
fi

# The services append stdout/stderr to raven.log; systemd (root) creates it
# if missing, root-owned. The 2.3.0 error-log API reads the logs as the app
# user, so make sure it owns them.
sudo install -d -o "$APP_USER" -g "$APP_USER" -m 750 "$APP_HOME/data/logs"
sudo test -e "$APP_HOME/data/logs/raven.log" \
  || sudo install -o "$APP_USER" -g "$APP_USER" -m 640 /dev/null "$APP_HOME/data/logs/raven.log"
sudo find "$APP_HOME/data/logs" -maxdepth 1 -type f -name '*.log*' ! -user "$APP_USER" \
  -exec chown "$APP_USER:$APP_USER" {} +

echo "${GREEN}Restarting services...${NC}"
sudo systemctl restart raven cot_parser eud_handler eud_handler_ssl mediamtx

if systemctl is-active --quiet federation-hub 2>/dev/null; then
  sudo systemctl restart federation-hub
fi

rm -rf "$TMP"

echo "${GREEN}Update complete.${NC}"
