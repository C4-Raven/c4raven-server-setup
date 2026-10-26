#!/bin/bash
# Unit tests for lib/distro.sh -- the distro/arch shim every install path
# now goes through.
#
# No containers, no root, no network, no package manager: detect_distro()
# reads /etc/os-release and `uname -m` and nothing else, and every other
# function in the file is a pure function of the variables it sets. So the
# entire {Ubuntu, Debian, Rocky, Alma, RHEL} x {amd64, arm64} cross product
# is testable here in under a second, which is why this runs on every push
# while the container tier runs nightly.
#
# What this file is really guarding against is the single most likely bug in
# a Debian-to-EL port: a package name, a path or a service name from the
# wrong family leaking into the other family's branch. Those are invisible
# to `bash -n` and to shellcheck, and on the container tier they cost 40
# minutes to discover.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$HERE/../lib/assert.sh"
harness_paths
# shellcheck source=tests/lib/sandbox.sh
. "$HERE/../lib/sandbox.sh"

sandbox_init || { echo "could not create the sandbox" >&2; exit 1; }
trap sandbox_cleanup EXIT

# Not in a command substitution: sandbox_distro_shim sets DISTRO_SHIM, and a
# subshell would throw that away.
if ! sandbox_distro_shim 2>"$SANDBOX/shim.err"; then
  t_skip_all "$(cat "$SANDBOX/shim.err")"
fi

for f in ubuntu-24.04 ubuntu-22.04 debian-12 rocky-9 rocky-8 almalinux-9 \
         rhel-9 centos-9 fedora-41 alpine-3.20 empty; do
  os_fixture "$f"
done

# --- stub sets -------------------------------------------------------------
# `mutate`: everything that would change a real machine, replaced by a
# recorder. `sudo` is transparent (it logs, strips its own flags and any
# leading VAR=value, then execs) so that the pure-shell logic behind it --
# the pg_hba.conf rewrite, the `test -f` guards -- is genuinely exercised
# while every dangerous binary underneath is still a stub.
sandbox_stub sudo --in mutate <<'EOF'
#!/bin/sh
printf 'sudo' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
while [ $# -gt 0 ]; do
  case "$1" in
    -E|-H|-n|-k) shift ;;
    -u) shift 2 ;;
    *=*) shift ;;
    *) break ;;
  esac
done
[ $# -eq 0 ] && exit 0
exec "$@"
EOF
# Note what is NOT in `mutate`: firewall-cmd, ufw and getenforce. Their mere
# presence on PATH is what firewall_open and selinux_enforcing branch on, so
# each lives in its own opt-in set and a test says which machine it is on.
for b in apt dnf rpm systemctl ln postgresql-setup curl \
         setsebool semanage restorecon; do
  sandbox_recorder "$b" mutate
done
# dpkg is a recorder too, except for `--print-architecture`: detect_distro
# asks that on every source, and it is a read-only query, not a mutation.
# It answers $STUB_DPKG_ARCH when set; unset, it fails the way a dpkg with
# no answer does, so uname -m (the probe's machine) decides.
sandbox_stub dpkg --in mutate <<'EOF'
#!/bin/sh
if [ "${1:-}" = --print-architecture ]; then
  [ -n "${STUB_DPKG_ARCH:-}" ] || exit 1
  echo "$STUB_DPKG_ARCH"; exit 0
fi
printf 'dpkg' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
exit 0
EOF

# Opt-in "this machine has ..." sets.
sandbox_stub getenforce --in selinux-on  <<<'#!/bin/sh
echo Enforcing'
sandbox_stub getenforce --in selinux-off <<<'#!/bin/sh
echo Disabled'
sandbox_stub systemctl --in firewalld <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$CALL_LOG"
case "$*" in *"is-active"*firewalld*) exit 0 ;; esac
exit 0
EOF
sandbox_recorder firewall-cmd firewalld
sandbox_stub ufw --in ufw-on <<'EOF'
#!/bin/sh
printf 'ufw %s\n' "$*" >> "$CALL_LOG"
case "${1:-}" in status) echo "Status: active"; exit 0 ;; esac
exit 0
EOF
# A node that runs the REAL version gate in lib/distro.sh against a spoofed
# process.versions.node, so the thing under test is distro.sh's comparison
# and not a reimplementation of it here.
if [ -n "${SANDBOX_REAL_NODE:-}" ]; then
  sandbox_stub node --in node <<EOF
#!/bin/sh
case "\${1:-}" in
  -e|--eval)
    shift
    exec "$SANDBOX_REAL_NODE" -e "Object.defineProperty(process.versions,'node',{value:'\${STUB_NODE_VERSION:-0.0.0}'});\$1"
    ;;
  -v|--version) echo "v\${STUB_NODE_VERSION:-0.0.0}" ;;
  *) exec "$SANDBOX_REAL_NODE" "\$@" ;;
esac
EOF
fi

# ===========================================================================
echo "== sourcing and API surface"
# ===========================================================================
# install.sh runs under `set -euo pipefail` and sources this file; a stray
# unset variable or an unguarded non-zero at source time takes the installer
# down before it prints anything useful.
t_true "lib/distro.sh sources cleanly under set -euo pipefail" -- \
  probe_rc ubuntu-24.04 x86_64 'true'

