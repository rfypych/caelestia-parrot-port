#!/usr/bin/env bash
# =============================================================================
#  install.sh — Caelestia desktop ecosystem installer for Parrot OS (Debian 13)
# =============================================================================
#
#  Ports the 4 Caelestia components (https://github.com/caelestia-dots/) to
#  Parrot OS Home without contaminating base system libraries:
#
#     1. lib        (C++ backing library)      -> /opt/caelestia/prefix
#     2. shell      (QML desktop shell)        -> /opt/caelestia/prefix
#     3. caelestia  (dotfiles + TypeScript)    -> /opt/caelestia/src + pinned Node
#     4. cli        (Python control script)    -> /opt/caelestia/venv
#
#  plus the two out-of-repo build prerequisites:
#     - quickshell v0.2.1 (the widget framework the shell runs on)
#     - fonts not shipped by Debian (Material Symbols Rounded, Rubik VF)
#
#  DESIGN CONTRACT (read before modifying):
#
#   * Parrot OS 7 "Home" is Debian 13 "trixie": Qt 6.8.2, Python 3.13,
#     GCC 14, CMake 3.31, multiarch lib dirs (/usr/lib/x86_64-linux-gnu).
#   * Every Caelestia release after shell v1.2.0 (2025-09-14) hard-requires
#     Qt >= 6.9 (qt_standard_project_setup(REQUIRES 6.9) in plugin/CMakeLists).
#     Parrot's system Qt is 6.8.2, so this installer pins the LAST
#     Qt-6.8-compatible, mutually-tested generation:
#         shell v1.1.1 + cli 8bc7e49 + quickshell v0.2.1 + dots 1a69a48
#     (shell v1.1.1's flake.lock pins cli 8bc7e49 and quickshell f7597cda;
#      quickshell v0.2.1 is exactly one commit after f7597cda.)
#   * NOTHING is ever installed into /usr or /usr/lib. Everything Caelestia
#     owns lives under /opt/caelestia/. The only system touchpoints are
#     additive, reversible files (wrappers, profile.d, environment.d,
#     sudoers.d) — all tracked and removed by `install.sh --uninstall`.
#   * Before the first prefix-mutating stage, any previous install is moved
#     to /opt/caelestia/backups/ and a fresh tree is built in place (CMake
#     bakes absolute RPATH/QML paths, so a rename-staging scheme would corrupt
#     them). If any stage fails, the EXIT trap restores the previous tree;
#     on success the previous tree is kept as a rollback point and pruned.
#
#  USAGE
#     sudo ./install.sh                          # full install
#     sudo ./install.sh --doctor                 # run post-install diagnostics
#     sudo ./install.sh --uninstall              # remove everything (asks --yes)
#     sudo ./install.sh --source-dir /path/dir   # use local checkouts instead
#                                                # of cloning (dir/lib, dir/shell,
#                                                # dir/cli, dir/caelestia,
#                                                # dir/quickshell)
#     sudo ./install.sh --ref shell=v1.1.1 --ref qs=v0.2.1
#     sudo ./install.sh --start-after sources --stop-after lib
#     sudo ./install.sh --with-hyprland          # also install Hyprland from apt
#     sudo ./install.sh --without-sudoers        # skip theming sudoers drop-in
#     sudo ./install.sh --no-fonts               # skip font downloads
#
#  EXIT CODES
#     0 success   1 failure (rolled back)   130 interrupted (rolled back)
#
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# -----------------------------------------------------------------------------
# 1. CONSTANTS AND VERSION PINS
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

readonly CAE_ROOT="/opt/caelestia"
readonly PREFIX="$CAE_ROOT/prefix"            # install tree (built in place)
readonly SRC="$CAE_ROOT/src"
readonly BUILD="$CAE_ROOT/build"
readonly VENV="$CAE_ROOT/venv"
readonly NODE_ROOT="$CAE_ROOT/node"
readonly BACKUPS="$CAE_ROOT/backups"
readonly LOGS="$CAE_ROOT/logs"
readonly LOCK_FILE="$CAE_ROOT/lock.env"
readonly MANIFEST="$CAE_ROOT/manifest.env"
readonly STATE="$CAE_ROOT/state"
readonly ENV_FILE="$CAE_ROOT/env"

# --- Component pins (the "tested-together" set; see DESIGN CONTRACT) --------
readonly URL_LIB="https://github.com/caelestia-dots/lib"
readonly URL_SHELL="https://github.com/caelestia-dots/shell"
readonly URL_CLI="https://github.com/caelestia-dots/cli"
readonly URL_DOTS="https://github.com/caelestia-dots/caelestia"
readonly URL_QS="https://github.com/outfoxxed/quickshell"

DEFAULT_LIB_REF="d8f3b72b7bffa22ace30595c3190a9f8cedb7e44"   # 2026-11-05, Qt>=6.7
DEFAULT_SHELL_REF="v1.1.1"          # 2025-09-03, last Qt 6.8 buildable release
DEFAULT_CLI_REF="8bc7e495af42c778143771179d23312f8ff7a3c8"   # 2025-08-30, flake pin of shell v1.1.1
DEFAULT_QS_REF="v0.2.1"             # 2025-10-11, 1 commit after flake pin f7597cda
DEFAULT_DOTS_REF="1a69a48730842c5e77b746d751ac337edd20b796"  # 2025-09-01, era-matched dotfiles

# --- Pinned Node.js layer (needed only for the TypeScript integrations) -----
NODE_VERSION="v26.13.0"
readonly NODE_SHA_X64="d28a96af6c38596f6d9d97c0ee531c13d238d757742387d1928de822d959e997"
readonly NODE_SHA_ARM64="406fe3fbde1c054adff8b297c16fdb5af6659db327c1ac8acd46b56ef1af9a92"

# --- Pinned fonts (not available in Debian repos) ----------------------------
readonly FONT_RUBIK_URL="https://raw.githubusercontent.com/google/fonts/24ddc1f324cac5d9f5aedca126d298f56e3f1640/ofl/rubik/Rubik%5Bwght%5D.ttf"
readonly FONT_RUBIK_SHA="1b3a7437ba2af80e465e773ed60c5036d1ba6ace492d89046dbcf18fb31e4e88"
readonly FONT_MSR_URL="https://raw.githubusercontent.com/google/material-design-icons/10ecc14790612ca8fd164e3f4ffe9c16fc50d5b7/variablefont/MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"
readonly FONT_MSR_SHA="7e74e36533ccee12c2b81e75bfcf3ccf123d3bb7e7e46d65d94445f23db0c97c"

# --- Python deps of the cli (era-appropriate, PEP 440 pins) ------------------
readonly PIP_PIN_PILLOW="pillow==11.3.0"
readonly PIP_PIN_MYC="materialyoucolor==2.0.10"

