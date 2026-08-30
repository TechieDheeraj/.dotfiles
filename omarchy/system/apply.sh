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
  rm -fv /etc/systemd/sleep.conf.d/50-hibernate-mode.conf
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

# Hibernate by plain power-off rather than ACPI S4. Must live here: systemd
# writes /sys/power/disk itself from HibernateMode= just before hibernating, so
# setting that file directly is discarded. See the drop-in for the measurements.
install -Dm644 "$HERE/etc/systemd/sleep.conf.d/50-hibernate-mode.conf" \
               /etc/systemd/sleep.conf.d/50-hibernate-mode.conf

# 2 ----------------------------------------------------------------------------
# OPT-IN, and OFF by default.
#
# Step 1 already closes every AUTOMATIC path into sleep: the lid, the idle timer
# and the power/sleep keys are all "ignore", so nothing puts this machine to
# sleep by itself. Masking goes further and makes sleep structurally impossible
# -- but it also blocks DELIBERATE `systemctl suspend` / `systemctl hibernate`
# and the Omarchy power menu, which is a capability worth keeping on a laptop
# that is still occasionally a laptop.
#
# The masked state was the original default here and is why `systemctl hibernate`
# answered "Access denied". For the stricter posture:
#     sudo MASK_SLEEP=1 bash apply.sh
if [[ ${MASK_SLEEP:-0} == 1 ]]; then
  step "Masking sleep/suspend/hibernate targets (MASK_SLEEP=1)"
  systemctl mask "${SLEEP_TARGETS[@]}"
else
  step "Unmasking sleep targets (deliberate suspend/hibernate stay available)"
  # Only unmask what is masked, so this is quiet on a clean system.
  # if/fi purely for readability; `[[ ... ]] && cmd` would also be safe here
  # (bash exempts the left side of a && list from set -e).
  for t in "${SLEEP_TARGETS[@]}"; do
    if [[ $(systemctl is-enabled "$t" 2>/dev/null) == masked ]]; then
      systemctl unmask "$t"
    fi
  done
  echo "  automatic sleep is still blocked by the logind drop-in above"
fi

# 3 ----------------------------------------------------------------------------
# Battery. See battery-conservation.service for why this is on/off and not 90%.
step "Enabling Lenovo Conservation Mode (charge cap ~80%) persistently"
install -Dm644 "$HERE/etc/systemd/system/battery-conservation.service" \
               /etc/systemd/system/battery-conservation.service
install -Dm644 "$HERE/etc/udev/rules.d/99-lenovo-battery-conservation.rules" \
               /etc/udev/rules.d/99-lenovo-battery-conservation.rules
systemctl daemon-reload
systemctl enable battery-conservation.service
# restart, not `enable --now`: the unit is Type=oneshot RemainAfterExit=yes, so
# once it is active `--now` is a no-op and an edited ExecStart would never run.
systemctl restart battery-conservation.service

# Apply the udev permission bits now, without waiting for a reboot.
udevadm control --reload
for attr in conservation_mode usb_charging; do
  a=/sys/bus/platform/devices/VPC2004:00/$attr
  if [[ -e $a ]]; then
    chgrp wheel "$a"
    chmod 0664  "$a"
  fi
done

# 4 ----------------------------------------------------------------------------
step "Verifying"
printf '%-34s %s\n' "HandleLidSwitch:" \
  "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch | awk '{print $2}')"
printf '%-34s %s\n' "IdleAction:" \
  "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager IdleAction | awk '{print $2}')"
printf '%-34s %s\n' "sleep.target:" "$(systemctl is-enabled sleep.target 2>&1)"
printf '%-34s %s\n' "hibernate.target:" "$(systemctl is-enabled hibernate.target 2>&1)"
printf '%-34s %s\n' "conservation_mode:" "$(cat /sys/bus/platform/devices/VPC2004:00/conservation_mode)"
printf '%-34s %s\n' "usb_charging:" "$(cat /sys/bus/platform/devices/VPC2004:00/usb_charging 2>/dev/null || echo n/a)"
printf '%-34s %s\n' "HibernateMode:" "$(systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | awk -F= '/^HibernateMode=/{print $2}' | tail -1)"
printf '%-34s %s\n' "conservation_mode perms:" "$(stat -c '%U:%G %a' /sys/bus/platform/devices/VPC2004:00/conservation_mode)"

cat <<'DONE'

Done. Remaining manual checks (as your normal user, not root):
  omarchy-toggle-idle status    -> should report "enabled":true  (= stay awake)
  battery-cap status            -> should report Conservation mode: ON
DONE
