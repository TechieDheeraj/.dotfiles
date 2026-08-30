#!/usr/bin/env bash
# Remote desktop: install Sunshine and open the Moonlight streaming ports.
#
# WHY THIS EXISTS INSTEAD OF `omarchy-install-service-sunshine`:
# That script's second step is `systemctl --user enable --now sunshine`, but the
# packaged unit is app-dev.lizardbyte.app.Sunshine.service and its
# `Alias=sunshine.service` does not exist until the real unit has been enabled
# once. So the enable fails with "not-found", `set -e` aborts the script, and the
# firewall rules, the admin web app and the Hyprland autostart entry never run.
# The pacman install DID succeed by then, so it looks like it half worked.
#
# This script is the root-level half (package + firewall). The user-level half
# (config + enabling the unit under its real name) is in ../install.sh.
#
# Run:  sudo bash ~/.dotfiles/omarchy/system/sunshine-remote-desktop.sh
# Undo: sudo bash ~/.dotfiles/omarchy/system/sunshine-remote-desktop.sh --revert

set -euo pipefail
(( EUID == 0 )) || { echo "Run with sudo: sudo bash $0 $*" >&2; exit 1; }

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# Port 47990 -- the admin web UI -- is deliberately NOT opened. It stays bound to
# localhost and is reached from the Mac over an SSH tunnel instead:
#   ssh -L 47990:localhost:47990 dheeraj@<host>
# then browse https://localhost:47990 on the Mac.
TCP_PORTS=(47984 47989 48010)
UDP_PORTS=(5353 47998 47999 48000 48002 48010)   # 5353 is mDNS: Moonlight autodiscovery
PRIVATE_CIDRS=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16)

# Same comment tag omarchy-remove-service-sunshine matches on, so Omarchy's own
# uninstaller can still clean up after this script.
UFW_COMMENT="omarchy-sunshine"

ufw_each_rule() {
  # $1 = "allow" | "delete"
  local action="$1" proto port cidr
  for port in "${TCP_PORTS[@]}"; do
    for cidr in "${PRIVATE_CIDRS[@]}"; do
      if [[ $action == allow ]]; then
        ufw allow in proto tcp from "$cidr" to any port "$port" comment "$UFW_COMMENT" >/dev/null
      else
        ufw --force delete allow in proto tcp from "$cidr" to any port "$port" >/dev/null 2>&1 || true
      fi
    done
    if ip link show tailscale0 >/dev/null 2>&1; then
      if [[ $action == allow ]]; then
        ufw allow in on tailscale0 to any port "$port" proto tcp comment "$UFW_COMMENT" >/dev/null
      else
        ufw --force delete allow in on tailscale0 to any port "$port" proto tcp >/dev/null 2>&1 || true
      fi
    fi
  done
  for port in "${UDP_PORTS[@]}"; do
    for cidr in "${PRIVATE_CIDRS[@]}"; do
      if [[ $action == allow ]]; then
        ufw allow in proto udp from "$cidr" to any port "$port" comment "$UFW_COMMENT" >/dev/null
      else
        ufw --force delete allow in proto udp from "$cidr" to any port "$port" >/dev/null 2>&1 || true
      fi
    done
    if ip link show tailscale0 >/dev/null 2>&1; then
      if [[ $action == allow ]]; then
        ufw allow in on tailscale0 to any port "$port" proto udp comment "$UFW_COMMENT" >/dev/null
      else
        ufw --force delete allow in on tailscale0 to any port "$port" proto udp >/dev/null 2>&1 || true
      fi
    fi
  done
}

if [[ ${1:-} == --revert ]]; then
  step "Closing Sunshine ports"
  ufw_each_rule delete
  ufw reload
  echo "Ports closed. The package and your config are left in place."
  echo "To go further, as your normal user:"
  echo "  systemctl --user disable --now app-dev.lizardbyte.app.Sunshine.service"
  echo "  sudo pacman -Rns sunshine"
  exit 0
fi

step "Installing Sunshine"
pacman -S --needed --noconfirm sunshine

step "Opening Moonlight ports for private LANs (and tailscale0 if present)"
ufw_each_rule allow
ufw reload

step "Verifying"
printf '%-24s %s\n' "sunshine:" "$(pacman -Q sunshine)"
# Count via `ufw status`, NOT by grepping /etc/ufw/user.rules for the comment:
# ufw stores comments hex-encoded there ("omarchy-sunshine" is written as
# comment=6f6d61726368792d73756e7368696e65), so the obvious grep always says 0.
printf '%-24s %s\n' "ufw rules:" "$(ufw status | grep -c "$UFW_COMMENT") active, persisted in /etc/ufw/user.rules"
printf '%-24s %s\n' "ufw at boot:" "$(systemctl is-enabled ufw)"

cat <<'DONE'

Done. Now the user-level half (as your normal user, NOT root):
  bash ~/.dotfiles/omarchy/install.sh

Then pair, from the Mac:
  ssh -L 47990:localhost:47990 dheeraj@<host>     # leave running
  open https://localhost:47990                    # create admin login, enter Moonlight's PIN
DONE