# --- Minimum system versions (hard gates; fail fast, never guess) ------------
readonly QT_MIN="6.7"          # caelestia-lib qt_standard_project_setup(REQUIRES 6.7)
readonly WAYLAND_PROTOCOLS_MIN="1.37"   # lib screenshot module (ext-image-copy-capture)
readonly PY_MIN="3.13"         # cli pyproject requires-python
readonly CMAKE_MIN="3.25"      # lib CMakeLists cmake_minimum_required

# --- Runtime deps: verified against the Debian 13 "trixie" package index -----
APT_BUILD=(
    build-essential cmake ninja-build pkg-config git curl ca-certificates xz-utils
    qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-declarative-private-dev
    qt6-wayland-dev qt6-wayland-private-dev qt6-shadertools-dev
    libcli11-dev spirv-tools libjemalloc-dev
    libdrm-dev libgbm-dev libegl-dev libgles-dev libvulkan-dev libxcb1-dev
    libwayland-dev wayland-protocols libpipewire-0.3-dev
    libpam0g-dev libpolkit-agent-1-dev libpolkit-gobject-1-dev libglib2.0-dev
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev
    python3-venv python3-pip
)
APT_RUNTIME=(
    qt6-svg-plugins libqt6svg6
    qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-templates
    qml6-module-qtquick-layouts qml6-module-qtquick-shapes qml6-module-qtquick-effects
    qml6-module-qtquick-window qml6-module-qtqml-workerscript
    network-manager ddcutil brightnessctl libnotify-bin libglib2.0-bin
    fish swappy grim slurp wl-clipboard cliphist fuzzel wf-recorder
    dconf-cli papirus-icon-theme fonts-jetbrains-mono
)
# Optional: nice-to-have, individually skipped with a warning if unavailable.
APT_OPTIONAL=( sassc lm-sensors power-profiles-daemon )
# Known-absent from trixie (documented, NOT fatal):
#   dart-sass          -> sassc + a `sass` shim installed into the prefix
#   gpu-screen-recorder, wl-screenrec -> era cli falls back to wf-recorder
#   qt6-imageformats   -> use PNG/JPEG wallpapers (no WebP/TIFF QML plugin)
#   hyprland           -> not in trixie main; --with-hyprland handles it

# -----------------------------------------------------------------------------
# 2. RUNTIME STATE
# -----------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOGS/install-$TS.log"
if mkdir -p "$LOGS" "$STATE" "$BACKUPS" 2>/dev/null; then
    :
else
    # Not root (e.g. plain --help): log + state to /tmp instead; a real
    # install run still fails fast with a clear message in preflight.
    LOG_FILE="/tmp/caelestia-install-$TS.log"
    STATE_FALLBACK="/tmp/caelestia-state-$TS"
    mkdir -p "$STATE_FALLBACK"
    TOUCHPOINT_NEW="$STATE_FALLBACK/touchpoints.$TS.new"
fi
CURRENT_STAGE="(pre)"
FAILED_STAGE=""
PREFIX_SWAPPED=0          # 1 once a previous prefix was moved to backups
VENV_SWAPPED=0            # 1 once a previous venv was moved to backups
VENV_CREATED=0            # 1 if this run created a venv where none existed
SUDOERS_WANTED=1
FONTS_WANTED=1
HYPR_WANTED=0
ASSUME_YES=0
FORCE_DISTRO=0
KEEP_BUILD=0
SOURCE_DIR=""
START_AFTER=""
STOP_AFTER=""
declare -A REF_OVERRIDE=()   # component -> ref (from --ref)
BACKUP_KEEP=2                # previous prefixes retained under backups/

