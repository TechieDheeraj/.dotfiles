#!/usr/bin/bash

socat TCP-LISTEN:8003,fork TCP:100.68.47.66:22 & # proxmox server ssh 
socat TCP-LISTEN:8004,fork TCP:100.120.152.18:22 & # tinybox ssh
socat TCP-LISTEN:8005,fork TCP:100.90.3.61:22 & # raspberrypi ssh
socat TCP-LISTEN:8006,fork TCP:100.68.47.66:8006 & # proxmox UI
socat TCP-LISTEN:8008,fork TCP:100.68.47.66:8008 & # tinyvm ssh inside proxmox
socat TCP-LISTEN:8009,fork TCP:100.68.47.66:8009 & # tinyvm nomachine inside proxmox
socat TCP-LISTEN:8010,fork TCP:100.68.47.66:8010 & # buildvm ssh inside proxmox
nginx -g 'daemon off;'
