#!/bin/bash
# Start
sudo su
screen -S APT apt update && apt upgrade -y
screen -S OVPN apt install openvpn -y