missing=$(probe ubuntu-24.04 x86_64 '
  for f in detect_distro distro_supported pkg_refresh pkg_install \
           pkg_install_optional pkg_installed nginx_site_file nginx_stream_file \
           nginx_stream_include nginx_enable_site nginx_enable_stream nginx_remove_site \
           firewall_open selinux_enforcing selinux_fixup selinux_fix_webroot \
           selinux_fix_certs stack_packages stack_packages_optional \
           setup_extra_repos pg_init node_ok node_install; do
    declare -F "$f" >/dev/null || printf "%s " "$f"
  done')
t_eq "$missing" "" "every function the header documents is defined"

# detect_distro must not need a readable /etc/os-release to be *sourced*;
# the RPM scriptlets source this file and call detect_distro later.
t_true "sourcing does not run detect_distro" -- \
  probe_rc empty x86_64 'true'

# ===========================================================================
echo "== detect_distro: family, version, architecture"
# ===========================================================================
fam() { probe "$1" "${2:-x86_64}" 'echo "$DISTRO_FAMILY"'; }
t_eq "$(fam ubuntu-24.04)" debian "ubuntu 24.04 -> debian family"
t_eq "$(fam ubuntu-22.04)" debian "ubuntu 22.04 -> debian family"
t_eq "$(fam debian-12)"    debian "debian 12 (no ID_LIKE) -> debian family"
t_eq "$(fam rocky-9)"      rhel   "rocky 9 -> rhel family"
t_eq "$(fam rocky-8)"      rhel   "rocky 8 -> rhel family"
t_eq "$(fam almalinux-9)"  rhel   "almalinux 9 (ID_LIKE=rhel centos fedora) -> rhel family"
t_eq "$(fam rhel-9)"       rhel   "rhel 9 (ID=rhel) -> rhel family"
t_eq "$(fam centos-9)"     rhel   "centos stream 9 -> rhel family"
t_eq "$(fam fedora-41)"    rhel   "fedora (ID=fedora, no ID_LIKE) -> rhel family"
t_eq "$(fam alpine-3.20)"  unknown "alpine -> unknown family"

t_eq "$(probe rocky-9 x86_64 'echo "$DISTRO_ID/$DISTRO_VERSION_ID/$DISTRO_MAJOR"')" \
     "rocky/9.5/9" "rocky: ID, VERSION_ID and the derived major"
t_eq "$(probe ubuntu-24.04 x86_64 'echo "$DISTRO_MAJOR"')" "24" \
     "ubuntu 24.04 -> DISTRO_MAJOR=24 (not 24.04)"
t_eq "$(probe ubuntu-24.04 x86_64 'echo "$DISTRO_NAME"')" "Ubuntu" \
     "DISTRO_NAME is the pretty name"
t_eq "$(probe empty x86_64 'echo "$DISTRO_ID/$DISTRO_FAMILY"')" "unknown/unknown" \
     "an empty os-release degrades to unknown rather than erroring"

arch() { probe "$1" "$2" 'echo "$ARCH_DEB/$ARCH_MTX"'; }
t_eq "$(arch ubuntu-24.04 x86_64)"  "amd64/amd64" "x86_64  -> ARCH_DEB=amd64 ARCH_MTX=amd64"
t_eq "$(arch ubuntu-24.04 aarch64)" "arm64/arm64" "aarch64 -> ARCH_DEB=arm64 ARCH_MTX=arm64"
t_eq "$(arch rocky-9 aarch64)"      "arm64/arm64" "aarch64 maps the same way on EL"
t_eq "$(arch ubuntu-24.04 arm64)"   "arm64/arm64" "uname -m 'arm64' is accepted too"
# The two spellings diverge only below 64-bit; this is the assertion that
# catches someone 'simplifying' ARCH_MTX away into ARCH_DEB.
t_eq "$(arch ubuntu-22.04 armv7l)"  "armhf/armv7" "armv7l -> dpkg armhf but mediamtx armv7"

# dpkg outranks uname: a 32-bit armhf userland on a 64-bit kernel (stock
# Raspberry Pi OS) has uname say aarch64, and the arm64 build won't run.
t_eq "$(PROBE_PATH=mutate STUB_DPKG_ARCH=armhf arch ubuntu-22.04 aarch64)" "armhf/armv7" \
     "dpkg armhf on an aarch64 kernel -> armhf/armv7, not arm64"
t_eq "$(PROBE_PATH=mutate STUB_DPKG_ARCH=arm64 arch ubuntu-24.04 aarch64)" "arm64/arm64" \
     "dpkg arm64 agrees with uname aarch64"
t_has "$(PROBE_PATH=mutate STUB_DPKG_ARCH=riscv64 probe ubuntu-24.04 x86_64 true 2>&1)" \
      "no Linux build for riscv64" \
      "riscv64 is refused by name, not handed the armv7 build by a catch-all"

t_eq "$(probe ubuntu-24.04 x86_64 'echo "$PKG_MGR"')" apt "debian family -> apt"
t_eq "$(probe rocky-9     x86_64 'echo "$PKG_MGR"')" dnf "rhel family -> dnf"
t_eq "$(probe alpine-3.20 x86_64 'echo "$PKG_MGR"')" apt \
     "an unknown family falls back to the debian defaults (documented behaviour)"

t_eq "$(probe ubuntu-24.04 x86_64 'echo "$NGINX_USER/$PG_SERVICE/$RABBIT_SERVICE"')" \
     "www-data/postgresql/rabbitmq-server" "debian: nginx user and service names"
t_eq "$(probe rocky-9 x86_64 'echo "$NGINX_USER/$PG_SERVICE/$RABBIT_SERVICE"')" \
     "nginx/postgresql/rabbitmq-server" "rhel: nginx runs as 'nginx', not www-data"
t_eq "$(probe rocky-9 x86_64 'echo "$PG_DATA_DIR"')" "/var/lib/pgsql/data" \
     "rhel: PGDATA is where postgresql-setup --initdb puts it"
t_eq "$(probe ubuntu-24.04 x86_64 'echo "[$PG_DATA_DIR]"')" "[]" \
     "debian: PG_DATA_DIR is deliberately empty (per-cluster layout)"

# ===========================================================================
echo "== distro_supported"
# ===========================================================================
t_true  "ubuntu 24.04 is supported"   -- probe_rc ubuntu-24.04 x86_64 'distro_supported'
t_true  "debian 12 is supported"      -- probe_rc debian-12    x86_64 'distro_supported'
t_true  "rocky 9 is supported"        -- probe_rc rocky-9      x86_64 'distro_supported'
t_true  "almalinux 9 is supported"    -- probe_rc almalinux-9  x86_64 'distro_supported'
t_false "rocky 8 is NOT supported"    -- probe_rc rocky-8      x86_64 'distro_supported'
t_false "alpine is NOT supported"     -- probe_rc alpine-3.20  x86_64 'distro_supported'
t_false "an empty os-release is NOT supported" -- probe_rc empty x86_64 'distro_supported'

# ===========================================================================
echo "== nginx layout"
# ===========================================================================
# EL nginx has no sites-available/sites-enabled: /etc/nginx/conf.d/*.conf is
# included from inside http{} directly. Getting this wrong produces an nginx
# that starts perfectly and serves nothing, which is the worst failure mode
# in the whole port.
t_eq "$(probe ubuntu-24.04 x86_64 'nginx_site_file raven_https')" \
     "/etc/nginx/sites-available/raven_https" "debian: site file path, no suffix"
t_eq "$(probe rocky-9 x86_64 'nginx_site_file raven_https')" \
     "/etc/nginx/conf.d/raven_https.conf" "rhel: site file lands in conf.d WITH .conf"
t_eq "$(probe ubuntu-24.04 x86_64 'nginx_stream_file rabbitmq')" \
     "/etc/nginx/streams-available/rabbitmq" "debian: stream file path"
t_eq "$(probe rocky-9 x86_64 'nginx_stream_file rabbitmq')" \
     "/etc/nginx/stream.d/rabbitmq.conf" "rhel: stream file path"
t_eq "$(probe ubuntu-24.04 x86_64 'nginx_stream_include')" \
     "/etc/nginx/streams-enabled/*" "debian: stream include globs the enabled dir"
t_eq "$(probe rocky-9 x86_64 'nginx_stream_include')" \
     "/etc/nginx/stream.d/*.conf" "rhel: stream include must carry the .conf suffix"

# The suffix and the include glob have to agree or nginx silently includes
# nothing -- an nginx that starts fine and proxies nothing. Assert the
# relationship, not just the two strings, because the two families get there
# by different routes: EL's stream file IS the included file, while Debian's
# is reached through the streams-enabled symlink nginx_enable_stream makes.
rhel_file=$(probe rocky-9 x86_64 'nginx_stream_file rabbitmq')
rhel_glob=$(probe rocky-9 x86_64 'nginx_stream_include')
# shellcheck disable=SC2254  # the glob is the point
case "$rhel_file" in
  $rhel_glob) t_ok "rhel: nginx_stream_file output is itself matched by nginx_stream_include" ;;
  *) t_no "rhel: nginx_stream_file output is matched by nginx_stream_include" \
          "file=$rhel_file glob=$rhel_glob" ;;
