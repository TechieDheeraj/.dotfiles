#!/usr/bin/bash


sudo nmcli networking off
sudo nmcli networking on 
sudo systemctl restart tailscaled.service
