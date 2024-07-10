#!/bin/bash
# Start
sudo su
screen -S start
apt update && apt upgrade -y
apt install openvpn easy-rsa -y
nano /etc/openvpn/server.conf

