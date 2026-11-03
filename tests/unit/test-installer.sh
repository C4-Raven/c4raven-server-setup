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
# Two: Turnstile and the public domain. Federation Hub's questions are
# install-fedhub.sh's own, and the matrix skips that step (RAVEN_FEDHUB_SKIP=1).
t_true "install.sh does not add [y/n] questions the matrix does not answer" -- \
  bash -c "[ \$(grep -v '^[[:space:]]*#' '$INS' | grep -c 'ask_yn \"') -eq 2 ]"

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

# ===========================================================================
echo "== Federation Hub step (ih_fedhub_step -> c4raven-updater's install-fedhub.sh)"
# ===========================================================================
# A local stand-in for c4raven-updater whose install-fedhub.sh records its
# arguments, the RAVEN_* environment and its stdin, and exits $FH_RC. Nothing
# here touches the network or the system.
if command -v git >/dev/null 2>&1; then
  export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
  FH="$TMP/fh"
  mkdir -p "$FH/updater" "$FH/home" "$FH/out" "$FH/root-tty/dev" "$FH/root-notty"
  printf '%s\n' '#!/bin/bash' \
    'printf "%s\n" "$@" > "$FH_OUT/args"' \
    'env | grep "^RAVEN_" | sort > "$FH_OUT/env"' \
    'cat > "$FH_OUT/stdin"' \
    'echo "fake install-fedhub.sh ran"' \
    'exit "${FH_RC:-0}"' > "$FH/updater/install-fedhub.sh"
  git -C "$FH/updater" init -q && git -C "$FH/updater" add . && git -C "$FH/updater" commit -q -m init
  echo "typed-answer" > "$FH/root-tty/dev/tty"
  export FH_OUT="$FH/out"

  # fh_run [VAR=VAL ...] -- one call in a clean subshell: none of the
  # caller's RAVEN_FEDHUB_* leak in, HOME has no ~/c4raven-updater, stdin
  # carries text the step must not consume. Sets FH_GOT (exit), FH_LOG
  # (output) and FH_REST (what was left of stdin afterwards).
  fh_run() {
    local dest="$FH/w/$RANDOM$RANDOM"
    rm -f "$FH/out/"*
    FH_LOG=$(printf 'REST-OF-INSTALL-SH\n' | env -u RAVEN_FEDHUB_SKIP -u RAVEN_FEDHUB_DEB -u RAVEN_FEDHUB_ARTIFACT \
      HOME="$FH/home" UPDATER_REPO="file://$FH/updater" IH_ROOT="$FH/root-notty" IH_RETRY_DELAY=0 "$@" \
      bash -c '. "$1"; rc=0; ih_fedhub_step raven /opt/raven /opt/raven/data "$2" "$3" || rc=$?; echo "RC=$rc"; echo "LEFT=$(cat)"' \
      _ "$LIB" "${FH_DOMAIN-tak.example.org}" "$dest" 2>&1)
    FH_GOT=$(printf '%s\n' "$FH_LOG" | sed -n 's/^RC=//p')
    FH_REST=$(printf '%s\n' "$FH_LOG" | sed -n 's/^LEFT=//p')
    FH_DEST="$dest"
  }
  fh_args() { tr '\n' ' ' < "$FH/out/args" 2>/dev/null; }

  # --- skipping without asking (unattended / CI) ---
  fh_run RAVEN_FEDHUB_SKIP=1
  t_eq "$FH_GOT" 2 "RAVEN_FEDHUB_SKIP=1: skipped (2)"
  t_false "RAVEN_FEDHUB_SKIP=1: c4raven-updater is not even cloned" -- test -e "$FH_DEST"
  t_has "$FH_LOG" "install-fedhub.sh --artifact" "a skip prints the add-it-later guide"
  fh_run RAVEN_FEDHUB_DEB=
  t_eq "$FH_GOT" 2 "legacy RAVEN_FEDHUB_DEB= (set but empty) still means skip"
  t_false "RAVEN_FEDHUB_DEB=: nothing is cloned" -- test -e "$FH_DEST"
  t_false "RAVEN_FEDHUB_DEB=: install-fedhub.sh is not run" -- test -e "$FH/out/args"
  fh_run RAVEN_FEDHUB_ARTIFACT=
  t_eq "$FH_GOT" 2 "RAVEN_FEDHUB_ARTIFACT= (set but empty) means skip too"
  fh_run RAVEN_FEDHUB_DEB= RAVEN_FEDHUB_ARTIFACT=/srv/fh.zip
  t_eq "$FH_GOT" 0 "an artifact path wins over a legacy empty RAVEN_FEDHUB_DEB"

  # --- the call itself ---
  fh_run
  t_eq "$FH_GOT" 0 "install-fedhub.sh exit 0: the step reports installed (0)"
  t_true "c4raven-updater was cloned into the given directory" -- test -f "$FH_DEST/install-fedhub.sh"
  t_eq "$(cat "$FH/out/env" 2>/dev/null | tr '\n' ' ')" \
       "RAVEN_DATA_DIR=/opt/raven/data RAVEN_DOMAIN=tak.example.org RAVEN_HOME=/opt/raven RAVEN_USER=raven " \
       "it gets RAVEN_USER/RAVEN_HOME/RAVEN_DATA_DIR/RAVEN_DOMAIN from install.sh's layout"
  t_eq "$(fh_args)" "--host tak.example.org " "with a domain and no artifact: just --host DOMAIN"
  t_eq "$FH_REST" "REST-OF-INSTALL-SH" "it does not read the inherited stdin (curl | bash: the rest of install.sh)"
  t_eq "$(cat "$FH/out/stdin")" "" "with no terminal its stdin is /dev/null (it skips non-interactively)"
  fh_run IH_ROOT="$FH/root-tty"
  t_eq "$(cat "$FH/out/stdin")" "typed-answer" "with a terminal its stdin is /dev/tty, so it can prompt"
  FH_DOMAIN="" fh_run
  t_hasnt "$(fh_args)" "--host" "no domain: no --host"
  t_true "no domain: RAVEN_DOMAIN is passed empty" -- grep -qx 'RAVEN_DOMAIN=' "$FH/out/env"
  fh_run RAVEN_FEDHUB_DEB=/srv/takserver-fed-hub_5.5_all.deb
  t_eq "$(fh_args)" "--artifact /srv/takserver-fed-hub_5.5_all.deb --host tak.example.org " \
       "legacy RAVEN_FEDHUB_DEB=PATH becomes --artifact PATH"
  fh_run RAVEN_FEDHUB_ARTIFACT=/srv/fedhub-docker.zip RAVEN_FEDHUB_DEB=/srv/old.deb
  t_eq "$(fh_args)" "--artifact /srv/fedhub-docker.zip --host tak.example.org " \
       "RAVEN_FEDHUB_ARTIFACT wins over RAVEN_FEDHUB_DEB"

  # --- its exit codes never fail the install ---
  fh_run FH_RC=2
  t_eq "$FH_GOT" 2 "install-fedhub.sh exit 2: skipped (2)"
  t_has "$FH_LOG" "Federation Hub skipped" "and says so"
  t_has "$FH_LOG" "git clone https://github.com/C4-Raven/c4raven-updater.git ~/c4raven-updater" "with the add-it-later guide"
  fh_run FH_RC=1
  t_eq "$FH_GOT" 1 "install-fedhub.sh exit 1: failed (1)"
  t_has "$FH_LOG" "Federation Hub setup failed (install-fedhub.sh exit 1)" "and says so"
  t_has "$FH_LOG" "./finish-install.sh also check for it" "with the guide"
  fh_run FH_RC=7
  t_eq "$FH_GOT" 1 "any other non-zero exit is a failure (1)"
  out=$(env -u RAVEN_FEDHUB_SKIP -u RAVEN_FEDHUB_DEB -u RAVEN_FEDHUB_ARTIFACT HOME="$FH/home" \
    UPDATER_REPO="file://$FH/updater" IH_ROOT="$FH/root-notty" FH_RC=1 \
    bash -c 'set -euo pipefail; trap "echo ERR-TRAP" ERR; . "$1"; FEDHUB_RC=0; ih_fedhub_step raven /opt/raven /opt/raven/data d "$2" < /dev/null || FEDHUB_RC=$?; echo "carried on with $FEDHUB_RC"' \
    _ "$LIB" "$FH/w/sete" 2>&1)
  t_has "$out" "carried on with 1" "under set -euo pipefail, install.sh's '|| FEDHUB_RC=\$?' call carries on"
  t_hasnt "$out" "ERR-TRAP" "and does not trip install.sh's ERR trap"

  # --- getting the installer ---
  fh_run UPDATER_REPO="file://$FH/no-such-repo"
  t_eq "$FH_GOT" 1 "clone fails and no other copy: failed (1), not fatal"
  t_has "$FH_LOG" "Could not download c4raven-updater" "says the download failed"
  t_has "$FH_LOG" "install-fedhub.sh --artifact" "and prints the guide"
  mkdir -p "$FH/home/c4raven-updater" && cp "$FH/updater/install-fedhub.sh" "$FH/home/c4raven-updater/"
  fh_run UPDATER_REPO="file://$FH/no-such-repo"
  t_eq "$FH_GOT" 0 "clone fails (offline): an existing ~/c4raven-updater copy is used instead"
  rm -rf "$FH/home/c4raven-updater"
  git clone -q "file://$FH/updater" "$FH/w/existing"
  rm -f "$FH/w/existing/install-fedhub.sh" && git -C "$FH/w/existing" commit -qam gone
  git -C "$FH/w/existing" remote set-url origin "file://$FH/no-such-repo"
  fh_run_existing() {
    printf '' | env -u RAVEN_FEDHUB_SKIP -u RAVEN_FEDHUB_DEB -u RAVEN_FEDHUB_ARTIFACT HOME="$FH/home" \
      UPDATER_REPO="file://$FH/no-such-repo" IH_ROOT="$FH/root-notty" \
      bash -c '. "$1"; rc=0; ih_fedhub_step raven /opt/raven /opt/raven/data "" "$2" || rc=$?; echo "RC=$rc"' _ "$LIB" "$FH/w/existing" 2>&1
  }
  out=$(fh_run_existing)
  t_has "$out" "RC=1" "an existing checkout without install-fedhub.sh (an old updater, diverged): failed, not fatal"
  t_has "$out" "using it as it is" "says the fast-forward did not happen"
  git -C "$FH/w/existing" reset -q --hard HEAD~1
  git -C "$FH/w/existing" remote set-url origin "file://$FH/updater"
  printf '%s\n' '#!/bin/bash' 'echo "updated installer"; exit 0' > "$FH/updater/install-fedhub.sh"
  git -C "$FH/updater" commit -qam update
  out=$(printf '' | env -u RAVEN_FEDHUB_SKIP -u RAVEN_FEDHUB_DEB -u RAVEN_FEDHUB_ARTIFACT HOME="$FH/home" \
      IH_ROOT="$FH/root-notty" bash -c '. "$1"; ih_fedhub_step raven /opt/raven /opt/raven/data "" "$2"; echo "RC=$?"' _ "$LIB" "$FH/w/existing" 2>&1)
  t_has "$out" "updated installer" "an existing checkout is fast-forwarded (git pull --ff-only) before use"
  t_has "$out" "RC=0" "and its result is reported"
