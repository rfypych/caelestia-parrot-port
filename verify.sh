#!/usr/bin/env bash
# =============================================================================
#  verify.sh — Caelestia-on-Parrot post-install verification & diagnostics
# =============================================================================
#  Companion to install.sh. Verifies every layer of the deployment:
#
#    1.  /opt/caelestia layout and multiarch pathing
#    2.  Environment file + /usr/local/bin wrappers
#    3.  Dynamic linking of libcaelestia, the QML plugin and quickshell
#    4.  System version gates (Qt, wayland-protocols, python)
#    5.  Live QML smoke test + CLI<->shell IPC round trip (Wayland session)
#    6.  Python venv health and Node layer / VSIX artifacts
#    7.  Fonts, sudoers drop-in
#    8.  APT DRIFT: compares the system against the versions recorded in
#        /opt/caelestia/manifest.env at install time — the early-warning
#        detector for "a Parrot upgrade moved my libraries".
#
#  USAGE
#     sudo /opt/caelestia/verify.sh          # full pass
#     ./verify.sh --quick                    # skip live shell test
#
#  EXIT CODES   0 = all checks passed   2 = warnings only   1 = failures
# =============================================================================

set -uo pipefail
# NOTE: no `set -e` here on purpose — a diagnostic tool must keep running
# after a failed check and report everything it finds.

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

CAE_ROOT="/opt/caelestia"
PREFIX="$CAE_ROOT/prefix"
ENV_FILE="$CAE_ROOT/env"
MANIFEST="$CAE_ROOT/manifest.env"

PASS=0; WARN=0; FAIL=0

if [ -t 1 ]; then
    C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_B=$'\033[1m'; C_O=$'\033[0m'
else
    C_G=""; C_Y=""; C_R=""; C_B=""; C_O=""
fi

pass() { printf ' %sPASS%s  %s\n' "$C_G" "$C_O" "$*"; PASS=$((PASS+1)); }
warn() { printf ' %sWARN%s  %s\n' "$C_Y" "$C_O" "$*"; WARN=$((WARN+1)); }
fail() { printf ' %sFAIL%s  %s\n' "$C_R" "$C_O" "$*"; FAIL=$((FAIL+1)); }
vhead() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_O"; }

# ---------------------------------------------------------------- helpers ---
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
dpkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
upstream_version() { printf '%s' "${1#*:}" | sed -E 's/-[^-]*$//; s/\+.*$//'; }

ARCH="$(gcc -dumpmachine 2>/dev/null || uname -m)"
LIBDIR_ABS="$PREFIX/lib/$ARCH"
QMLDIR_ABS="$LIBDIR_ABS/qt6/qml"

# ------------------------------------------------------------- 1. layout ---
vhead "Install layout"
[ -d "$CAE_ROOT" ] && pass "$CAE_ROOT exists" || { fail "$CAE_ROOT missing"; exit 1; }
for f in "$ENV_FILE" "$CAE_ROOT/lock.env" "$MANIFEST" "$PREFIX/bin/qs" \
         "$CAE_ROOT/venv/bin/caelestia"; do
    if [ -e "$f" ]; then pass "present: ${f#$CAE_ROOT/}"; else fail "missing: ${f#$CAE_ROOT/}"; fi
done
if [ -d "$LIBDIR_ABS" ]; then
    pass "multiarch libdir lib/$ARCH (dynamically resolved)"
else
    fail "multiarch libdir $LIBDIR_ABS missing (was the install run on a different arch?)"
fi
if [ -d "$QMLDIR_ABS/Caelestia" ]; then
    pass "QML module: $QMLDIR_ABS/Caelestia"
else
    fail "QML module dir $QMLDIR_ABS/Caelestia missing"
fi
[ -d "$QMLDIR_ABS/Quickshell" ] && pass "QML module: Quickshell (private build)" \
    || warn "Quickshell QML modules not in prefix (system quickshell in use?)"

# ------------------------------------------------------ 2. env + wrappers ---
vhead "Environment and wrappers"
if bash -c ". '$ENV_FILE' && : \$QML2_IMPORT_PATH" 2>/dev/null; then
    pass "env file sources cleanly"
else
    fail "env file broken: $ENV_FILE"