# Touchpoints created this run (removed again on rollback).
TOUCHPOINT_NEW="${TOUCHPOINT_NEW:-$STATE/touchpoints.$TS.new}"
mkdir -p "$(dirname "$TOUCHPOINT_NEW")" 2>/dev/null || true
: > "$TOUCHPOINT_NEW" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 3. LOGGING
# -----------------------------------------------------------------------------
if [ -t 2 ]; then
    C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'; C_OK=$'\033[0;32m'
    C_INFO=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_ERR=""; C_WARN=""; C_OK=""; C_INFO=""; C_BOLD=""; C_OFF=""
fi

# Mirror everything (stdout+stderr) into the log file from here on.
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '%s[%s]%s %s\n' "$C_INFO" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

stage_banner() {
    printf '\n%s========== STAGE: %s ==========%s\n' "$C_BOLD" "$*" "$C_OFF"
}

# -----------------------------------------------------------------------------
# 4. SMALL HELPERS
# -----------------------------------------------------------------------------
# ver_ge A B -> success if version A >= B (dotted, numeric)
ver_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# dpkg_version PKG -> installed version ("" when absent)
dpkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

# strip Debian epoch/revision: "1:3.6.2-2" -> "3.6.2"
upstream_version() {
    printf '%s' "${1#*:}" | sed -E 's/-[^-]*$//; s/\+.*$//'
}

track_touchpoint() {  # record system files we create so rollback can undo them
    printf '%s\n' "$1" >> "$TOUCHPOINT_NEW"
}

# -----------------------------------------------------------------------------
# 5. TRAPS, ROLLBACK AND FAILURE SEMANTICS
# -----------------------------------------------------------------------------
# The EXIT trap is the single authority for cleanup. Every failure path (set -e,
# explicit die, or a signal) funnels into it with a non-zero exit code.
trap 'on_exit $?' EXIT
trap 'on_signal INT'  INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP'  HUP

on_signal() {
    err "Interrupted by $1 during stage '$CURRENT_STAGE' — rolling back."
    exit 130
}

rollback() {
    # A rollback runs from the EXIT trap: it must never fail itself, so
    # disable errexit for its duration.
    set +e
    log "Rolling back failed install run..."

    # 1. Build artifacts: always discard (they are reproducible from pins).
    if [ "$KEEP_BUILD" = "0" ]; then
        rm -rf -- "$BUILD" || true
    else
        warn "--keep-build given; build tree kept at $BUILD"
    fi

    # 2. Prefix: restore the pre-run tree if we displaced it; otherwise this
    #    was a first install, so remove the half-built tree entirely.
    if [ "$PREFIX_SWAPPED" = "1" ]; then
        local latest
        latest="$(ls -1dt "$BACKUPS"/prefix-* 2>/dev/null | head -n1 || true)"
        rm -rf -- "$PREFIX"
        if [ -n "$latest" ] && [ -d "$latest" ]; then
            mv -- "$latest" "$PREFIX"
            log "Restored previous prefix from $latest."
        else
            log "No backup prefix found; partial prefix removed."
        fi
    elif [ -d "$PREFIX" ]; then
        rm -rf -- "$PREFIX"
        log "Removed partially built prefix (first install)."
    fi

    # 3. venv: restore the previous one, or drop a half-built fresh one.
    if [ "$VENV_SWAPPED" = "1" ]; then
        local latest_venv
        latest_venv="$(ls -1dt "$BACKUPS"/venv-* 2>/dev/null | head -n1 || true)"
        rm -rf -- "$VENV"
        if [ -n "$latest_venv" ] && [ -d "$latest_venv" ]; then
            mv -- "$latest_venv" "$VENV"
            log "Restored previous venv from $latest_venv."
        fi
    elif [ "$VENV_CREATED" = "1" ] && [ -d "$VENV" ]; then
        rm -rf -- "$VENV"
        log "Removed partially built venv (first install)."
    fi

    # 4. System touchpoints created by this run (wrappers, profile.d, ...).
    if [ -f "$TOUCHPOINT_NEW" ]; then
        while IFS= read -r f; do
            [ -e "$f" ] && rm -f -- "$f"
        done < "$TOUCHPOINT_NEW"
        log "Removed system touchpoints created by this run."
    fi

    # 5. Partially downloaded Node layer (content-addressed, safe to drop).
    rm -rf -- "$NODE_ROOT/$NODE_VERSION.partial" || true

    log "Rollback complete. Log kept at $LOG_FILE"
}

on_exit() {
    local rc=$1
    if [ "$rc" -eq 0 ]; then
        ok "Install finished successfully. Log: $LOG_FILE"
    else
        FAILED_STAGE="${CURRENT_STAGE:-unknown}"
        err "Install FAILED during stage '$FAILED_STAGE' (exit $rc)."
        rollback || true
        err "Fix the issue above and re-run. You can resume with:"
        err "    sudo $0 --start-after $FAILED_STAGE"
    fi
    return "$rc"
}

# -----------------------------------------------------------------------------
# 6. ARGUMENT PARSING
# -----------------------------------------------------------------------------
usage() {
    awk 'NR>1 && /^set -Eeuo pipefail/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)          usage ;;
            --doctor)           MODE_DOCTOR=1 ;;
            --uninstall)        MODE_UNINSTALL=1 ;;
            --yes|-y)           ASSUME_YES=1 ;;
            --force)            FORCE_DISTRO=1 ;;
            --keep-build)       KEEP_BUILD=1 ;;
            --no-fonts)         FONTS_WANTED=0 ;;
            --without-sudoers)  SUDOERS_WANTED=0 ;;
            --with-hyprland)    HYPR_WANTED=1 ;;
            --source-dir)       [ $# -ge 2 ] || die "--source-dir needs a path"
                                SOURCE_DIR="$2"; shift ;;
            --start-after)      [ $# -ge 2 ] || die "--start-after needs a stage name"
                                START_AFTER="$2"; shift ;;
            --stop-after)       [ $# -ge 2 ] || die "--stop-after needs a stage name"
                                STOP_AFTER="$2"; shift ;;
            --ref)              [ $# -ge 2 ] || die "--ref needs COMP=REF (lib|shell|cli|qs|dots)"
                                case "$2" in
                                    lib=*)   REF_OVERRIDE[lib]="${2#lib=}" ;;
                                    shell=*) REF_OVERRIDE[shell]="${2#shell=}" ;;
                                    cli=*)   REF_OVERRIDE[cli]="${2#cli=}" ;;
                                    qs=*)    REF_OVERRIDE[qs]="${2#qs=}" ;;
                                    dots=*)  REF_OVERRIDE[dots]="${2#dots=}" ;;
                                    *) die "--ref component must be lib|shell|cli|qs|dots" ;;
                                esac
                                shift ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    # Refuse pins that cannot build on system Qt 6.8 — better an honest error
    # now than a broken desktop later. (Bypass deliberately: --force.)
    if [ "${REF_OVERRIDE[shell]:-}" ] && [ "${REF_OVERRIDE[shell]}" != "v1.1.1" ] \
       && [ "${REF_OVERRIDE[shell]}" != "v1.1.0" ] && [ "${REF_OVERRIDE[shell]}" != "v1.0.0" ] \
       && [ "$FORCE_DISTRO" = "0" ]; then
        die "shell pin '${REF_OVERRIDE[shell]}' requires Qt >= 6.9 (see DESIGN CONTRACT in header). \
Parrot ships Qt 6.8.2; use the default v1.1.1 pin or pass --force if you really ported a newer Qt."
    fi
}

MODE_DOCTOR=0
MODE_UNINSTALL=0

# -----------------------------------------------------------------------------
# 7. MULTIARCH RESOLUTION (dynamic, never hardcoded)
# -----------------------------------------------------------------------------
# Debian trixie puts native libraries in /usr/lib/<triplet>. We mirror that
# inside our own prefix and resolve the triplet three ways, most authoritative
# first, so the same script works on x86_64, aarch64 and future ports.
resolve_arch() {
    local arch=""
    if command -v dpkg-architecture >/dev/null 2>&1; then
        arch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
    fi
    if [ -z "$arch" ] && command -v gcc >/dev/null 2>&1; then
        arch="$(gcc -dumpmachine 2>/dev/null || true)"
    fi
    if [ -z "$arch" ]; then
        case "$(uname -m)" in
            x86_64)  arch="x86_64-linux-gnu" ;;
            aarch64) arch="aarch64-linux-gnu" ;;
            *)       arch="$(uname -m)-linux-gnu" ;;
        esac
    fi
    printf '%s' "$arch"
}

ARCH="$(resolve_arch)"
LIBDIR_REL="lib/$ARCH"                    # prefix-relative
QMLDIR_REL="$LIBDIR_REL/qt6/qml"          # single QML import root for everything
LIBDIR_ABS="$PREFIX/$LIBDIR_REL"
QMLDIR_ABS="$PREFIX/$QMLDIR_REL"

# -----------------------------------------------------------------------------
# 8. LOCK FILE (persistent pins; created on first install, editable by admin)
# -----------------------------------------------------------------------------
load_or_create_lock() {
    if [ -f "$LOCK_FILE" ]; then
        log "Using existing pin lock: $LOCK_FILE"
        # shellcheck disable=SC1090,SC1091
        source "$LOCK_FILE"
        # --ref overrides win over the lock for this run and are persisted.
    fi
    LIB_REF="${REF_OVERRIDE[lib]:-${LIB_REF:-$DEFAULT_LIB_REF}}"
    SHELL_REF="${REF_OVERRIDE[shell]:-${SHELL_REF:-$DEFAULT_SHELL_REF}}"
    CLI_REF="${REF_OVERRIDE[cli]:-${CLI_REF:-$DEFAULT_CLI_REF}}"
    QS_REF="${REF_OVERRIDE[qs]:-${QS_REF:-$DEFAULT_QS_REF}}"
    DOTS_REF="${REF_OVERRIDE[dots]:-${DOTS_REF:-$DEFAULT_DOTS_REF}}"

    cat > "$LOCK_FILE" <<EOF
# Caelestia pin lock — generated $TS by install.sh
# Edit deliberately; this is the compatibility contract of the deployment.
# shellcheck shell=bash
LIB_REF="$LIB_REF"
SHELL_REF="$SHELL_REF"
CLI_REF="$CLI_REF"
QS_REF="$QS_REF"
DOTS_REF="$DOTS_REF"
NODE_VERSION="$NODE_VERSION"
EOF
    chmod 0644 "$LOCK_FILE"
    log "Pins: lib=$LIB_REF shell=$SHELL_REF cli=$CLI_REF qs=$QS_REF dots=$DOTS_REF"
}