else
  t_ok "git not installed -- Federation Hub step tests skipped"
fi

# --- install.sh's side of it (static: install.sh is never run here) ---
t_true "install.sh calls ih_fedhub_step with the Raven layout and the domain" -- \
  grep -q '^ih_fedhub_step "$APP_USER" "$APP_HOME" "$DATA_DIR" "$DOMAIN" "$INSTALLER_DIR/c4raven-updater" || FEDHUB_RC=\$?$' "$INS"
l_fh=$(line_of "$INS" '^ih_fedhub_step ')
l_up=$(line_of "$INS" 'api/health 2>/dev/null; then break')
l_admin=$(line_of "$INS" '^step "Hardening the first administrator account"')
[ -n "$l_fh" ] && [ -n "$l_up" ] && [ -n "$l_admin" ] && [ "$l_up" -lt "$l_fh" ] && [ "$l_fh" -lt "$l_admin" ] \
  && t_ok "the Federation Hub step runs after the services are up and before the admin-account step" \
  || t_no "the Federation Hub step runs after the services are up and before the admin-account step" "up $l_up, fedhub $l_fh, admin $l_admin"
t_false "install.sh no longer installs MongoDB or the .deb itself" -- \
  grep -Eq 'mongodb-org|pkg_install "\$FEDHUB|ask_yn "Do you already have a takserver' "$INS"
t_true "install.sh's health check only warns about Federation Hub" -- \
  bash -c "grep -q 'hc_warn \"Federation Hub setup failed' '$INS' && ! grep -q 'hc_fail \"Federation Hub' '$INS'"
t_true "install.sh repeats the add-it-later guide at the end when it was skipped or failed" -- \
  bash -c "tail -n 15 '$INS' | grep -q 'ih_fedhub_guide'"
t_true "install.sh keeps RAVEN_FEDHUB_ENABLE's default in .raven-secrets.env" -- \
  grep -q 'RAVEN_FEDHUB_ENABLE=$(secret_or RAVEN_FEDHUB_ENABLE False)' "$INS"
t_true "the install-sh matrix method skips Federation Hub (no TAK.gov artifact in CI)" -- \
  grep -q 'RAVEN_FEDHUB_SKIP=1 bash install.sh' "$REPO_DIR/tests/methods/install-sh.sh"

t_summary