esac
deb_glob=$(probe ubuntu-24.04 x86_64 'nginx_stream_include')
deb_endir=$(probe ubuntu-24.04 x86_64 'echo "$NGINX_STREAMS_ENABLED_DIR"')
t_eq "$deb_glob" "$deb_endir/*" \
     "debian: nginx_stream_include globs exactly the directory nginx_enable_stream links into"

PROBE_PATH=mutate
sandbox_log_reset
probe ubuntu-24.04 x86_64 'nginx_enable_site raven_http' >/dev/null
t_has "$(sandbox_log)" "ln -sf /etc/nginx/sites-available/raven_http /etc/nginx/sites-enabled/" \
      "debian: nginx_enable_site creates the sites-enabled symlink"

sandbox_log_reset
probe rocky-9 x86_64 'nginx_enable_site raven_http' >/dev/null
t_eq "$(sandbox_log)" "" "rhel: nginx_enable_site is a no-op (conf.d is already included)"
t_true "rhel: nginx_enable_site still returns 0" -- \
  probe_rc rocky-9 x86_64 'nginx_enable_site raven_http'

sandbox_log_reset
probe ubuntu-24.04 x86_64 'nginx_enable_stream mediamtx' >/dev/null
t_has "$(sandbox_log)" "ln -sf /etc/nginx/streams-available/mediamtx /etc/nginx/streams-enabled/" \
      "debian: nginx_enable_stream creates the streams-enabled symlink"