fi
# shellcheck disable=SC1090
. "$ENV_FILE" 2>/dev/null || true
for w in caelestia qs; do
    if command -v "$w" >/dev/null 2>&1; then
        pass "wrapper resolves: $(command -v "$w")"
    else
        fail "wrapper not on PATH: $w (log out/in, or source $ENV_FILE)"
    fi
done
if command -v caelestia >/dev/null 2>&1 && caelestia --version >/dev/null 2>&1; then
    pass "cli responds: $(caelestia --version 2>&1 | head -n1)"
else
    fail "caelestia --version did not succeed"
fi

# --------------------------------------------------------- 3. linkage -------
vhead "Dynamic linking (system symbols untouched, private libs resolved)"
check_ldd() {
    local label="$1" bin="$2"
    local out
    out="$(ldd "$bin" 2>&1)" || { fail "$label: ldd failed"; return; }
    if grep -q 'not found' <<<"$out"; then
        fail "$label: unresolved libs:"$'\n'"$(grep 'not found' <<<"$out" | sed 's/^/         /')"
    else
        pass "$label: all $(grep -c '=>' <<<"$out") shared objects resolve"
    fi
    # Prove isolation: every Caelestia-owned library must come from the prefix.
    local ours
    ours="$(grep "=> $PREFIX/" <<<"$out" | wc -l)"
    if [ "$ours" -gt 0 ]; then pass "$label: $ours lib(s) served from private prefix"; fi
    return 0
}
libso="$(find "$LIBDIR_ABS" -maxdepth 1 -name 'libcaelestia.so.*' 2>/dev/null | head -n1)"
[ -n "$libso" ] && check_ldd "libcaelestia ($(basename "$libso"))" "$libso" \
    || fail "libcaelestia.so not found in $LIBDIR_ABS"
qs_plugin="$(find "$QMLDIR_ABS/Caelestia" -maxdepth 1 -name '*.so' 2>/dev/null | head -n1)"
[ -n "$qs_plugin" ] && check_ldd "shell QML plugin" "$qs_plugin" \
    || warn "no binary plugin in QML dir (pure-QML build?)"
[ -x "$PREFIX/bin/qs" ] && check_ldd "quickshell" "$PREFIX/bin/qs"

# ------------------------------------------------- 4. system version gates --
vhead "System version gates"
qt_ver="$(upstream_version "$(dpkg_version libqt6core6t64)")"
wp_ver="$(upstream_version "$(dpkg_version wayland-protocols)")"
py_ver="$(python3 -c 'import platform; print(platform.python_version())' 2>/dev/null || echo '?')"
if [ -n "$qt_ver" ]; then
    ver_ge "$qt_ver" "6.7" && pass "Qt $qt_ver >= 6.7 (lib gate)" \
        || fail "Qt $qt_ver < 6.7 — lib cannot run; system upgraded/downgraded?"
    ver_ge "$qt_ver" "6.9" && warn "Qt $qt_ver >= 6.9: you may unlock newer Caelestia pins"
else
    fail "libqt6core6t64 not installed (apt layer broken?)"
fi
ver_ge "$wp_ver" "1.37" && pass "wayland-protocols $wp_ver >= 1.37" \
    || fail "wayland-protocols $wp_ver < 1.37 (lib screenshot module)"
ver_ge "$py_ver" "3.13" && pass "python3 $py_ver >= 3.13" \
    || fail "python3 $py_ver < 3.13 (cli gate)"

# --------------------------------------- 5. live shell + IPC (needs session) -
vhead "Live shell & IPC"
if [ "$QUICK" = "1" ]; then
    warn "skipped (--quick)"
