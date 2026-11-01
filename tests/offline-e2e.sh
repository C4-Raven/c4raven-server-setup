#!/bin/bash
# The offline bundle, installed in a container that has NO network at all.
#
#   tests/offline-e2e.sh --bundle build/c4raven-server-offline_X_noble_amd64.tar \
#                        [--from c4raven-server-offline_OLD_noble_amd64.tar] \
#                        [--rerun] [--keep]
#
# Unlike tests/methods/deb-offline.sh (which takes the default route away
# from an otherwise networked container), the container here is started with
# `--network none`: its only interface is loopback, plus a dummy interface
# with a private address standing in for an air-gapped LAN. There is no
# route, no DNS and no proxy; nothing can reach the internet however hard it
# tries. The proof is checked and logged before and after the install.
#
#   --from OLD   install OLD's bundle first, then upgrade to --bundle over it:
#                checks the database migrates to head, config.yml and the
#                server certificate are preserved, and a certbot-edited nginx
#                site file gets the X-Ssl-Cert fix patched in place.
#   --rerun      afterwards, run the same bundle's install.sh again (the
#                reinstall/repair path) and verify again.
#   --keep       leave the container running.
#
# Needs docker (or podman). Logs go to tests/.artifacts/offline-e2e/.
set -uo pipefail

# shellcheck source=tests/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
harness_paths

NEW=""; OLD=""; RERUN=0; KEEP=0
TIMEOUT_MIN="${TIMEOUT_MIN:-45}"
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) NEW=$2; shift 2 ;;
    --from)   OLD=$2; shift 2 ;;
    --rerun)  RERUN=1; shift ;;
    --keep)   KEEP=1; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$NEW" ] || die "--bundle: no such file '$NEW'"
[ -z "$OLD" ] || [ -f "$OLD" ] || die "--from: no such file '$OLD'"

ENGINE=$(detect_engine)
ARCH=$(host_arch)
DISTRO=ubuntu-24.04
NAME=c4raven-offline-e2e
OUT="$TESTS_DIR/.artifacts/offline-e2e"
rm -rf "$OUT"; mkdir -p "$OUT"

