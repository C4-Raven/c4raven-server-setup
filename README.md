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

## Supported platforms

The stack started as Ubuntu/amd64 and is being extended to Rocky/RHEL 9
and to arm64. The table below is what each combination actually is today,
not what we intend it to be:

| Target | `curl \| bash` | `.deb` | `.rpm` | offline bundle |
| --- | --- | --- | --- | --- |
| Ubuntu 24.04 / 25.10, amd64 | supported | supported | n/a | supported |
| Ubuntu 24.04 / 25.10, arm64 | untested | untested | n/a | untested, arm64-built only |
| Rocky / Alma / RHEL 9, x86_64 | untested | n/a | untested | not available |
| Rocky / Alma / RHEL 9, aarch64 | untested | n/a | untested | not available |
| Debian 12 | untested | untested | n/a | not available |

**"Untested" means exactly that.** Everything outside the Ubuntu/amd64
row is static analysis plus archive metadata: the package names, repo
URLs and architectures have been checked against the live archives, and
`tests/run-matrix.sh` runs the cells in containers, but no Rocky and no
arm64 install has been run on real hardware. Treat the first one you do
as a bring-up, not a deployment, and read
[`docs/rocky-el9.md`](docs/rocky-el9.md) and
[`docs/architectures.md`](docs/architectures.md) first.

Three limits that are structural rather than a to-do list:

- **Offline bundles are best built on their own architecture.**
  `build-offline.sh` refuses a cross-build unless `ALLOW_CROSS_BUILD=1`.
  Two locked dependencies (`mutf8` 1.0.6, `unishox2-py3` 1.0.0) publish
  no wheel for Python 3.12/3.13 on any architecture, so every build
  compiles them from sdist. A native build installs and imports the
  result; a cross-build compiles them with zig for the target and checks
  each `.so` is the right architecture, but cannot import them — see
  [`docs/architectures.md`](docs/architectures.md).
- **An EL9 offline payload cannot be built on Ubuntu** for the same
  reason in the other direction: Rocky 9 is glibc 2.34, Ubuntu 24.04 is
  2.39 and 25.10 is 2.42, so wheels compiled on Ubuntu fail at *import*
  on Rocky. `rpm/build-rpm.sh` refuses it. Nothing stages an EL9 offline
  payload today, which is why those cells read "not available" rather
  than "untested".
- **Federation Hub is Debian-only.** It ships as a `.deb` from TAK.gov
  with an Ubuntu MongoDB repo behind it; there is no EL port and the RPM
  does not pretend otherwise.

## Install

### Offline (no internet on the server)

`build-offline.sh` produces one archive per Ubuntu release and
architecture, `c4raven-server-offline_<version>_<release>_<arch>.tar`,
holding the server package and every Ubuntu package it needs. Copy it
across and run:

```
tar -xf c4raven-server-offline_*_noble_amd64.tar
cd c4raven-server-offline_*_noble_amd64
sudo ./install.sh
```

