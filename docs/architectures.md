# Architectures

amd64/x86_64 is the only architecture this stack has ever run on in
anger. arm64/aarch64 is believed to work and has not been run on real
hardware — see [the support matrix](../README.md#supported-platforms).
This page is the arm64 detail that doesn't belong in the README.

Three names for the same thing, and the scripts have to speak all
three: dpkg says `amd64`/`arm64`, RPM and `uname -m` say
`x86_64`/`aarch64`, mediamtx's release assets say `amd64`/`arm64`/
`armv7`. `lib/distro.sh`'s `detect_distro` sets `ARCH_DEB` and
`ARCH_MTX` so nothing else has to think about it: from
`dpkg --print-architecture` where dpkg exists (a 32-bit armhf userland
on a 64-bit kernel reports `aarch64` from `uname -m`), from `uname -m`
on EL. An architecture mediamtx doesn't publish is refused by name.

## Online installs

Nothing in the online paths is architecture-specific beyond picking the
right download:

- **mediamtx** publishes `linux_amd64`, `linux_arm64` and `linux_armv7`
  assets; the pinned release is 1.13.0.
- **NodeSource** publishes amd64 and arm64 for both `setup_22.x`
  flavours (deb and rpm), which is what gets the UI build a Node new
  enough for vite 8.
- **Ubuntu** has every dependency on both architectures; **EL9
  AppStream/BaseOS and EPEL 9** have every dependency we take on both,
  with the single exception below.
- The `.deb` is `Architecture: all` and the online `.rpm` is `noarch` —
  both build the venv and the UI on the target, so neither needs an
  architecture-specific build.

armhf/armv7 is not supported. `detect_distro` maps it and
`install.sh` will try, but nothing has been checked and the Python
wheel situation is worse, not better.

## The one hard arm64 limit: RabbitMQ on EL9

rabbitmq.com's erlang repository is x86_64 and noarch only —
`yum1.rabbitmq.com/erlang/el/9/aarch64` 404s. On aarch64, erlang comes
from EPEL 9 (26.2.5) instead, and RabbitMQ's `Requires: erlang >= N,
erlang < M` ranges cap `rabbitmq-server` at **4.3.2**. dnf backtracks to
it automatically. This does not apply to Ubuntu, where arm64 RabbitMQ
is just a package.

## Offline bundles must be built on the target architecture

`build-offline.sh` defaults `TARGET_ARCH` to the build machine's and
**refuses a mismatch**. This is not caution, it is a correctness
problem that no verification step on the build host can catch:

`pip download --platform` can only hand you wheels PyPI already has.
Anything with no wheel for the target falls through to its sdist, which
the build compiles — with this machine's compiler, for this machine's
architecture. Four of the lock's sdist-only packages
(`flask-apscheduler`, `flask-principal`, `sgmllib3k`, `simplekml`) are
pure Python and produce an arch-independent `py3-none-any` wheel, so
they are harmless. Two are C extensions and are not:

- **`mutf8` 1.0.6** — no cp31x wheels at all, for any architecture.
- **`unishox2-py3` 1.0.0** — wheels stop at cp310.

Both build a `linux_<host arch>` wheel every single time. Cross-build
and the bundle ships x86_64 `.so` files labelled arm64; the build's own
verify step passes, because it runs on the build host; the failure
surfaces at install time on the customer's machine. The glibc audit has
the same blind spot — it runs `objdump` on whatever was compiled here,
which only means something when "here" is the target.

So: run `build-offline.sh` unchanged on arm64 hardware, an arm64 cloud
VM, or `docker run --platform linux/arm64` on a binfmt/qemu-enabled
host. The script itself is architecture-clean.

`ALLOW_CROSS_BUILD=1` exists for the day `mutf8` and `unishox2-py3` gain
aarch64 wheels or leave the lock. It is not a way to force a cross-build
today: the build still hard-fails on any locally compiled wheel that is
not arch-independent, and it downgrades the "install it and import it"
check to resolve-only, because foreign-arch wheels cannot be imported
here. **That path has never produced a bundle anyone has installed.**

## ports.ubuntu.com

`archive.ubuntu.com` and `security.ubuntu.com` carry amd64 and i386
only. Every other architecture — arm64 included — lives on
`ports.ubuntu.com/ubuntu-ports/`, which also serves the security pocket
from the same host. `archive.ubuntu.com` does not merely lack packages
there; `dists/<suite>/main/binary-arm64/` 404s outright, and an apt
run pointed at it fails with a confusing hash-sum or 404 error rather
than "wrong architecture".

`build-offline.sh` picks the mirror from `TARGET_ARCH` automatically.
`UBUNTU_MIRROR` and `UBUNTU_SECURITY_MIRROR` override it if you have a
local mirror; point them somewhere that actually carries the
architecture you asked for.

## glibc, and why EL9 payloads can't be built on Ubuntu

The compiled wheels in a bundle have to run on the *oldest* target it
claims to support, so `GLIBC_MAX` is a property of that target, not a
constant:

| Target | glibc |
| --- | --- |
| Rocky Linux 9 / EL9 | 2.34 |
| Debian 12 bookworm | 2.36 |
| Ubuntu 24.04 noble | 2.39 |
| Ubuntu 25.10 questing | 2.42 |

`build-offline.sh` derives `GLIBC_MAX` from `SUITES` and audits what it
compiled against it. EL9's 2.34 is below every current Ubuntu, so an RPM
payload built on Ubuntu would need `GLIBC_MAX=2.34`, which no current
Ubuntu can satisfy. `rpm/build-rpm.sh` refuses to build an offline
payload anywhere but EL9 (`ALLOW_NON_EL9_BUILD=1` lifts it, with the
same "you are on your own" caveat as `ALLOW_CROSS_BUILD`).

This cuts both ways: it means there are four offline build hosts to
maintain, not one — {amd64, arm64} x {Ubuntu, EL9} — and today only the
amd64 Ubuntu one has ever produced a bundle.

## CI

`tests/run-matrix.sh` runs each {distro, arch, method} cell in a
systemd container; `.github/workflows/install-matrix.yml` runs amd64 on
every push and the full cross product nightly, with arm64 on GitHub's
native `ubuntu-24.04-arm` runners.

QEMU emulation is deliberately **not** used in CI: Node and the Erlang
JIT do not survive it reliably, so an emulated pass or fail is not a
signal either way. `tests/run-matrix.sh --emulated` exists for local
smoke testing only, and a green run from it is not evidence that the
architecture works.
