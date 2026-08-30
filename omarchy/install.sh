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

# Sunshine's web UI rewrites both of these on Save, so they are COPIED rather
# than symlinked, for the same reason as shell.json above. After changing
# anything in the UI, copy it back with:
#   cp ~/.config/sunshine/{sunshine.conf,apps.json} "$HERE/config/sunshine/"
step "Copying Sunshine config (remote desktop)"
if [[ -d $HOME/.config/sunshine ]] || command -v sunshine >/dev/null; then
  mkdir -p "$HOME/.config/sunshine"
  for f in sunshine.conf apps.json; do
    if ! cmp -s "$HERE/config/sunshine/$f" "$HOME/.config/sunshine/$f"; then
      cp -v --backup=numbered "$HERE/config/sunshine/$f" "$HOME/.config/sunshine/$f"
    else
      echo "$f already current"
    fi
  done
else
  echo "sunshine not installed; skipping (see system/sunshine-remote-desktop.sh)"
fi

# The unit is app-dev.lizardbyte.app.Sunshine.service. It carries
# `Alias=sunshine.service`, but that alias does not exist until the real unit is
# enabled once -- so `systemctl --user enable sunshine` fails with "not-found" on
# a fresh machine. That is the exact line omarchy-install-service-sunshine dies
# on. Always enable the real name.
step "Enabling the Sunshine user service"
SUNSHINE_UNIT=app-dev.lizardbyte.app.Sunshine.service
if [[ -f /usr/lib/systemd/user/$SUNSHINE_UNIT ]]; then
  systemctl --user enable --now "$SUNSHINE_UNIT"
  # Already running from a previous install? Restart so the config copied above
  # actually takes effect.
  systemctl --user restart "$SUNSHINE_UNIT"
  echo "state: $(systemctl --user is-active "$SUNSHINE_UNIT"), $(systemctl --user is-enabled "$SUNSHINE_UNIT")"
else
  echo "sunshine not installed; run: sudo bash $HERE/system/sunshine-remote-desktop.sh"
fi

# ~/.bashrc is seeded from the omarchy-settings package and is NOT a file this
# repo can symlink -- Omarchy's own bootstrap lines have to stay at the top. So
# append a source block instead, once, idempotently.
step "Wiring ~/.dotfiles/bashrc_mac into ~/.bashrc"
if [[ ! -r $HOME/.dotfiles/bashrc_mac ]]; then
  echo "~/.dotfiles/bashrc_mac not found; skipping"
elif grep -q 'dotfiles/bashrc_mac' "$HOME/.bashrc" 2>/dev/null; then
  echo "already wired"
else
  cat >> "$HOME/.bashrc" <<'BASHRC'

# --- personal bash config ---------------------------------------------------
# Sourced LIVE from the dotfiles repo -- nothing is copied here, so any edit to
# ~/.dotfiles/bashrc_mac takes effect in the next shell you open.
if [[ -r "$HOME/.dotfiles/bashrc_mac" ]]; then
  source "$HOME/.dotfiles/bashrc_mac"

  # Omarchy runs `eval "$(starship init bash)"` from default/bash/init, and
  # starship_precmd rewrites PS1 via PROMPT_COMMAND before EVERY prompt -- so a
  # plain PS1= assignment is overwritten before you ever see it.
  #
  # Surgically remove ONLY starship's hook. An exact-match test is not enough:
  # kube-ps1 prepends its own, giving "_kube_ps1_prompt_update;starship_precmd",
  # and that hook must survive or $(kube_ps1) in your PS1 stops updating.
  if [[ ${PROMPT_COMMAND:-} == *starship_precmd* ]]; then
    PROMPT_COMMAND=${PROMPT_COMMAND//starship_precmd/}
    PROMPT_COMMAND=${PROMPT_COMMAND//;;/;}
    PROMPT_COMMAND=${PROMPT_COMMAND#;}
    PROMPT_COMMAND=${PROMPT_COMMAND%;}
  fi
fi
BASHRC
  echo "appended source block to ~/.bashrc"
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