# =============================================================================
#                            STAGE IMPLEMENTATIONS
# =============================================================================

# -----------------------------------------------------------------------------
stage_preflight() {
    stage_banner "preflight"

    [ "$(id -u)" -eq 0 ] || die "This installer must run as root (try sudo)."

    # -- Distro gate: Parrot 7.x or Debian 13.x (both are trixie). -----------
    if [ "$FORCE_DISTRO" = "0" ]; then
        local id ver
        id="$(. /etc/os-release && printf '%s' "$ID")"
        ver="$(. /etc/os-release && printf '%s' "$VERSION_ID")"
        case "$id/$ver" in
            parrot/7*|debian/13*) : ;;
            *) die "Unsupported base: $id $ver. This installer targets Parrot OS 7 / Debian 13 \
(trixie). Re-run with --force to override the check at your own risk." ;;
        esac
    fi

    # -- Version gates (fail fast, never "probably fine") --------------------
    local qt_ver py_ver wp_ver cmake_ver
    qt_ver="$(upstream_version "$(dpkg_version libqt6core6t64)")"
    py_ver="$(python3 -c 'import platform; print(platform.python_version())')"
    wp_ver="$(upstream_version "$(dpkg_version wayland-protocols)")"
    cmake_ver="$(cmake --version 2>/dev/null | head -n1 | awk '{print $3}' || true)"

    # The qt6 dev packages may not be installed yet (stage apt-deps installs
    # them), so only hard-fail when they ARE installed and still too old.
    if [ -n "$qt_ver" ]; then
        ver_ge "$qt_ver" "$QT_MIN" || die "System Qt $qt_ver < required $QT_MIN. \
Parrot 7 ships 6.8.2 which satisfies lib; refusing to proceed on this system."
        ver_ge "$qt_ver" "6.9" && warn "System Qt $qt_ver >= 6.9: newer Caelestia pins \
may now be buildable — review the lock file (default pins stay on the tested set)."
    fi
    ver_ge "$py_ver" "$PY_MIN" || die "python3 $py_ver < required $PY_MIN (cli needs >= 3.13)."
    [ -n "$wp_ver" ] && { ver_ge "$wp_ver" "$WAYLAND_PROTOCOLS_MIN" \
        || die "wayland-protocols $wp_ver < required $WAYLAND_PROTOCOLS_MIN (lib screenshot module)."; }
    [ -n "$cmake_ver" ] && { ver_ge "$cmake_ver" "$CMAKE_MIN" \
        || die "cmake $cmake_ver < required $CMAKE_MIN (lib needs >= 3.25)."; }

    # -- Resources ------------------------------------------------------------
    if ! command -v curl >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends curl >/dev/null 2>&1 \
            || die "curl is required (apt install curl) and could not be installed."
    fi
    local need_kb=2500000 avail_kb   # ~2.5 GB for sources, builds, node, fonts
    avail_kb="$(df --output=avail /opt | tail -n1 | tr -d ' ')"
    [ "$avail_kb" -ge "$need_kb" ] || warn "Low disk space on /opt: ${avail_kb}kB available \
(recommended >= 2.5 GB)."

    # -- Network reachability (fail early with a clear message) ---------------
    if ! curl -fsS -m 15 -o /dev/null https://github.com; then
        die "Cannot reach github.com — network required for first install \
(offline re-installs can reuse $SRC clones)."
    fi

    mkdir -p "$SRC" "$BUILD" "$BACKUPS" "$STATE"
    ok "Preflight passed (arch=$ARCH, python=$py_ver)."
}

