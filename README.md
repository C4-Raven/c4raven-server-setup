<p align="center">
  <img src="docs/logo.png" alt="C4 Raven" width="480">
</p>

<p align="center">
  <a href="https://tak.c4raven.net"><strong>tak.c4raven.net</strong></a>
</p>

# C4 Raven server setup

Setup files for a fresh deployment of our TAK (Team Awareness Kit) server —
a Raven-branded, security-hardened
fork of [the upstream project](https://www.opentakserver.io/)
([c4raven-server](https://github.com/C4-Raven/c4raven-server)), paired with
the [C4 Raven UI](https://github.com/C4-Raven/c4raven-ui) frontend.

## Install

### Option 1: `.deb` package

Download the latest `c4raven-server_*_all.deb` from
[Releases](https://github.com/C4-Raven/c4raven-server-setup/releases) and:

```
sudo apt install ./c4raven-server_*_all.deb
```

apt pulls in PostgreSQL, RabbitMQ, nginx, and everything else this needs as
real dependencies, then prompts for the two questions install.sh below
also asks (a public domain, Cloudflare Turnstile) via the standard Debian
config-file prompt, and does the rest of the setup (backend venv,
frontend build, certificate authority, systemd services) in its postinst
script. `sudo apt install ./c4raven-server_*_all.deb` again on a newer
`.deb` to upgrade — each release is pinned to a specific, reproducible
commit of `c4raven-server`/`c4raven-ui` rather than always floating to
`main`.

One prerequisite apt can't satisfy for you: building the frontend needs
Node.js 20.19 or newer, and Ubuntu 24.04's own `nodejs` package is 18.x.
On such a system install Node 22 first (`install.sh` does this itself):

```
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
```

`apt remove` stops the services but leaves your data in place; `apt purge`
prints exactly what a full wipe (database, `/opt/raven`, the `raven`
system user) requires rather than doing it automatically — that's too
high-stakes to run unattended.

### Option 2: `install.sh`

One command, on a fresh Ubuntu box:

```
curl -fsSL https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/install.sh | bash
```

This installs everything in one pass: system packages, PostgreSQL,
RabbitMQ, the backend and frontend, nginx, mediamtx, and the systemd
services. It interactively asks whether to enable Cloudflare Turnstile
(the login-page bot check — you'll need a site key and secret key from your
Cloudflare dashboard's Turnstile section) and whether to configure a public
domain (gets you a real Let's Encrypt certificate instead of a self-signed
one), and whether you have a Federation Hub `.deb` to install. Run as
your own sudo-capable user, not root and not `raven` — it uses `sudo`
itself where needed and prompts for your password on the terminal even
when piped into `bash`. Update later with `update.sh`, which always pulls
the latest `main` rather than a pinned version.

At the end, either option makes sure the first administrator account has
to set a real password on first login (see [`seed_admin.py`](#files)
below) and prints the URL to log in at.

### Federation Hub

TAK Federation Hub isn't something this script can download for you — the
`takserver-fed-hub_*.deb` package is only available from a licensed
TAK.gov account. If you already have it downloaded, `install.sh` will
install it (along with its MongoDB dependency) and point you at its own
setup docs (`/opt/tak/federation-hub/docs`) for the remaining TLS
keystore/policy configuration, which is domain-specific and has to be done
by hand either way. The `.deb` doesn't prompt for it; see
[federation-hub-setup](https://github.com/C4-Raven/federation-hub-setup)
to add it afterwards.

## Update

For a server installed with `install.sh` (or the `.deb`, if you'd rather
track `main` than wait for the next release), one command, run as your own
sudo-capable user (not root, not `raven`):

```
curl -fsSL https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/update.sh | bash
```

Pulls the latest `main` of `c4raven-server` and `c4raven-ui`, reinstalls
the backend (`poetry install`), rebuilds the frontend with `yarn` and
deploys it to the webroot, then restarts the services (`raven`,
`cot_parser`, `eud_handler`, `eud_handler_ssl`, `mediamtx`, and
`federation-hub` if it's running) — you'll be asked for your `sudo`
password on the terminal as needed. Database migrations happen
automatically when `raven` restarts — there's no separate migration step
to run. Never touches your `config.yml` or data — safe to run any time.

Servers on the older single-user layout (`~/.opentakserver_venv`, `~/ots`,
`opentakserver.service`) predate this repo; they are updated with
[c4raven-updater](https://github.com/C4-Raven/c4raven-updater) instead,
and this `update.sh` will stop with "No existing install found" on them.

## Files

- **`install.sh`** / **`update.sh`** — see above.
- **`debian/`**, **`build-deb.sh`** — the `.deb` package source.
  `build-deb.sh` stages a package tree and calls `dpkg-deb --build`
  directly (not `dpkg-buildpackage`/debhelper — there's no compilation at
  package-build time, the venv is built by postinst on the target
  machine). `.github/workflows/release.yml` runs it on every `v*` tag push
  and attaches the result to a GitHub Release. Tags are `vX.Y.Z` (e.g.
  `v2.1.3`); keep the same scheme so `dpkg` orders upgrades correctly.
- **`nginx_configs/`**, **`mediamtx.yml`**, **`rabbitmq.conf`** — templates
  `install.sh` fetches and fills in (`SERVER_CERT_FILE`, `OTS_FOLDER`, ...)
  at install time. `build-deb.sh` runs the same substitution over the same
  files at build time for the `.deb` (every path they reference is a fixed
  `/opt/raven/...` constant), so there is only one copy of each to
  maintain. Not meant to be used standalone.
- **`seed_admin.py`** — run automatically at the end of both installs.
  The server creates its own first administrator the first time it starts
  on an empty database (`administrator` / `password`); this script makes
  that account set a real password on first login (or creates it that way
  if the server hasn't yet). Leaves the database alone — exit 3 — if any
  other accounts already exist, so it's safe to keep around. Can also be
  run by hand as the `raven` user:
  `cd /opt/raven/c4raven-server && FLASK_APP=raven.app RAVEN_DATA_FOLDER=/opt/raven/data poetry run python /opt/raven/seed_admin.py`
  (the `.deb` keeps its copy at `/usr/share/c4raven-server/seed_admin.py`).

## Layout

Everything runs under a dedicated, non-login `raven` system account (not
whoever ran `install.sh`) at `/opt/raven`:

- `/opt/raven/c4raven-server`, `/opt/raven/c4raven-ui` — the two repos.
  The backend's dependencies come from Poetry (`poetry.lock`), with its
  virtualenv kept in-project at `c4raven-server/.venv`.
- `/opt/raven/data` — `config.yml`, the certificate authority, mediamtx
  recordings, logs, uploads. Equivalent to `RAVEN_DATA_FOLDER`.
- `/opt/raven/.raven-secrets.env` — a locked-down (600) file read via
  systemd's `EnvironmentFile=`, supplying `RAVEN_DATA_FOLDER` (so the app
  can find `config.yml` in the first place) plus the database/RabbitMQ
  credentials.
- PostgreSQL role and database are both named `raven`.
- nginx configs and the webroot are named to match:
  `/etc/nginx/sites-available/raven_*`, `/var/www/html/raven`.
