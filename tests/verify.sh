#!/bin/bash
# Post-install assertions for a C4 Raven server.
#
# Runs as root on the installed machine -- inside a harness container, or on
# a real server as a standalone health check. It makes no assumptions about
# how the install happened beyond the two possible backend layouts.
#
#   sudo tests/verify.sh [--layout source|venv|auto] [--expect-arch amd64|arm64]
#                        [--skip-login] [--quiet]
#
# Every assertion below is derived from what install.sh and
# debian/c4raven-server.postinst actually do, in the same order they do it.
# "It installed" is not an assertion: a .deb whose postinst exits 0 while
# raven crash-loops is the failure mode this file exists to catch, which is
# why the service checks look at NRestarts and not just is-active.
set -uo pipefail

APP_USER=raven
APP_HOME=/opt/raven
DATA_DIR=$APP_HOME/data
DB_NAME=raven
WEBROOT=/var/www/html/raven

LAYOUT=auto
EXPECT_ARCH=""
SKIP_LOGIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --layout)      LAYOUT=$2; shift 2 ;;
    --expect-arch) EXPECT_ARCH=$2; shift 2 ;;
    --skip-login)  SKIP_LOGIN=1; shift ;;
    --quiet)       shift ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" != 0 ]; then
  echo "verify.sh must run as root (it reads /opt/raven and queries postgres)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Distro family -- the nginx layout and the PostGIS expectation both depend
# on it. Prefer lib/distro.sh so there is exactly one definition of where
# nginx's config lives; fall back to reading /etc/os-release directly,
# because verify.sh is also run standalone on an installed server where the
# repo (and therefore lib/distro.sh) is not present.
# ---------------------------------------------------------------------------
_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$_VERIFY_DIR/../lib/distro.sh" ]; then
  # shellcheck source=lib/distro.sh
  . "$_VERIFY_DIR/../lib/distro.sh"
  detect_distro
else
  # Minimal stand-in for detect_distro's nginx/family facts.
  DISTRO_FAMILY=debian
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:+ $ID_LIKE}" in
      *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) DISTRO_FAMILY=rhel ;;
    esac
  fi
  if [ "$DISTRO_FAMILY" = rhel ]; then
    NGINX_SITES_DIR=/etc/nginx/conf.d;        NGINX_SITES_ENABLED_DIR=""
    NGINX_STREAMS_DIR=/etc/nginx/stream.d;    NGINX_STREAMS_ENABLED_DIR=""
    NGINX_CONF_SUFFIX=".conf"
  else
    NGINX_SITES_DIR=/etc/nginx/sites-available
    NGINX_SITES_ENABLED_DIR=/etc/nginx/sites-enabled
    NGINX_STREAMS_DIR=/etc/nginx/streams-available
    NGINX_STREAMS_ENABLED_DIR=/etc/nginx/streams-enabled
    NGINX_CONF_SUFFIX=""
  fi
  nginx_site_file()   { printf '%s/%s%s' "$NGINX_SITES_DIR" "$1" "$NGINX_CONF_SUFFIX"; }
  nginx_stream_file() { printf '%s/%s%s' "$NGINX_STREAMS_DIR" "$1" "$NGINX_CONF_SUFFIX"; }
fi

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; N=''
fi

PASS=0; FAIL=0; WARN=0
FAILURES=()

section() { printf '\n%s-- %s%s\n' "$B" "$1" "$N"; }
pass()    { PASS=$((PASS + 1)); printf '  %sok%s   %s\n' "$G" "$N" "$1"; }
fail()    { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '  %sFAIL%s %s%s\n' "$R" "$N" "$1" "${2:+ -- $2}"; }
softfail(){ WARN=$((WARN + 1)); printf '  %swarn%s %s%s\n' "$Y" "$N" "$1" "${2:+ -- $2}"; }

