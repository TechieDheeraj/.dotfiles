#!/usr/bin/env bash
# User-level setup. No root needed -- run system/apply.sh separately with sudo.
#
# Symlinks (rather than copies) the tracked configs into ~/.config, so any later
# edit you make lands in this git repo automatically and `git status` tells you
# the truth about what has drifted.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

link_config() {
  local src="$1" target="$HOME/.config/$2"
  mkdir -p "$(dirname "$target")"
  # Keep the pristine Omarchy template around the first time we replace it.
  if [[ -e $target && ! -L $target ]]; then
    mv -v "$target" "$target.omarchy-default"
  fi
  ln -sfnv "$src" "$target"
}

step "Linking configs into ~/.config"
for f in "$HERE"/config/hypr/*.lua; do
  link_config "$f" "hypr/$(basename "$f")"
done
link_config "$HERE/config/kitty/kitty.conf" "kitty/kitty.conf"
link_config "$HERE/config/herdr/config.toml" "herdr/config.toml"

# shell.json is deliberately COPIED, not symlinked: the Quickshell bar writes to
# it (right-clicking the clock cycles the format and saves it), and an atomic
# write would replace the symlink with a plain file. After changing bar settings
# from the UI, copy it back with:
#   cp ~/.config/omarchy/shell.json "$HERE/config/omarchy/shell.json"
step "Copying shell.json (12-hour clock)"
if ! cmp -s "$HERE/config/omarchy/shell.json" "$HOME/.config/omarchy/shell.json"; then
  cp -v --backup=numbered "$HERE/config/omarchy/shell.json" "$HOME/.config/omarchy/shell.json"
else
  echo "already current"
fi

step "Linking helper scripts into ~/.local/bin"
mkdir -p "$HOME/.local/bin"
for f in "$HERE"/bin/*; do
  ln -sfnv "$f" "$HOME/.local/bin/$(basename "$f")"
done

step "Disabling the screensaver and idle lock (always-on server)"
# Writes ~/.local/state/omarchy/indicators/stay-awake. State, not config, so it
# is not tracked in git -- this line is what reproduces it on a fresh machine.
omarchy-toggle-idle stay-awake >/dev/null
omarchy-toggle-idle status

step "Reloading Hyprland"
if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null && echo "reloaded"
else
  echo "(not inside a Hyprland session; changes apply at next login)"
fi

cat <<'DONE'

Done. Verify with:
  omarchy menu keybindings --print | grep -iE 'swap|focus on|resize'
  hyprctl getoption input:touchpad:natural_scroll
  hyprctl getoption input:repeat_delay
DONE