sandbox_log_reset
probe rocky-9 x86_64 'nginx_enable_stream mediamtx' >/dev/null
t_eq "$(sandbox_log)" "" "rhel: nginx_enable_stream is a no-op"

# nginx_remove_site is how install.sh takes the 8446 domain block out of
# certbot's sight before every certbot run. On Debian it must take the
# sites-enabled symlink too, or nginx is left including a dangling path.
# rm gets its own opt-in recorder set: the transparent sudo stub would
# otherwise exec the real rm against this machine's /etc/nginx.
sandbox_recorder rm rmrec
PROBE_PATH=mutate:rmrec
sandbox_log_reset
probe ubuntu-24.04 x86_64 'nginx_remove_site raven_certificate_enrollment_domain' >/dev/null
t_has "$(sandbox_log)" "rm -f /etc/nginx/sites-enabled/raven_certificate_enrollment_domain" \
      "debian: nginx_remove_site removes the sites-enabled symlink"
t_has "$(sandbox_log)" "rm -f /etc/nginx/sites-available/raven_certificate_enrollment_domain" \
      "debian: nginx_remove_site removes the site file"
sandbox_log_reset
probe rocky-9 x86_64 'nginx_remove_site raven_certificate_enrollment_domain' >/dev/null
t_has "$(sandbox_log)" "rm -f /etc/nginx/conf.d/raven_certificate_enrollment_domain.conf" \
      "rhel: nginx_remove_site removes the conf.d file, .conf suffix and all"
t_hasnt "$(sandbox_log)" "sites-enabled" "rhel: nginx_remove_site never touches a sites-enabled dir"
PROBE_PATH=mutate

# Port 8446's default server is "the first block nginx loads for the port",
# not an explicit default_server (see nginx_configs/raven_certificate_
# enrollment for why). nginx loads an include glob in C-locale byte order, so
# the base file must sort ahead of the domain file in BOTH layouts.
for d in ubuntu-24.04 rocky-9; do
  base=$(probe "$d" x86_64 'nginx_site_file raven_certificate_enrollment')
  dom=$(probe "$d" x86_64 'nginx_site_file raven_certificate_enrollment_domain')
  first=$(printf '%s\n%s\n' "$dom" "$base" | LC_ALL=C sort | head -1)
  t_eq "$first" "$base" "$d: raven_certificate_enrollment sorts before the _domain file (stays 8446's default)"
done
unset PROBE_PATH

# ===========================================================================
echo "== package names"
# ===========================================================================
deb_pkgs=" $(probe ubuntu-24.04 x86_64 'echo $(stack_packages)') "
rhel_pkgs=" $(probe rocky-9 x86_64 'echo $(stack_packages)') "
opt_rhel=" $(probe rocky-9 x86_64 'echo $(stack_packages_optional)') "

# Both lists are checked by CAPABILITY, not by exact spelling: the exact
# names are still being tuned (python3.12 vs python3 on EL, ffmpeg-free vs
# ffmpeg) and a test that pins them turns every legitimate edit red. What
# must not drift is that each family still covers every capability, and that
# neither family has picked up the other's vocabulary.
need_cap() { # need_cap LIST ERE DESCRIPTION
  t_match "$1" "(^| )$2( |$)" "$3"
}
for spec in \
  'curl:curl' 'git:git' 'openssl:openssl' 'rsync:rsync' \
  'a python interpreter:python3[0-9.]*' \
  'pip:python3[0-9.]*-pip' \
  'a PyYAML binding:(python3[0-9.]*-yaml|python3[0-9.]*-pyyaml)' \
  'nginx:nginx' \
  'certbot:certbot' 'the certbot nginx plugin:python3-certbot-nginx' \
  'rabbitmq:rabbitmq-server'; do
  need_cap "$deb_pkgs"  "${spec#*:}" "debian list provides ${spec%%:*}"
  need_cap "$rhel_pkgs" "${spec#*:}" "rhel list provides ${spec%%:*}"
done
need_cap "$deb_pkgs"  'libnginx-mod-stream' "debian list provides the nginx stream module"
need_cap "$rhel_pkgs" 'nginx-mod-stream'    "rhel list provides the nginx stream module"
need_cap "$deb_pkgs"  'postgresql'          "debian list provides the postgres server"
need_cap "$rhel_pkgs" 'postgresql-server'   "rhel list provides the postgres server"
need_cap "$deb_pkgs"  'build-essential'     "debian list provides a C toolchain (mutf8/unishox2 build from sdist)"
need_cap "$rhel_pkgs" 'gcc'                 "rhel list provides a C compiler"
need_cap "$rhel_pkgs" 'gcc-c\+\+'           "rhel list provides a C++ compiler"
need_cap "$rhel_pkgs" 'make'                "rhel list provides make"
need_cap "$deb_pkgs"  'python3[0-9.]*-dev'  "debian list provides the Python headers"
need_cap "$rhel_pkgs" 'python3[0-9.]*-devel' "rhel list provides the Python headers"
need_cap "$rhel_pkgs" 'policycoreutils-python-utils' \
         "rhel list provides semanage (selinux_fixup is useless without it)"

# Cross-contamination. These are the assertions that earn this whole file:
# a Debian spelling in the EL list fails `dnf install` 30 minutes into a
# container run, and fails it on a customer's machine the same way.
for p in build-essential libnginx-mod-stream python3-venv python3-dev \
         python3-yaml postgresql-postgis dpkg-dev apt-utils; do
  t_hasnt "$rhel_pkgs$opt_rhel" " $p " "rhel list does NOT carry the debian spelling $p"
