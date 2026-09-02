<p align="center">
  <img src="docs/logo.png" alt="C4 Raven" width="480">
</p>

<p align="center">
  <a href="https://tak.c4raven.net"><strong>tak.c4raven.net</strong></a>
</p>

# C4 Raven server setup

Setup files for a fresh deployment of our TAK (Team Awareness Kit) server —
a Raven-branded, security-hardened
[OpenTAKServer](https://www.opentakserver.io/) fork
([c4raven-server](https://github.com/C4-Raven/c4raven-server)), paired with
the [C4 Raven UI](https://github.com/C4-Raven/c4raven-ui) frontend.

## Install

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
one). Run as a normal user, not root — it uses `sudo` itself where needed.

### Federation Hub

TAK Federation Hub isn't something this script can download for you — the
`takserver-fed-hub_*.deb` package is only available from a licensed
TAK.gov account. If you already have it downloaded, the installer will
install it (along with its MongoDB dependency) and point you at its own
setup docs (`/opt/tak/federation-hub/docs`) for the remaining TLS
keystore/policy configuration, which is domain-specific and has to be done
by hand either way.

## Update

```
curl -fsSL https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/update.sh | bash
```

Pulls the latest backend and frontend, applies any new database
migrations, rebuilds the UI, and restarts every service. Never touches
your `config.yml` or data — safe to run any time.

## Files

- **`install.sh`** / **`update.sh`** — see above.
- **`nginx_configs/`**, **`mediamtx.yml`**, **`rabbitmq.conf`** — templates
  the installer fetches and fills in; not meant to be used standalone.
- **`seed_admin.py`** — run automatically by `install.sh` on a freshly
  migrated (empty) database to create the first administrator account:
  - username: `admin`
  - password: `password`
  - forced to set a real password and 2FA on first login

  Refuses to run if any user already exists, so it's safe to keep around
  without risk of it being run against a live, populated database. Can
  also be run by hand: `python3 seed_admin.py` (with the venv active, from
  inside `~/src/c4raven-server`).