# check "description" <command...>  -- runs the command, records the result.
check() {
  local desc=$1; shift
  local out
  if out=$("$@" 2>&1); then
    pass "$desc"
  else
    fail "$desc" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------
section "Layout and ownership"
# ---------------------------------------------------------------------------
if id "$APP_USER" >/dev/null 2>&1; then
  pass "system user '$APP_USER' exists"
  [ "$(getent passwd "$APP_USER" | cut -d: -f6)" = "$APP_HOME" ] \
    && pass "$APP_USER home is $APP_HOME" \
    || fail "$APP_USER home is $APP_HOME" "got $(getent passwd "$APP_USER" | cut -d: -f6)"
else
  fail "system user '$APP_USER' exists"
fi

# Resolve the backend layout: install.sh and the online .deb build a Poetry
# in-project venv inside the source checkout; the offline .deb installs a
# plain venv behind a symlink and ships no source at all.
if [ "$LAYOUT" = auto ]; then
  if [ -x "$APP_HOME/venv/bin/raven" ]; then LAYOUT=venv
  elif [ -x "$APP_HOME/c4raven-server/.venv/bin/raven" ]; then LAYOUT=source
  else LAYOUT=unknown
  fi
fi
case "$LAYOUT" in
  source) VENV=$APP_HOME/c4raven-server/.venv ;;
  venv)   VENV=$APP_HOME/venv ;;
  *)      VENV="" ;;
esac
if [ -n "$VENV" ]; then
  pass "backend layout: $LAYOUT ($VENV)"
  for bin in raven eud_handler cot_parser; do
    [ -x "$VENV/bin/$bin" ] && pass "entry point $bin is executable" \
                            || fail "entry point $bin is executable" "$VENV/bin/$bin"
  done
else
  fail "a backend venv exists" "neither $APP_HOME/venv/bin/raven nor $APP_HOME/c4raven-server/.venv/bin/raven"
fi

if [ -f "$APP_HOME/.raven-secrets.env" ]; then
  mode=$(stat -c '%a %U' "$APP_HOME/.raven-secrets.env")
  [ "$mode" = "600 $APP_USER" ] \
    && pass "secrets env is 600 $APP_USER" \
    || fail "secrets env is 600 $APP_USER" "got $mode"
  for key in RAVEN_DATA_FOLDER SQLALCHEMY_DATABASE_URI RAVEN_RABBITMQ_USERNAME RAVEN_MEDIAMTX_ENABLE; do
    grep -q "^$key=" "$APP_HOME/.raven-secrets.env" \
      && pass "secrets env sets $key" \
      || fail "secrets env sets $key"
  done
else
  fail "$APP_HOME/.raven-secrets.env exists"
fi

# ---------------------------------------------------------------------------
section "Configuration"
# ---------------------------------------------------------------------------
if [ -f "$DATA_DIR/config.yml" ]; then
  pass "config.yml exists"
  # The backend's own interpreter: EL9's system python3 has no PyYAML.
  YAML_PY=python3
  [ -n "$VENV" ] && [ -x "$VENV/bin/python" ] && YAML_PY=$VENV/bin/python
  DB_URI=$("$YAML_PY" - "$DATA_DIR/config.yml" <<'PY' 2>/dev/null
import sys, yaml
print(yaml.safe_load(open(sys.argv[1])).get("SQLALCHEMY_DATABASE_URI", ""))
PY
) || DB_URI=""
  case "$DB_URI" in
    postgresql+psycopg://*) pass "config.yml points at postgres via psycopg" ;;
    "")                     fail "config.yml has SQLALCHEMY_DATABASE_URI" "unset or config.yml is not valid YAML" ;;
    *)                      fail "config.yml points at postgres via psycopg" "got ${DB_URI%%:*}:..." ;;
  esac
  case "$DB_URI" in
    *%*) fail "DB password is percent-safe" "URI contains '%', which libpq will percent-decode" ;;
  esac
else
  fail "$DATA_DIR/config.yml exists"
  DB_URI=""
fi

# ---------------------------------------------------------------------------
section "Certificate authority"
# ---------------------------------------------------------------------------
CA=$DATA_DIR/ca/ca.pem
SRV=$DATA_DIR/ca/certs/raven/raven.pem
KEY=$DATA_DIR/ca/certs/raven/raven.nopass.key
for f in "$CA" "$SRV" "$KEY"; do
  [ -s "$f" ] && pass "$(basename "$f") present" || fail "$f present"
