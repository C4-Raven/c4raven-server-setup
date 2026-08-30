"""
Raven server -- initial admin seed script.

Run this ONCE against a freshly migrated (empty) database to create the
first administrator account. It refuses to run if any user already exists,
so it is safe to keep in source control without risk of it being run
against a live, populated database by mistake.

Creates:
    username: admin
    password: password
    role:     administrator
    force_password_change: True   -- the account is locked out of everything
                                      except changing its password until a
                                      real password is set, on first login.

Requires the force_password_change patch (custom column on the User model
and the enforcement hook in app.py) to already be applied -- without it,
create_user() below will raise a TypeError on the unexpected keyword.

Usage (from the server, with the app's virtualenv active):
    python3 seed_admin.py
"""

import sys

from opentakserver.app import create_app

app = create_app(cli=True)

from opentakserver.extensions import db
from opentakserver.models.role import Role
from opentakserver.models.user import User
from flask_security import SQLAlchemyUserDatastore, hash_password

ADMIN_USERNAME = "admin"
ADMIN_PASSWORD = "password"

with app.app_context():
    existing_user_count = User.query.count()
    if existing_user_count > 0:
        print(
            f"Refusing to run: {existing_user_count} user(s) already exist in "
            "this database. This script is only for seeding a brand new, "
            "empty deployment."
        )
        sys.exit(1)

    datastore = SQLAlchemyUserDatastore(db, User, Role, None)

    admin_role = datastore.find_role("administrator")
    if not admin_role:
        admin_role = datastore.create_role(name="administrator")

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
    print("It will be forced to set a real password and 2FA on first login.")
