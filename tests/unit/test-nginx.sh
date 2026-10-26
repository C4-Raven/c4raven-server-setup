#!/bin/bash
# Unit tests for the nginx templates and how the three install paths wire
# them -- in particular port 8446, which has to serve two different
# certificates depending on what the client asked for:
#
#   * no SNI / any other name -> raven_certificate_enrollment, the port's
#     default server, Raven's own internal-CA cert. VPN and bare-IP users,
#     onboarded with a data package that ships Raven's CA ("preconfigured
#     trust": ATAK trusts only that CA and skips the hostname check).
#   * SNI = the public domain -> raven_certificate_enrollment_domain, the
#     Let's Encrypt cert. ATAK "Quick Connect" users, who need a publicly
#     trusted cert that matches what they typed.
#
# The static checks need nothing but bash and grep. Two deeper checks run
# only when their tools are on this machine and SKIP (loudly) otherwise:
#   * certbot's own nginx parser (python3 -c 'import certbot_nginx'), to prove
#     `certbot --nginx -d <new domain>` can still find a block to clone;
#   * a real nginx + openssl: render the templates with throwaway certs, run
#     `nginx -t` with and without the domain block, then start it on high
#     ports and check which certificate each kind of client is handed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$HERE/../lib/assert.sh"
harness_paths

