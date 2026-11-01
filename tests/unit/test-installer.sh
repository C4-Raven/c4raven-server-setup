#!/bin/bash
# Unit tests for lib/installer.sh and lib/nginx_clear_ssl_cert.py -- the
# retry, container-detection, resume and migration-check helpers shared by
# install.sh, the .deb postinst and the RPM's configure.sh -- plus static
# checks that the install paths actually use them.
#
# No containers, no root, no network. Container/systemd detection is pointed
# at fixture trees through IH_ROOT; git clones are local file:// repos.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$HERE/../lib/assert.sh"
harness_paths

LIB="$REPO_DIR/lib/installer.sh"
[ -f "$LIB" ] || t_skip_all "lib/installer.sh does not exist"
# shellcheck source=lib/installer.sh
. "$LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ===========================================================================
echo "== ih_retry"
# ===========================================================================
export IH_RETRY_DELAY=0
COUNT="$TMP/count"
flaky() {  # fails until it has been called $1 times
  local n
  n=$(( $(cat "$COUNT" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$COUNT"
  [ "$n" -ge "$1" ]
}
rm -f "$COUNT"
t_true "succeeds once the command does (3rd attempt of 5)" -- ih_retry -n 5 flaky 3
t_eq "$(cat "$COUNT")" 3 "stops retrying after the first success"
rm -f "$COUNT"
t_false "gives up after -n attempts" -- ih_retry -n 2 flaky 3
t_eq "$(cat "$COUNT")" 2 "ran exactly -n times"
rc=0; ih_retry -n 2 sh -c 'exit 7' 2>/dev/null || rc=$?
t_eq "$rc" 7 "returns the command's own exit status"
out=$(ih_retry -n 2 false 2>&1 || true)
t_has "$out" "giving up after 2 attempts" "says it gave up, and after how many"
t_has "$out" "attempt 1/2 failed" "reports each failed attempt"
t_true "a command that succeeds first time is run once" -- ih_retry true
# Under set -e the caller must survive a failing attempt.
t_true "a failing attempt does not trip the caller's set -e" -- \
  bash -c "set -euo pipefail; . '$LIB'; IH_RETRY_DELAY=0; n=0; f() { n=\$((n+1)); [ \$n -ge 2 ]; }; ih_retry -n 3 f; echo ok"

# ===========================================================================
echo "== container / systemd detection"
# ===========================================================================
mkroot() {  # mkroot NAME -> empty fixture root
  local r="$TMP/root-$1"
  mkdir -p "$r/proc/1" "$r/proc/sys/kernel" "$r/run"
  echo "6.8.0-generic" > "$r/proc/sys/kernel/osrelease"
  echo "0::/init.scope" > "$r/proc/1/cgroup"
  printf '%s' "$r"
}

R=$(mkroot vm); echo systemd > "$R/proc/1/comm"; mkdir -p "$R/run/systemd/system"
t_false "a VM is not a container" -- env IH_ROOT="$R" IH_CONTAINER_ENV= bash -c ". '$LIB'; ih_container_kind"
t_true  "systemd PID 1 + /run/systemd/system = booted" -- env IH_ROOT="$R" bash -c ". '$LIB'; ih_systemd_booted"
t_true  "ih_require_systemd passes on a systemd host" -- env IH_ROOT="$R" bash -c ". '$LIB'; ih_require_systemd"

R=$(mkroot docker-bash); echo bash > "$R/proc/1/comm"; touch "$R/.dockerenv"
t_eq "$(IH_ROOT="$R" IH_CONTAINER_ENV='' ih_container_kind)" docker "/.dockerenv means docker"
t_false "plain docker (bash as PID 1) is not systemd-booted" -- env IH_ROOT="$R" bash -c ". '$LIB'; ih_systemd_booted"
out=$(IH_ROOT="$R" IH_CONTAINER_ENV='' ih_require_systemd 2>&1); rc=$?
t_ne "$rc" 0 "ih_require_systemd fails in a container without systemd"
t_has "$out" "PID 1 here is 'bash'" "names what PID 1 actually is"
t_has "$out" "container (docker)" "says it is a docker container"
t_has "$out" "--privileged --cgroupns=host" "gives the systemd container flags"
t_has "$out" "--tmpfs /run --tmpfs /run/lock" "including the tmpfs mounts"
t_has "$out" "/sys/fs/cgroup:/sys/fs/cgroup:rw" "and the cgroup mount"
t_has "$out" "--systemd=always" "and the podman equivalent"
t_has "$out" "Dockerfile.ubuntu-24.04" "points at the ready-made test images"
t_true "RAVEN_SKIP_SYSTEMD_CHECK=1 bypasses it" -- env IH_ROOT="$R" RAVEN_SKIP_SYSTEMD_CHECK=1 bash -c ". '$LIB'; ih_require_systemd"

# Flags in the message must match what the harness itself uses.
for f in --privileged --cgroupns=host "--tmpfs /run" "--tmpfs /run/lock" "/sys/fs/cgroup:/sys/fs/cgroup:rw"; do
  t_has "$(engine_run_flags docker amd64 | tr '\n' ' ')" "$f" "harness engine_run_flags also uses $f"
done

R=$(mkroot docker-stale); echo sh > "$R/proc/1/comm"; mkdir -p "$R/run/systemd/system"; touch "$R/.dockerenv"
t_false "a stale /run/systemd/system in an image layer does not fool it" -- env IH_ROOT="$R" bash -c ". '$LIB'; ih_systemd_booted"

R=$(mkroot docker-systemd); echo systemd > "$R/proc/1/comm"; mkdir -p "$R/run/systemd/system"; touch "$R/.dockerenv"
t_true "a systemd container (the test images) passes" -- env IH_ROOT="$R" bash -c ". '$LIB'; ih_require_systemd"

R=$(mkroot podman); echo catatonit > "$R/proc/1/comm"; touch "$R/run/.containerenv"
t_eq "$(IH_ROOT="$R" IH_CONTAINER_ENV='' ih_container_kind)" podman "/run/.containerenv means podman"

R=$(mkroot cgroup); echo node > "$R/proc/1/comm"; echo "0::/kubepods/besteffort/pod1/abc" > "$R/proc/1/cgroup"
t_eq "$(IH_ROOT="$R" IH_CONTAINER_ENV='' ih_container_kind)" container "a kubepods cgroup means a container"

R=$(mkroot envvar); echo bash > "$R/proc/1/comm"
t_eq "$(IH_ROOT="$R" IH_CONTAINER_ENV=lxc ih_container_kind)" lxc "\$container=lxc is honoured"

R=$(mkroot wsl); echo init > "$R/proc/1/comm"; echo "5.15.0-microsoft-standard-WSL2" > "$R/proc/sys/kernel/osrelease"
t_eq "$(IH_ROOT="$R" IH_CONTAINER_ENV='' ih_container_kind)" wsl "WSL is recognised"
out=$(IH_ROOT="$R" IH_CONTAINER_ENV='' ih_require_systemd 2>&1)
t_has "$out" "systemd=true" "WSL gets the wsl.conf fix, not docker flags"
t_hasnt "$out" "--privileged" "and no docker flags"

R=$(mkroot bare-nosystemd); echo runit > "$R/proc/1/comm"
out=$(IH_ROOT="$R" IH_CONTAINER_ENV='' ih_require_systemd 2>&1); rc=$?
t_ne "$rc" 0 "a non-container without systemd also fails early"
t_has "$out" "systemd does not appear to be running" "with a plain explanation"

# ===========================================================================
echo "== parsers"
# ===========================================================================
URI="postgresql+psycopg://raven:0123abcd@127.0.0.1/raven"
t_eq "$(ih_uri_password "$URI")" 0123abcd "password out of a psycopg URI"
t_eq "$(ih_uri_user "$URI")" raven "user out of a psycopg URI"
t_false "no password in a URI without one" -- ih_uri_password "postgresql://raven@127.0.0.1/raven"
t_false "no password in garbage" -- ih_uri_password "not a uri"
t_false "no password in an empty string" -- ih_uri_password ""
t_eq "$(ih_uri_user "postgresql+psycopg://ots:POSTGRESQL_PASSWORD@127.0.0.1/ots")" ots \
     "generate-config's placeholder URI has user ots (so install.sh will not try it for raven)"

cat > "$TMP/env" <<'EOF'
RAVEN_DATA_FOLDER=/opt/raven/data
RAVEN_FEDHUB_ENABLE=True
QUOTED="with space"
RAVEN_FEDHUB_ENABLE=False
EOF
t_eq "$(ih_env_value "$TMP/env" RAVEN_DATA_FOLDER)" /opt/raven/data "env value"
t_eq "$(ih_env_value "$TMP/env" RAVEN_FEDHUB_ENABLE)" False "the last assignment wins, as in systemd"
t_eq "$(ih_env_value "$TMP/env" QUOTED)" "with space" "quotes stripped"
t_false "missing key" -- ih_env_value "$TMP/env" NOPE
t_false "missing file" -- ih_env_value "$TMP/nope" RAVEN_DATA_FOLDER

# ===========================================================================
echo "== ih_heads_match"
# ===========================================================================
t_true  "same single head" -- ih_heads_match "d3f1a7c95b20" "d3f1a7c95b20"
t_true  "whitespace/newlines and order do not matter" -- ih_heads_match $'b2\na1\n' "a1 b2"
t_false "database behind the code" -- ih_heads_match "b8e4d2a6c913" "d3f1a7c95b20"
t_false "empty database (no alembic_version rows)" -- ih_heads_match "" "d3f1a7c95b20"
t_false "both empty is not 'at head'" -- ih_heads_match "" ""
t_false "a missing branch head" -- ih_heads_match "a1" "a1 b2"

# ===========================================================================
echo "== ih_clone_repo (resume over an interrupted clone)"
# ===========================================================================
if command -v git >/dev/null 2>&1; then
  runner() { bash -c "$1"; }
  export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
  git init -q "$TMP/upstream" && git -C "$TMP/upstream" commit -q --allow-empty -m init
  UP="file://$TMP/upstream"

  t_true "fresh clone" -- ih_clone_repo runner "$UP" "$TMP/w/fresh"
  t_true "result is a real checkout" -- git -C "$TMP/w/fresh" rev-parse --verify HEAD
  t_false "no .partial left behind" -- test -e "$TMP/w/fresh.partial"

  echo local > "$TMP/w/fresh/local-change"
  t_true "existing good checkout: no-op" -- ih_clone_repo runner "$UP" "$TMP/w/fresh"
  t_true "and local files in it are kept (never reset)" -- test -f "$TMP/w/fresh/local-change"

  mkdir -p "$TMP/w/broken" && git init -q "$TMP/w/broken"   # .git but no HEAD commit
  t_true "broken partial clone is replaced" -- ih_clone_repo runner "$UP" "$TMP/w/broken"
  t_true "now a real checkout" -- git -C "$TMP/w/broken" rev-parse --verify HEAD
  t_true "the broken one was moved aside, not deleted" -- bash -c "ls -d '$TMP'/w/broken.broken.* >/dev/null"

  mkdir -p "$TMP/w/plain" && echo x > "$TMP/w/plain/file"
  t_true "a non-git directory in the way is moved aside too" -- ih_clone_repo runner "$UP" "$TMP/w/plain"

  t_false "an unreachable URL fails (after its retries)" -- \
    env IH_RETRY_ATTEMPTS=2 bash -c ". '$LIB'; runner() { bash -c \"\$1\"; }; ih_clone_repo runner 'file://$TMP/nope' '$TMP/w/nope'"
  t_false "and leaves no half-made target" -- test -e "$TMP/w/nope"
else
  t_ok "git not installed -- clone tests skipped"
fi

# ===========================================================================
echo "== the install paths use all this"
# ===========================================================================
INS="$REPO_DIR/install.sh"
POST="$REPO_DIR/debian/c4raven-server.postinst"
CONFSH="$REPO_DIR/rpm/configure.sh"

line_of() { grep -n -m1 -- "$2" "$1" | cut -d: -f1; }
t_true "install.sh fetches lib/installer.sh" -- grep -q 'lib/installer.sh' "$INS"
l_check=$(line_of "$INS" '^if ! ih_require_systemd')
l_pkgs=$(line_of "$INS" 'ih_retry pkg_refresh')
t_ne "$l_check" "" "install.sh calls ih_require_systemd"
[ -n "$l_check" ] && [ -n "$l_pkgs" ] && [ "$l_check" -lt "$l_pkgs" ] \
  && t_ok "the systemd check runs before any package is installed" \
  || t_no "the systemd check runs before any package is installed" "check at line $l_check, packages at $l_pkgs"
t_hasnt "$(cat "$INS")" "already exists -- enter its password" "install.sh no longer prompts for the DB password on a re-run"
t_true "install.sh guards issue-server-certificate (it wipes certs/raven/)" -- \
  grep -q 'test -s "$DATA_DIR/ca/certs/raven/raven.pem"' "$INS"
t_true "install.sh retries the network-bound steps" -- \
  bash -c "grep -q 'ih_retry pkg_install' '$INS' && grep -q 'ih_retry node_install' '$INS' && grep -q 'yarn install --immutable' '$INS' && grep -q 'ih_retry run_as_app \"cd .*poetry install' '$INS'"
t_true "install.sh clones through ih_clone_repo (partial-clone safe)" -- \
  bash -c "[ \$(grep -c '^ih_clone_repo run_as_app' '$INS') -eq 2 ]"
t_true "install.sh no longer clones with a bare git clone" -- bash -c "! grep -q 'run_as_app \"git clone' '$INS'"
t_true "install.sh ends with a health check that verifies migrations" -- \
  bash -c "grep -q 'ih_heads_match' '$INS' && grep -q 'alembic_version' '$INS'"
t_true "install.sh's REPO_RAW stays a single ^REPO_RAW= line (tests/methods/install-sh.sh rewrites it)" -- \
  bash -c "[ \$(grep -c '^REPO_RAW=' '$INS') -eq 1 ]"
t_true "install.sh does not add [y/n] questions the matrix does not answer" -- \
  bash -c "[ \$(grep -v '^[[:space:]]*#' '$INS' | grep -c 'ask_yn \"') -eq 3 ]"

for f in "$INS" "$POST" "$CONFSH" "$REPO_DIR/update.sh"; do
  # A key in config.yml overrides the env var of the same name; the server
  # team asked that existing installs NOT get it written in (2.3.0 notes).
  t_true "$(basename "$f") does not pin RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH into config.yml" -- \
    bash -c "! grep -v '^[[:space:]]*#' '$f' | grep -q 'RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH'"
  t_true "$(basename "$f") pre-creates the service log files owned by the app user (error-log API reads them)" -- \
    grep -q 'raven.log' "$f"
done
for f in "$POST" "$CONFSH"; do
  t_true "$(basename "$f") checks for systemd before configuring" -- grep -q 'ih_require_systemd' "$f"
  t_true "$(basename "$f") verifies migrations reached head" -- grep -q 'ih_heads_match' "$f"
done
t_true "build-deb.sh ships lib/installer.sh" -- grep -q 'lib/installer.sh" "$STAGE' "$REPO_DIR/build-deb.sh"
t_true "build-rpm.sh ships lib/installer.sh" -- grep -q 'lib/installer.sh" "$STAGE' "$REPO_DIR/rpm/build-rpm.sh"

for f in raven_http raven_certificate_enrollment raven_certificate_enrollment_domain; do
  t_true "nginx_configs/$f clears a client-supplied X-Ssl-Cert" -- \
    grep -q 'proxy_set_header X-Ssl-Cert "";' "$REPO_DIR/nginx_configs/$f"
done
n_backend=$(grep -c 'proxy_pass http://127.0.0.1:8081' "$REPO_DIR/nginx_configs/raven_http")
n_clear=$(grep -c 'X-Ssl-Cert ""' "$REPO_DIR/nginx_configs/raven_http")
t_eq "$n_clear" "$n_backend" "raven_http clears X-Ssl-Cert in every location that proxies to the backend"

# ===========================================================================
echo "== nginx_clear_ssl_cert.py (existing installs' nginx files)"
# ===========================================================================
NCS="$REPO_DIR/lib/nginx_clear_ssl_cert.py"
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
   && git -C "$REPO_DIR" cat-file -e 4f27bd8:nginx_configs/raven_http 2>/dev/null; then
  mkdir -p "$TMP/ngx"
  # The templates as they were before the fix = what an existing install has.
  for f in raven_http raven_certificate_enrollment raven_certificate_enrollment_domain; do
    git -C "$REPO_DIR" show "4f27bd8:nginx_configs/$f" > "$TMP/ngx/$f"
  done
  ln -s "$TMP/ngx/raven_http" "$TMP/ngx/enabled_raven_http"
  python3 "$NCS" "$TMP/ngx/enabled_raven_http" "$TMP/ngx/raven_certificate_enrollment" "$TMP/ngx/raven_certificate_enrollment_domain" >/dev/null
  t_true "a sites-enabled symlink stays a symlink" -- test -L "$TMP/ngx/enabled_raven_http"
  for f in raven_http raven_certificate_enrollment raven_certificate_enrollment_domain; do
    t_eq "$(grep -c 'X-Ssl-Cert ""' "$TMP/ngx/$f")" "$(grep -c 'X-Ssl-Cert ""' "$REPO_DIR/nginx_configs/$f")" \
         "patching an old $f clears X-Ssl-Cert in as many locations as the new template"
  done
  before=$(cat "$TMP/ngx/"raven_* | md5sum)
  out=$(python3 "$NCS" "$TMP/ngx/"raven_*)
  t_eq "$(cat "$TMP/ngx/"raven_* | md5sum)" "$before" "second run changes nothing (idempotent)"
  t_has "$out" "in 0 location(s)" "and says so"
  cp "$REPO_DIR/nginx_configs/raven_https" "$TMP/ngx/https"
  python3 "$NCS" "$TMP/ngx/https" >/dev/null
  t_true "mTLS locations that set X-Ssl-Cert from the verified cert are left alone" -- \
    grep -q 'X-Ssl-Cert $ssl_client_escaped_cert' "$TMP/ngx/https"
  rc=0; python3 "$NCS" "$TMP/ngx/does-not-exist" 2>/dev/null || rc=$?
  t_eq "$rc" 2 "unreadable file: exit 2"
  t_true "update.sh applies it with a backup and nginx -t" -- \
    bash -c "grep -q 'nginx_clear_ssl_cert.py' '$REPO_DIR/update.sh' && grep -q 'nginx -t' '$REPO_DIR/update.sh'"
else
  t_ok "no python3/git history -- nginx patcher tests skipped"
fi

t_summary