done
if [ -s "$CA" ] && [ -s "$SRV" ]; then
  # The server cert must actually chain to the CA this install created --
  # a cert left over from a previous install, or one issued against a CA
  # that was then regenerated, is a silent and very confusing failure.
  check "server cert verifies against ca.pem" \
    openssl verify -CAfile "$CA" "$SRV"
  check "server cert is not expired" \
    openssl x509 -in "$SRV" -noout -checkend 0
fi
if [ -s "$KEY" ]; then
  k=$(stat -c '%U' "$KEY")
  [ "$k" = "$APP_USER" ] && pass "server key owned by $APP_USER" \
                         || softfail "server key owned by $APP_USER" "got $k"
fi

# ---------------------------------------------------------------------------
section "systemd units"
# ---------------------------------------------------------------------------
# The whole stack is five of our units plus three from the distro. The
# PostgreSQL unit is `postgresql` on Debian/Ubuntu but versioned
# (`postgresql-16`) when it comes from PGDG, which is where Rocky 9 has to
# get PostGIS from -- so discover it rather than hardcoding either.
OUR_UNITS="raven cot_parser eud_handler eud_handler_ssl mediamtx"
PG_UNIT=$(systemctl list-unit-files --no-legend --plain 'postgresql*.service' 2>/dev/null \
            | awk '{print $1}' | grep -vE '@|postgresql-check' | head -1)
PG_UNIT=${PG_UNIT:-postgresql.service}
note_pg=$(printf '%s' "$PG_UNIT")
DEP_UNITS="nginx rabbitmq-server ${note_pg%.service}"

for u in $OUR_UNITS $DEP_UNITS; do
  state=$(systemctl is-enabled "$u" 2>&1 || true)
  case "$state" in
    enabled|enabled-runtime|indirect|static|generated)
      pass "$u is enabled at boot ($state)" ;;
    *) fail "$u is enabled at boot" "is-enabled said '$state'" ;;
  esac
done

for u in $OUR_UNITS $DEP_UNITS; do
  state=$(systemctl is-active "$u" 2>&1 || true)
  if [ "$state" != active ]; then
    fail "$u is active" "is-active said '$state'"
    systemctl status --no-pager --lines=15 "$u" 2>&1 | sed 's/^/       /' || true
    continue
  fi
  # Restart=always means a crash-looping unit still reads "active". The
  # restart counter is what tells them apart. A unit that has restarted
  # even once during a fresh install is a failure, not a flake.
  case " $OUR_UNITS " in
    *" $u "*)
      n=$(systemctl show -p NRestarts --value "$u" 2>/dev/null || echo 0)
      if [ "${n:-0}" -gt 0 ]; then
        fail "$u is active and has never restarted" "NRestarts=$n (crash loop)"
        tail -n 30 "$DATA_DIR/logs/raven.log" 2>/dev/null | sed 's/^/       /'
      else
        pass "$u is active, NRestarts=0"
      fi
      ;;
    *) pass "$u is active" ;;
  esac
done

# The units' own dependency wiring, not just their state. raven Requires=
# the three handlers; the handlers are PartOf= raven.
req=$(systemctl show -p Requires --value raven 2>/dev/null || true)
for dep in eud_handler.service eud_handler_ssl.service cot_parser.service; do
  case " $req " in
    *" $dep "*) pass "raven.service Requires=$dep" ;;
    *) fail "raven.service Requires=$dep" "Requires='$req'" ;;
  esac
done

failed_units=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [ -n "${failed_units// /}" ]; then
  # Some distro units legitimately fail in a container (nothing of ours
  # should). Report ours as failures and the rest as warnings.
  for u in $failed_units; do
    case " $OUR_UNITS " in
      *" ${u%.service} "*) fail "no failed units" "$u is failed" ;;
      *) softfail "unrelated failed unit (expected in a container)" "$u" ;;
    esac
  done
else
  pass "no failed systemd units"
fi