WORK=$(mktemp -d "${TMPDIR:-/tmp}/c4raven-nginx.XXXXXX")
NGINX_PID_FILE=""
cleanup() {
  if [ -n "$NGINX_PID_FILE" ] && [ -s "$NGINX_PID_FILE" ]; then
    kill "$(cat "$NGINX_PID_FILE")" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

T="$REPO_DIR/nginx_configs"
BASE="$T/raven_certificate_enrollment"
DOM="$T/raven_certificate_enrollment_domain"
INSTALL="$REPO_DIR/install.sh"
POSTINST="$REPO_DIR/debian/c4raven-server.postinst"
CONFIGURE="$REPO_DIR/rpm/configure.sh"

# Directives only, comments stripped -- the templates explain themselves at
# length and those explanations mention the very words we grep for.
directives() { sed -e 's/#.*//' "$1" | grep -v '^[[:space:]]*$'; }
# The `location` lines of a server block, in order.
locations() { directives "$1" | grep -E '^[[:space:]]*location' | sed 's/^[[:space:]]*//'; }
# First line number in FILE matching ERE, or empty.
line_of() { grep -nE -- "$2" "$1" | head -1 | cut -d: -f1; }

# ===========================================================================
echo "== 8446 default block: Raven's own certificate"
# ===========================================================================
if [ ! -f "$BASE" ]; then
  t_skip_all "nginx_configs/raven_certificate_enrollment is missing"
fi
b=$(directives "$BASE")
t_has "$b" "server_name _;" "raven_certificate_enrollment is the catch-all (server_name _)"
t_match "$b" 'listen 8446 ssl;' "it listens on 8446 with TLS"
t_has "$b" "ssl_certificate SERVER_CERT_FILE;" "it presents the Raven server cert (SERVER_CERT_FILE)"
t_has "$b" "ssl_certificate_key SERVER_KEY_FILE;" "...with the Raven key (SERVER_KEY_FILE)"
t_hasnt "$b" "letsencrypt" "it never points at a Let's Encrypt cert (IP/VPN clients only trust Raven's CA)"
# Not an oversight -- see the template. An explicit default_server here is a
# second one next to raven_http's on 8080, and certbot then refuses to clone
# a block for a new domain. "First block for the port" is nginx's default.
t_hasnt "$b" "default_server" "no explicit default_server (it would break certbot --nginx; see template)"

# ===========================================================================
echo "== 8446 domain block: the Let's Encrypt certificate"
# ===========================================================================
if [ ! -f "$DOM" ]; then
  t_no "nginx_configs/raven_certificate_enrollment_domain exists"
else
  d=$(directives "$DOM")
  t_has "$d" "server_name DOMAIN_NAME;" "the domain block matches only DOMAIN_NAME"
  t_match "$d" 'listen 8446 ssl;' "it listens on 8446 with TLS"
  t_hasnt "$d" "default_server" "it never claims the port's default (that is the Raven block's)"
  t_has "$d" "ssl_certificate /etc/letsencrypt/live/DOMAIN_NAME/fullchain.pem;" \
        "it presents the LE fullchain for DOMAIN_NAME"
  t_has "$d" "ssl_certificate_key /etc/letsencrypt/live/DOMAIN_NAME/privkey.pem;" \
        "...with the LE private key"
  t_false "it carries none of the build-time placeholders (so build-deb/build-rpm leave it intact)" -- \
    grep -qE 'OTS_FOLDER|SERVER_CERT_FILE|SERVER_KEY_FILE|CA_CERT_FILE' "$DOM"
  t_eq "$(locations "$DOM")" "$(locations "$BASE")" \
       "it proxies exactly the same locations as the default block"
  # The proxy bodies must match too, not just the location lines: the two
  # blocks differ ONLY in server_name and certificate.
  strip() { directives "$1" | grep -vE 'server_name|ssl_certificate'; }
  t_eq "$(strip "$DOM")" "$(strip "$BASE")" \
       "apart from server_name and the certificate, the two blocks are identical"
fi

# ===========================================================================
echo "== only one default_server anywhere (certbot --nginx needs exactly one)"
# ===========================================================================
# certbot, asked for a domain no block names yet, clones the ONE vhost marked
# default_server (preferring one on 443). Two of them on other ports and it
# gives up: "Could not automatically find a matching server block".
mapfile -t defaults < <(grep -lE '^[^#]*listen[^;]*default_server' "$T"/* 2>/dev/null)
t_eq "${defaults[*]:-}" "$T/raven_http" "raven_http is the only template with a default_server listen"

# ===========================================================================
echo "== port 8080: the plain-HTTP listener the onboarding package comes from"
# ===========================================================================
h=$(directives "$T/raven_http")
t_has "$h" "listen 8080 default_server;" "raven_http is 8080's default server"
loc=$(printf '%s\n' "$h" | grep -E 'location ~ \^/\(api\|Marti\)' | head -1)
t_ne "$loc" "" "raven_http has the /api|/Marti backend proxy location"
for path in /api/onboard/ /api/onboard/abc123/package.zip /Marti/api/version; do
  printf '%s' "$path" | grep -qE '^/(api|Marti)' \
    && t_ok "8080 proxies $path to the backend" \
    || t_no "8080 proxies $path to the backend"
done
t_has "$h" 'if ($server_port = 80)' "only port 80 redirects to HTTPS (8080 must stay plain for onboarding)"
# /api/onboard/<token>: the path is a bearer token, so it must not reach the
# access log on any listener that proxies /api.
for f in raven_http raven_https; do
  n=$(directives "$T/$f" | awk '/location \^~ \/api\/onboard\/ \{/ {inb=1; next}
      inb && /access_log off;/ {c++; inb=0} inb && /}/ {inb=0} END {print c+0}')
  want=1; [ "$f" = raven_https ] && want=2   # 443 and 8443
  t_eq "$n" "$want" "$f: every /api/onboard/ location turns access_log off"
done
o=$(locations "$T/raven_http")
t_true "raven_http: the onboard location precedes the /api regex" -- \
  awk '/\/api\/onboard\// {o=NR} /\^\/\(api\|Marti\)/ {r=NR} END {exit !(o && r && o < r)}' <<< "$o"
for f in "$INSTALL" "$POSTINST" "$CONFIGURE"; do
  [ -f "$f" ] || continue
  # The firewall port list is a single command/array spanning a few lines.
  fw=$(grep -A3 -E 'firewall_open 80/tcp|RAVEN_PORTS=\(' "$f")
  t_has "$fw" "8080/tcp" "$(basename "$f"): firewall list opens 8080/tcp"
  t_has "$fw" "8446/tcp" "$(basename "$f"): firewall list opens 8446/tcp"
done

# ===========================================================================
echo "== install paths: the domain block is wired the same way in all three"
# ===========================================================================
# For each path: the domain block is (1) taken out of certbot's sight BEFORE
# certbot runs -- certbot installs into the first ssl block whose server_name
# matches, which would otherwise be it, leaving the web UI on 443 without LE;
# (2) written only AFTER, and only when certbot's lineage (falling back to
# live/<domain>) holds a certificate that has not expired;
# (3) DOMAIN_NAME substituted; (4) checked with nginx -t and backed out if it
# fails; (5) given the renewal deploy hook.
check_wiring() {
  local f=$1 name rm_re rm_ln cb_ln guard_ln tpl_ln if_ln
  name=$(basename "$f")
  if [ ! -f "$f" ]; then t_no "$name exists"; return; fi
  rm_re=$2
  rm_ln=$(line_of "$f" "$rm_re")
  cb_ln=$(line_of "$f" 'certbot --nginx -d "\$DOMAIN"')
  guard_ln=$(line_of "$f" 'openssl x509 -checkend 0 -noout -in "\$LE_DIR/fullchain.pem"')
  tpl_ln=$(line_of "$f" 'nginx_configs/raven_certificate_enrollment_domain')
  if [ -z "$rm_ln" ] || [ -z "$cb_ln" ] || [ -z "$guard_ln" ] || [ -z "$tpl_ln" ]; then
    t_no "$name: removes, runs certbot, checks the cert, installs the template" \
         "rm=$rm_ln certbot=$cb_ln guard=$guard_ln template=$tpl_ln"
    return
  fi
  [ "$rm_ln" -lt "$cb_ln" ] && t_ok "$name: domain block removed before certbot runs" \
    || t_no "$name: domain block removed before certbot runs" "rm at $rm_ln, certbot at $cb_ln"
  # Outside the `if [ -n "$DOMAIN" ]`: clearing the domain must remove it too.
  if_ln=$(line_of "$f" '^[[:space:]]*if \[ -n "\$DOMAIN" \]; then')
  [ -n "$if_ln" ] && [ "$rm_ln" -lt "$if_ln" ] \
    && t_ok "$name: domain block removed even when no domain is set" \
    || t_no "$name: domain block removed even when no domain is set" "rm at $rm_ln, domain if at ${if_ln:-none}"
  t_true "$name: asks certbot for the lineage path, falling back to live/<domain>" -- \
    grep -q 'certbot certificates -d "\$DOMAIN"' "$f"
  t_true "$name: points the rendered block at that lineage" -- \
    grep -q 's~/etc/letsencrypt/live/DOMAIN_NAME~\$LE_DIR~g' "$f"
  t_false "$name: never tells the admin to run certbot --nginx by hand" -- \
    grep -qE 'run: sudo certbot --nginx' "$f"
  [ "$cb_ln" -lt "$guard_ln" ] && [ "$guard_ln" -lt "$tpl_ln" ] \
    && t_ok "$name: domain block written after certbot, only if its certificate is unexpired" \
    || t_no "$name: domain block written after certbot, behind the cert check" \
            "certbot=$cb_ln guard=$guard_ln template=$tpl_ln"
  t_true "$name: substitutes DOMAIN_NAME with \$DOMAIN" -- grep -q 's~DOMAIN_NAME~\$DOMAIN~g' "$f"
  t_true "$name: validates with nginx -t before reloading" -- \
    awk -v s="$tpl_ln" 'NR>s && /nginx -t/ {found=1} END {exit !found}' "$f"
  t_true "$name: installs the certbot deploy hook" -- \
    grep -q '/etc/letsencrypt/renewal-hooks/deploy/raven-nginx-reload' "$f"
  t_true "$name: the hook reloads nginx" -- grep -q 'systemctl reload nginx\\n' "$f"
}
check_wiring "$INSTALL"   'nginx_remove_site raven_certificate_enrollment_domain'
check_wiring "$POSTINST"  'rm -f /etc/nginx/sites-enabled/raven_certificate_enrollment_domain'
check_wiring "$CONFIGURE" 'rm -f "\$NGINX_SITES_DIR/raven_certificate_enrollment_domain.conf"'

t_true "postinst links the domain block into sites-enabled" -- \
  grep -q 'ln -sf /etc/nginx/sites-available/raven_certificate_enrollment_domain' "$POSTINST"
t_true "install.sh enables the domain block through the shim" -- \
  grep -q 'nginx_enable_site raven_certificate_enrollment_domain' "$INSTALL"
t_true "configure.sh writes the domain block with EL's .conf suffix" -- \
  grep -q '> "\$NGINX_SITES_DIR/raven_certificate_enrollment_domain.conf"' "$CONFIGURE"
# The base 8446 file must keep getting the cert placeholders substituted.
t_true "install.sh still substitutes SERVER_CERT_FILE into the base 8446 file" -- \
  grep -q 'nginx_site_file raven_certificate_enrollment)' "$INSTALL"
# Both package builds ship every template in nginx_configs/ and must leave
# DOMAIN_NAME for install time.
for b in "$REPO_DIR/build-deb.sh" "$REPO_DIR/rpm/build-rpm.sh"; do
  [ -f "$b" ] || continue
  t_true "$(basename "$b") ships every nginx_configs/ template" -- grep -q 'nginx_configs/\*' "$b"
  t_true "$(basename "$b") refuses a staged domain template without DOMAIN_NAME" -- \
    grep -q "grep -q 'DOMAIN_NAME'" "$b"
  t_false "$(basename "$b")'s build-time subst does not touch DOMAIN_NAME" -- \
    grep -E '^\s*(-e )?"s~DOMAIN_NAME' "$b"
done
t_true "rpm %postun instructions remove the domain block" -- \
  grep -q 'conf.d/raven_certificate_enrollment_domain.conf' "$REPO_DIR/rpm/c4raven-server.spec"

# ---------------------------------------------------------------------------
# Rendering, the way the installers do it, into a scratch nginx tree.
# ---------------------------------------------------------------------------
DOMAIN=tak.example.test
render() {  # render OUTDIR WITH_DOMAIN(0|1)
  local out=$1 with=$2
  mkdir -p "$out/sites" "$out/certs" "$out/le/$DOMAIN" "$out/logs"
  for f in raven_http raven_https raven_certificate_enrollment; do
    sed -e "s~SERVER_CERT_FILE~$WORK/certs/raven.pem~g" \
        -e "s~SERVER_KEY_FILE~$WORK/certs/raven.key~g" \
        -e "s~CA_CERT_FILE~$WORK/certs/ca.pem~g" \
        "$T/$f" > "$out/sites/$f"
  done
  if [ "$with" = 1 ]; then
    sed -e "s~DOMAIN_NAME~$DOMAIN~g" -e "s~/etc/letsencrypt/live~$WORK/le~g" \
        "$DOM" > "$out/sites/raven_certificate_enrollment_domain"
  fi
  cp "$REPO_DIR/rpm/proxy_params" "$out/proxy_params"
  cat > "$out/nginx.conf" <<EOF
pid $out/nginx.pid;
error_log $out/logs/error.log;
events {}
http {
    access_log off;
    client_body_temp_path $out/tmp_body;
    proxy_temp_path $out/tmp_proxy;
    fastcgi_temp_path $out/tmp_fcgi;
    uwsgi_temp_path $out/tmp_uwsgi;
    scgi_temp_path $out/tmp_scgi;
    include $out/sites/*;
}
EOF
}

# ===========================================================================
echo "== certbot --nginx can still clone a block for a new domain"
# ===========================================================================
if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import certbot_nginx._internal.configurator' 2>/dev/null; then
  render "$WORK/cb" 1
  cat > "$WORK/cb.py" <<'EOF'
import sys
from certbot_nginx._internal import configurator, parser
c = configurator.NginxConfigurator.__new__(configurator.NginxConfigurator)
c.parser = parser.NginxParser(sys.argv[1])
c.new_vhost = None
# What deploy_cert falls back to when no server_name matches: the vhost it
# will duplicate into the domain's 443 block.
v = c._get_default_vhost("new.example.test", True, "443")
print(v.filep.rsplit("/", 1)[-1])
EOF
  got=$(python3 -I "$WORK/cb.py" "$WORK/cb" 2>&1 | tail -1)
  t_eq "$got" "raven_http" "certbot's default-vhost fallback still resolves to raven_http"
else
  t_ok "certbot default-vhost check SKIPPED -- certbot_nginx is not importable here"
fi

# ===========================================================================
echo "== real nginx: nginx -t, and which cert each kind of client gets"
# ===========================================================================
NGINX=$(command -v nginx 2>/dev/null || true)
[ -n "$NGINX" ] || { [ -x /usr/sbin/nginx ] && NGINX=/usr/sbin/nginx; }
if [ -z "$NGINX" ] || ! command -v openssl >/dev/null 2>&1; then
  t_ok "nginx render checks SKIPPED -- needs nginx and openssl on PATH"
else
  # Throwaway certs: a "Raven" CA-issued-ish self-signed and an "LE" one.
  mkdir -p "$WORK/certs" "$WORK/le/$DOMAIN"
  mkcert() {  # mkcert CN CERT KEY
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$1" \
      -keyout "$3" -out "$2" >/dev/null 2>&1
  }
  mkcert "raven-internal" "$WORK/certs/raven.pem" "$WORK/certs/raven.key"
  cp "$WORK/certs/raven.pem" "$WORK/certs/ca.pem"
  mkcert "$DOMAIN" "$WORK/le/$DOMAIN/fullchain.pem" "$WORK/le/$DOMAIN/privkey.pem"

  # nginx -t really binds every listen, so run it as non-root on the same
  # config with the listens moved to free high ports on loopback. Nothing
  # else changes: the server_name/cert/default-server logic is untouched.
  relocate() {  # relocate DIR FIRST_PORT -- 8446 becomes FIRST_PORT
    local dir=$1 port=$2 i=1 p
    sed -i -e "s/listen 8446 /listen 127.0.0.1:$port /" "$dir"/sites/*
    for p in 80 8080 443 8443; do
      sed -i -e "s/listen $p\([ ;]\)/listen 127.0.0.1:$((port + i))\1/" "$dir"/sites/*
      i=$((i + 1))
    done
    # IPv6 loopback may be absent in a container; the v6 twins add nothing.
    sed -i '/listen \[::\]/d' "$dir"/sites/*
  }
  ntest() { "$NGINX" -t -q -p "$1" -c "$1/nginx.conf" -e "$1/logs/error.log" 2>&1 | grep -v '\[warn\]'; return "${PIPESTATUS[0]}"; }
  base_port=$(( 20000 + RANDOM % 20000 ))
  render "$WORK/nd" 0; relocate "$WORK/nd" "$base_port"
  out=$(ntest "$WORK/nd"); rc=$?
  t_eq "$rc" "0" "nginx -t passes without a domain block${out:+ ($out)}"
  render "$WORK/wd" 1; relocate "$WORK/wd" "$base_port"
  out=$(ntest "$WORK/wd"); rc=$?
  t_eq "$rc" "0" "nginx -t passes with the domain block${out:+ ($out)}"

  # Live check on the with-domain tree: start it and look at the cert each
  # kind of client is handed on (relocated) 8446.
  P8446=$base_port
  live="$WORK/wd"
  NGINX_PID_FILE="$live/nginx.pid"
  if "$NGINX" -p "$live" -c "$live/nginx.conf" -e "$live/logs/error.log" 2>"$WORK/start.err"; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$NGINX_PID_FILE" ] && break; sleep 0.2; done
    subject() {  # subject [SNI]
      local sni=()
      [ -n "${1:-}" ] && sni=(-servername "$1")
      [ -z "${1:-}" ] && sni=(-noservername)
      openssl s_client -connect "127.0.0.1:$P8446" "${sni[@]}" </dev/null 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | tr -d ' '
    }
    t_has "$(subject)" "CN=raven-internal" "no SNI (bare-IP / VPN client) -> Raven's own cert"
    t_has "$(subject "$DOMAIN")" "CN=$DOMAIN" "SNI = the domain (Quick Connect) -> the LE cert"
    t_has "$(subject other.example.test)" "CN=raven-internal" "SNI = some other name -> Raven's own cert"
    kill "$(cat "$NGINX_PID_FILE")" 2>/dev/null || true
    NGINX_PID_FILE=""
  else
    t_ok "live 8446 check SKIPPED -- nginx would not start here: $(head -1 "$WORK/start.err")"
  fi
fi

t_summary