done
for p in gcc-c++ python3-devel python3-pyyaml nginx-mod-stream \
         postgresql-server policycoreutils-python-utils rpm-build \
         python3.12 libpq-devel; do
  t_hasnt "$deb_pkgs" " $p " "debian list does NOT carry the rhel spelling $p"
done
# Deliberately dropped: nothing in any C4 Raven repo invokes pgloader.
t_hasnt "$deb_pkgs$rhel_pkgs" " pgloader " "pgloader is not reintroduced"

# ffmpeg and postgis exist on EL only via RPM Fusion / EPEL-free / PGDG, so
# they must be optional there and never a hard requirement.
case "$rhel_pkgs" in
  *" ffmpeg "*|*" ffmpeg-free "*)
    t_no "rhel list does not hard-require ffmpeg" "EL AppStream has no usable ffmpeg; it belongs in stack_packages_optional" ;;
  *) t_ok "rhel list does not hard-require ffmpeg (no EL AppStream package)" ;;
esac
t_hasnt "$rhel_pkgs" " postgis " "rhel list does not hard-require postgis (PGDG only)"
t_match "$opt_rhel" '(^| )ffmpeg' "rhel optional list names an ffmpeg (ffmpeg or ffmpeg-free)"
t_has "$opt_rhel" " postgis " "rhel optional list has postgis"
t_eq "$(probe ubuntu-24.04 x86_64 'echo $(stack_packages_optional)')" "" \
     "debian has no optional packages -- everything is in main/universe"

# rabbitmq-server is not in EPEL; it comes from the repo setup_extra_repos
# wires up. It still has to be named, or verify.sh's rabbitmq-server
# assertion fails on Rocky for a reason nobody will connect to this list.
t_has "$rhel_pkgs$opt_rhel" " rabbitmq-server " \
      "rhel names rabbitmq-server (it comes from rabbitmq.com's repo, not EPEL)"

# PYTHON_BIN: EL9's `python3` is 3.9, which the backend does not support, so
# the shim picks an explicit interpreter. Whatever it picks must be the same
# family as the python packages it installs, or the venv is built with an
# interpreter that has no headers.
pybin_deb=$(probe ubuntu-24.04 x86_64 'echo "${PYTHON_BIN:-unset}"')
pybin_rhel=$(probe rocky-9 x86_64 'echo "${PYTHON_BIN:-unset}"')
if [ "$pybin_deb" = unset ] && [ "$pybin_rhel" = unset ]; then
  t_ok "PYTHON_BIN is not part of the shim's API (skipping its checks)"
else
  t_eq "$pybin_deb" "python3" "debian PYTHON_BIN is plain python3"
  t_match "$pybin_rhel" '^python3\.[0-9]+$' \
          "rhel PYTHON_BIN pins an explicit minor version (EL9's python3 is 3.9, which the backend does not support)"
  t_has "$rhel_pkgs" " $pybin_rhel " \
        "rhel installs the very interpreter PYTHON_BIN names ($pybin_rhel)"
  t_has "$rhel_pkgs" " $pybin_rhel-devel " \
        "rhel installs the matching $pybin_rhel-devel headers"
fi

# ===========================================================================
echo "== package manager dispatch"
# ===========================================================================
PROBE_PATH=mutate
sandbox_log_reset
probe ubuntu-24.04 x86_64 'pkg_install nginx openssl' >/dev/null
log=$(sandbox_log)
t_has "$log" "apt install -y nginx openssl" "debian pkg_install shells out to apt"
t_has "$log" "NEEDRESTART_MODE=a" "debian pkg_install sets NEEDRESTART_MODE=a (else apt blocks on a prompt)"
t_hasnt "$log" " dnf " "debian pkg_install never touches dnf"
t_has "$log" "Dpkg::Options::=--force-confold" "debian pkg_install keeps modified conffiles without asking (--force-confold)"
t_has "$log" "Dpkg::Options::=--force-confdef" "debian pkg_install takes dpkg's default where there is one (--force-confdef)"
t_true "every apt call goes through apt_noninteractive (stdin from /dev/null)" -- \
  bash -c "! grep -nE '(^|[^_[:alnum:]])apt (install|update|upgrade)' '$REPO_DIR/lib/distro.sh' '$REPO_DIR/install.sh' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -q ."
t_true "apt_noninteractive reads stdin from /dev/null" -- \
  grep -q 'force-confold </dev/null' "$REPO_DIR/lib/distro.sh"

sandbox_log_reset
probe rocky-9 x86_64 'pkg_install nginx openssl' >/dev/null
log=$(sandbox_log)
t_has "$log" "dnf install -y nginx openssl" "rhel pkg_install shells out to dnf"
t_hasnt "$log" " apt " "rhel pkg_install never touches apt"

sandbox_log_reset
probe ubuntu-24.04 x86_64 'pkg_refresh' >/dev/null
log=$(sandbox_log)
t_has "$log" "apt update" "debian pkg_refresh runs apt update"
t_has "$log" "apt upgrade -y" "debian pkg_refresh runs apt upgrade"
t_has "$log" "apt upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold" \
      "debian pkg_refresh's upgrade never stops at a conffile prompt"