elif [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    warn "no Wayland session detected — start the shell from your Hyprland
         session and re-run, or test manually with:  caelestia shell -d"
else
    if ! pgrep -f 'qs -c caelestia' >/dev/null 2>&1; then
        caelestia shell -d >/dev/null 2>&1
        sleep 3
    fi
    if pgrep -f 'qs -c caelestia' >/dev/null 2>&1; then
        pass "shell process running (qs -c caelestia)"
        # IPC round trip: this is the real CLI -> quickshell IPC -> QML path.
        if qs -c caelestia ipc show >/dev/null 2>&1; then
            pass "IPC round trip: qs -c caelestia ipc show"
        else
            fail "IPC call failed (qs -c caelestia ipc show)"
        fi
        # Same trip through the Python CLI.
        if caelestia shell --show >/dev/null 2>&1; then
            pass "IPC round trip: caelestia shell --show"
        else
            warn "caelestia shell --show failed (older/newer cli semantics?)"
        fi
    else
        fail "shell did not stay running — inspect: qs -c caelestia -n (foreground)"
    fi
fi

# ------------------------------------------------------ 6. python + node ----
vhead "Python venv / Node layer"
if "$CAE_ROOT/venv/bin/pip" check >/dev/null 2>&1; then
    pass "venv pip check: dependency graph consistent"
else
    fail "venv pip check reported conflicts:"$'\n'"$($CAE_ROOT/venv/bin/pip check 2>&1 | sed 's/^/         /')"
fi
node_bin="$CAE_ROOT/node/current/bin/node"
if [ -x "$node_bin" ]; then
    pass "Node layer: $($node_bin --version)"
else
    fail "Node layer missing at $node_bin"
fi
vsix="$(find "$PREFIX/share/caelestia/extensions" -name '*.vsix' 2>/dev/null | head -n1)"
[ -n "$vsix" ] && pass "VS Code integration artifact: $(basename "$vsix")" \
    || warn "no .vsix artifact (build skipped or failed — check install log)"

# ------------------------------------------------------ 7. fonts + sudoers --
vhead "Fonts & sudoers"
if fc-list 2>/dev/null | grep -q "Material Symbols Rounded"; then
    pass "font: Material Symbols Rounded (icon glyphs)"
else
    warn "Material Symbols Rounded not in fontconfig cache — did fonts stage run? \
(log out/in or: XDG_DATA_DIRS=$PREFIX/share fc-cache -f)"
fi
fc-list 2>/dev/null | grep -q "Rubik" && pass "font: Rubik" || warn "Rubik font not cached"
if [ -f /etc/sudoers.d/caelestia-theming ]; then
    if [ "$(id -u)" = "0" ] && command -v visudo >/dev/null 2>&1; then
        visudo -cf /etc/sudoers.d/caelestia-theming >/dev/null 2>&1 \
            && pass "sudoers drop-in valid (theming helper)" \
            || fail "sudoers drop-in FAILED visudo validation"
    else
        pass "sudoers drop-in present (run as root to validate with visudo)"
    fi
else
    warn "no theming sudoers drop-in (--without-sudoers or missing)"
fi

# ------------------------------------------------------ 8. apt drift --------
vhead "APT drift vs install manifest"
if [ -f "$MANIFEST" ]; then
    drift=0
    while IFS='=' read -r key val; do
        case "$key" in
            PKG_*)
                pkg="${key#PKG_}"; val="${val%\"}"; val="${val#\"}"
                cur="$(dpkg_version "$pkg")"
                if [ -z "$cur" ]; then
                    warn "$pkg: recorded '$val' but NOT installed anymore"
                    drift=1
                elif [ "$cur" != "$val" ]; then
                    warn "$pkg: $val -> $cur (changed since install)"
                    drift=1
                fi
                ;;
        esac
    done < "$MANIFEST"
    [ "$drift" = "0" ] && pass "no drift: tracked system packages match manifest"
    [ "$drift" = "1" ] && printf '         (drift is expected after apt upgrades; if the\n         shell misbehaves, rebuild: sudo install.sh --start-after quickshell)\n'
else
    warn "no manifest found — install predates manifest support?"
fi

# ------------------------------------------------------------- summary ------
printf '\n%s────────────────────────────────────────%s\n' "$C_B" "$C_O"
printf '  Result: %s%d passed%s, %s%d warnings%s, %s%d failures%s\n' \
       "$C_G" "$PASS" "$C_O" "$C_Y" "$WARN" "$C_O" "$C_R" "$FAIL" "$C_O"
if [ "$FAIL" -gt 0 ]; then
    printf '  Status: BROKEN — fix the FAIL items above (install log: %s/logs/)\n' "$CAE_ROOT"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    printf '  Status: WORKING with warnings\n'
    exit 2
else
    printf '  Status: HEALTHY\n'
    exit 0
fi
