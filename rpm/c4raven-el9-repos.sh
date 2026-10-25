#!/bin/bash
# Adds the package repositories c4raven-server's RPM resolves against on
# Enterprise Linux 9 (Rocky / AlmaLinux / RHEL), x86_64 and aarch64.
#
# This cannot live inside the package: dnf has to be able to resolve
# `Requires: rabbitmq-server` *before* the package is installed. Run it once on
# a fresh box, then `dnf install ./c4raven-server-*.rpm`.
#
# What comes from where, and why (each verified against the live repositories):
#
#   AppStream / BaseOS  nginx, nginx-mod-stream, postgresql, postgresql-server,
#                       python3.12 (+ -devel, -pyyaml), nodejs (module),
#                       gcc, make, openssl, rsync, git-core
#                       -- all present for x86_64 AND aarch64.
#   EPEL 9              certbot 3.1.0, python3-certbot-nginx 3.1.0 (both
#                       noarch), erlang 26.2.5 (x86_64 and aarch64),
#                       ffmpeg-free 7.1.5 (x86_64 and aarch64).
#   rabbitmq.com        rabbitmq-server, published as *noarch* -- so one
#                       repository serves both architectures.
#
# NOT used, deliberately:
#   PGDG (yum.postgresql.org) -- AppStream already has postgis (3.5.3, both
#       arches) for its PostgreSQL. PGDG would replace the distro PostgreSQL
#       with a versioned `postgresql-16.service` that the setup script does
#       not support.
#   RPM Fusion -- carries a full `ffmpeg` 7.1.5 for el9 aarch64 and x86_64, but
#       the only ffmpeg use in the server is a `-c:v copy -f rtsp` remux, which
#       EPEL's ffmpeg-free does. Add RPM Fusion yourself if you want the
#       patent-encumbered codecs.
#   rabbitmq.com's erlang repo -- x86_64 ONLY (see the warning below).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root." >&2
  exit 1
fi

. /etc/os-release
case "${ID}:${VERSION_ID}" in
  rhel:9*|rocky:9*|almalinux:9*|centos:9*) ;;
  *) echo "This script is for Enterprise Linux 9; this is ${PRETTY_NAME:-unknown}." >&2; exit 1 ;;
esac

ARCH=$(uname -m)

echo "Enabling EPEL 9 and CRB..."
# dnf-plugins-core provides `dnf config-manager`; minimal images lack it,
# and without it CRB silently stays off.
if [ "$ID" = rhel ]; then
  # RHEL's own repos don't carry epel-release; Fedora publishes it.
  dnf -y install dnf-plugins-core \
    https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
else
  dnf -y install dnf-plugins-core epel-release
fi
# EPEL expects CodeReady Builder / PowerTools to be on. The repo id differs
# between RHEL and the rebuilds.
dnf config-manager --set-enabled crb 2>/dev/null \
  || dnf config-manager --set-enabled codeready-builder-for-rhel-9-"$ARCH"-rpms 2>/dev/null \
  || echo "  (could not enable CRB automatically -- enable it by hand if a dependency is missing)"

echo "Adding the RabbitMQ repository..."
# rabbitmq-server is noarch, so the same directory serves x86_64 and aarch64.
# Erlang is where the architectures diverge:
#
#   yum1/yum2.rabbitmq.com/erlang/el/9/  has x86_64 and noarch -- NO aarch64.
#   EPEL 9                               has erlang 26.2.5 for x86_64 AND aarch64.
#
# RabbitMQ's own packages carry `Requires: erlang >= N, erlang < M`:
#
#   4.3.0-4.3.2  erlang >=26 <29
#   4.3.3-4.3.x  erlang >=27 <29
#   4.4.0        erlang >=27 <30
#
# So on aarch64, EPEL's erlang 26 caps you at RabbitMQ 4.3.2. dnf does NOT
# just backtrack to it: EL9's dnf.conf has best=True, so `dnf install
# rabbitmq-server` and every whole-system `dnf upgrade` fail on "cannot
# install the best candidate". Exclude the versions EPEL's erlang can't
# satisfy so 4.3.2 *is* the best candidate. On x86_64 the erlang repo below
# lifts the cap, so nothing is excluded there.
RABBIT_EXCLUDE=""
if [ "$ARCH" != "x86_64" ]; then
  RABBIT_EXCLUDE="excludepkgs=rabbitmq-server-4.3.[3-9]* rabbitmq-server-4.3.[1-9][0-9]* rabbitmq-server-4.[4-9]* rabbitmq-server-[5-9]*"
fi
cat > /etc/yum.repos.d/rabbitmq.repo << EOF
[rabbitmq-server]
name=RabbitMQ server (noarch)
baseurl=https://yum1.rabbitmq.com/rabbitmq/el/9/noarch
        https://yum2.rabbitmq.com/rabbitmq/el/9/noarch
$RABBIT_EXCLUDE
repo_gpgcheck=0
enabled=1
gpgcheck=0
sslverify=1
metadata_expire=300
EOF

if [ "$ARCH" = "x86_64" ]; then
  cat >> /etc/yum.repos.d/rabbitmq.repo << 'EOF'

[rabbitmq-erlang]
name=RabbitMQ Erlang (x86_64)
baseurl=https://yum1.rabbitmq.com/erlang/el/9/$basearch
        https://yum2.rabbitmq.com/erlang/el/9/$basearch
repo_gpgcheck=0
enabled=1
gpgcheck=0
sslverify=1
metadata_expire=300
EOF
else
  cat << EOF

NOTE ($ARCH): RabbitMQ publishes no Erlang RPMs for this architecture --
yum1/yum2.rabbitmq.com/erlang/el/9/ has x86_64 and noarch only. Erlang will
come from EPEL 9 (26.2.5), which caps rabbitmq-server at 4.3.2; newer
versions are excluded in /etc/yum.repos.d/rabbitmq.repo so dnf upgrades keep
working. Lift that when EPEL's erlang moves to 27.

EOF
fi

echo "Enabling a Node.js stream new enough to build the UI..."
# EL9's default nodejs module stream is 18; the UI build (vite 8) needs
# 20.19+/22.12+. Harmless if the UI is not built on this box (offline RPM).
dnf -y module reset nodejs 2>/dev/null || true
dnf -y module enable nodejs:22 2>/dev/null || dnf -y module enable nodejs:20 2>/dev/null || true

dnf -y makecache

cat << 'EOF'

Repositories configured. Next:

    sudo dnf install ./c4raven-server-*.rpm

Set the install-time answers first if you have them (domain name, Cloudflare
Turnstile) -- either as environment variables:

    sudo RAVEN_DOMAIN=tak.example.org dnf install ./c4raven-server-*.rpm

or by editing /etc/c4raven-server/setup.conf after the install and running
`sudo c4raven-setup`.
EOF