sandbox_log_reset
probe rocky-9 x86_64 'pkg_refresh' >/dev/null
t_has "$(sandbox_log)" "dnf -y upgrade --refresh" "rhel pkg_refresh runs dnf upgrade --refresh"

sandbox_log_reset
probe ubuntu-24.04 x86_64 'pkg_installed nginx' >/dev/null
t_has "$(sandbox_log)" "dpkg -s nginx" "debian pkg_installed queries dpkg"
sandbox_log_reset
probe rocky-9 x86_64 'pkg_installed nginx' >/dev/null
t_has "$(sandbox_log)" "rpm -q nginx" "rhel pkg_installed queries rpm"
unset PROBE_PATH

# pkg_installed must report absence as a non-zero exit, not a crash.
sandbox_recorder dpkg absent-pkg 1
sandbox_recorder rpm  absent-pkg 1
PROBE_PATH=absent-pkg:mutate
t_false "debian pkg_installed returns non-zero when dpkg says no" -- \
  probe_rc ubuntu-24.04 x86_64 'pkg_installed nosuchthing'
t_false "rhel pkg_installed returns non-zero when rpm says no" -- \
  probe_rc rocky-9 x86_64 'pkg_installed nosuchthing'
unset PROBE_PATH

# ===========================================================================
echo "== PostgreSQL initialisation"
# ===========================================================================
PROBE_PATH=mutate
sandbox_log_reset
probe ubuntu-24.04 x86_64 'pg_init' >/dev/null
log=$(sandbox_log)
t_hasnt "$log" "postgresql-setup" "debian pg_init does NOT run postgresql-setup (the cluster already exists)"
t_has "$log" "systemctl enable postgresql" "debian pg_init enables postgresql"
t_has "$log" "systemctl start postgresql"  "debian pg_init starts postgresql"

sandbox_log_reset
probe rocky-9 x86_64 'pg_init' >/dev/null
log=$(sandbox_log)
t_has "$log" "postgresql-setup --initdb" "rhel pg_init runs postgresql-setup --initdb on an empty PGDATA"

# Re-run: PG_VERSION exists but sits in a 0700 postgres-owned directory, so
# the check has to go through sudo or install.sh's user never sees it.
sandbox_log_reset
probe rocky-9 x86_64 '
  PG_DATA_DIR="$SANDBOX/pgdata-rerun"; mkdir -p "$PG_DATA_DIR"
  touch "$PG_DATA_DIR/PG_VERSION"
  pg_init' >/dev/null
log=$(sandbox_log)
t_hasnt "$log" "postgresql-setup" "rhel pg_init does NOT initdb again when PG_VERSION exists"
t_has "$log" "sudo test -f" "rhel pg_init checks PG_VERSION through sudo (PGDATA is 0700 postgres)"
t_has "$log" "systemctl enable postgresql" "rhel pg_init enables postgresql"