# -----------------------------------------------------------------------------
stage_apt_deps() {
    stage_banner "apt-deps"

    # Additive only: every package here is a standard trixie package and none
    # of them replaces or downgrades base system libraries.
    apt-get update -y
    apt-get install -y --no-install-recommends "${APT_BUILD[@]}" "${APT_RUNTIME[@]}"

    # Optional deps: install one by one, warn (never fail) when unavailable.
    local p
    for p in "${APT_OPTIONAL[@]}"; do
        if apt-get install -y --no-install-recommends "$p" 2>/dev/null; then
            ok "optional: $p installed"
        else
            warn "optional package '$p' unavailable on this system — skipped."
        fi
    done

    # Known gaps on trixie, handled explicitly so nobody is surprised later:
    if ! command -v wl-screenrec >/dev/null 2>&1 && ! command -v gpu-screen-recorder >/dev/null 2>&1; then
        warn "gpu-screen-recorder / wl-screenrec are not in Debian 13. \
Screen recording will use wf-recorder (installed)."
    fi
    if ! dpkg -s qt6-imageformats >/dev/null 2>&1; then
        warn "qt6-imageformats is not packaged in trixie — use PNG/JPEG wallpapers \
(no WebP/TIFF QML image plugins)."
    fi

    if [ "$HYPR_WANTED" = "1" ]; then
        if apt-get install -y --no-install-recommends hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk; then
            ok "Hyprland + portals installed."
        else
            warn "Hyprland is not available from your current apt sources. On plain \
Debian it lives in trixie-backports; on Parrot enable it with:
  echo 'deb http://deb.debian.org/debian trixie-backports main' > /etc/apt/sources.list.d/backports.list
  apt update && apt install -t trixie-backports hyprland
(review Parrot's mixing policy first), then re-run with --with-hyprland."
        fi
    fi

    # Re-run the version gates now that dev packages exist (belt and braces).
    local qt_ver
    qt_ver="$(upstream_version "$(dpkg_version libqt6core6t64)")"
    ver_ge "$qt_ver" "$QT_MIN" || die "Installed Qt $qt_ver still < $QT_MIN — aborting."
    ok "Build and runtime dependencies installed (Qt $qt_ver)."
}

# -----------------------------------------------------------------------------
# fetch_source NAME URL REF DIR
#   Clones (or reuses) a checkout at an exact tag/branch/commit and sets the
#   global FETCHED_SHA to the resolved commit SHA. Commit SHAs are fetched
#   explicitly so shallow repos still land on the exact pinned tree (GitHub
#   allows fetch-by-SHA).
FETCHED_SHA=""
fetch_source() {
    local name="$1" url="$2" ref="$3" dir="$4"

    if [ -n "$SOURCE_DIR" ]; then
        local local_src="$SOURCE_DIR/$name"
        [ -d "$local_src" ] || die "--source-dir: expected $local_src to exist."
        rm -rf -- "$dir"
        cp -a -- "$local_src" "$dir"
        FETCHED_SHA="$(git -C "$dir" rev-parse HEAD)"
        ok "sources: $name copied from $local_src ($FETCHED_SHA)"
        return 0
    fi

    if [ -d "$dir/.git" ]; then
        local cur want
        cur="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
        want="$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null | head -c40 || true)"
        if [ -n "$want" ] && [ "$cur" = "$want" ]; then
            log "sources: $name already at $ref ($cur) — reusing clone."
            FETCHED_SHA="$cur"
            return 0
        fi
    fi

    rm -rf -- "$dir"
    log "sources: fetching $name @ $ref ..."
    if ! git clone --quiet --depth 1 --branch "$ref" "$url" "$dir" 2>/dev/null; then
        # Not a branch/tag name (or branch clone failed): fetch the raw SHA.
        rm -rf -- "$dir"
        git clone --quiet --depth 1 --no-checkout "$url" "$dir"
        git -C "$dir" fetch --quiet --depth 1 origin "$ref"
        git -C "$dir" checkout --quiet --detach FETCH_HEAD
    fi
    FETCHED_SHA="$(git -C "$dir" rev-parse HEAD)"
    ok "sources: $name @ $ref -> $FETCHED_SHA"
}

stage_sources() {
    stage_banner "sources"
    fetch_source lib "$URL_LIB" "$LIB_REF" "$SRC/lib";             LIB_SHA="$FETCHED_SHA"
    fetch_source quickshell "$URL_QS" "$QS_REF" "$SRC/quickshell"; QS_SHA="$FETCHED_SHA"
    fetch_source shell "$URL_SHELL" "$SHELL_REF" "$SRC/shell";     SHELL_SHA="$FETCHED_SHA"
    fetch_source cli "$URL_CLI" "$CLI_REF" "$SRC/cli";             CLI_SHA="$FETCHED_SHA"
    fetch_source caelestia "$URL_DOTS" "$DOTS_REF" "$SRC/caelestia"; DOTS_SHA="$FETCHED_SHA"

    # Persist resolved SHAs into the lock for auditing / reproducible re-runs.
    cat >> "$LOCK_FILE" <<EOF
# resolved $TS
LIB_SHA="$LIB_SHA"
QS_SHA="$QS_SHA"
SHELL_SHA="$SHELL_SHA"
CLI_SHA="$CLI_SHA"
DOTS_SHA="$DOTS_SHA"
EOF
}

# -----------------------------------------------------------------------------
stage_node_layer() {
    stage_banner "node-layer (TypeScript toolchain, fully local)"

    local node_dir="$NODE_ROOT/$NODE_VERSION"
    if [ -x "$node_dir/bin/node" ] && [ "$("$node_dir/bin/node" --version)" = "$NODE_VERSION" ]; then
        ok "Node $NODE_VERSION already provisioned."
    else
        local arch_tag sha tarball
        case "$ARCH" in
            x86_64-linux-gnu)  arch_tag="x64";   sha="$NODE_SHA_X64" ;;
            aarch64-linux-gnu) arch_tag="arm64"; sha="$NODE_SHA_ARM64" ;;
            *) die "No pinned Node.js build for $ARCH (pin a new one in the script header)." ;;
        esac
        tarball="node-$NODE_VERSION-linux-$arch_tag.tar.xz"
        log "Downloading $tarball ..."
        mkdir -p "$NODE_ROOT"
        curl -fsSL -o "$NODE_ROOT/$tarball" "https://nodejs.org/dist/$NODE_VERSION/$tarball"
        printf '%s  %s\n' "$sha" "$NODE_ROOT/$tarball" | sha256sum -c - \
            || die "Node tarball SHA256 mismatch — refusing to install."
        mkdir -p "$NODE_ROOT/$NODE_VERSION.partial"
        tar -xJf "$NODE_ROOT/$tarball" -C "$NODE_ROOT/$NODE_VERSION.partial" --strip-components=1
        rm -rf -- "$node_dir"
        mv -- "$NODE_ROOT/$NODE_VERSION.partial" "$node_dir"
        rm -f -- "$NODE_ROOT/$tarball"
        ok "Node $NODE_VERSION installed under $node_dir (sha256 verified)."
    fi
    ln -sfn "$node_dir" "$NODE_ROOT/current"

    # npm behaves strictly locally: cache inside /opt, no update nags.
    mkdir -p "$NODE_ROOT/cache"
}

# -----------------------------------------------------------------------------
# cmake helpers — one flag contract shared by every C++ component.
#
# Rationale (see blueprint §5 for the full derivation):
#   CMAKE_INSTALL_PREFIX     everything stays inside /opt/caelestia/prefix
#   CMAKE_INSTALL_LIBDIR     Debian multiarch triplet, resolved dynamically
#   RPATH                    absolute into our own prefix only; Qt/system libs
#                            keep resolving through ldconfig — we never
#                            shadow or rewrite system sonames
#   -O2 (not -O3)            distro-standard optimization; -O3 in Qt-heavy QML
#                            plugins has historically tripped compiler bugs
#   _FORTIFY_SOURCE=2 + SSP  standard Debian hardening, works in shared libs
#   -Wl,--as-needed          DT_NEEDED lists stay minimal (no accidental
#                            linkage -> no accidental soname coupling)
cmake_configure() {
    local srcdir="$1" builddir="$2"; shift 2
    rm -rf -- "$builddir"
    cmake -S "$srcdir" -B "$builddir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR="$LIBDIR_REL" \
        -DCMAKE_INSTALL_RPATH="$LIBDIR_ABS" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DCMAKE_CXX_FLAGS_RELEASE="-O2 -g -DNDEBUG -Wp,-D_FORTIFY_SOURCE=2 -fstack-protector-strong" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,--as-needed -Wl,-z,relro -Wl,-z,now" \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--as-needed -Wl,-z,relro" \
        -DDISTRIBUTOR="Parrot-Caelestia-Port" \
        "$@"
}

cmake_build_install() {
    local builddir="$1" name="$2"
    cmake --build "$builddir" --parallel "$(nproc)"
    cmake --install "$builddir"
    ok "$name installed into $PREFIX."
}

# displacement_guard — called by the first prefix-mutating stage: moves any
# previous install tree to backups so rollback can restore it. CMake bakes
# absolute paths (RPATH, QML dirs) into its outputs, so we build directly at
# the final location instead of renaming a staging tree.
displacement_guard() {
    if [ "$PREFIX_SWAPPED" = "0" ] && [ -d "$PREFIX" ]; then
        mv -- "$PREFIX" "$BACKUPS/prefix-$TS"
        PREFIX_SWAPPED=1
        log "Previous install tree moved to $BACKUPS/prefix-$TS (rollback point)."
    fi
    mkdir -p "$PREFIX"
}

stage_quickshell() {
    stage_banner "quickshell ($QS_REF)"
    displacement_guard
    local b="$BUILD/quickshell"
    # CRASH_REPORTER=OFF: v0.2.1's crash handler links google-breakpad, which
    # Debian trixie does not ship. Everything else stays at upstream defaults
    # (Wayland + Hyprland IPC + layershell + session lock + screencopy ON).
    # INSTALL_QMLDIR puts Quickshell's own QML modules into the same single
    # QML root as the Caelestia modules.
    cmake_configure "$SRC/quickshell" "$b" \
        -DINSTALL_QMLDIR="$QMLDIR_ABS" \
        -DCRASH_REPORTER=OFF
    cmake_build_install "$b" "quickshell"
}

