<p align="center">
  <img src="docs/logo.png" alt="C4 Raven" width="480">
</p>

<p align="center">
  <a href="https://tak.c4raven.net"><strong>tak.c4raven.net</strong></a>
</p>

# C4 Raven server setup

Setup files for a fresh deployment of our TAK (Team Awareness Kit) server —
a Raven-branded, security-hardened
[OpenTAKServer](https://www.opentakserver.io/) instance, paired with the
[C4 Raven UI](https://github.com/C4Raven/c4raven-ui) frontend. This repo
holds just the pieces needed to bootstrap a new install cleanly: a real,
working configuration with every secret stripped out, and a script to
create the very first admin account without ever hand-picking or emailing
around a real password.

## Files

- **`config.example.yml`** — a sanitized copy of a working `config.yml`.
  Every real secret has been replaced with a `CHANGE_ME_...` placeholder
  (generation hints are inline as comments). Copy it to your data
  directory as `config.yml` and fill those in before starting the server.
  Keys prefixed `OTS_` are read literally by the installed `opentakserver`
  Python package and can't be renamed.

- **`seed_admin.py`** — run once against a freshly migrated (empty)
  database to create the first administrator account:
  - username: `admin`
  - password: `password`
  - forced to set a real password and 2FA on first login

  Refuses to run if any user already exists, so it's safe to keep around
  without risk of it being run against a live, populated database.

  Requires the `force_password_change` patch (a custom column on the
  `User` model, plus the login-flow enforcement hook) to already be
  applied to the `opentakserver` install this is run against.

  ```
  python3 seed_admin.py
  ```
