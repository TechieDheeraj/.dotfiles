#!/usr/bin/bash

sudo killall socat
#sudo systemctl restart tailscaled.service
# lsof -i tcp:8006
# To connect to proxmox dashboard
socat TCP-LISTEN:8006,fork TCP:100.68.47.66:8006 &
# To connect to windows rdp 
socat TCP-LISTEN:3389,fork TCP:100.68.47.66:8007 &
# To do ssh on devvm (tiny) machine
socat TCP-LISTEN:8008,fork TCP:100.68.47.66:8008 &
# To do nomachine on devvm (tiny) 
socat TCP-LISTEN:8009,fork TCP:100.68.47.66:8009 &
# To do ssh on buildvm (big (6wind)) 
socat TCP-LISTEN:8010,fork TCP:100.68.47.66:8010 &
# To do nomachine on buildvm (big (6wind)) 
socat TCP-LISTEN:8011,fork TCP:100.68.47.66:8011 &