stage_lib() {
    stage_banner "lib (C++ backing library)"
    displacement_guard
    local b="$BUILD/lib"
    # lib has no git tags (rolling repo) and its CMake derives VERSION via
    # `git describe --tags` — which fails on a shallow/untagged clone. Pass an
    # explicit VERSION/GIT_REVISION so the build is deterministic; both end up
    # recorded in the component manifest the library installs.
    # The theming helper ships a sudoers drop-in; it must go to the REAL
    # /etc/sudoers.d to function (the only privileged file we install).
    if [ "$SUDOERS_WANTED" = "1" ]; then
        cmake_configure "$SRC/lib" "$b" \
            -DVERSION="0.0.0" \
            -DGIT_REVISION="$LIB_SHA" \
            -DINSTALL_SUDOERS=ON \
            -DSUDOERS_DIR="/etc/sudoers.d" \
            -DBUILD_TESTING=OFF
    else
        cmake_configure "$SRC/lib" "$b" \
            -DVERSION="0.0.0" \
            -DGIT_REVISION="$LIB_SHA" \
            -DINSTALL_SUDOERS=OFF \
            -DBUILD_TESTING=OFF
    fi
    cmake_build_install "$b" "caelestia-lib"

    # sudo(8) ignores files containing a dot in sudoers.d — normalize name
    # and permissions of whatever the upstream install produced (covers any
    # future "*.sudoers" or similar dotted names, not just today's).
    if [ "$SUDOERS_WANTED" = "1" ]; then
        local f
        while IFS= read -r f; do
            [ -e "$f" ] || continue
            mv -- "$f" "${f%.*}"
            log "Renamed sudoers drop-in: $f -> ${f%.*}"
        done < <(find /etc/sudoers.d -maxdepth 1 -type f -name 'caelestia*' \
                 \( -name '*.*' -o -name 'caelestia-theming.sudoers' \) 2>/dev/null)
        if [ -f /etc/sudoers.d/caelestia-theming ]; then
            chown root:root /etc/sudoers.d/caelestia-theming
            chmod 0440 /etc/sudoers.d/caelestia-theming
            if command -v visudo >/dev/null 2>&1; then
                visudo -cf /etc/sudoers.d/caelestia-theming >/dev/null \
                    || die "Generated sudoers file failed visudo validation."
            fi
            track_touchpoint /etc/sudoers.d/caelestia-theming
            ok "Theming sudoers drop-in installed: /etc/sudoers.d/caelestia-theming"
        fi
    fi
}

stage_shell() {
    stage_banner "shell (QML desktop shell, $SHELL_REF)"
    displacement_guard
    local b="$BUILD/shell"
    # v1.1.1 install destinations are prefix-RELATIVE cache strings whose
    # upstream defaults are Arch-style ("usr/lib/qt6/qml"). Point every one of
    # them at our multiarch layout inside the staging prefix.
    cmake_configure "$SRC/shell" "$b" \
        -DINSTALL_QMLDIR="$QMLDIR_REL" \
        -DINSTALL_LIBDIR="$LIBDIR_REL/caelestia" \
        -DINSTALL_QSCONFDIR="etc/xdg/quickshell/caelestia"
    cmake_build_install "$b" "caelestia-shell"
}

# -----------------------------------------------------------------------------
stage_ts_integrations() {
    stage_banner "caelestia (TypeScript integrations from the dots repo)"

    local node_bin="$NODE_ROOT/current/bin"
    export PATH="$node_bin:$PATH"
    export npm_config_cache="$NODE_ROOT/cache"
    export npm_config_update_notifier=false
    export npm_config_fund=false
    export npm_config_audit=false

    local out_dir="$PREFIX/share/caelestia/extensions"
    mkdir -p "$out_dir"

    # --- VS Code / VSCodium integration --------------------------------------
    local vscode_dir="$SRC/caelestia/vscode/caelestia-vscode-integration"
    if [ -f "$vscode_dir/package.json" ]; then
        log "Building VS Code integration (pinned Node $(node --version)) ..."
        (
            cd "$vscode_dir"
            # No lockfile is shipped; npm install resolves from the pinned
            # package.json inside our private Node layer (never global).
            if [ -f package-lock.json ]; then
                npm ci --no-fund --no-audit
            else
                npm install --no-fund --no-audit
            fi
            # Compile TypeScript (same script upstream uses for packaging).
            ./node_modules/.bin/tsc -p ./
            # Package a .vsix for the user to install per-editor; fall back to
            # shipping the compiled tree if vsce refuses (e.g. missing license).
            if ./node_modules/.bin/vsce package --no-dependencies -o "$out_dir/caelestia-vscode-integration.vsix" 2>/tmp/vsce.err; then
                ok "VSIX packaged: $out_dir/caelestia-vscode-integration.vsix"
            else
                warn "vsce packaging failed ($(head -n1 /tmp/vsce.err)); shipping compiled tree instead."
                rm -rf -- "$out_dir/caelestia-vscode-integration"
                cp -a -- "$vscode_dir" "$out_dir/caelestia-vscode-integration"
                rm -rf -- "$out_dir/caelestia-vscode-integration/node_modules"
            fi
        )
    else
        warn "No VS Code integration found at this dots pin — skipped."
    fi

    # --- Firefox integration (added upstream AFTER our era pin) --------------
    local ff_dir="$SRC/caelestia/firefox/caelestia-firefox-integration"
    if [ -f "$ff_dir/package.json" ]; then
        log "Building Firefox integration ..."
        (
            cd "$ff_dir"
            [ -f package-lock.json ] && npm ci --no-fund --no-audit || npm install --no-fund --no-audit
            ./node_modules/.bin/web-ext build --artifacts-dir "$out_dir" >/dev/null 2>&1 \
                || warn "web-ext build failed; source kept at $ff_dir"
        )
    else
        log "Firefox integration does not exist at the pinned dots commit — \
skipped (it is a later upstream addition; bump DOTS_REF to include it)."
    fi
    ok "TypeScript layer handled with local node_modules only (no global npm state)."
}