Pick the archive matching the machine, both halves of it: `noble` is
Ubuntu 24.04 and `questing` is 25.10, and the architecture suffix is the
dpkg name (`amd64`, `arm64`). A bundle only exists for an architecture
somebody built it on — see
[Supported platforms](#supported-platforms). `install.sh` checks the archive's checksums, then
installs through apt with the bundled repository as the only source, so it
never reaches for a mirror and never downgrades anything already
installed. Leave the domain prompt blank: without internet there's no
Let's Encrypt, and the server's own CA is used instead.

Everything comes from inside the package, pinned at build time: the
backend and all its Python dependencies (prebuilt wheels), the built web
UI, mediamtx, and the tak.gov-signed CROW Remote Clear ATAK plugin. The
plugin is published into the server's plugin repository on install, set to
install on enrollment, so devices get it with no upload through the web
UI. A newer APK uploaded later is never downgraded by a package upgrade.

To upgrade, run `install.sh` from a newer archive. `update.sh` does not
apply to offline installs (there's no source checkout to pull).

Building it (on a machine with internet and read access to the C4-Raven
repos, which are private):

```
PKG_VERSION=2.2.0 ./build-offline.sh
```

It builds for the machine it runs on. To get an arm64 bundle, run the
same command unchanged on arm64 hardware, an arm64 cloud VM, or
`docker run --platform linux/arm64`; or, on amd64, add
`TARGET_ARCH=arm64 ALLOW_CROSS_BUILD=1`, which cross-compiles the two C
extensions but can only resolve-check, not import-check, the result (see
[Supported platforms](#supported-platforms)). The apt dependencies
come from `archive.ubuntu.com` for amd64 and from `ports.ubuntu.com` for
everything else, which the script picks automatically;
`archive.ubuntu.com` has no `binary-arm64` at all and 404s if you point
it there by hand.

It needs Node.js 20.19+ and a `python3.12` and `python3.13` (on `PATH`, or
via `uv python install 3.12 3.13`). It builds from each repo's `main` tip
unless `SERVER_SHA`/`UI_SHA`/`PLUGIN_APK` say otherwise, refuses a plugin
that isn't signed by the TAK Product Center, and before packaging proves
that the Python wheels install with no index and that each release's
repository resolves `c4raven-server` on its own. The server `.deb` it also
leaves in `build/` (`c4raven-server_<version>_amd64.deb`) installs
offline on its own too, on a machine that already has the apt
dependencies. See the header of `build-offline.sh` for every option.

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

The package is `Architecture: all` and builds everything on the target,
so the same `.deb` installs on arm64 as on amd64 — every dependency it
declares exists on both in Ubuntu, and NodeSource's `setup_22.x`
publishes both. Untested on arm64 all the same. The offline `.deb` is
the exception: it carries prebuilt binaries, so it is
`Architecture: amd64` or `arm64` and built once per architecture.

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

Everything that differs between distributions — package manager and
package names, the nginx layout, PostgreSQL's initdb, firewalld, SELinux
— goes through `lib/distro.sh`, so the same script is meant to run on
Rocky/Alma/RHEL 9 as well. That path is the least exercised of the
three: on EL the `.rpm` below is the better-trodden route, because it is
the one `tests/run-matrix.sh` installs and verifies.

### Option 3: `.rpm` package (Rocky / Alma / RHEL 9)

EL9 needs its repositories set up first — `dnf` has to be able to
resolve `rabbitmq-server` and `certbot` *before* the package is
installed, so this cannot live inside the package:

```
sudo ./rpm/c4raven-el9-repos.sh
sudo dnf install ./c4raven-server-*.el9.*.rpm
```

That enables EPEL 9 and CRB, adds the RabbitMQ repository, and switches
the `nodejs` module stream to 22 (EL9's default is 18, which cannot
build the UI). Build the RPM itself with `PKG_VERSION=2.2.3
./rpm/build-rpm.sh`; it is `noarch` like the `.deb`, builds nothing at
package-build time, and does the whole setup on the target machine from
`/usr/libexec/c4raven-server/configure.sh`.

There is no debconf on RPM, so the two questions the `.deb` asks are
answered in a file instead. Either set them in the environment for an
unattended install:

```
sudo RAVEN_DOMAIN=tak.example.org dnf install ./c4raven-server-*.rpm
```

or install first, then edit `/etc/c4raven-server/setup.conf` and apply
it with `sudo c4raven-setup` — the same code path, idempotent, as many
times as you like. `setup.conf` is `%config(noreplace)` and mode 0600
(the Turnstile secret passes through it, and is blanked out of the file
once it has been consumed).

The practical differences from Ubuntu, all of them things an operator
will notice, are in [`docs/rocky-el9.md`](docs/rocky-el9.md): SELinux and
firewalld are on by default, the nginx layout has no
`sites-available`/`sites-enabled`, PostgreSQL ships uninitialised, the
venv is built with `python3.12` rather than `python3`, PostGIS and the
full `ffmpeg` are not packaged for EL9, and on aarch64 RabbitMQ is
capped at 4.3.2. Federation Hub is not available on EL at all.

At the end, every option makes sure the first administrator account has
to set a real password on first login (see [`seed_admin.py`](#files)
below) and prints the URL to log in at.

### Federation Hub

Federation Hub is Debian-only, and not by our choice: TAK.gov publishes
it as a `.deb`, and it wants MongoDB from MongoDB's own Ubuntu
repository. There is no EL build of either, so the `.rpm` prints a
pointer and stops — do not expect to add it to a Rocky server later.

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

An RPM install is upgraded the same way the `.deb` is — `sudo dnf
install ./c4raven-server-<newer>.rpm`, which re-runs `configure.sh` and
checks out the commit that version pins. `update.sh` itself is
distro-agnostic (it pulls, rebuilds and restarts; nothing in it is
apt-specific), so it also works on an EL box installed from source, with
the same caveat that it floats to `main`.

Servers on the older single-user layout (`~/.opentakserver_venv`, `~/ots`,
`opentakserver.service`) predate this repo; they are updated with
[c4raven-updater](https://github.com/C4-Raven/c4raven-updater) instead,
and this `update.sh` will stop with "No existing install found" on them.

## Files

- **`install.sh`** / **`update.sh`** — see above.
- **`lib/distro.sh`** — the distro/architecture shim everything else is
  meant to go through, sourced by `install.sh` (which fetches it
  alongside `colors.sh`, since `curl | bash` has no repo on disk) and by
  the RPM's setup script. `detect_distro` sets the family, the
  architecture in dpkg's and mediamtx's spellings, the nginx paths, the
  service names and the interpreter to build the venv with; the rest of
  the file is package names, `firewall_open`, the SELinux fixups and
  PostgreSQL's initdb. Nothing in it changes the system until you call
  one of the doers, and every function is safe to run twice.
- **`rpm/`** — the EL9 counterpart of `debian/`:
  `c4raven-server.spec` mirrors `debian/control` and the maintainer
  scripts, `build-rpm.sh` mirrors `build-deb.sh` (stage a tree, hand it
  to `rpmbuild`), `configure.sh` mirrors `postinst` step for step, and
  `setup.conf` + `c4raven-setup` stand in for debconf and
  `dpkg-reconfigure`. `c4raven-el9-repos.sh` is the source of truth for
  which repository each EL dependency comes from, and the one file to
  read before arguing about RabbitMQ versions on aarch64.
- **`tests/`**, **`.github/workflows/install-matrix.yml`**,
  **`.github/workflows/lint.yml`** — the verification matrix.
  `run-matrix.sh` installs each {distro, arch, method} cell end to end
  in a systemd container and then runs `verify.sh` against it, which
  asserts the stack is actually serving rather than that the installer
  exited 0. A cell whose inputs don't exist is skipped with a reason,
  never failed. CI runs amd64 on every push and the full cross product —
  arm64 included, on native runners — nightly; QEMU is deliberately not
  used, because Node and the Erlang JIT don't survive it reliably enough
  for a red/green signal.
- **`debian/`**, **`build-deb.sh`** — the `.deb` package source.
  `build-deb.sh` stages a package tree and calls `dpkg-deb --build`
  directly (not `dpkg-buildpackage`/debhelper — there's no compilation at
  package-build time, the venv is built by postinst on the target
  machine). `.github/workflows/release.yml` runs it on every `v*` tag push
  and attaches the result to a GitHub Release. Tags are `vX.Y.Z` (e.g.
  `v2.1.3`); keep the same scheme so `dpkg` orders upgrades correctly.
- **`build-offline.sh`**, **`offline/`** — the offline build (see
  [Offline](#offline-no-internet-on-the-server)). It stages the wheels,
  UI, mediamtx and plugin, then calls `build-deb.sh` with
  `OFFLINE_PAYLOAD` set; the payload lands in
  `/usr/share/c4raven-server/offline`, and its presence is what switches
  the same postinst to installing from local files. Offline installs run
  from a plain venv at `/opt/raven/venv` (a symlink into
  `/opt/raven/venvs/`, swapped on upgrade) instead of the git checkout.
  `offline/` holds the `install.sh` and `README.txt` templates each
  archive ships with.
- **`seed_plugin.py`** — used by the offline package: copies a bundled
  APK into the data folder's `packages/`, writes its `packages` row and
  regenerates the `product.infz` indexes. Never downgrades; exit 3 when
  the same or a newer revision is already published.
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

One dependency has gone away: **`pgloader`**. It was declared since the
upstream project but is not invoked anywhere in any C4 Raven repo — it
belonged to upstream's sqlite-to-postgres migration path, which this
fork does not have. It is out of `debian/control` and was never carried
into the RPM. Existing servers are unaffected; `sudo apt remove
pgloader` if you want the disk back.

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

On Rocky/RHEL the `/opt/raven` layout, the `raven` user, the database
names and the webroot are all identical — the paths that move are the
ones the distribution owns: nginx sites are
`/etc/nginx/conf.d/raven_*.conf` and streams
`/etc/nginx/stream.d/*.conf` (there is no available/enabled split to
symlink across), PostgreSQL's cluster is `/var/lib/pgsql/data`, and
nginx runs as `nginx` rather than `www-data`. The offline layout differs
more: no source checkout, and a plain venv at `/opt/raven/venv`
symlinked into `/opt/raven/venvs/`. See
[`docs/rocky-el9.md`](docs/rocky-el9.md) for the full list and for what
to check first when something is broken.
