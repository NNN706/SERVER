#!/bin/bash

WG_SERVER_CONF="/etc/wireguard/wg0.conf"
WG_CLIENT_DIR="$HOME/wireguard_clients"
WG_CLIENT_IP_BASE="10.8.1."

mkdir -p "$WG_CLIENT_DIR"

# Получаем внешний IP сервера автоматически
SERVER_IP=$(curl -s https://ifconfig.me)
SERVER_PORT=43142

next_client_number() {
  max=0
  for file in "$WG_CLIENT_DIR"/client*.conf; do
    [ -e "$file" ] || continue
    num=$(basename "$file" .conf | sed 's/client//')
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      (( num > max )) && max=$num
    fi
  done
  echo $((max + 1))
}

CLIENT_NUMBER=$(next_client_number)
CLIENT_NAME="client${CLIENT_NUMBER}"

CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(echo "$CLIENT_PRIV_KEY" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

USED_IPS=$(grep AllowedIPs "$WG_SERVER_CONF" | grep -oP '10\.8\.1\.\d+' | sort -t . -k 4 -n)
LAST_IP=2
if [ -n "$USED_IPS" ]; then
  LAST_IP=$(echo "$USED_IPS" | tail -1 | awk -F. '{print $4}')
  LAST_IP=$((LAST_IP + 1))
fi

CLIENT_IP="${WG_CLIENT_IP_BASE}${LAST_IP}/32"

CLIENT_CONF="$WG_CLIENT_DIR/${CLIENT_NAME}.conf"

cat > "$CLIENT_CONF" << EOF
[Interface]
Address = $CLIENT_IP
DNS = 1.1.1.1, 1.0.0.1
PrivateKey = $CLIENT_PRIV_KEY
Jc = 4
Jmin = 8
Jmax = 80
S1 = 124
S2 = 77
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = $(grep '^PrivateKey' $WG_SERVER_CONF -A2 | grep PublicKey | awk '{print $3}')
PresharedKey = $CLIENT_PSK
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:$SERVER_PORT
PersistentKeepalive = 25
EOF

echo "Клиентский конфиг создан: $CLIENT_CONF"

cat >> "$WG_SERVER_CONF" << EOF

[Peer]
PublicKey = $CLIENT_PUB_KEY
PresharedKey = $CLIENT_PSK
AllowedIPs = $CLIENT_IP
EOF

echo "Пир добавлен в серверный конфиг $WG_SERVER_CONF с IP $CLIENT_IP"

sudo wg-quick down wg0
sudo wg-quick up wg0

echo "WireGuard сервер перезапущен."
echo "Новый клиент: $CLIENT_NAME с IP $CLIENT_IP"