# -----------------------------------------------------------------------------
stage_cli() {
    stage_banner "cli (Python, virtualenv-isolated)"

    # Displace any previous venv to backups (restored by rollback on failure).
    if [ -d "$VENV" ]; then
        mv -- "$VENV" "$BACKUPS/venv-$TS"
        VENV_SWAPPED=1
    else
        VENV_CREATED=1
    fi

    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip wheel

    # Era pins for the cli's two runtime deps keep PyPI drift out of the
    # deployment (hatch-vcs ignores them at build time; they constrain the
    # *installed* runtime set).
    local constraints="$STATE/pip-constraints.txt"
    printf '%s\n%s\n' "$PIP_PIN_PILLOW" "$PIP_PIN_MYC" > "$constraints"

    # Build deps preinstalled + --no-build-isolation => the wheel build never
    # reaches out to PyPI for hatchling/hatch-vcs mid-build (reproducible).
    "$VENV/bin/pip" install --quiet hatchling hatch-vcs

    # hatch-vcs derives the version from git tags; our shallow commit-only
    # checkout has none, so pin the version explicitly (both env variants
    # setuptools-scm understands).
    export SETUPTOOLS_SCM_PRETEND_VERSION="1.0.0"
    export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_CAELESTIA="1.0.0"

    "$VENV/bin/pip" install --quiet \
        --no-build-isolation -c "$constraints" "$SRC/cli"

    # Fish completions, if this pin ships them (kept inside our prefix; fish
    # finds them via XDG_DATA_DIRS from the env file).
    if [ -f "$SRC/cli/completions/caelestia.fish" ]; then
        mkdir -p "$PREFIX/share/fish/vendor_completions.d"
        cp -- "$SRC/cli/completions/caelestia.fish" \
              "$PREFIX/share/fish/vendor_completions.d/"
    fi

    ln -sfn "$VENV/bin/caelestia" "$PREFIX/bin/caelestia"
    "$VENV/bin/caelestia" --version >/dev/null || true
    ok "cli installed into isolated venv: $VENV"
}

# -----------------------------------------------------------------------------
stage_fonts() {
    stage_banner "fonts (pinned downloads, prefix-local)"
    [ "$FONTS_WANTED" = "1" ] || { log "skipped (--no-fonts)"; return 0; }

    local fontdir="$PREFIX/share/fonts/truetype/caelestia"
    mkdir -p "$fontdir"

    fetch_font() {
        local name="$1" url="$2" sha="$3"
        local dest="$fontdir/$name"
        [ -f "$dest" ] && { log "font $name already present"; return 0; }
        curl -fsSL -o "$dest.tmp" "$url"
        printf '%s  %s\n' "$sha" "$dest.tmp" | sha256sum -c - \
            || { rm -f -- "$dest.tmp"; die "font $name SHA256 mismatch."; }
        mv -- "$dest.tmp" "$dest"
        ok "font $name installed (sha256 verified)."
    }

    fetch_font "Rubik-VF.ttf"        "$FONT_RUBIK_URL" "$FONT_RUBIK_SHA"
    fetch_font "MaterialSymbolsRounded-VF.ttf" "$FONT_MSR_URL" "$FONT_MSR_SHA"

    # Make fontconfig see prefix-local fonts system-wide for this session.
    XDG_DATA_DIRS="$PREFIX/share" fc-cache -f >/dev/null 2>&1 || true
}

# =============================================================================
#                        INTEGRATION (final cutover)
# =============================================================================
write_env_file() {
    cat > "$ENV_FILE" <<EOF
# /opt/caelestia/env — sourced by wrappers, profile.d and environment.d.
# Generated by install.sh on $TS. Hand-edits will be overwritten on reinstall.
export CAELESTIA_ROOT="$CAE_ROOT"

# Caelestia-owned binaries (qs, sass shim, theming helper)
export PATH="$PREFIX/bin:$NODE_ROOT/current/bin:\$PATH"

# Our shared objects (libcaelestia, quickshell libs) — private prefix only;
# system Qt/system libs still resolve via /etc/ld.so.cache as usual.
export LD_LIBRARY_PATH="$LIBDIR_ABS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

# Single QML import root for quickshell + caelestia + lib modules.
export QML2_IMPORT_PATH="$QMLDIR_ABS\${QML2_IMPORT_PATH:+:\$QML2_IMPORT_PATH}"
export QML_IMPORT_PATH="\$QML2_IMPORT_PATH"

# Let quickshell find the caelestia config, and desktop data (icons,
# fonts, fish completions) live in our prefix.
export XDG_CONFIG_DIRS="$PREFIX/etc/xdg:\${XDG_CONFIG_DIRS:-/etc/xdg}"
export XDG_DATA_DIRS="$PREFIX/share:/usr/local/share:/usr/share"

# For developers building Caelestia plugins against the installed lib.
export CMAKE_PREFIX_PATH="$PREFIX\${CMAKE_PREFIX_PATH:+:\$CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="$LIBDIR_ABS/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"

# Node layer behaves strictly locally.
export npm_config_cache="$NODE_ROOT/cache"
export npm_config_update_notifier=false
EOF
    chmod 0644 "$ENV_FILE"
}

write_wrappers() {
    # /usr/local/bin is for local-admin software by FHS convention and is
    # NOT managed by apt/dpkg on Debian — the right (and only) system-wide
    # integration point for our /opt payload.
    local wrapper
    for wrapper in caelestia qs; do
        cat > "/usr/local/bin/$wrapper" <<EOF
#!/bin/sh
# Caelestia wrapper — loads the isolated environment, then execs the real
# binary so the environment also applies to anything it spawns.
. $ENV_FILE
exec $PREFIX/bin/$wrapper "\$@"
EOF
        chmod 0755 "/usr/local/bin/$wrapper"
        track_touchpoint "/usr/local/bin/$wrapper"
    done

    # `sass` shim: the era cli invokes dart-sass' `sass -I dir input.scss`
    # for Discord theming; trixie only ships libsass' sassc (same positional
    # CLI for this usage). The shim keeps the feature working unchanged.
    if ! command -v sass >/dev/null 2>&1 && command -v sassc >/dev/null 2>&1; then
        cat > "$PREFIX/bin/sass" <<'EOF'
#!/bin/sh
# Minimal dart-sass -> sassc compatibility shim (positional compile-to-stdout).
exec sassc "$@"
EOF
        chmod 0755 "$PREFIX/bin/sass"
        ok "Installed sass->sassc shim at $PREFIX/bin/sass"
    fi
}

write_session_integration() {
    # Login shells.
    cat > /etc/profile.d/caelestia.sh <<EOF
# Source the Caelestia environment for login shells (installed by install.sh).
[ -f $ENV_FILE ] && . $ENV_FILE
EOF
    chmod 0644 /etc/profile.d/caelestia.sh
    track_touchpoint /etc/profile.d/caelestia.sh

    # systemd user sessions (covers Hyprland started via uwsm/display manager).
    mkdir -p /etc/environment.d
    cat > /etc/environment.d/50-caelestia.conf <<EOF
PATH=$PREFIX/bin:$NODE_ROOT/current/bin:/usr/local/bin:/usr/bin:/bin
LD_LIBRARY_PATH=$LIBDIR_ABS
QML2_IMPORT_PATH=$QMLDIR_ABS
XDG_CONFIG_DIRS=$PREFIX/etc/xdg:/etc/xdg
XDG_DATA_DIRS=$PREFIX/share:/usr/local/share:/usr/share
EOF
    chmod 0644 /etc/environment.d/50-caelestia.conf
    track_touchpoint /etc/environment.d/50-caelestia.conf
}

