# Changelog

Releases of the C4 Raven server stack: the installer and packaging in this
repo, plus the [c4raven-server](https://github.com/C4-Raven/c4raven-server)
backend and [c4raven-ui](https://github.com/C4-Raven/c4raven-ui) frontend
they deploy.

## 2.3.0

### New

**Security and monitoring**

- **Security audit trail.** Web and LDAP logins, failed logins and failed
  2FA, logouts, password and 2FA changes, certificate enrollments, and
  changes to users, groups, API tokens, data packages and device profiles
  are recorded in a new `audit_events` table. Admins can browse,
  filter and download it.
- **Live error log.** Admins can read and download the server's recent
  errors from the web UI, without shell access.
- **Server Requests page** (`/server-requests`). One page for scheduled
  jobs, the audit trail and the error log. The old `/jobs` link redirects
  there.

**Scheduler**

- Every job now has a description.
- Admins can set a job's schedule in the web UI: once at a date and time,
  every N minutes, hourly, daily or weekly, in a timezone they pick. They
  can also cancel a scheduled run.
- Schedules an admin sets survive restarts. `config.yml` never overwrites
  them.

**Groups**

- **Group policies.** Each group can have a default access (send &
  receive, send only, receive only), auto-join for new users (existing
  users can be added in one action), a default membership length after
  which members are removed by the new `expire_group_memberships` job, and
  a lock. A locked group cannot be changed by hand, but its auto-join and
  expiry policies keep running. Policy changes are written to the audit
  trail.
- The Groups page is rewritten around these policies. Members can be given
  an expiry date.
- **One-way visibility fix.** Redrawing a two-way connection as one-way in
  the "Who Can See Whom" diagram, or reversing its arrow, now removes the
  reverse direction. If a shared named group still grants that direction,
  the diagram names the group so you can change it there. Every connection
  in the diagram shows which groups carry it.

**Device profiles**

- **Device profiles are redesigned.** A profile is now a named set of ATAK
  settings, aimed at everyone or at specific users, groups or devices, and
  sent on enrollment, on connection or both. Profiles can be previewed per
  user or device, exported, imported, and can carry data packages and
  plugins to install. The enrollment and connection packages ATAK downloads
  are built from these profiles.
- The connection profile endpoint (`/Marti/api/device/profile/connection`,
  `/api/connection`) now requires a verified client certificate or Basic
  credentials. See the upgrade notes.

**Web UI**

- Redesigned dashboard.
- Users page: no nested scrolling, and separate Tx and Rx group pickers.
- The visibility diagram and the device profile pages are redesigned.
- An expired CSRF token is now refreshed and the request retried
  automatically, instead of failing until the page is reloaded.
- The Server Plugin Manager page is removed.

**Fixes**

- Downloading an enrollment package no longer returns a 500 error.
- nginx no longer passes a client-supplied `X-Ssl-Cert` header to the
  backend on ports that do not verify client certificates (80, 8080 and
  the enrollment port 8446). Without this, a client could forge a
  certificate identity there.

**Installer and packages**

- `install.sh` can be re-run after a failure and picks up where it
  stopped. It keeps the database, CA and server certificate,
  `config.yml`, `mediamtx.yml`, source checkouts and secrets. It reuses
  the database password and the domain answer from the previous run
  instead of asking again.
- Network steps (apt/dnf, git, PyPI, npm, downloads) are retried with
  backoff.
- `install.sh` ends with a health check (services, migrations, a live API
  request, the admin account) and a PASS/FAIL summary. It exits non-zero
  if any check fails. When it stops, it prints which step failed and how
  to resume or recover.
- `install.sh`, the `.deb`, the `.rpm` and the offline bundle check that
  systemd is PID 1 before changing anything. In a container they print the
  `docker run` flags needed (`RAVEN_SKIP_SYSTEMD_CHECK=1` skips the
  check). After the first start they wait up to 5 minutes and confirm the
  database reached the latest migration.
- The installers create `raven.log` owned by the `raven` user, so the new
  error log can read it.
- `REPO_RAW=file:///path/to/checkout` installs from a local copy of this
  repo. `RAVEN_DB_PASSWORD` supplies the database password on a re-run.

**Updating**

- This repo's `update.sh` adds the `X-Ssl-Cert` fix to existing nginx
  sites.
- [c4raven-updater](https://github.com/C4-Raven/c4raven-updater) also
  runs and verifies the database migrations, applies the nginx fixes to
  both layouts (`raven_*` and legacy `ots_*`), fixes log file ownership,
  retries network steps, and can run as root inside a container.
  `finish-install.sh` now repairs any missing piece of an install, and
  `update.sh` runs it by itself when an install never finished.

### Upgrade notes

- **Database migrations run automatically.** Three new migrations
  (`e5a9c3f17b20` audit events, `b8e4d2a6c913` group policies,
  `d3f1a7c95b20` device profile sets) run when `raven` starts. There is
  no separate migration step. They are additive, but the last one copies
  data, so back up the database first (c4raven-updater does this on every
  run). No Python dependencies were added or removed.
- **Old device profile rows are migrated.** Each existing setting moves
  into the new profiles: settings for everyone go into one profile called
  "Default settings", and settings for one device go into a profile called
  "Settings for <callsign>". Inactive settings go into a separate disabled
  "(inactive)" profile, so nothing starts being sent that was not sent
  before. Rows with a blank key are dropped. The old `device_profiles`
  table is kept but no longer used.
- **The connection profile now requires authentication.** ATAK fetches it
  on 8443 with its client certificate, so enrolled devices are not
  affected. Devices that connect over plain TCP and fetch the profile over
  HTTP no longer get it. If you have such devices, add
  `RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH: false` to
  `/opt/raven/data/config.yml` and restart `raven`.
- **nginx `X-Ssl-Cert` hardening.** New installs get it from the updated
  templates. On an existing install, run this repo's `update.sh` or
  c4raven-updater. Either one adds `proxy_set_header X-Ssl-Cert "";` to
  the sites that don't verify client certificates (`raven_http`,
  `raven_certificate_enrollment`, `raven_certificate_enrollment_domain`),
  backs each file up, and restores it if `nginx -t` fails. To patch by
  hand, run `sudo python3 lib/nginx_clear_ssl_cert.py <site files>`, then
  `sudo nginx -t && sudo systemctl reload nginx`. Do not run it on
  `raven_https`.
- **ADS-B and AIS jobs are removed.** `get_adsb_data` and `ais` are
  dropped from `config.yml`'s job list at startup and deleted from the job
  store, so nothing needs editing by hand. `expire_group_memberships` is
  added to existing configs automatically. A schedule an admin set in the
  web UI is kept across restarts; editing `JOBS` in `config.yml` does not
  change an existing job's schedule.
- **New optional settings.** `RAVEN_ERROR_LOG_MAX_BYTES` (default 20 MiB)
  and `RAVEN_ERROR_LOG_DOWNLOAD_MAX_BYTES` (default 100 MiB) cap how much
  of each log the error log view reads and downloads. The error log reads
  `logs/*.log` in the data folder; a file the `raven` user cannot read is
  skipped.
