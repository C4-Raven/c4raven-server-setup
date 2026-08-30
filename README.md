# Raven server setup

Setup files for a fresh Raven (OpenTAKServer-based) deployment.

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