write_manifest() {
    # Snapshot of the system the build was validated against. verify.sh
    # compares these later — this is the apt-upgrade drift detector.
    cat > "$MANIFEST" <<EOF
# Caelestia install manifest — generated $TS
INSTALL_DATE="$(date -Is)"
ARCH="$ARCH"
LIB_REF="$LIB_REF"; LIB_SHA="$LIB_SHA"
SHELL_REF="$SHELL_REF"; SHELL_SHA="$SHELL_SHA"
CLI_REF="$CLI_REF"; CLI_SHA="$CLI_SHA"
QS_REF="$QS_REF"; QS_SHA="$QS_SHA"
DOTS_REF="$DOTS_REF"; DOTS_SHA="$DOTS_SHA"
NODE_VERSION="$NODE_VERSION"
EOF
    local p
    for p in libqt6core6t64 qt6-base-dev qt6-declarative-dev qt6-wayland-dev \
             wayland-protocols libpipewire-0.3-0 network-manager ddcutil \
             libavcodec61 libglib2.0-0t64 python3.13; do
        local v
        v="$(dpkg_version "$p")"
        [ -n "$v" ] && printf 'PKG_%s="%s"\n' "$p" "$v" >> "$MANIFEST"
    done
    chmod 0644 "$MANIFEST"
}

prune_backups() {
    local kind="$1" keep="$2" i=0
    while IFS= read -r d; do
        i=$((i + 1))
        [ "$i" -gt "$keep" ] && rm -rf -- "$d" && log "pruned old backup $d"
    done < <(ls -1dt "$BACKUPS"/"$kind"-* 2>/dev/null || true)
    return 0
}

stage_integrate() {
    stage_banner "integrate (finalize)"

    # Ship the diagnostic script alongside the install (if the operator kept
    # it next to install.sh) so `install.sh --doctor` works out of the box.
    local self_dir
    self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    if [ -f "$self_dir/verify.sh" ]; then
        install -m 0755 -- "$self_dir/verify.sh" "$CAE_ROOT/verify.sh"
    fi

    write_env_file
    write_wrappers
    write_session_integration
    write_manifest

    # Keep a bounded number of rollback points around.
    prune_backups prefix "$BACKUP_KEEP"
    prune_backups venv "$BACKUP_KEEP"

    # Merge this run's touchpoints into the persistent registry for --uninstall.
    cat "$TOUCHPOINT_NEW" >> "$STATE/touchpoints" 2>/dev/null || \
        cp -- "$TOUCHPOINT_NEW" "$STATE/touchpoints"
    rm -f -- "$TOUCHPOINT_NEW"

    # --- Post-install smoke test (failure here triggers full rollback) ------
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    command -v qs >/dev/null || die "wrapper 'qs' not on PATH after integrate."
    [ -x "$PREFIX/bin/qs" ] || die "$PREFIX/bin/qs missing."
    [ -x "$VENV/bin/caelestia" ] || die "venv caelestia missing."
    local libso
    libso="$(find "$LIBDIR_ABS" -maxdepth 1 -name 'libcaelestia.so.*' | head -n1 || true)"
    [ -n "$libso" ] || die "libcaelestia.so not installed."
    if ldd "$libso" 2>/dev/null | grep -q 'not found'; then
        die "libcaelestia has unresolved dependencies (see ldd output above)."
    fi

    ok "Caelestia is live under $PREFIX."
    cat <<'EOF'

  ─────────────────────────────────────────────────────────────
   NEXT STEPS (as your normal user, log out/in first):
     caelestia --help           # the CLI (from the isolated venv)
     caelestia shell -d         # start the shell (qs -c caelestia)
     code --install-extension \
       /opt/caelestia/prefix/share/caelestia/extensions/*.vsix
     sudo /opt/caelestia/verify.sh   # full diagnostic pass
   Apply the dotfiles (Hyprland config etc.) manually from
   /opt/caelestia/src/caelestia — the installer never touches $HOME.
  ─────────────────────────────────────────────────────────────
EOF
}

# =============================================================================
#                       DOCTOR / UNINSTALL MODES
# =============================================================================
mode_doctor() {
    if [ -x "$CAE_ROOT/verify.sh" ]; then
        exec "$CAE_ROOT/verify.sh"
    fi
    die "verify.sh not found at $CAE_ROOT/verify.sh — copy it there first \
(or run it directly from wherever you saved it)."
}

mode_uninstall() {
    if [ "$ASSUME_YES" != "1" ]; then
        printf 'This removes %s and every system touchpoint. Continue? [y/N] ' "$CAE_ROOT"
        read -r reply
        case "$reply" in y|Y|yes|YES) : ;; *) die "Aborted." ;; esac
    fi
    # Touchpoints: from the registry plus the well-known set.
    local f
    if [ -f "$STATE/touchpoints" ]; then
        while IFS= read -r f; do
            [ -e "$f" ] && rm -f -- "$f" && log "removed $f"
        done < <(sort -u "$STATE/touchpoints")
    fi
    for f in /usr/local/bin/caelestia /usr/local/bin/qs \
             /etc/profile.d/caelestia.sh \
             /etc/environment.d/50-caelestia.conf \
             /etc/sudoers.d/caelestia-theming; do
        [ -e "$f" ] && rm -f -- "$f" && log "removed $f"
    done
    rm -rf -- "$CAE_ROOT"
    ok "Caelestia removed. (apt packages installed by stage apt-deps were \
additive standard packages and are left in place — remove manually if desired.)"
    exit 0
}

# =============================================================================
#                                  MAIN
# =============================================================================
main() {
    parse_args "$@"
    [ "$MODE_UNINSTALL" = "1" ] && mode_uninstall
    [ "$MODE_DOCTOR" = "1" ] && mode_doctor

    load_or_create_lock

    # Ordered stage machine: lib -> shell -> caelestia -> cli (per the porting
    # contract), bracketed by the prerequisite stages they depend on.
    local -a stages=(
        preflight
        apt-deps
        sources
        node-layer
        quickshell
        lib
        shell
        ts-integrations
        cli
        fonts
        integrate
    )

    local -A stage_fn=(
        [preflight]=stage_preflight      [apt-deps]=stage_apt_deps
        [sources]=stage_sources          [node-layer]=stage_node_layer
        [quickshell]=stage_quickshell    [lib]=stage_lib
        [shell]=stage_shell              [ts-integrations]=stage_ts_integrations
        [cli]=stage_cli                  [fonts]=stage_fonts
        [integrate]=stage_integrate
    )

    local running=0 s
    for s in "${stages[@]}"; do
        if [ -n "$START_AFTER" ] && [ "$running" = 0 ]; then
            if [ "$s" = "$START_AFTER" ]; then
                running=1
            else
                log "skip (before --start-after): $s"
                continue
            fi
        fi
        CURRENT_STAGE="$s"
        "${stage_fn[$s]}"
        if [ -n "$STOP_AFTER" ] && [ "$s" = "$STOP_AFTER" ]; then
            ok "Stopped after stage '$s' as requested."
            break
        fi
    done
    exit 0
}

main "$@"
