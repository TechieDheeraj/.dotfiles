#!/usr/bin/env bash
# Stop the Intel BE200 Wi-Fi 7 card dying on every resume from suspend.
#
# SYMPTOM this fixes: after resuming from s2idle the wifi is simply gone. No
# networks listed, the NetworkManager toggle does nothing, `nmcli device` reports
# the interface as "unavailable", and dmesg is full of iwlwifi register dumps
# where every value is 0xFFFFFFFF. Nothing short of a full power cycle -- not a
# reboot menu entry, an actual power-off -- brings it back.
#
# CAUSE: the card sits behind root port 0000:00:06.0, whose ACPI node
# \_SB_.PC00.RP10 declares _PR3, so the platform may cut power to the slot. On
# this laptop it does, on every suspend, and then fails to bring the PCIe link
# back up:  "Data Link Layer Link Active not set in 100 msec". The card is then
# electrically absent; `lspci -vv` reports "Unknown header type 7f" because every
# config-space read returns 0xFF.
#
# WHY THERE IS NO RECOVERY PATH HERE: measured on this exact machine, a root-port
# rescan, a whole-bus /sys/bus/pci/rescan, and a secondary bus reset on 00:06.0
# all failed to bring it back. A "recover on resume" hook would be a no-op that
# looks like a fix. So this prevents the D3cold transition instead.
#
# Run:  sudo bash ~/.dotfiles/omarchy/system/wifi-be200-suspend-fix.sh
# Undo: sudo bash ~/.dotfiles/omarchy/system/wifi-be200-suspend-fix.sh --revert
#
# NOTE: this is for a laptop that actually suspends. It is pointless alongside
# system/apply.sh, which masks sleep.target to build an always-on server -- that
# script makes suspend impossible, so there is no resume to survive. Run one or
# the other, not both.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
(( EUID == 0 )) || { echo "Run with sudo: sudo bash $0 $*" >&2; exit 1; }

DEV=0000:01:00.0
BE200_ID="8086:272b"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if [[ ${1:-} == --revert ]]; then
  step "Reverting"
  rm -fv /etc/udev/rules.d/81-iwlwifi-no-d3cold.rules
  rm -fv /usr/lib/systemd/system-sleep/wifi-d3cold-guard
  rm -fv /etc/NetworkManager/conf.d/20-wifi-route-metric.conf
  udevadm control --reload
  systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager
  echo
  echo "Reverted. The card will be allowed into D3cold again from the next boot,"
  echo "which means the suspend bug comes back. Wifi also loses route priority."
  exit 0
fi

# 1 ----------------------------------------------------------------------------
# Not fatal if absent: the udev rule keys on vendor/device, so it lies inert on
# hardware it does not match. Worth saying out loud though -- if you are running
# this on a machine without a BE200 you have almost certainly picked the wrong
# script.
step "Checking for the BE200"
if lspci -nn | grep -qi "$BE200_ID"; then
  lspci -nn | grep -i "$BE200_ID"
else
  echo "WARNING: no $BE200_ID found. Installing anyway; the rule will not match."
fi

# 2 ----------------------------------------------------------------------------
# The actual fix. Caps the card at D3hot so the slot keeps power and the PCIe
# link stays trained across suspend.
step "Installing udev rule (keeps the card out of D3cold)"
install -Dm644 "$HERE/etc/udev/rules.d/81-iwlwifi-no-d3cold.rules" \
               /etc/udev/rules.d/81-iwlwifi-no-d3cold.rules

# 3 ----------------------------------------------------------------------------
# Belt and braces, plus the thing that makes a future regression diagnosable in
# one command instead of an evening. Must be /usr/lib -- see the hook's own
# comment for why /etc/systemd/system-sleep/ silently does nothing.
step "Installing sleep hook into /usr/lib/systemd/system-sleep"
install -Dm755 "$HERE/usr/lib/systemd/system-sleep/wifi-d3cold-guard" \
               /usr/lib/systemd/system-sleep/wifi-d3cold-guard

# 4 ----------------------------------------------------------------------------
step "Preferring wifi over wired for the default route"
install -Dm644 "$HERE/etc/NetworkManager/conf.d/20-wifi-route-metric.conf" \
               /etc/NetworkManager/conf.d/20-wifi-route-metric.conf
systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager

# 5 ----------------------------------------------------------------------------
# Apply to the already-enumerated card rather than waiting for a reboot. The rule
# is ACTION=="add", so re-triggering add is what makes it take effect now.
step "Applying to the running system"
udevadm control --reload
udevadm trigger --action=add --subsystem-match=pci \
  --attr-match=vendor=0x8086 --attr-match=device=0x272b 2>/dev/null || true
udevadm settle || true

# 6 ----------------------------------------------------------------------------
step "Verifying"
printf '%-34s %s\n' "udev rule:"      "$(test -f /etc/udev/rules.d/81-iwlwifi-no-d3cold.rules && echo installed || echo MISSING)"
printf '%-34s %s\n' "sleep hook:"     "$(test -x /usr/lib/systemd/system-sleep/wifi-d3cold-guard && echo installed || echo MISSING)"
printf '%-34s %s\n' "NM route metric:" "$(test -f /etc/NetworkManager/conf.d/20-wifi-route-metric.conf && echo installed || echo MISSING)"
printf '%-34s %s\n' "d3cold_allowed:" "$(cat /sys/bus/pci/devices/$DEV/d3cold_allowed 2>/dev/null || echo 'n/a - card absent') (want 0)"
printf '%-34s %s\n' "power_state:"    "$(cat /sys/bus/pci/devices/$DEV/power_state 2>/dev/null || echo 'n/a')"
printf '%-34s %s\n' "wifi interface:" "$(ip -br link | awk '/^wl/{print $1, $2}' || echo none)"

cat <<'DONE'

Done. The real test is a suspend/resume cycle:

    systemctl suspend      # then wake it and check:
    journalctl -t wifi-d3cold-guard -b 0

  post-suspend: OK ...      the guard held, wifi survived
  post-suspend: FAILED ...  it did not; next lever is pcie_port_pm=off on the
                            kernel cmdline (touches the bootloader, hence not
                            applied automatically here)
DONE
