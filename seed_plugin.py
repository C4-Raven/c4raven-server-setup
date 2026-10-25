"""
Raven server -- register a bundled ATAK plugin in the package repository.

The offline .deb ships the tak.gov-signed CROW Remote Clear APK. This script
puts it in <data>/packages, writes (or updates) its row in the `packages`
table, and regenerates the product.infz indexes ATAK syncs from, so enrolling
devices are offered the plugin without anyone uploading it through the web UI.

It never downgrades and never touches other packages:

  * no row for this package name yet:          add it (install on enrollment)
  * one row with a LOWER revision code:         replace the APK, update the row
  * one row with the same or higher revision:   leave it alone, exit 3
  * more than one row for this package name:    leave it alone, exit 4

A row that already exists keeps its file name and its install-on-enrollment /
install-on-connection choices, so settings changed in the web UI survive
package upgrades.

Deliberately does NOT call raven.app.create_app(): that rewrites mediamtx.yml
and starts the app's extensions. A bare Flask app with the same config is all
this needs (the same approach as the plugin repo's publish_ravenclear.py).

Exit codes: 0 published, 2 database tables not ready (server not up yet),
3 already up to date, 4 ambiguous (several rows), 1 anything else.

Usage, as the app user, with the server's virtualenv and RAVEN_DATA_FOLDER set:
    python seed_plugin.py /usr/share/c4raven-server/plugins/<plugin>.apk
"""

import argparse
import datetime
import hashlib
import importlib
import os
import pkgutil
import re
import shutil
import sys

import yaml
from flask import Flask

from raven.defaultconfig import DefaultConfig
from raven.extensions import db

DESCRIPTIONS = {
    "com.atakmap.android.ravenclear.plugin": (
        "Lets a C4 Raven administrator remotely clear this device's ATAK content"
    ),
}

parser = argparse.ArgumentParser()
parser.add_argument("apk", help="APK to register")
parser.add_argument(
    "--atak-version",
    help="ATAK version the package repo files it under (default: from the APK's plugin-api)",
)
ARGS = parser.parse_args()

SRC = os.path.abspath(ARGS.apk)
if not os.path.isfile(SRC):
    print(f"no such APK: {SRC}", file=sys.stderr)
    sys.exit(1)

app = Flask(__name__)
app.config.from_object(DefaultConfig)
app.config.from_file(
    os.path.join(app.config["RAVEN_DATA_FOLDER"], "config.yml"), load=yaml.safe_load
)
db.init_app(app)

# raven.models.user.User mixes in Flask-Security's FsUserMixin, which resolves
# its relationships against FsModels.db at class-definition time, and querying
# any model configures every mapper in the registry. Register the lot first.
import sqlalchemy.exc  # noqa: E402
import sqlalchemy.orm  # noqa: E402
from flask_security.models import fsqla  # noqa: E402

try:
    fsqla.FsModels.set_db_info(db)
except sqlalchemy.exc.InvalidRequestError:
    pass

import raven.models  # noqa: E402

for _mod in sorted(m.name for m in pkgutil.iter_modules(raven.models.__path__)):
    importlib.import_module(f"raven.models.{_mod}")

from androguard.core.apk import APK  # noqa: E402

from raven.blueprints.raven_api.package_api import create_product_infz  # noqa: E402
from raven.models.Packages import Packages  # noqa: E402

sqlalchemy.orm.configure_mappers()

# androguard logs every resource it parses at DEBUG through loguru.
try:
    from loguru import logger as _loguru

    _loguru.remove()
except ImportError:
    pass

apk = APK(SRC)
package_name = apk.get_package()
version = apk.get_androidversion_name()
revision = int(apk.get_androidversion_code())
manifest_xml = apk.get_android_manifest_axml().get_xml().decode("utf-8", "replace")
m = re.search(r'value="com\.atakmap\.app@([0-9.]+)\.[A-Z]+"', manifest_xml)
atak_version = ARGS.atak_version or (m.group(1) if m else None)
if not atak_version:
    print("could not read the ATAK version from the APK; pass --atak-version", file=sys.stderr)
    sys.exit(1)

with open(SRC, "rb") as f:
    blob = f.read()

with app.app_context():
    try:
        rows = db.session.query(Packages).filter_by(package_name=package_name).all()
    except (sqlalchemy.exc.ProgrammingError, sqlalchemy.exc.OperationalError) as e:
        print(f"packages table not ready yet: {e.__class__.__name__}", file=sys.stderr)
        sys.exit(2)

    if len(rows) > 1:
        print(
            f"{len(rows)} package rows exist for {package_name}; leaving them alone. "
            "Remove the extras in the web UI, then re-run this script."
        )
        sys.exit(4)

    row = rows[0] if rows else None
    packages_dir = os.path.join(app.config["RAVEN_DATA_FOLDER"], "packages")
    os.makedirs(packages_dir, exist_ok=True)

    if row is not None and (row.revision_code or 0) >= revision:
        # Up to date, but put the file back if someone deleted it from disk.
        dest = os.path.join(packages_dir, row.file_name)
        if not os.path.exists(dest) and (row.revision_code or 0) == revision:
            shutil.copyfile(SRC, dest)
            print(f"restored missing {dest}")
        print(
            f"{package_name} revision {row.revision_code} already published "
            f"(bundled: {revision}); nothing to do"
        )
        sys.exit(3)

    old_atak_version = row.atak_version if row is not None else None
    if row is None:
        row = Packages()
        row.platform = "Android"
        row.plugin_type = "plugin"
        row.package_name = package_name
        row.file_name = os.path.basename(SRC)
        row.install_on_enrollment = True
        row.install_on_connection = False
        db.session.add(row)

    dest = os.path.join(packages_dir, row.file_name)
    shutil.copyfile(SRC, dest)

    row.name = apk.get_app_name() or package_name
    row.version = version
    row.revision_code = revision
    row.description = row.description or DESCRIPTIONS.get(package_name)
    row.apk_hash = hashlib.sha256(blob).hexdigest()
    row.file_size = len(blob)
    row.os_requirement = apk.get_min_sdk_version()
    row.atak_version = atak_version
    row.publish_time = datetime.datetime.now(datetime.timezone.utc)

    icon_path = apk.get_app_icon()
    if icon_path and icon_path.endswith(".png"):
        row.icon = apk.get_file(icon_path)
        row.icon_filename = f"{package_name}.png"

    db.session.commit()

    # ATAK asks for /api/packages/<its own version>/product.infz and falls back
    # to /api/packages/product.infz; refresh every index this row appears in.
    for v in {atak_version, old_atak_version, None}:
        create_product_infz(v)

    print(f"published {package_name} {version} (revision {revision}) as {dest}")
