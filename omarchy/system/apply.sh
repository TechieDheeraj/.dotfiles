#!/usr/bin/env bash
# Configure this Omarchy laptop as an always-on, plugged-in headless server.
#
# WHAT THIS DOES NOT TOUCH: /usr/share/omarchy/** is owned by the `omarchy` and
# `omarchy-settings` pacman packages and is rewritten by every `omarchy-update`.
# Nothing here writes there. Everything goes to /etc drop-in directories, which
# are the supported, update-safe override layer.
#
# Run:  sudo bash ~/.dotfiles/omarchy-server/apply.sh
# Undo: sudo bash ~/.dotfiles/omarchy-server/apply.sh --revert

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
(( EUID == 0 )) || { echo "Run with sudo: sudo bash $0 $*" >&2; exit 1; }

SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if [[ ${1:-} == --revert ]]; then
  step "Reverting"
  rm -fv /etc/systemd/logind.conf.d/50-always-on-server.conf
  rm -fv /etc/udev/rules.d/99-lenovo-battery-conservation.rules
  systemctl disable --now battery-conservation.service 2>/dev/null || true
  rm -fv /etc/systemd/system/battery-conservation.service
  systemctl unmask "${SLEEP_TARGETS[@]}"
  systemctl daemon-reload
  systemctl reload systemd-logind || systemctl restart systemd-logind
  udevadm control --reload
  echo 0 > /sys/bus/platform/devices/VPC2004:00/conservation_mode 2>/dev/null || true
  echo "Reverted. Default laptop suspend/idle behaviour is back."
  echo "Note: 'omarchy-toggle-idle allow-idle' (as your user) restores the screensaver and lock."
  exit 0
fi

# 1 ----------------------------------------------------------------------------
# Stop logind from ever suspending the machine. Closing the lid is currently
# HandleLidSwitch=suspend, which is the one thing guaranteed to kill this server.
step "Installing logind drop-in (lid close and idle no longer suspend)"
install -Dm644 "$HERE/etc/systemd/logind.conf.d/50-always-on-server.conf" \
               /etc/systemd/logind.conf.d/50-always-on-server.conf
systemctl reload systemd-logind || systemctl restart systemd-logind

# 2 ----------------------------------------------------------------------------
# Belt and braces. Step 1 covers every automatic path into sleep, but masking the
# targets makes suspend structurally impossible -- an accidental click in the
# Omarchy power menu, a stray `systemctl suspend`, or some future package's
# inhibitor logic simply cannot put this machine to sleep.
#
# Cost: you also lose deliberate suspend/hibernate. That is the intended trade
# for a server. `--revert` unmasks them.
step "Masking sleep/suspend/hibernate targets"
systemctl mask "${SLEEP_TARGETS[@]}"

# 3 ----------------------------------------------------------------------------
# Battery. See battery-conservation.service for why this is on/off and not 90%.
step "Enabling Lenovo Conservation Mode (charge cap ~60%) persistently"
install -Dm644 "$HERE/etc/systemd/system/battery-conservation.service" \
               /etc/systemd/system/battery-conservation.service
install -Dm644 "$HERE/etc/udev/rules.d/99-lenovo-battery-conservation.rules" \
               /etc/udev/rules.d/99-lenovo-battery-conservation.rules
systemctl daemon-reload
systemctl enable --now battery-conservation.service

# Apply the udev permission bits now, without waiting for a reboot.
udevadm control --reload
chgrp wheel /sys/bus/platform/devices/VPC2004:00/conservation_mode
chmod 0664  /sys/bus/platform/devices/VPC2004:00/conservation_mode

# 4 ----------------------------------------------------------------------------
step "Verifying"
printf '%-34s %s\n' "HandleLidSwitch:" \
  "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch | awk '{print $2}')"
printf '%-34s %s\n' "IdleAction:" \
  "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager IdleAction | awk '{print $2}')"
printf '%-34s %s\n' "sleep.target:" "$(systemctl is-enabled sleep.target 2>&1)"
printf '%-34s %s\n' "conservation_mode:" "$(cat /sys/bus/platform/devices/VPC2004:00/conservation_mode)"
printf '%-34s %s\n' "conservation_mode perms:" "$(stat -c '%U:%G %a' /sys/bus/platform/devices/VPC2004:00/conservation_mode)"

cat <<'DONE'

Done. Remaining manual checks (as your normal user, not root):
  omarchy-toggle-idle status    -> should report "enabled":true  (= stay awake)
  battery-cap status            -> should report Conservation mode: ON
DONE