# The pg_hba.conf rewrite, run for real against a scratch copy of the file EL
# actually generates. Without it the app's 127.0.0.1 password URI is rejected
# by `ident` and every service crash-loops on "Ident authentication failed",
# long after the installer has reported success.
hba=$(probe rocky-9 x86_64 '
  PG_DATA_DIR="$SANDBOX/pgdata"; mkdir -p "$PG_DATA_DIR"
  touch "$PG_DATA_DIR/PG_VERSION"
  cat > "$PG_DATA_DIR/pg_hba.conf" <<X
local   all             all                                     peer
host    all             all             127.0.0.1/32            ident
host    all             all             ::1/128                 ident
X
  pg_init >/dev/null 2>&1
  cat "$PG_DATA_DIR/pg_hba.conf"')
t_match "$hba" '^host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+md5$' \
        "rhel pg_init switches the IPv4 host line from ident to md5 (PG 13 stores md5 passwords)"
t_match "$hba" '::1/128[[:space:]]+md5' \
        "rhel pg_init switches the IPv6 host line too"
t_match "$hba" '^local[[:space:]]+all[[:space:]]+all[[:space:]]+peer$' \
        "rhel pg_init leaves the local/peer line alone (install.sh's sudo -u postgres psql depends on it)"

# Idempotence: install.sh is documented as safe to re-run.
hba2=$(probe rocky-9 x86_64 '
  PG_DATA_DIR="$SANDBOX/pgdata2"; mkdir -p "$PG_DATA_DIR"
  touch "$PG_DATA_DIR/PG_VERSION"
  printf "host    all  all  127.0.0.1/32  scram-sha-256\n" > "$PG_DATA_DIR/pg_hba.conf"
  pg_init >/dev/null 2>&1; pg_init >/dev/null 2>&1
  cat "$PG_DATA_DIR/pg_hba.conf"')
t_eq "$hba2" "host    all  all  127.0.0.1/32  scram-sha-256" \
     "rhel pg_init leaves a scram-sha-256 host line alone"
hba3=$(probe rocky-9 x86_64 '
  PG_DATA_DIR="$SANDBOX/pgdata3"; mkdir -p "$PG_DATA_DIR"
  touch "$PG_DATA_DIR/PG_VERSION"
  printf "host    all  all  127.0.0.1/32  ident\n" > "$PG_DATA_DIR/pg_hba.conf"
  pg_init >/dev/null 2>&1; pg_init >/dev/null 2>&1
  cat "$PG_DATA_DIR/pg_hba.conf"')
t_eq "$hba3" "host    all  all  127.0.0.1/32  md5" \
     "rhel pg_init is idempotent across re-runs"
unset PROBE_PATH

# ===========================================================================
echo "== third-party repositories"
# ===========================================================================
PROBE_PATH=mutate
sandbox_log_reset
t_true "setup_extra_repos is a no-op on debian" -- \
  probe_rc ubuntu-24.04 x86_64 'setup_extra_repos'
t_eq "$(sandbox_log)" "" "setup_extra_repos runs nothing at all on debian"

sandbox_log_reset
probe rocky-9 x86_64 'setup_extra_repos' >/dev/null 2>&1
log=$(sandbox_log)
t_has "$log" "epel-release" \
      "rhel setup_extra_repos falls back to installing epel-release when no helper script is given"
t_match "$log" 'config-manager --set-enabled (crb|powertools)' \
      "...and enables CRB/PowerTools, where the -devel packages live"

# The documented form: hand it rpm/c4raven-el9-repos.sh and it runs that
# instead, so the baseurls live in one place.
sandbox_log_reset
probe rocky-9 x86_64 '
  printf "#!/bin/sh\necho ran-the-helper\n" > "$SANDBOX/repos.sh"
  setup_extra_repos "$SANDBOX/repos.sh"' >/dev/null 2>&1
t_has "$(sandbox_log)" "sudo bash $SANDBOX/repos.sh" \
      "rhel setup_extra_repos defers to the helper script when one is supplied"
unset PROBE_PATH

if [ -f "$REPO_DIR/rpm/c4raven-el9-repos.sh" ]; then
  t_ok "rpm/c4raven-el9-repos.sh exists (setup_extra_repos' documented argument)"
else
  t_no "rpm/c4raven-el9-repos.sh exists" "setup_extra_repos documents it as the single source of truth for EL repo URLs"
fi

# ===========================================================================
echo "== firewall"
# ===========================================================================
# No firewall tool on PATH at all -- the normal case on Ubuntu Server and
# always the case in a container.
sandbox_log_reset
t_true "firewall_open succeeds when no firewall tool exists" -- \
  probe_rc ubuntu-24.04 x86_64 'firewall_open 443/tcp 8089/tcp'
t_eq "$(sandbox_log)" "" "firewall_open does nothing when no firewall tool exists"

PROBE_PATH=firewalld:mutate
sandbox_log_reset
probe rocky-9 x86_64 'firewall_open 443/tcp 8189/udp' >/dev/null 2>&1
log=$(sandbox_log)
t_has "$log" "firewall-cmd --permanent --add-port=443/tcp" "firewalld: adds 443/tcp"
t_has "$log" "firewall-cmd --permanent --add-port=8189/udp" "firewalld: adds 8189/udp"
t_has "$log" "firewall-cmd --reload" "firewalld: reloads so the permanent rules take effect"
t_hasnt "$log" "systemctl start firewalld" "firewall_open never starts a firewall that is off"
t_hasnt "$log" "firewall-cmd --set-default-zone" "firewall_open only ever adds allow rules"
unset PROBE_PATH

PROBE_PATH=ufw-on:mutate
sandbox_log_reset
probe ubuntu-24.04 x86_64 'firewall_open 443/tcp' >/dev/null 2>&1
log=$(sandbox_log)
t_has "$log" "ufw allow 443/tcp" "ufw: adds 443/tcp when ufw reports Status: active"
t_hasnt "$log" "ufw enable" "firewall_open never enables ufw (it would drop the installing SSH session)"
unset PROBE_PATH

# ===========================================================================
echo "== SELinux"
# ===========================================================================
PROBE_PATH=selinux-on:mutate
t_false "selinux_enforcing is false on debian even with getenforce saying Enforcing" -- \
  probe_rc ubuntu-24.04 x86_64 'selinux_enforcing'
t_true  "selinux_enforcing is true on rhel with getenforce=Enforcing" -- \
  probe_rc rocky-9 x86_64 'selinux_enforcing'

sandbox_log_reset
probe rocky-9 x86_64 'selinux_fixup' >/dev/null 2>&1
log=$(sandbox_log)
t_has "$log" "setsebool -P httpd_can_network_connect 1" \
      "selinux_fixup lets nginx proxy to the backend (without it every proxy_pass 502s)"
# The ports that genuinely need labelling, and the only ones worth asserting:
# nginx cannot name_bind them under the stock targeted policy otherwise.
# rpm/configure.sh labels exactly these four and explains why the other two
# in lib/distro.sh's list are not needed -- 8080 is already http_cache_port_t
# and 8443 is already http_port_t, so `semanage port -a` against them fails
# and is swallowed by `|| true`.
#
# So assert the four that must be there, and do NOT assert the two no-ops:
# pinning them would turn a harmless redundancy into a requirement and make
# removing it look like a regression.
SELINUX_REQUIRED_PORTS="8446 8322 1936 8883"
for p in $SELINUX_REQUIRED_PORTS; do
  t_has "$log" "semanage port -a -t http_port_t -p tcp $p" \
        "selinux_fixup labels port $p http_port_t (nginx cannot bind it otherwise)"
done

# Drift guard: the rpm path and the shared shim must not disagree about which
# ports need labelling. Anything rpm/configure.sh labels must also be labelled
# by selinux_fixup, or a Rocky install done through the shim is missing it.
if [ -f "$REPO_DIR/rpm/configure.sh" ]; then
  rpm_ports=$(sed -n 's/^ *for p in \(\([0-9]\+ *\)\+\); do$/\1/p' "$REPO_DIR/rpm/configure.sh" \
              | tr ' ' '\n' | grep -E '^(8446|8322|1936|8883|8080|8443)$' | sort -u | tr '\n' ' ')
  if [ -z "$rpm_ports" ]; then
    t_no "rpm/configure.sh's semanage port list could be read" \
         "the loop's shape changed -- re-point this drift guard at it"
  else
    missing=""
    for p in $rpm_ports; do
      case " $log " in *"http_port_t -p tcp $p"*) ;; *) missing="$missing $p" ;; esac
    done
    t_eq "$missing" "" \
         "every port rpm/configure.sh labels is also labelled by selinux_fixup"
  fi
fi

sandbox_log_reset
probe rocky-9 x86_64 '
  WEBROOT="$SANDBOX/webroot"; mkdir -p "$WEBROOT"
  selinux_fixup' >/dev/null 2>&1
log=$(sandbox_log)
t_has "$log" "semanage fcontext -a -t httpd_sys_content_t $SANDBOX/webroot(/.*)?" \
      "selinux_fixup relabels \$WEBROOT when one is set"
t_has "$log" "restorecon -R $SANDBOX/webroot" "selinux_fixup runs restorecon on the webroot"

sandbox_log_reset
probe rocky-9 x86_64 '
  mkdir -p "$SANDBOX/certs"
  selinux_fix_certs "$SANDBOX/certs"' >/dev/null 2>&1
t_has "$(sandbox_log)" "semanage fcontext -a -t cert_t $SANDBOX/certs(/.*)?" \
      "selinux_fix_certs labels the CA directory cert_t (nginx cannot read /opt otherwise)"

t_true "selinux_fix_webroot on a directory that does not exist is a no-op, not an error" -- \
  probe_rc rocky-9 x86_64 'selinux_fix_webroot /no/such/dir'
unset PROBE_PATH

PROBE_PATH=selinux-off:mutate
t_false "selinux_enforcing is false when getenforce says Disabled" -- \
  probe_rc rocky-9 x86_64 'selinux_enforcing'
sandbox_log_reset
probe rocky-9 x86_64 'selinux_fixup' >/dev/null 2>&1
t_eq "$(sandbox_log)" "" "selinux_fixup does nothing when SELinux is disabled"
unset PROBE_PATH

PROBE_PATH=mutate
t_false "selinux_enforcing is false when getenforce is not installed at all" -- \
  probe_rc rocky-9 x86_64 'selinux_enforcing'
t_true "selinux_fixup returns 0 on debian" -- probe_rc ubuntu-24.04 x86_64 'selinux_fixup'
unset PROBE_PATH

# ===========================================================================
echo "== Node.js version gate"
# ===========================================================================
# vite 8 needs Node 20.19+ or 22.12+. Ubuntu 24.04 ships 18.x; EL 9's module
# streams top out below that too. An off-by-one here means the UI build dies
# three-quarters of the way through an install.
if [ -z "${SANDBOX_REAL_NODE:-}" ]; then
  t_ok "node version gate SKIPPED -- no node on this machine to run the real check against"
else
  PROBE_PATH=node:mutate
  check_node() { # version, expect ok|no
    export STUB_NODE_VERSION=$1
    if [ "$2" = ok ]; then
      t_true "node $1 satisfies the UI build requirement" -- probe_rc ubuntu-24.04 x86_64 'node_ok'
    else
      t_false "node $1 is rejected" -- probe_rc ubuntu-24.04 x86_64 'node_ok'
    fi
    unset STUB_NODE_VERSION
  }
  check_node 18.20.4 no
  check_node 20.18.3 no
  check_node 20.19.0 ok
  check_node 20.19.4 ok
  check_node 21.7.3  no
  check_node 22.11.0 no
  check_node 22.12.0 ok
  check_node 24.3.0  ok
  unset PROBE_PATH

  # node_install must short-circuit when node is already good enough, and use
  # the right NodeSource flavour when it is not.
  PROBE_PATH=node:mutate
  export STUB_NODE_VERSION=22.12.0
  sandbox_log_reset
  probe ubuntu-24.04 x86_64 'node_install' >/dev/null 2>&1
  t_eq "$(sandbox_log)" "" "node_install is a no-op when node is already new enough"
  unset STUB_NODE_VERSION
  unset PROBE_PATH
fi

PROBE_PATH=mutate   # no node on PATH at all -> must install one
sandbox_log_reset
probe ubuntu-24.04 x86_64 'node_install' >/dev/null 2>&1
log=$(sandbox_log)
t_has "$log" "deb.nodesource.com/setup_22.x" "debian node_install uses the deb NodeSource script"
t_has "$log" "apt install -y nodejs" "debian node_install installs nodejs with apt"
sandbox_log_reset
probe rocky-9 x86_64 'node_install' >/dev/null 2>&1
log=$(sandbox_log)
t_has "$log" "rpm.nodesource.com/setup_22.x" "rhel node_install uses the rpm NodeSource script"
t_has "$log" "dnf install -y nodejs" "rhel node_install installs nodejs with dnf"
t_hasnt "$log" "deb.nodesource.com" "rhel node_install does not reach for the deb script"
unset PROBE_PATH

t_summary
