# Rocky / Alma / RHEL 9

The EL9 port of the C4 Raven server, and what an operator who knows the
Ubuntu install will find different. Read
[the support matrix](../README.md#supported-platforms) first: **none of
this has been run on real hardware yet.** It is static analysis plus
archive metadata plus container runs, and the first machine you build
should be treated as a bring-up.

## Install

Repositories first, package second. `dnf` has to be able to resolve
`rabbitmq-server` and `certbot` *before* the package is installed, so
that step cannot live inside the package:

```
sudo ./rpm/c4raven-el9-repos.sh
sudo dnf install ./c4raven-server-*.el9.*.rpm
```

`c4raven-el9-repos.sh` enables EPEL 9 and CRB (`crb` on the rebuilds,
`codeready-builder-for-rhel-9-$arch-rpms` on RHEL), writes
`/etc/yum.repos.d/rabbitmq.repo`, and resets the `nodejs` module stream
to 22. EL9's default `nodejs` stream is 18, and the UI build (vite 8)
needs 20.19+/22.12+.

Build the RPM with:

```
PKG_VERSION=2.2.3 ./rpm/build-rpm.sh
```

It is `noarch` — like the `.deb`, it compiles nothing at package-build
time and builds the backend venv and the UI on the target machine. Only
an offline build (`--with offline`, a staged payload) is
architecture-specific.

### Where each dependency comes from

| Component | Repository |
| --- | --- |
| nginx, nginx-mod-stream, postgresql(-server), python3.12, gcc, make, git-core | AppStream / BaseOS, both arches |
| certbot, python3-certbot-nginx (noarch), erlang 26.2.5, ffmpeg-free 7.1.5 | EPEL 9, both arches |
| rabbitmq-server (noarch) | `yum1`/`yum2.rabbitmq.com` |
| erlang (newer than EPEL's) | `yum1`/`yum2.rabbitmq.com`, **x86_64 only** |
| PostGIS | PGDG only — not configured, see below |
| full `ffmpeg` (patent-encumbered codecs) | RPM Fusion only — not configured |

### Answering the install-time questions

RPM has no debconf and no equivalent: `%post` runs unattended, often
with no controlling terminal at all (dnf under Ansible, kickstart, a
container build). So the two questions the `.deb` asks interactively are
read from `/etc/c4raven-server/setup.conf` instead, with the
environment taking precedence over the file:

```
sudo RAVEN_DOMAIN=tak.example.org dnf install ./c4raven-server-*.rpm
```

or install first, fill in the file, and apply it:

```
sudo c4raven-setup          # same code path %post runs, idempotent
sudo c4raven-setup --edit   # open it in $EDITOR first
sudo c4raven-setup --show   # print the answers, secret masked
```

`setup.conf` is `%config(noreplace)` (an upgrade never clobbers your
answers) and mode 0600, because `RAVEN_TURNSTILE_SECRET_KEY` passes
through it — it is consumed on the first successful run and blanked out
of the file afterwards, living only in `config.yml` from then on.

Beyond the domain and Turnstile answers, `setup.conf` carries three
EL-only knobs with no Debian counterpart:

- `RAVEN_PYTHON` (default `python3.12`) — the interpreter the venv is
  built with.
- `RAVEN_OPEN_FIREWALL` (default `true`) — open the ports in firewalld.
- `RAVEN_SELINUX_FIXUP` (default `true`) — apply the SELinux policy.

If `%post` fails, the package stays installed and nothing is rolled
back: rpm has no `dpkg --configure -a` to resume with, so `c4raven-setup`
is the retry, and it is safe to run as many times as you need.

## What differs from Ubuntu

| | Ubuntu | EL9 |
| --- | --- | --- |
| nginx sites | `sites-available` + a `sites-enabled` symlink | `/etc/nginx/conf.d/*.conf` — writing the file *is* enabling it |
| nginx streams | `streams-available`/`streams-enabled` | `/etc/nginx/stream.d/*.conf`, and the `stream{}` block is added to `nginx.conf` |
| nginx user | `www-data` | `nginx` |
| `proxy_params` | shipped by the distro | not shipped; the package installs its own copy |
| default site | a file in `sites-enabled` nobody enables | a `server{}` block inline in `nginx.conf`, commented out on install |
| PostgreSQL | cluster created and started by the package | `postgresql-setup --initdb` first, service disabled until then |
| `pg_hba.conf` | host connections already scram/md5 | `ident` by default; the two 127.0.0.1 lines are switched to `scram-sha-256` |
| Python | `python3` is new enough | `python3` is 3.9, below the backend's `>=3.10`; the venv uses `python3.12` |
| webroot | `/var/www` exists | `/var/www` does not exist at all and is created |
| MAC | AppArmor, no nginx profile enforced | SELinux targeted, **Enforcing** |
| Firewall | ufw installed but inactive | firewalld running, default-deny |
| PostGIS | `postgresql-postgis` | not packaged; extension creation is best-effort |
| ffmpeg | `ffmpeg` | `ffmpeg-free` from EPEL, and only `Recommends:` |
| Federation Hub | optional `.deb` | not available |

The things that are identical and worth saying so: `/opt/raven`, the
`raven` system user, `/opt/raven/data`, `.raven-secrets.env`, the
`raven` role and database, `/var/www/html/raven`, and all five systemd
units.

## SELinux

This is the one most likely to cost you an afternoon. EL9 is Enforcing
out of the box and three separate things bite:

1. **`httpd_can_network_connect` is off by default.** nginx (`httpd_t`)
   may not open outbound sockets at all, so every `proxy_pass` to
   `127.0.0.1:8081` / `:8888` / `:8889` and every stream proxy returns
   **502 while the backend tests perfectly healthy on localhost**. If
   you take one thing from this page, take this: a 502 from nginx with a
   `curl http://127.0.0.1:8081/api/health` that answers fine is this
   boolean, not the app.
2. **nginx may only bind ports the policy already grants it.** 80, 443
   and 8443 are `http_port_t`, and 8080 is `http_cache_port_t` — the
   stock targeted policy lets `httpd_t` bind all four, so none of them
   need relabelling. 8446 and the TLS media proxies (8322 rtsps, 1936
   rtmps, 8883 mqtts) are *not* labelled for httpd, and nginx fails to
   start on them until `semanage port` says otherwise. (Relabelling a
   port the base policy already owns, such as 8080, simply fails and is
   ignored — harmless, but it is not what makes nginx work.)
3. **File labels.** A webroot created under `/var/www` inherits `var_t`
   from its parent rather than the `httpd_sys_content_t` the policy maps
   it to, so nginx 403s every asset — and that is true again after every
   rsync of a new UI build. The CA's cert and key live under `/opt`,
   which `httpd_t` cannot read either; they are labelled `cert_t`.

The setup script does all three (`setsebool -P`, `semanage port`,
`semanage fcontext` + `restorecon`) when `RAVEN_SELINUX_FIXUP=true`,
which is the default. Checking by hand:

```
getenforce
getsebool httpd_can_network_connect
semanage port -l | grep http_port_t
ls -Z /var/www/html/raven /opt/raven/data/ca
ausearch -m AVC -ts recent
```

If you redeploy the UI yourself, `restorecon -RF /var/www/html/raven`
afterwards.

## firewalld

firewalld is running and default-deny for everything but ssh, so with
`RAVEN_OPEN_FIREWALL=false` the server installs successfully and is
unreachable from anywhere but localhost. What the setup opens:

- tcp 80, 443, 8080, 8443, 8446, 8322, 1936, 8883
- tcp 8554 (rtsp), 1935 (rtmp)
- udp 8189 (WebRTC ICE), 8890 (SRT)

It only ever *adds* allow rules, and it will not enable a firewall that
is switched off — turning one on mid-install would drop the SSH session
the installer is running in.

## PostGIS and ffmpeg

Neither is a hard dependency on EL, for different reasons.

**PostGIS** is not in EL9 AppStream and not in EPEL 9. It exists only in
PGDG, and pulling PGDG in means replacing the distro PostgreSQL and
inheriting a versioned `postgresql-16.service` unit name with it.
Nothing in the current schema actually uses it — the one migration that
mentions PostGIS (`8a43097881d7`) was written without geoalchemy2 — so
the setup script creates the extension if it can and carries on if it
can't. If you do want it: install PGDG's `postgresql16-server` and
`postgis34_16`, set `PG_SERVICE=postgresql-16`, and
`CREATE EXTENSION postgis` by hand.

**ffmpeg** is used only by the YouTube-restream path in
`mediamtx_api.py`, where all three call sites sit inside
`try/except BaseException` that logs and continues. Missing it costs
stream thumbnails and recording metadata; the webhook still returns 200.
EPEL 9 ships `ffmpeg-free` 7.1.5 for x86_64 and aarch64, which covers
the remux this needs (`-c:v copy -f rtsp`, no encoders), so that is what
the package `Recommends:`. RPM Fusion's full `ffmpeg` is an alternative
if you want the patent-encumbered codecs; it is not configured by
default, because degrading one feature beats making the whole install
depend on a third-party multimedia repository.

## aarch64

Everything above applies, plus one hard limit: **RabbitMQ is capped at
4.3.2.** rabbitmq.com publishes `rabbitmq-server` as noarch, so one
repository serves both architectures, but its *erlang* repository has
x86_64 and noarch only — `yum1.rabbitmq.com/erlang/el/9/aarch64` 404s.
Erlang therefore comes from EPEL 9 (26.2.5), and RabbitMQ's packages
carry `Requires: erlang >= N, erlang < M`:

- erlang >=26 <29 → newest `rabbitmq-server` 4.3.2
- erlang >=27 <30 → newest `rabbitmq-server` 4.4.0

dnf backtracks to 4.3.2 on its own; there is nothing to do about it, but
keep it in mind the next time a release note says "requires Erlang 27".
`c4raven-el9-repos.sh` prints this as a note when it runs on a non-x86_64
machine.

## Offline

There is no EL9 offline bundle. `rpm/build-rpm.sh` supports an offline
payload (`--with offline`, arch-specific RPM), but nothing stages one for
EL9 today — `build-offline.sh` builds Ubuntu bundles only.

Even once something does, it will have to be built **on EL9**: Rocky 9 is
glibc 2.34 against Ubuntu 24.04's 2.39 and 25.10's 2.42, and two locked
dependencies (`mutf8`, `unishox2-py3`) are compiled from sdist in every
build because they publish no wheel for Python 3.12/3.13 on any
architecture. Wheels compiled on Ubuntu link against a newer glibc than
EL9 provides and fail at *import* on the target. `build-rpm.sh` refuses
the build rather than shipping that.

## Uninstall

`dnf remove c4raven-server` stops and disables the services and leaves
your data alone — deliberately. RPM has no purge/remove distinction, so
unlike the `.deb` the `%postun` has one chance to tell you what a full
wipe takes, and it prints the exact commands: dropping the database and
role, `/opt/raven`, the webroot, the `raven` user, the nginx files
(written by the setup script, not shipped by the package, so rpm does
not remove them), and the `semanage`/`firewall-cmd` changes. The stock
`nginx.conf` and `pg_hba.conf` were backed up in place as
`*.c4raven.bak`.

## When something is broken

In rough order of likelihood on a fresh EL9 box:

1. nginx 502s everything, backend healthy on localhost →
   `getsebool httpd_can_network_connect`.
2. nginx won't start, "bind() to 0.0.0.0:8446 failed" →
   `semanage port -l | grep http_port_t`.
3. 403 on every static asset → `ls -Z /var/www/html/raven`, then
   `restorecon -RF`.
4. Unreachable from the network, fine from the box → `firewall-cmd
   --list-ports`.
5. Backend won't start, database connection refused → `pg_hba.conf`
   still on `ident`, or the cluster was never initdb'd.
6. CA creation or device enrollment fails on PKCS12 → RHEL
   crypto-policies refusing the legacy provider's RC2/3DES; the setup
   script preflights this and warns loudly rather than failing.
7. UI build fails → the `nodejs` module stream is still 18.

`sudo tests/verify.sh` runs the full set of post-install assertions
against a live machine and is a reasonable first move on any of these.