FAILED=""
fail() { FAILED="$FAILED\n  - $*"; printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
ok()   { printf '%sok%s   %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
x()    { "$ENGINE" exec "$NAME" "$@"; }
xsh()  { "$ENGINE" exec "$NAME" bash -c "$1"; }

collect() {
  xsh 'journalctl -b --no-pager' > "$OUT/journal.log" 2>&1
  xsh 'systemctl list-units --state=failed --no-pager' > "$OUT/failed-units.log" 2>&1
  xsh 'cat /opt/raven/data/logs/raven.log' > "$OUT/raven.log" 2>&1
  xsh 'cat /var/log/nginx/error.log' > "$OUT/nginx-error.log" 2>&1
  xsh 'tail -n 200 /var/log/postgresql/*.log' > "$OUT/postgresql.log" 2>&1
}
finish() {
  collect
  [ "$KEEP" = 1 ] || "$ENGINE" rm -f "$NAME" >/dev/null 2>&1
  if [ -n "$FAILED" ]; then
    printf '\n%sOFFLINE E2E FAILED%s%b\n' "$C_RED" "$C_OFF" "$FAILED" >&2
    exit 1
  fi
  printf '\n%sOFFLINE E2E PASSED%s (logs: %s)\n' "$C_GRN" "$C_OFF" "$OUT" >&2
  exit 0
}

log "building the $DISTRO image"
"$ENGINE" build --platform "linux/$ARCH" -t "c4raven-test:$DISTRO-$ARCH" \
  -f "$TESTS_DIR/images/Dockerfile.$DISTRO" "$TESTS_DIR/images" > "$OUT/image-build.log" 2>&1 \
  || { tail -40 "$OUT/image-build.log" >&2; die "image build failed"; }

"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
log "booting systemd with --network none"
mapfile -t flags < <(engine_run_flags "$ENGINE" "$ARCH")
"$ENGINE" run "${flags[@]}" --network none --name "$NAME" "c4raven-test:$DISTRO-$ARCH" \
  > "$OUT/run.log" 2>&1 || { cat "$OUT/run.log" >&2; die "container would not start"; }
for i in $(seq 1 120); do
  state=$(x systemctl is-system-running 2>/dev/null | tr -d '\r')
  case "$state" in running|degraded) break ;; esac
  sleep 1
done
note "systemd is ${state:-not up} after ${i}s"

# An air-gapped server still has a LAN address: give it one on a dummy
# interface (best effort -- the host kernel needs the dummy module), so
# `hostname -I` and the WebRTC host list see what they would on site.
xsh 'ip link add lan0 type dummy && ip addr add 10.77.0.10/24 dev lan0 && ip link set lan0 up' \
  >/dev/null 2>&1 && note "lan0 = 10.77.0.10/24 (dummy, no route out)" \
  || note "no dummy interface available; loopback only"

network_proof() {
  local when=$1 f="$OUT/network-proof-$1.log"
  {
    echo "== $when: docker NetworkMode = $("$ENGINE" inspect -f '{{.HostConfig.NetworkMode}}' "$NAME")"
    echo "== ip -o addr";  x ip -o addr 2>&1
    echo "== ip route";    x ip route 2>&1; echo "(end of routes)"
    echo "== ip -6 route"; x ip -6 route 2>&1; echo "(end of routes)"
    echo "== getent hosts github.com archive.ubuntu.com pypi.org"
    x getent hosts github.com archive.ubuntu.com pypi.org 2>&1; echo "exit $?"
    echo "== curl https://github.com (by name)"
    x curl -sS -m 10 -o /dev/null https://github.com 2>&1; echo "exit $?"
    echo "== curl https://140.82.112.3 (github.com by address)"
    x curl -sS -m 10 -k -o /dev/null https://140.82.112.3 2>&1; echo "exit $?"
    echo "== curl http://1.1.1.1"
    x curl -sS -m 10 -o /dev/null http://1.1.1.1 2>&1; echo "exit $?"
  } > "$f"
  cat "$f" >&2
  [ "$("$ENGINE" inspect -f '{{.HostConfig.NetworkMode}}' "$NAME")" = none ] \
    || fail "$when: container is not on --network none"
  # Only the dummy LAN's own on-link routes may exist.
  if x ip route 2>/dev/null | grep -v '^10\.77\.0\.0/24 ' | grep -q .; then
    fail "$when: the container has an IPv4 route out"
  fi
  if x ip -6 route 2>/dev/null | grep -Ev '^(::1|fe80::|multicast|local|anycast|ff00::)' | grep -q .; then
    fail "$when: the container has an IPv6 route out"
  fi
  x getent hosts github.com >/dev/null 2>&1 && fail "$when: DNS resolves github.com"
  x curl -s -m 10 -o /dev/null https://github.com 2>/dev/null && fail "$when: github.com is reachable"
  x curl -s -m 10 -k -o /dev/null https://140.82.112.3 2>/dev/null && fail "$when: 140.82.112.3 is reachable"
  x curl -s -m 10 -o /dev/null http://1.1.1.1 2>/dev/null && fail "$when: 1.1.1.1 is reachable"
  [ -z "$FAILED" ] && ok "$when: no network (no route, no DNS, no reachable address)"
}
network_proof before
[ -z "$FAILED" ] || finish

log "copying the harness and bundle(s) in (docker cp needs no network)"
x mkdir -p /opt/harness/repo /opt/harness/new /opt/harness/old
tar -C "$REPO_DIR" --exclude=./.git --exclude=./build --exclude=./tests/.artifacts -cf - . \
  | "$ENGINE" cp - "$NAME:/opt/harness/repo" || die "could not copy the repo in"
"$ENGINE" cp "$NEW" "$NAME:/opt/harness/new.tar" || die "could not copy $NEW in"
x tar -xf /opt/harness/new.tar -C /opt/harness/new --strip-components=1 || die "could not unpack $NEW"
if [ -n "$OLD" ]; then
  "$ENGINE" cp "$OLD" "$NAME:/opt/harness/old.tar" || die "could not copy $OLD in"
  x tar -xf /opt/harness/old.tar -C /opt/harness/old --strip-components=1 || die "could not unpack $OLD"
fi

# install DIR LOGNAME: the bundle's own install.sh, non-interactively (debconf
# defaults: blank domain, no Turnstile, unless preseeded below).
install_bundle() {
  local dir=$1 logf="$OUT/$2.log" rc
  log "running $dir/install.sh ($2)"
  timeout "${TIMEOUT_MIN}m" "$ENGINE" exec --env DEBIAN_FRONTEND=noninteractive "$NAME" \
    "$dir/install.sh" > "$logf" 2>&1
  rc=$?
  tail -25 "$logf" >&2
  if [ "$rc" != 0 ] && [ "${3:-}" = recover ]; then
    # Bundles before 2.3.0 fail their first configure on a fresh box
    # (libpq5 is unpacked in the same apt run and not in ld.so.cache yet;
    # fixed in 2.3.0's postinst). The documented recovery is to resume.
    warn "$2: install.sh exited $rc; resuming with dpkg --configure -a, as its message says"
    timeout "${TIMEOUT_MIN}m" "$ENGINE" exec --env DEBIAN_FRONTEND=noninteractive "$NAME" \
      dpkg --configure -a >> "$logf" 2>&1
    rc=$?
    tail -10 "$logf" >&2
  fi
  [ "$rc" = 0 ] || { fail "$2: install.sh exited $rc (see $logf)"; finish; }
  ok "$2: install.sh succeeded"
}

run_verify() {
  log "verify.sh ($1)"
  if x bash /opt/harness/repo/tests/verify.sh --expect-arch "$ARCH" > "$OUT/verify-$1.log" 2>&1; then
    tail -5 "$OUT/verify-$1.log" >&2; ok "$1: verify.sh passed"
  else
    cat "$OUT/verify-$1.log" >&2; fail "$1: verify.sh failed (see verify-$1.log)"
  fi
}

conf_fingerprint() {
  # The settings an upgrade must never change.
  xsh "python3 -c \"import yaml; c = yaml.safe_load(open('/opt/raven/data/config.yml')); \
print('|'.join(str(c.get(k)) for k in ('SQLALCHEMY_DATABASE_URI', 'SECRET_KEY', 'SECURITY_PASSWORD_SALT', 'RAVEN_MEDIAMTX_TOKEN', 'OFFLINE_E2E_MARKER')))\" \
&& sha256sum /opt/raven/data/ca/certs/raven/raven.pem /opt/raven/data/ca/ca.pem 2>/dev/null | cut -d' ' -f1"
}

if [ -n "$OLD" ]; then
  install_bundle /opt/harness/old install-old recover
  x dpkg-query -W -f='old: c4raven-server ${Version}\n' c4raven-server >&2
  # An admin's own key in config.yml, which the upgrade must keep.
  xsh "echo 'OFFLINE_E2E_MARKER: kept-across-upgrade' >> /opt/raven/data/config.yml"
  # Stand in for a certbot-edited site file: postinst leaves those alone, so
  # only the in-place patch can give them the X-Ssl-Cert fix. Strip any
  # X-Ssl-Cert lines the old template had so the patch has work to do.
  xsh "sed -i '/X-Ssl-Cert/d' /etc/nginx/sites-available/raven_http && \
       echo '# ssl_certificate lines here are managed by Certbot (offline-e2e stand-in)' >> /etc/nginx/sites-available/raven_http && \
       nginx -t" > "$OUT/certbot-standin.log" 2>&1 || fail "could not set up the certbot stand-in"
  BEFORE=$(conf_fingerprint)
  printf 'before upgrade: %s\n' "$BEFORE" > "$OUT/config-fingerprint.log"
  # A domain answered for the upgrade: postinst must skip Let's Encrypt
  # offline rather than try it.
  xsh "printf 'c4raven-server c4raven-server/domain string raven.offline.test\n' | debconf-set-selections"
fi

install_bundle /opt/harness/new install-new
x dpkg-query -W -f='installed: c4raven-server ${Version}\n' c4raven-server >&2
grep -q "Database migrations are at head" "$OUT/install-new.log" \
  && ok "postinst: database migrations are at head" \
  || fail "postinst did not report migrations at head"
run_verify new

ICONS=$(xsh "su postgres -c \"psql -XtAd raven -c 'SELECT count(*) FROM icons'\"" 2>/dev/null | tr -d ' \r')
[ "${ICONS:-0}" -gt 0 ] 2>/dev/null && ok "ATAK icon sets loaded offline ($ICONS icons)" \
  || fail "icons table is empty (got '${ICONS}')"
PLUG=$(xsh "su postgres -c \"psql -XtAd raven -c \\\"SELECT count(*) FROM packages WHERE package_name='com.atakmap.android.ravenclear.plugin'\\\"\"" 2>/dev/null | tr -d ' \r')
[ "${PLUG:-0}" = 1 ] && ok "Remote Clear plugin published" || fail "Remote Clear plugin not published (rows: '${PLUG}')"

if [ -n "$OLD" ]; then
  AFTER=$(conf_fingerprint)
  printf 'after upgrade:  %s\n' "$AFTER" >> "$OUT/config-fingerprint.log"
  [ -n "$BEFORE" ] && [ "$BEFORE" = "$AFTER" ] \
    && ok "config.yml settings, server and CA certificates kept across the upgrade" \
    || fail "config/certificates changed across the upgrade (see config-fingerprint.log)"
  xsh "grep -q 'managed by Certbot' /etc/nginx/sites-available/raven_http && \
       grep -q 'proxy_set_header X-Ssl-Cert \"\";' /etc/nginx/sites-available/raven_http" \
    && ok "certbot-edited raven_http kept and patched with the X-Ssl-Cert fix" \
    || fail "certbot-edited raven_http was not patched (or was overwritten)"
  grep -q "Offline install: not requesting a Let's Encrypt certificate" "$OUT/install-new.log" \
    && ok "Let's Encrypt skipped offline for the preseeded domain" \
    || fail "postinst did not skip Let's Encrypt for the offline install"
fi

if [ "$RERUN" = 1 ]; then
  install_bundle /opt/harness/new install-rerun
  grep -q "reinstalling it to re-run its setup" "$OUT/install-rerun.log" \
    && ok "re-run reinstalled the same version" || fail "re-run did not reinstall"
  run_verify rerun
fi

network_proof after
finish
