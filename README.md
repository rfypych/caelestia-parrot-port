# Caelestia on Parrot OS — Porting & Deployment Kit

A production-grade port of the [Caelestia](https://github.com/caelestia-dots/)
desktop ecosystem (C++ `lib`, QML `shell`, TypeScript `caelestia` integrations,
Python `cli`) from Arch Linux to **Parrot OS Home (Debian 13 "trixie")**, with
zero contamination of base system libraries.

## Package contents

| File | What it is |
|---|---|
| `install.sh` | The production orchestrator (11 stages, strict shell mode, signal-safe traps, automatic rollback, pinned downloads, multiarch-aware) |
| `verify.sh` | Post-install diagnostic suite: layout, linkage, version gates, live QML/IPC smoke test, and an apt-drift detector against the install manifest |
| `Caelestia-ParrotOS-Porting-Blueprint.pdf` | 22-page engineering blueprint: architecture, cross-distro conflict analysis, toolchain flags, package mapping, pin set, failure semantics, verification, runbook, appendices |
| `Caelestia-Blueprint-cover.html` | Editable HTML source of the PDF cover (regenerate with `html2poster.js --width 794px`) |

## Quick start

```bash
unzip caelestia-parrot-port.zip
cd caelestia-parrot-port
sudo ./install.sh            # full install (or: sudo bash install.sh)
sudo ./verify.sh             # post-install diagnostics
```

`install.sh --help` lists every option (`--doctor`, `--uninstall`, `--ref`,
`--source-dir`, `--start-after`, `--with-hyprland`, ...).

## The compatibility contract (read this first)

Every Caelestia shell release since v1.2.0 (Sep 2025) requires **Qt >= 6.9**,
while Parrot OS 7 ships **Qt 6.8.2**. This kit therefore pins the last
Qt-6.8-buildable, mutually-tested generation instead of fighting the gate:

| Component | Pin | Why |
|---|---|---|
| shell | `v1.1.1` | last release with no Qt version gate |
| cli | `8bc7e49` | the exact commit in shell v1.1.1's `flake.lock` |
| quickshell | `v0.2.1` | one commit after the flake-tested pin `f7597cda` |
| caelestia (dots) | `1a69a48` | same-era dotfiles incl. the VS Code TS integration |
| lib | `d8f3b72` | current HEAD of the (tagless) backing library; Qt >= 6.7 only |
| Node.js | `v26.13.0` | SHA-256-pinned tarball for the TypeScript builds |

Pins live in `/opt/caelestia/lock.env` after install and are meant to be
edited deliberately. The installer's preflight gate refuses newer shell pins
until the system Qt actually supports them.

## Isolation model in one paragraph

Everything Caelestia owns is installed under `/opt/caelestia` — a private CMake
prefix with Debian multiarch layout (`lib/x86_64-linux-gnu`, resolved
dynamically), a Python venv for the CLI, a pinned local Node layer with no
global npm state, and SHA-256-verified font downloads. The only system-level
footprint is five tracked, reversible files (two `/usr/local/bin` wrappers,
`/etc/profile.d`, `/etc/environment.d`, optional sudoers drop-in), all removed
by `sudo ./install.sh --uninstall`. System Qt and the externally-managed system
Python are never modified.

## Where to look in the PDF

- Ch. 3 — why current Caelestia cannot build on Parrot, and the rejected alternatives
- Ch. 5 — the full CMake/GCC flag contract with rationale
- Ch. 6 — verified Arch-to-Debian package mapping (trixie index, Nov 2026)
- Ch. 8 — stage machine, traps and rollback semantics
- Ch. 10 — manual verification commands (the ones `verify.sh` automates)
- Ch. 11 — runbook: dotfiles, upgrades, uninstall, troubleshooting
