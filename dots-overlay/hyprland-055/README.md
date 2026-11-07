# Dotfiles overlay for Hyprland 0.55 (Parrot / Debian trixie)

The pinned caelestia dotfiles were written for the pre-0.55 Hyprland
config grammar. Hyprland 0.55 (the version in echo-backports) removed
or renamed several things, which produced ~150 config errors on first
login (red error overlay) and silently dropped every window/layer
rule. Apply this overlay AFTER copying the dotfiles to ~/.config:

1. Replace `~/.config/hypr/hyprland/rules.conf` with `rules.conf`
   from this folder. Changes vs the dots original:
   - matchers use the new grammar: `match:class`, `match:title`,
     `match:initial_title`, `match:xwayland`, `match:float`,
     `match:fullscreen_state_internal`
   - effects renamed to snake_case: `no_blur`, `no_dim`, `no_shadow`,
     `keep_aspect_ratio`, `idle_inhibit`, layer `no_anim`,
     `ignore_alpha`
   - boolean effects now need an explicit value: `float on`,
     `center on`, `opaque on`, `pin on`, `immediate on`
   - `size` percentages rewritten as monitor expressions,
     `move` rewritten with monitor/window variables

2. In `~/.config/hypr/hyprland/input.conf`: delete the
   `workspace_swipe = true` and `workspace_swipe_fingers = ...`
   lines from the `gestures {}` block (removed in 0.55) and add a
   gesture bind with your finger count, e.g.
   `gesture = 4, horizontal, workspace`

3. In `~/.config/hypr/hyprland/misc.conf`: delete `vfr = true` and
   `new_window_takes_over_fullscreen = ...` (both removed in 0.55).

4. In `~/.config/hypr/hyprland/keybinds.conf`: the `splitratio`
   dispatcher is gone in 0.55. Replace
   `binde = Super, Minus, splitratio, -0.1` with
   `binde = Super, Minus, layoutmsg, splitratio -0.1` (same for
   Super+Equal with 0.1).

5. App launch keybinds call `app2unit`, which this kit installs to
   ~/.local/bin. The graphical session PATH set via
   /etc/environment.d does NOT include ~/.local/bin, so every launch
   bind (terminal, browser, editor, file manager) silently does
   nothing. Add to `~/.config/hypr/hyprland/env.conf`:
   `env = PATH, /home/<user>/.local/bin:/opt/caelestia/prefix/bin:/opt/caelestia/node/current/bin:/usr/local/bin:/usr/bin:/bin`
   then `hyprctl reload`.

Verify with `hyprctl reload` then `hyprctl configerrors` (must print
nothing).

## Also needed on Parrot/Debian (found during the same bring-up)

- A Nerd Font symbols font. The bar's workspace labels are Nerd Font
  private-use glyphs and render as empty boxes without one. The kit's
  fonts stage installs Material Symbols + Rubik only. User-level fix:
  unzip NerdFontsSymbolsOnly (ryanoasis/nerd-fonts releases) into
  ~/.local/share/fonts/ and run `fc-cache -f`, then restart the shell.
- `qt6ct` package: the dots' env.conf sets
  QT_QPA_PLATFORMTHEME=qt6ct, which is not installed by default.
- `hyprland-guiutils` package (echo-backports): without it Hyprland
  nags that its GUI utilities are missing and has no crash dialog.
- Backlight permissions: /sys/class/backlight/*/brightness is
  root-only on Parrot and brightnessctl cannot write even from the
  active session. Add a udev rule granting the video group (the
  user must be a member):
  ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness /sys/class/backlight/%k/bl_power", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness /sys/class/backlight/%k/bl_power"

## Shell does not autostart (grey empty desktop)

The dots start the shell with a bare `exec-once = caelestia shell -d`.
That only works if the session environment already carries the
Caelestia variables (LD_LIBRARY_PATH, QML2_IMPORT_PATH,
XDG_DATA_DIRS). On Parrot/Debian that environment comes from
/etc/environment.d and is NOT reliably applied to the LightDM
session leader: after a KDE logout/login cycle the exec-once child
environment had no LD_LIBRARY_PATH and no prefix in XDG_DATA_DIRS,
the shell died instantly with no log, and the user got a bare grey
Hyprland with only a leftover app window. Wrap the start commands so
they source the env file themselves, in
~/.config/hypr/hyprland/execs.conf:

    exec-once = sh -c ". /opt/caelestia/env && exec caelestia shell -d"
    exec-once = sh -c ". /opt/caelestia/env && exec caelestia resizer -d"

and apply the same wrapping to the shell restart keybinds in
keybinds.conf (the `caelestia shell -d` binds).
