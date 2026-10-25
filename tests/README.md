# Verification harness

Built for the ARM/Rocky port: the repo used to target Ubuntu on amd64 only,
and the port doubled the install matrix in two directions at once. These
tests exist to say which of those cells actually work, and — just as
importantly — to be honest about which ones are only smoke.

Three tiers, cheapest first. **Run the first two before every push; they
take about a minute between them and catch most of what breaks here.**

| Tier | Command | Needs | Runtime | Runs in CI |
|---|---|---|---|---|
| 1 · static | `tests/lint.sh` | shellcheck, python3 | ~20 s | every push/PR |
| 1b · unit | `tests/unit/run.sh` | bash only | ~1 s | every push/PR |
| 2 · install matrix | `tests/run-matrix.sh` | docker/podman, root-ish | 20–90 min/cell | nightly + manual |

```sh
tests/lint.sh                 # tier 1
tests/unit/run.sh             # tier 1b
tests/unit/run.sh distro      # just tests/unit/test-distro.sh
VERBOSE=1 tests/unit/run.sh   # print passing assertions too
tests/run-matrix.sh --list    # show tier 2's matrix without running it
```

`STRICT=1` turns "a tool/subject is missing, so I skipped" into a failure.
CI sets it on tiers 1 and 1b. Locally, leave it off: half the point of the
skip machinery is that a half-landed workstream reports "not here yet"
rather than a red X nobody can tell from a regression.

Exit codes are autotools' convention: `0` pass, `1` fail, **`77` skip**.

---

## Tier 1 — `tests/lint.sh`

`bash -n`/`sh -n` and shellcheck (severity ≥ warning, `-x`, `-e SC1091`) over
every shell script in the repo — including the `debian/` maintainer scripts
and the generated offline installer, which carry no `.sh` suffix and are the
ones most often missed. Plus `py_compile`, a YAML parse of the workflows,
`systemd-analyze verify` on the shipped units, `rpmspec --parse` on
`rpm/*.spec`, and a sweep for unsubstituted `OTS_FOLDER` / `SERVER_CERT_FILE`
/ `CA_CERT_FILE` placeholders outside the templates meant to have them.

**Proves:** nothing is syntactically broken, and no template shipped
un-substituted.
**Does NOT prove:** that any of it does the right thing. A script can be
shellcheck-clean and install a Debian package name on Rocky.

## Tier 1b — `tests/unit/`

No containers, no root, no network, no package manager. This is the highest
value-per-second in the harness and the tier worth extending first.

### `test-distro.sh` — `lib/distro.sh` (177 assertions)

`detect_distro` reads exactly two things: `/etc/os-release` and `uname -m`.
So `tests/lib/sandbox.sh` stubs both and drives the real `lib/distro.sh`
across `{ubuntu-24.04, ubuntu-22.04, debian-12, rocky-9, rocky-8,
almalinux-9, rhel-9, centos-9, fedora-41, alpine-3.20, empty} × {x86_64,
aarch64}`, asserting package lists, nginx user and stream-config paths,
`PG_SERVICE`/`RABBIT_SERVICE`, `PYTHON_BIN`, `PKG_MGR` dispatch, PostgreSQL
init, third-party repo setup, firewall (ufw vs firewalld), SELinux, and the
`ARCH_DEB`/`ARCH_MTX` mappings.

Everything that would change a real machine is replaced by a recorder, so
tests assert on *what would have been run*. `sudo` is transparent — it logs,
strips its own flags, then `exec`s — so the pure-shell logic behind it (the
`pg_hba.conf` rewrite, the `test -f` guards) is genuinely exercised while
every dangerous binary underneath is still a stub.

**Proves:** the single most likely bug in a Debian→EL port — a package name,
path or service name from the wrong family leaking into the other family's
branch. Invisible to shellcheck; costs 40 minutes to find on tier 2.
**Does NOT prove:** that the recorded commands succeed on a real machine, or
that the package names exist in any real repository. `dnf install
postgresql-server` is asserted as the right *string*, not as installable.

### `test-packaging.sh` — the packaging guards (64 assertions)

Guards only: nothing here builds a package. Each one is a bug that has
already happened at least once.

- **`build-offline.sh` refuses to cross-build.** Two locked dependencies
  (`mutf8`, `unishox2-py3`) publish no wheel, so pip compiles them from
  sdist and the result is a **host**-arch `.so` whatever `--platform` says.
  A bundle cross-built on an amd64 runner is labelled arm64 and carries
  x86-64 objects, and nothing before the customer's install notices. The
  refusal is also asserted to be *immediate* (not a 60 s hang), to name the
  reason, and to document its own `ALLOW_CROSS_BUILD=1` escape hatch — and
  no workflow is allowed to set that variable.
- **`build-deb.sh` takes arch only from the payload `MANIFEST`.** A missing
  `MANIFEST`, a missing `arch` line, an unknown arch, and an arch that
  disagrees with the bundled mediamtx tarball are each refused before
  anything is staged under `build/`. The `arch` line's exact format is
  round-tripped through `build-deb.sh`'s real awk expression, because the
  writer and the reader are 400 lines apart in two files.
