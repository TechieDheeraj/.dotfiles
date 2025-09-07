#!/bin/bash

lid_state=$(cat /proc/acpi/button/lid/LID/state | awk '{print $2}')

if [ "$lid_state" == "closed" ]; then
  hyprctl dispatch dpms off eDP-1
  hyprctl dispatch moveworkspacetomonitor 1 DP-1
else
  hyprctl dispatch dpms on eDP-1
fi
