# c4raven-server.spec -- the Enterprise Linux 9 counterpart of debian/control
# and debian/c4raven-server.{postinst,prerm,postrm}.
#
# Built by rpm/build-rpm.sh, which stages a package tree exactly the way
# build-deb.sh does and hands it to rpmbuild as Source0. There is no
# compilation at package-build time: the backend's venv is built on the *target*
# machine by %post, matching install.sh and the .deb.
#
# Two shapes, same spec:
#   * default            -> noarch, mirrors `Architecture: all`
#   * --with offline     -> arch-specific (x86_64 / aarch64), mirrors the
#                           .deb's `Architecture: amd64` offline variant

%bcond_with offline

# %%{_unitdir} comes from systemd-rpm-macros, which a Debian-hosted rpmbuild
# (see build-rpm.sh) may not have; build-rpm.sh stages the units here.
%{!?_unitdir:%global _unitdir /usr/lib/systemd/system}
%global pkgdata    %{_datadir}/c4raven-server

# The offline payload is prebuilt binaries: wheels (ELF .so inside), the
# mediamtx static binary, an APK. Nothing in here is ours to strip, mangle or
# generate dependencies from, and rpmbuild would do all three by default.
%global debug_package %{nil}
%global __brp_strip %{nil}
%global __brp_strip_static_archive %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_mangle_shebangs %{nil}
%global __requires_exclude_from ^%{pkgdata}/offline/.*$
%global __provides_exclude_from ^%{pkgdata}/offline/.*$

# xz at the default level, matching build-deb.sh's `dpkg-deb -Zxz`: the wheels
# and APK are already compressed and -9 roughly doubles build time for a
# percent or two.
%global _binary_payload w6.xzdio

Name:           c4raven-server
Version:        %{?pkg_version}%{!?pkg_version:0.0.0}
Release:        1%{?dist}
Summary:        C4 Raven TAK server -- full stack, single package
License:        Proprietary
URL:            https://github.com/C4-Raven/c4raven-server-setup
Source0:        %{name}-%{version}-stage.tar.gz

%if %{without offline}
BuildArch:      noarch
%endif

# --- hard runtime requirements --------------------------------------------
# Translated from debian/control. Package name differences are flagged inline.
Requires:       bash
Requires:       coreutils
Requires:       util-linux
# Debian: curl / git / openssl / rsync -- same names except git.
Requires:       curl
Requires:       openssl
Requires:       rsync
Requires:       tar
Requires:       gzip
# `hostname -I` is used to print the web UI address and to fill in
# webrtcAdditionalHosts. It is not in an EL9 minimal install's @core.
Requires:       hostname
# EL9's python3 is 3.9; c4raven-server's pyproject requires >=3.10, <3.15.
# python3.12 is a plain (non-modular) AppStream package on x86_64 and aarch64.
# Debian's python3-venv has no EL counterpart: venv is in python3.12-libs.
Requires:       python3.12
Requires:       python3.12-pyyaml
%if %{without offline}
# Only the online build compiles anything: `poetry install` builds sdists for
# the handful of locked packages without a wheel for this interpreter/arch.
# Debian's build-essential -> gcc/gcc-c++/make; python3-dev -> python3.12-devel.
Requires:       git-core
Requires:       gcc
Requires:       gcc-c++
Requires:       make
Requires:       python3.12-devel
Requires:       libpq-devel
Requires:       libffi-devel
Requires:       openssl-devel
%endif
# Debian postgresql + postgresql-postgis. AppStream carries postgis (3.5.3,
# x86_64 and aarch64), but nothing in the current schema uses it -- the one
# migration that mentions it (8a43097881d7) was written without geoalchemy2 --
# so it is a Recommends and the setup creates the extension when it is there.
Requires:       postgresql-server
Requires:       postgresql
Recommends:     postgis
Requires:       nginx
# Debian: libnginx-mod-stream
Requires:       nginx-mod-stream
# EPEL 9
Requires:       certbot
Requires:       python3-certbot-nginx
# Third-party: yum1.rabbitmq.com / yum2.rabbitmq.com (noarch), plus erlang from
# EPEL 9. See rpm/c4raven-el9-repos.sh -- the repo must exist before dnf can
# resolve this, which is why it can't be shipped inside the package.
Requires:       rabbitmq-server

