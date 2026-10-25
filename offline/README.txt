C4 Raven server @VERSION@ -- offline install bundle for Ubuntu @SUITE@ (@ARCH@)
=====================================================================

Everything needed to install the server on a machine with no internet access:

  repo/        c4raven-server_@VERSION@_@ARCH@.deb plus every Ubuntu package it
               needs (PostgreSQL, PostGIS, RabbitMQ, nginx, ffmpeg, ...)
  install.sh   installs from repo/ only
  MANIFEST     target architecture and exact backend / UI / mediamtx /
               plugin versions inside
  SHA256SUMS   checksums install.sh verifies before doing anything

Install:

  tar -xf c4raven-server-offline_@VERSION@_@SUITE@_@ARCH@.tar
  cd c4raven-server-offline_@VERSION@_@SUITE@_@ARCH@
  sudo ./install.sh

You'll be asked two questions. Leave the domain name blank on an offline
network: a Let's Encrypt certificate needs the internet, so the server uses
its own certificate authority instead. Answer "no" to Cloudflare Turnstile
for the same reason.

What you get: the Raven backend, the web UI (https://<this machine's IP>),
the certificate authority, mediamtx video streaming, and the CROW Remote
Clear ATAK plugin already published in the server's plugin repository, so
devices are offered it when they enrol.

First login: username "administrator", password "password". You must set a
real password straight away.

This bundle only installs on @ARCH@ and only on Ubuntu @SUITE@; install.sh
checks both before touching anything. Other combinations are built as
separate bundles.

Upgrading: run install.sh from a newer bundle. Your config, certificates,
database and uploads are kept.