# ---------------------------------------------------------------------------
section "Listening sockets"
# ---------------------------------------------------------------------------
LISTENING=$(ss -lntuH 2>/dev/null | awk '{print $5}' | sed 's/.*://' | sort -un | tr '\n' ' ')
want_port() {
  local port=$1 what=$2
  case " $LISTENING " in
    *" $port "*) pass "port $port open ($what)" ;;
    *) fail "port $port open ($what)" "listening: $LISTENING" ;;
  esac
}
# This list is the fourth place the port facts are written down (after
# install.sh's and rpm/configure.sh's firewall lists and lib/distro.sh's
# SELinux list) and it has drifted twice. Every listener the firewall opens
# belongs here: a port that is firewalled open but not actually bound is a
# silent half-install. `ss -lntuH` above covers UDP as well as TCP.
want_port 8081 "raven HTTP API"
want_port 8088 "eud_handler TCP streaming"
want_port 8089 "eud_handler_ssl"
# Not 8087/udp: eud_handler serves TCP, SSL or UDP per process (--ssl/--udp)
# and no installer creates an `eud_handler --udp` unit -- nothing binds it on
# a real server either. The firewall still opens it for a UDP unit an admin
# adds by hand.
want_port 80   "nginx HTTP redirect"
want_port 8080 "nginx Marti HTTP"
want_port 443  "nginx HTTPS / web UI"
want_port 8443 "nginx Marti HTTPS (client certs)"
want_port 8446 "nginx certificate enrollment"
# nginx stream {} TLS passthrough -- these are the listeners that prove the
# stream module is not merely loaded but actually serving.
want_port 8322 "nginx stream -> mediamtx RTSP over TLS"
want_port 1936 "nginx stream -> mediamtx RTMP over TLS"
want_port 8883 "nginx stream -> rabbitmq MQTT over TLS"
# mediamtx's own listeners, behind those stream proxies.
want_port 8554 "mediamtx RTSP"
want_port 1935 "mediamtx RTMP"
want_port 8889 "mediamtx WebRTC (HTTP)"
want_port 8189 "mediamtx WebRTC ICE (udp)"
want_port 8890 "mediamtx SRT (udp)"
want_port 5432 "postgresql"
want_port 5672 "rabbitmq AMQP"
# Deliberately not asserted: mediamtx's HLS (8888), API (9997) and playback
# (9996). They are enabled in mediamtx.yml but are not firewalled open and
# are not part of the contract any client depends on.