# --- soft requirements ----------------------------------------------------
# Debian makes these hard Depends; on EL each has a reason not to be.
#
# ffmpeg: used only by the YouTube-restream path in mediamtx_api.py, where all
# three call sites sit inside try/except BaseException that logs and continues.
# Not in EL9 AppStream or (as plain `ffmpeg`) EPEL; ffmpeg-free in EPEL9 covers
# the remux this needs (`-c:v copy -f rtsp`, no encoders), and RPM Fusion's
# full ffmpeg is an alternative. Degrading one feature beats making the whole
# install depend on a third-party multimedia repo.
Recommends:     ffmpeg-free
# nodejs: the UI build (vite 8) needs 20.19+/22.12+. EL9's nodejs is a DNF
# module whose default stream is still 18, so a hard `Requires: nodejs >= 20.19`
# makes the package *uninstallable* on a stock box rather than pulling a newer
# node in. %post checks the binary at runtime and tells the admin which module
# stream to enable.
%if %{without offline}
Recommends:     nodejs >= 20.19
# The module nodejs splits npm out and has no corepack; setup installs
# corepack with npm, and stops with instructions if this weak dep was skipped.
Recommends:     npm
%endif
# semanage for the SELinux port labels: a hard Requires, because on an
# enforcing box without it nginx cannot bind 8446/8322/1936/8883 and setup
# stops at the nginx restart. It is in BaseOS/AppStream everywhere.
Requires:       policycoreutils-python-utils
# firewalld for the port openings; guarded in the setup so the package still
# installs in a container without it.
Recommends:     firewalld
# `pgloader` from debian/control is a dead dependency and is deliberately not
# carried over.

Requires(post):   systemd
Requires(preun):  systemd
Requires(postun): systemd

