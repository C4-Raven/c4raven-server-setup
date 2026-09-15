"""
Raven server -- first-admin hardening script.

The server creates its own first administrator the first time it starts
against an empty database (see main() in raven/app.py): username
`administrator`, password `password`, with NO forced password change. Both
installers (install.sh and the .deb postinst) start the server before this
script runs, because the database tables are only created by the
migrations the server itself applies on startup -- so by the time this
runs, that default account normally already exists.

This script therefore does one of three things, and nothing else:

  * no users yet (server not started, or migrations ran without main()):
      create `administrator` / `password` with force_password_change=True
  * exactly one user, the server's default `administrator` still on the
    default password and not yet forced to change it:
      set force_password_change=True on it
  * anything else (real accounts exist, or the default one is already
    hardened):
      leave the database alone and exit 3

force_password_change locks the account out of everything except changing
its own password until a real one is set (custom column on User plus the
enforcement hook in app.py).

Exit codes: 0 done, 2 database tables not ready (server not up yet),
3 nothing to do. Never touches an existing, populated deployment.

Usage (from the server checkout, with the app's virtualenv):
    RAVEN_DATA_FOLDER=/opt/raven/data poetry run python seed_admin.py
"""

import sys
import time

from raven.app import create_app

app = create_app(cli=True)

from flask_security import SQLAlchemyUserDatastore, hash_password, verify_password  # noqa: E402
from sqlalchemy.exc import OperationalError, ProgrammingError  # noqa: E402

from raven.extensions import db  # noqa: E402
from raven.models.role import Role  # noqa: E402
from raven.models.user import User  # noqa: E402

ADMIN_USERNAME = "administrator"  # must match what raven/app.py main() creates
ADMIN_PASSWORD = "password"
WAIT_SECONDS = 120


def wait_for_tables():
    """The migrations run inside the server on startup; poll until `user` exists."""
    deadline = time.monotonic() + WAIT_SECONDS
    while True:
        try:
            return User.query.all()
        except (ProgrammingError, OperationalError):
            db.session.rollback()
            if time.monotonic() > deadline:
                print(
                    f"Database tables still not present after {WAIT_SECONDS}s -- is the "
                    "raven service running? Re-run this script once it is."
                )
                sys.exit(2)
            time.sleep(2)


with app.app_context():
    users = wait_for_tables()
    datastore = SQLAlchemyUserDatastore(db, User, Role, None)

    if not users:
        admin_role = datastore.find_role("administrator")
        if not admin_role:
            admin_role = datastore.create_role(name="administrator", permissions={"administrator"})
        datastore.create_user(
            username=ADMIN_USERNAME,
            email=None,
            password=hash_password(ADMIN_PASSWORD),
            active=True,
            roles=[admin_role],
            force_password_change=True,
        )
        db.session.commit()
        print(f"Created admin account '{ADMIN_USERNAME}' with password '{ADMIN_PASSWORD}'.")
        print("It must set a real password on first login before it can do anything else.")
        sys.exit(0)

    if len(users) == 1:
        (user,) = users
        if (
            user.username == ADMIN_USERNAME
            and not user.force_password_change
            and verify_password(ADMIN_PASSWORD, user.password)
        ):
            user.force_password_change = True
            db.session.commit()
            print(
                f"Server-created default account '{ADMIN_USERNAME}' (password "
                f"'{ADMIN_PASSWORD}') is now required to set a real password on first login."
            )
            sys.exit(0)

    print(
        f"Nothing to do: {len(users)} account(s) already exist and none is the untouched "
        "default -- leaving the database alone."
    )
    sys.exit(3)