# ---------------------------------------------------------------------------
section "Backend API"
# ---------------------------------------------------------------------------
health=$(curl -fsS --max-time 10 http://127.0.0.1:8081/api/health 2>&1)
if [ "$health" = '{"status":"healthy"}' ] || printf '%s' "$health" | grep -q '"healthy"'; then
  pass "GET 127.0.0.1:8081/api/health -> healthy"
else
  fail "GET 127.0.0.1:8081/api/health -> healthy" "got: ${health:0:120}"
fi
check "GET 127.0.0.1:8081/api/turnstile answers" \
  curl -fsS --max-time 10 -o /dev/null http://127.0.0.1:8081/api/turnstile

# ---------------------------------------------------------------------------
section "nginx"
# ---------------------------------------------------------------------------
check "nginx -t accepts the generated config" nginx -t
if nginx -V 2>&1 | grep -q 'with-stream'; then
  pass "nginx has the stream module"
else
  fail "nginx has the stream module" "rabbitmq/mediamtx TLS passthrough needs it (libnginx-mod-stream)"
fi
grep -q 'stream {' /etc/nginx/nginx.conf \
  && pass "nginx.conf has the stream {} block" \
  || fail "nginx.conf has the stream {} block"
# The two families put these files in different places and only Debian has
# an available/enabled symlink dance (on EL, conf.d/*.conf and stream.d/*.conf
# are included directly, so writing the file IS enabling it). Ask
# lib/distro.sh where they go rather than hardcoding one family's layout.
NGINX_CONFIGS=()
for s in raven_http raven_https raven_certificate_enrollment; do
  f=$(nginx_site_file "$s")
  NGINX_CONFIGS+=("$f")
  if [ -e "$f" ]; then pass "nginx site $f exists"
  else fail "nginx site $f exists"; fi
  # Debian additionally has to symlink it into sites-enabled.
  if [ -n "${NGINX_SITES_ENABLED_DIR:-}" ]; then
    if [ -e "$NGINX_SITES_ENABLED_DIR/$s" ]; then pass "nginx site $s is linked into sites-enabled"
    else fail "nginx site $s is linked into sites-enabled"; fi
  fi
done
for s in rabbitmq mediamtx; do
  f=$(nginx_stream_file "$s")
  NGINX_CONFIGS+=("$f")
  if [ -e "$f" ]; then pass "nginx stream $f exists"
  else fail "nginx stream $f exists"; fi
  if [ -n "${NGINX_STREAMS_ENABLED_DIR:-}" ]; then
    if [ -e "$NGINX_STREAMS_ENABLED_DIR/$s" ]; then pass "nginx stream $s is linked into streams-enabled"
    else fail "nginx stream $s is linked into streams-enabled"; fi
  fi
done

# This used to grep two hardcoded Debian paths, which on EL matched nothing
# and so "passed" without reading a single file. Check the files we just
# resolved, and say so loudly if none of them are there to check.
present=()
for f in "${NGINX_CONFIGS[@]}"; do [ -r "$f" ] && present+=("$f"); done
if [ "${#present[@]}" -eq 0 ]; then
  fail "nginx configs have no unsubstituted placeholders" \
       "none of the expected config files exist, so nothing was checked"
elif grep -qE 'OTS_FOLDER|SERVER_CERT_FILE|SERVER_KEY_FILE|CA_CERT_FILE' "${present[@]}"; then
  fail "nginx configs have no unsubstituted placeholders" \
       "$(grep -lE 'OTS_FOLDER|SERVER_CERT_FILE|SERVER_KEY_FILE|CA_CERT_FILE' "${present[@]}" | tr '\n' ' ')"
else
  pass "nginx configs have no unsubstituted placeholders (${#present[@]} files checked)"
fi

# ---------------------------------------------------------------------------
section "Web UI"
# ---------------------------------------------------------------------------
if [ -s "$WEBROOT/index.html" ]; then
  pass "$WEBROOT/index.html exists"
  # A built vite bundle, not the nginx placeholder page. The built index
  # always references hashed assets; the Debian default page never does.
  if grep -qE '(assets/|type="module")' "$WEBROOT/index.html"; then
    pass "index.html is a built SPA bundle"
  else
    fail "index.html is a built SPA bundle" "looks like a placeholder page"
  fi
  if [ -d "$WEBROOT/assets" ] && [ -n "$(ls -A "$WEBROOT/assets" 2>/dev/null)" ]; then
    pass "$WEBROOT/assets is populated"
  else
    fail "$WEBROOT/assets is populated"
  fi
  owner=$(stat -c '%U:%G %a' "$WEBROOT")
  [ "$owner" = "$APP_USER:$APP_USER 755" ] \
    && pass "webroot is $APP_USER:$APP_USER 755" \
    || fail "webroot is $APP_USER:$APP_USER 755" "got $owner"
else
  fail "$WEBROOT/index.html exists"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8080/ || echo 000)
[ "$code" = 200 ] && pass "nginx serves the UI on :8080 (HTTP 200)" \
                  || fail "nginx serves the UI on :8080" "HTTP $code"
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/ || echo 000)
[ "$code" = 200 ] && pass "nginx serves the UI on :443 over TLS (HTTP 200)" \
                  || fail "nginx serves the UI on :443 over TLS" "HTTP $code"
# SPA fallback: a client-side route must return index.html, not a 404.
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/dashboard || echo 000)
[ "$code" = 200 ] && pass "SPA fallback serves index.html for /dashboard" \
                  || fail "SPA fallback serves index.html for /dashboard" "HTTP $code"
# The reverse proxy, not just the static files: this is the wiring that
# actually broke the last time the nginx templates drifted.
body=$(curl -s --max-time 10 http://127.0.0.1:8080/api/health || true)
printf '%s' "$body" | grep -q healthy \
  && pass "nginx proxies /api to the backend" \
  || fail "nginx proxies /api to the backend" "got: ${body:0:120}"
# Marti must be 404 on 443 and reachable on 8443 -- that split is a
# deliberate security property of this config, not an accident.
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/Marti/api/version || echo 000)
[ "$code" = 404 ] && pass "Marti is refused on :443 (404 by design)" \
                  || fail "Marti is refused on :443" "HTTP $code -- the Marti API is exposed without client-cert verification"