- **`debian/control`'s trailing Description paragraph stays last.** This is
  an unguarded ordering coupling: `build-deb.sh`'s offline rewrite drops
  *everything* from the `" Building the UI needs"` marker to EOF. Its own
  `END` block catches the marker being reworded away, and tier 1 catches it
  being deleted — neither catches the other half, which is a field appended
  *after* the marker. That field survives into the online `.deb` and
  silently vanishes from the offline one, and both builds exit 0. The test
  reads the marker out of `build-deb.sh` (so changing one side only is what
  fails), asserts no control field follows it, then extracts and runs
  `build-deb.sh`'s **actual** awk program — not a copy that could drift —
  over `debian/control`, checking both the success path and that the `END`
  guard still fires when the marker is gone.

**Proves:** the refusals still fire, and the two sides of each contract still
agree. A guard that has quietly stopped firing looks exactly like a guard
that works.
**Does NOT prove:** that a *successful* build produces a correct package.
Nothing here builds one.

### `test-harness.sh` — the harness's own wiring (67 assertions)

A verification harness that has quietly stopped verifying is worse than no
harness: every cell goes green because every cell skipped. Checks that every
method in `ALL_METHODS` has a script and vice versa, that every method is
claimed by some distro, that every distro has a Dockerfile, that `host_arch`
speaks the same vocabulary as `ALL_ARCHES`, that the systemd-in-container
flags are all present, and that nothing lost its executable bit or its
shebang.

**Proves:** the matrix cannot silently shrink to nothing.
**Does NOT prove:** anything about the product.

## Tier 2 — `tests/run-matrix.sh`

One cell = one `{distro, arch, method}`. Boots a systemd container, runs
`tests/methods/<method>.sh` inside it, then runs `tests/verify.sh` against
the result. `--reboot-check` restarts the container and re-verifies, which is
the only thing that catches "it works until you reboot" unit-ordering bugs.

Methods: `install-sh` (curl|bash, online), `deb` (`build-deb.sh` + apt,
postinst builds on target), `rpm` (Rocky only), `deb-offline` (bundle built
on the *host* and bind-mounted in, installed with no default route).

`tests/verify.sh` asserts across: layout/ownership, configuration, the CA
(cert chains to `ca.pem`, not expired), the five app units plus three distro
units, listening sockets, a live `GET /api/turnstile`, `nginx -t`, the built
UI, the database, the seeded admin account, mediamtx, and that the installed
package's architecture matches the host.

**Proves:** on this distro and arch, this install method produces a stack
that boots and serves.
**Does NOT prove:**
- *Anything about a bare-metal host.* These are privileged containers sharing
  the host kernel, with `/sys/fs/cgroup` bind-mounted. Kernel-version,
  firewall, SELinux-in-practice and real-disk behaviour are all out of scope.
- *That the offline bundle is self-contained*, except in the `deb-offline`
  cell, which is the only one installed without a default route.
- *Anything on arm64 from an emulated run.* `--emulated` exists for local
  smoke only: Node and the Erlang JIT do not survive QEMU reliably, so an
  emulated failure is not evidence of a bug and an emulated pass is not
  evidence of a fix. **CI never emulates** — arm64 cells run on native arm64
  runners or they do not run.
- *That private-repo clones work*, when `GH_TOKEN` is absent: those cells
  SKIP rather than fail.

### systemd in a container

Docker by default (`CONTAINER_ENGINE=podman` is supported). Needs
`--privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock -v
/sys/fs/cgroup:/sys/fs/cgroup:rw`; podman additionally needs
`--systemd=always`, which docker infers from the image CMD. Losing one of
these does not error — it produces a container where systemd boots degraded
and half the units never start, which reads like an install bug. That is why
`test-harness.sh` asserts the flag list.

---

## CI

- **`lint.yml`** — tiers 1 and 1b with `STRICT=1`, on every push and PR, plus
  a Rocky 9 container job running `rpmspec --parse` for `x86_64` and
  `aarch64` (the `%systemd_*` and `%{?dist}` macros only exist on the real
  thing).
- **`install-matrix.yml`** — tier 2. amd64-only on push/PR; the full cross
  product including arm64 nightly (04:17 UTC) and on manual dispatch. The
  offline-bundle job is opt-in via `workflow_dispatch` because it takes
  hours.

### The arm64 runner label

arm64 cells use **`ubuntu-24.04-arm`**, a GitHub-hosted native arm64 runner
(Cobalt 100 / Neoverse N2, 4 vCPU), generally available for **public**
repositories since 2025-08-07 and free there.

This works **only because `C4-Raven/c4raven-server-setup` is public.** Arm64
standard runners are not available to private repositories on the Free plan
— and a label that is not available does not fail with a clear message, it
fails at queue time with a label-not-found error that says nothing about the
cause. If this repo is ever made private, either move to a paid plan's arm
runners or drop the matrix back to amd64-only.

(The org has no larger/hosted runners provisioned — `GET
/orgs/C4-Raven/actions/hosted-runners` returns 404 — so `runs-on` must stick
to standard labels.)

---

## Adding to the harness

Prefer tier 1b. A new assertion there costs milliseconds and runs on every
push; the same check on tier 2 costs 40 minutes and runs nightly. Before
adding a tier 2 cell, ask whether the thing you want to prove is actually a
function of `/etc/os-release` and `uname -m` — if it is, it belongs in
`test-distro.sh`.

When you add a guard, **make it fail on purpose once.** Every guard in
`test-packaging.sh` was checked against a deliberately broken input; a guard
nobody has seen fail is a guard nobody knows works.