%description
A security-hardened fork of the upstream project this is derived from.
This package installs the whole server: the Raven backend (cloned and built
with Poetry on first install), the C4 Raven UI frontend (built with Yarn and
deployed to nginx's webroot), a dedicated certificate authority, mediamtx for
video streaming, and the systemd units that tie it all together.

Postgres, RabbitMQ, and nginx are pulled in as real package dependencies;
everything specific to this app (the venv, the CA, the first admin account) is
set up by this package's %%post scriptlet, which mirrors the .deb's postinst
step for step.

Unlike the .deb there is no debconf: answers go in
/etc/c4raven-server/setup.conf (or the matching RAVEN_* environment variables)
and are applied by %%post, or at any later time by `c4raven-setup`.

%if %{with offline}
This is the offline build: the backend wheels, the built UI, mediamtx and the
CROW Remote Clear ATAK plugin are all inside the package, so installing it
needs no internet access and no Node.js.
%else
Building the UI needs Node.js 20.19 or newer. EL9's default nodejs module
stream is 18: run `dnf module reset nodejs && dnf module enable nodejs:22`
before installing, or install now and re-run `c4raven-setup` afterwards.
%endif

%prep
%setup -q -c -T

%build
# Nothing to build -- see the header.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
tar -xf %{SOURCE0} -C %{buildroot}

%files
%dir %{_sysconfdir}/c4raven-server
# noreplace: an upgrade must never clobber the admin's answers, and this is the
# closest thing the RPM has to debconf's persistent answer database.
%config(noreplace) %attr(0600,root,root) %{_sysconfdir}/c4raven-server/setup.conf
%attr(0755,root,root) %{_sbindir}/c4raven-setup
%dir %{_libexecdir}/c4raven-server
%attr(0755,root,root) %{_libexecdir}/c4raven-server/configure.sh
%{_unitdir}/raven.service
%{_unitdir}/cot_parser.service
%{_unitdir}/eud_handler.service
%{_unitdir}/eud_handler_ssl.service
%{_unitdir}/mediamtx.service
%{pkgdata}

%post
systemctl daemon-reload >/dev/null 2>&1 || true

%posttrans
# Setup runs here, not in %post: rpm orders %post only after Requires, so
# Recommends (nodejs, firewalld, postgis) may not be installed yet when %post
# runs. %posttrans runs once the whole transaction is in. It runs on install
# and upgrade alike, exactly like the .deb's `postinst configure`.
if ! /usr/libexec/c4raven-server/configure.sh; then
    cat >&2 << 'EOF'

c4raven-server is installed but its setup did not finish. Nothing has been
rolled back; fix the problem reported above and re-run:

    sudo c4raven-setup

EOF
    # Deliberately not a failure: rpm has no `dpkg --configure -a` to resume a
    # half-configured package, and failing here would leave the package
    # installed-but-broken with no supported way to retry. `c4raven-setup` is
    # that retry, and it is idempotent.
fi

%preun
# $1 == 0 on erase, 1 on upgrade. Stop and disable only on a real erase.
#
# Unlike dpkg there is no ordering hazard here: rpm runs %preun before removing
# the unit files, so `systemctl disable` can still clean up the wants/ symlinks
# (the exact problem debian/c4raven-server.prerm exists to work around).
if [ $1 -eq 0 ]; then
    systemctl stop raven cot_parser eud_handler eud_handler_ssl mediamtx >/dev/null 2>&1 || true
    systemctl disable raven cot_parser eud_handler eud_handler_ssl mediamtx >/dev/null 2>&1 || true
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || true
if [ $1 -eq 0 ]; then
    # Deliberately NOT done automatically: dropping the Postgres database,
    # deleting /opt/raven/data (certs, config, mediamtx recordings), or removing
    # the 'raven' system user. A TAK server's device/user database is too
    # high-stakes to delete from an unattended `dnf remove` -- print exactly
    # what a full wipe requires instead.
    #
    # RPM has no purge/remove distinction at all, so unlike the .deb (which
    # prints this only on `apt purge`) this is the one and only chance to say
    # it.
    cat << 'EOF'

c4raven-server has been removed, but its data was intentionally left in place.
Note that nginx is still serving the raven_* sites: their files under
/etc/nginx were written by the setup script, not shipped by the package, so rpm
does not remove them. To fully wipe it:

    sudo -u postgres psql -c "DROP DATABASE IF EXISTS raven;"
    sudo -u postgres psql -c "DROP ROLE IF EXISTS raven;"
    sudo rm -rf /opt/raven
    sudo rm -rf /var/www/html/raven
    sudo userdel -r raven
    sudo rm -f /etc/nginx/conf.d/raven_http.conf /etc/nginx/conf.d/raven_https.conf
    sudo rm -f /etc/nginx/conf.d/raven_certificate_enrollment.conf
    sudo rm -f /etc/nginx/conf.d/raven_certificate_enrollment_domain.conf
    sudo rm -f /etc/letsencrypt/renewal-hooks/deploy/raven-nginx-reload
    sudo rm -f /etc/nginx/stream.d/rabbitmq.conf /etc/nginx/stream.d/mediamtx.conf
    sudo systemctl reload nginx

If you also want the EL-specific changes undone:

    sudo semanage port -d -t http_port_t -p tcp 8446
    sudo semanage port -d -t http_port_t -p tcp 8322
    sudo semanage port -d -t http_port_t -p tcp 1936
    sudo semanage port -d -t http_port_t -p tcp 8883
    sudo semanage fcontext -d '/opt/raven/data/ca(/.*)?'
    for p in 80 443 8080 8443 8446 8322 1936 8883 8554 1935 8088 8089; do
        sudo firewall-cmd --permanent --remove-port=$p/tcp
    done
    for p in 8189 8890 8087; do
        sudo firewall-cmd --permanent --remove-port=$p/udp
    done
    sudo firewall-cmd --reload

The stock nginx default server was backed up in place as
/etc/nginx/nginx.conf.c4raven.bak. In /var/lib/pgsql/data/pg_hba.conf the
127.0.0.1 and ::1 host lines were switched from ident to md5.

EOF
fi

%changelog
# Intentionally empty: versions come from PKG_VERSION, exactly as the .deb's do
# (there is no debian/changelog either). rpmlint will warn about this.