# ---------------------------------------------------------------------------
section "Database"
# ---------------------------------------------------------------------------
psql_as_postgres() { su postgres -c "psql -XtAc \"$1\""; }
if role=$(psql_as_postgres "SELECT 1 FROM pg_roles WHERE rolname='$DB_NAME'" 2>/dev/null) && [ "$role" = 1 ]; then
  pass "postgres role '$DB_NAME' exists"
else
  fail "postgres role '$DB_NAME' exists"
fi
if dbex=$(psql_as_postgres "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null) && [ "$dbex" = 1 ]; then
  pass "database '$DB_NAME' exists"
else
  fail "database '$DB_NAME' exists"
fi
ext=$(su postgres -c "psql -XtAd $DB_NAME -c \"SELECT extname FROM pg_extension WHERE extname='postgis'\"" 2>/dev/null || true)
if [ "$ext" = postgis ]; then
  pass "postgis extension installed in '$DB_NAME'"
elif [ "${DISTRO_FAMILY:-}" = rhel ]; then
  # EL9 ships no PostGIS outside PGDG, so every EL install path installs it
  # best-effort and carries on without it (install.sh, rpm/configure.sh, the
  # spec's weak dependency, docs/rocky-el9.md). Hard-failing here would make
  # every Rocky cell red by design and hide the real regressions.
  softfail "postgis extension installed in '$DB_NAME'" \
           "absent, which is expected on the rhel family (no PostGIS outside PGDG on EL9)"
else
  fail "postgis extension installed in '$DB_NAME'" "got '$ext'"
fi

# The app's own credentials, over TCP, exactly as the services use them.
if [ -n "$DB_URI" ]; then
  PSQL_URI="postgresql://${DB_URI#postgresql+psycopg://}"
  if out=$(su postgres -c "psql -XtAc 'SELECT 1' '$PSQL_URI'" 2>&1) && [ "$out" = 1 ]; then
    pass "the app's own DB credentials connect over TCP"
  else
    fail "the app's own DB credentials connect over TCP" "$(printf '%s' "$out" | head -1)"
  fi
  # Migrations are applied by the server at startup, not by the installer,
  # so an empty alembic_version means the server never finished booting.
  ver=$(su postgres -c "psql -XtAc 'SELECT version_num FROM alembic_version' '$PSQL_URI'" 2>/dev/null | tr -d ' ')
  [ -n "$ver" ] && pass "alembic migrations applied (head $ver)" \
                || fail "alembic migrations applied" "alembic_version is missing or empty"
  tbl=$(su postgres -c "psql -XtAc \"SELECT to_regclass('public.\\\"user\\\"')\" '$PSQL_URI'" 2>/dev/null | tr -d ' ')
  [ -n "$tbl" ] && pass "the 'user' table exists" \
                || fail "the 'user' table exists"
fi

# ---------------------------------------------------------------------------
section "Administrator account"
# ---------------------------------------------------------------------------
if [ -n "${PSQL_URI:-}" ]; then
  row=$(su postgres -c "psql -XtAF'|' -c \"SELECT username, force_password_change FROM \\\"user\\\" ORDER BY id\" '$PSQL_URI'" 2>/dev/null)
  if [ -z "$row" ]; then
    fail "an administrator account was seeded" "the user table is empty"
  else
    printf '%s\n' "$row" | sed 's/^/       /'
    if printf '%s\n' "$row" | grep -qx 'administrator|t'; then
      pass "'administrator' exists and is flagged force_password_change"
    else
      fail "'administrator' exists and is flagged force_password_change" \
           "seed_admin.py did not harden the default account"
    fi
  fi
fi

if [ "$SKIP_LOGIN" = 0 ]; then
  # End to end, through the real auth stack: proves the app, the database,
  # the migrations, the password hashing and the force_password_change
  # patch are all wired together -- not just that files are on disk.
  login=$(curl -sS --max-time 20 -X POST \
            -H 'Content-Type: application/json' \
            -d '{"username":"administrator","password":"password"}' \
            'http://127.0.0.1:8081/api/login?include_auth_token' 2>&1 || true)
  if printf '%s' "$login" | grep -q '"force_password_change": *true'; then
    pass "POST /api/login as administrator succeeds and demands a password change"
  else
    fail "POST /api/login as administrator succeeds and demands a password change" \
         "response: ${login:0:200}"
  fi
fi

# ---------------------------------------------------------------------------
section "mediamtx"
# ---------------------------------------------------------------------------
MTX=$DATA_DIR/mediamtx/mediamtx
if [ -x "$MTX" ]; then
  pass "mediamtx binary present"
  # e_machine, bytes 18-19 of the ELF header: 0x3e = x86-64, 0xb7 = AArch64.
  # Reading it directly avoids depending on file(1) or binutils, and it is
  # the single assertion that catches an amd64 binary shipped to an arm64
  # box -- the most likely multi-arch packaging bug in this whole port.
  machine=$(od -An -tx1 -j18 -N2 "$MTX" 2>/dev/null | tr -d ' ')
  case "$machine" in
    3e00) got=amd64 ;;
    b700) got=arm64 ;;
    *)    got="unknown(e_machine=$machine)" ;;
  esac
  if [ -n "$EXPECT_ARCH" ]; then
    want=$EXPECT_ARCH
  else
    case "$(uname -m)" in
      x86_64)  want=amd64 ;;
      aarch64) want=arm64 ;;
      *)       want=$(uname -m) ;;
    esac
  fi
  [ "$got" = "$want" ] && pass "mediamtx binary is $want" \
                       || fail "mediamtx binary is $want" "ELF says $got"
