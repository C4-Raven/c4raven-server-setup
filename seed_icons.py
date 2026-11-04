"""
Raven server -- load the bundled ATAK icon sets into an empty icons table.

On its first start the server copies the `icons` rows of its own vendored
iconsets.sqlite (raven/data/) into the database. The offline .deb ships the
same file and the postinst runs this once the server's migrations have created
the table, as a fallback should the server not have loaded them yet.

  * icons table already has rows:  leave it alone, exit 3
  * icons table empty:             copy every row from the bundled file, exit 0
  * icons table not created yet:   exit 2 (the server is not up yet)

Deliberately does NOT call raven.app.create_app() (see seed_plugin.py): only
the database URI from config.yml is needed.

Usage, as the app user, with the server's virtualenv and RAVEN_DATA_FOLDER set:
    python seed_icons.py /usr/share/c4raven-server/offline/icons/iconsets.sqlite
"""

import os
import sqlite3
import sys

import sqlalchemy as sa
import yaml

from raven.defaultconfig import DefaultConfig

if len(sys.argv) != 2 or not os.path.isfile(sys.argv[1]):
    print("usage: seed_icons.py <iconsets.sqlite>", file=sys.stderr)
    sys.exit(1)

data_dir = os.environ.get("RAVEN_DATA_FOLDER") or DefaultConfig.RAVEN_DATA_FOLDER
with open(os.path.join(data_dir, "config.yml")) as f:
    uri = (yaml.safe_load(f) or {}).get("SQLALCHEMY_DATABASE_URI") or os.environ.get(
        "SQLALCHEMY_DATABASE_URI"
    )
if not uri:
    print("no SQLALCHEMY_DATABASE_URI in config.yml", file=sys.stderr)
    sys.exit(1)

engine = sa.create_engine(uri)
try:
    icons = sa.Table("icons", sa.MetaData(), autoload_with=engine)
except sa.exc.NoSuchTableError:
    print("icons table not created yet", file=sys.stderr)
    sys.exit(2)

with engine.begin() as conn:
    if conn.execute(sa.select(sa.func.count()).select_from(icons)).scalar():
        print("Icons already loaded.")
        sys.exit(3)

    src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    src.row_factory = sqlite3.Row
    cols = set(icons.c.keys())
    rows = [
        {k: r[k] for k in r.keys() if k in cols} for r in src.execute("SELECT * FROM icons")
    ]
    src.close()
    if not rows:
        print("the bundled icon set is empty", file=sys.stderr)
        sys.exit(1)
    conn.execute(icons.insert(), rows)
    # The rows carry their own ids; move the id sequence past them so icons
    # added later through the web UI do not collide.
    if engine.dialect.name == "postgresql" and "id" in cols:
        conn.execute(
            sa.text(
                "SELECT setval(pg_get_serial_sequence('icons', 'id'), "
                "(SELECT MAX(id) FROM icons)) WHERE pg_get_serial_sequence('icons', 'id') IS NOT NULL"
            )
        )
    print(f"Loaded {len(rows)} icons.")
