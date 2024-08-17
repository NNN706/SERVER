#!/bin/bash
cd /etc/openvpn/easy-rsa
./easyrsa build-client-full client1 nopass
./easyrsa build-client-full client2 nopass
./easyrsa build-client-full client3 nopass
./easyrsa build-client-full client4 nopass
./easyrsa build-client-full client5 nopass
./easyrsa build-client-full client6 nopass

mkdir /etc/openvpn/clientkeys
cd /etc/openvpn/clientkeys
mkdir client1
mkdir client2
mkdir client3
mkdir client4
mkdir client5
mkdir client6

cd /etc/openvpn
cp ./easy-rsa/pki/ca.crt
cp ./serverkeys/ta.key ./clientkeys/client1
cp ./serverkeys/ta.key ./clientkeys/client2
cp ./serverkeys/ta.key ./clientkeys/client3
cp ./serverkeys/ta.key ./clientkeys/client4
cp ./serverkeys/ta.key ./clientkeys/client5
cp ./serverkeys/ta.key ./clientkeys/client6

cp ./serverkeys/ca.crt ./clientkeys/client1
cp ./serverkeys/ca.crt ./clientkeys/client2
cp ./serverkeys/ca.crt ./clientkeys/client3
cp ./serverkeys/ca.crt ./clientkeys/client4
cp ./serverkeys/ca.crt ./clientkeys/client5
cp ./serverkeys/ca.crt ./clientkeys/client6

cp ./easy-rsa/pki/issued/client1.crt ./clientkeys/client1
cp ./easy-rsa/pki/issued/client2.crt ./clientkeys/client2
cp ./easy-rsa/pki/issued/client3.crt ./clientkeys/client3
cp ./easy-rsa/pki/issued/client4.crt ./clientkeys/client4
cp ./easy-rsa/pki/issued/client5.crt ./clientkeys/client5
cp ./easy-rsa/pki/issued/client6.crt ./clientkeys/client6

cp ./easy-rsa/pki/private/client1.key ./clientkeys/client1
cp ./easy-rsa/pki/private/client2.key ./clientkeys/client2
cp ./easy-rsa/pki/private/client3.key ./clientkeys/client3
cp ./easy-rsa/pki/private/client4.key ./clientkeys/client4
cp ./easy-rsa/pki/private/client5.key ./clientkeys/client5
cp ./easy-rsa/pki/private/client6.key ./clientkeys/client6