else
  fail "mediamtx binary present at $MTX"
fi
if [ -f "$DATA_DIR/mediamtx/mediamtx.yml" ]; then
  grep -q 'webrtcAdditionalHosts: \[\]' "$DATA_DIR/mediamtx/mediamtx.yml" \
    && fail "mediamtx.yml has a WebRTC host substituted" "still the empty default" \
    || pass "mediamtx.yml has a WebRTC host substituted"
else
  fail "mediamtx.yml installed"
fi

# ---------------------------------------------------------------------------
section "Architecture"
# ---------------------------------------------------------------------------
if [ -n "$EXPECT_ARCH" ]; then
  case "$(uname -m)" in
    x86_64)  running=amd64 ;;
    aarch64) running=arm64 ;;
    *)       running=$(uname -m) ;;
  esac
  [ "$running" = "$EXPECT_ARCH" ] && pass "running on $EXPECT_ARCH" \
                                  || fail "running on $EXPECT_ARCH" "uname -m says $(uname -m)"
fi
if command -v dpkg >/dev/null 2>&1 && dpkg -s c4raven-server >/dev/null 2>&1; then
  a=$(dpkg -s c4raven-server | awk '/^Architecture:/{print $2}')
  case "$a" in
    all) pass "c4raven-server.deb is Architecture: all" ;;
    "$(dpkg --print-architecture)") pass "c4raven-server.deb is Architecture: $a (matches host)" ;;
    *) fail "c4raven-server.deb architecture matches the host" "package=$a host=$(dpkg --print-architecture)" ;;
  esac
fi
if command -v rpm >/dev/null 2>&1 && rpm -q c4raven-server >/dev/null 2>&1; then
  a=$(rpm -q --qf '%{ARCH}' c4raven-server)
  pass "c4raven-server.rpm installed, arch $a"
  case "$a" in
    noarch|"$(rpm --eval '%{_arch}')") : ;;
    *) fail "rpm architecture matches the host" "package=$a host=$(rpm --eval '%{_arch}')" ;;
  esac
fi

# ---------------------------------------------------------------------------
echo
printf '%s%d passed, %d failed, %d warnings%s\n' \
  "$([ "$FAIL" -eq 0 ] && printf '%s' "$G" || printf '%s' "$R")" \
  "$PASS" "$FAIL" "$WARN" "$N"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailed assertions:\n'
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
