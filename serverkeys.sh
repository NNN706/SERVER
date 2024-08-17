#!/bin/bash
mkdir /etc/openvpn/serverkeys
rm -R /etc/openvpn/easy-rsa
cp -R /usr/share/easy-rsa /etc/openvpn
cd /etc/openvpn/easy-rsa
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
openvpn --genkey secret /etc/openvpn/serverkeys/ta.key
./easyrsa gen-crl

cd /etc/openvpn
cp ./easy-rsa/pki/ca.crt ./serverkeys
cp ./easy-rsa/pki/dh.pem ./serverkeys
cp ./easy-rsa/pki/issued/server.crt ./serverkeys
cp ./easy-rsa/pki/private/ca.key ./serverkeys

