#!/usr/bin/env bash
set -euo pipefail

# ---------------------------

# ---------------------------

# Поиск серверного конфига (расширенный)
WG_SERVER_CONF=$(find / -type f \( -name wg0.conf -o -name awg-server.conf -o -name "*wg*.conf" \) 2>/dev/null | head -n 1 || true)

if [[ -z "${WG_SERVER_CONF:-}" ]]; then
  echo "Ошибка: серверный конфиг не найден (wg0.conf/awg-server.conf/*wg*.conf)."
  exit 1
fi

WG_DIR=$(dirname "$WG_SERVER_CONF")
WG_CLIENT_DIR="${WG_CLIENT_DIR:-$WG_DIR}"

echo "Найден конфиг: $WG_SERVER_CONF"
echo "Клиентские конфиги: $WG_CLIENT_DIR"

# Проверки утилит (ваш код)
for cmd in wg wg-quick curl sed awk grep tr od; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Ошибка: требуется '$cmd'"
    exit 1
  fi
done

mkdir -p "$WG_CLIENT_DIR"

# =========================
# =========================
extract_server_params() {
  # PrivateKey (ваш проверенный код)
  SERVER_PRIV_KEY=$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$WG_SERVER_CONF" | head -n 1 | tr -d '\r' | sed -E "s/^['\"]|['\"]$//g" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  
  # ListenPort (критично!)
  SERVER_PORT=$(sed -n 's/.*ListenPort[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "51820")
  
  # J-параметры AWG (критично!)
  SERVER_JC=$(sed -n 's/.*Jc[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "4")
  SERVER_JMIN=$(sed -n 's/.*Jmin[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "8")
  SERVER_JMAX=$(sed -n 's/.*Jmax[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "80")
  SERVER_S1=$(sed -n 's/.*S1[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "124")
  SERVER_S2=$(sed -n 's/.*S2[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "77")
  SERVER_H1=$(sed -n 's/.*H1[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "1")
  SERVER_H2=$(sed -n 's/.*H2[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "2")
  SERVER_H3=$(sed -n 's/.*H3[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "3")
  SERVER_H4=$(sed -n 's/.*H4[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$WG_SERVER_CONF" | head -n1 || echo "4")
  
  SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip || echo "your.server.ip")
  
  echo "Сервер: $SERVER_IP:$SERVER_PORT | Jc=$SERVER_JC Jmin=$SERVER_JMIN"
}

# Ваш код next_client_number() — оставляем без изменений
next_client_number() {
  local max=0 file num
  for file in "$WG_CLIENT_DIR"/client*.conf; do
    [ -e "$file" ] || continue
    num=$(basename "$file" .conf | sed 's/^client//' || true)
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      (( num > max )) && max=$num
    fi
  done
  echo $((max + 1))
}

# Инициализация параметров
extract_server_params
CLIENT_NUMBER=$(next_client_number)
CLIENT_NAME="client${CLIENT_NUMBER}"

# Ваш проверенный блок PrivateKey + pubkey (без изменений)
if [[ -z "$SERVER_PRIV_KEY" ]]; then
  echo "Ошибка: PrivateKey сервера не найден"
  exit 1
fi

if ! printf "%s" "$SERVER_PRIV_KEY" | grep -Eq '^[A-Za-z0-9+/]+=*$'; then
  echo "Ошибка: PrivateKey не base64"
  exit 1
fi

set +e
SERVER_PUB_KEY=$(printf "%s" "$SERVER_PRIV_KEY" | wg pubkey 2>/tmp/_wg_err.$$) || true
WG_RC=$?
set -e

if [[ $WG_RC -ne 0 || -z "${SERVER_PUB_KEY:-}" ]]; then
  echo "Ошибка wg pubkey. Проверьте PrivateKey."
  rm -f /tmp/_wg_err.$$ || true
  exit 1
fi
rm -f /tmp/_wg_err.$$ || true

# Генерация ключей клиента (ваш код)
CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(printf "%s" "$CLIENT_PRIV_KEY" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

# IP (ваш код)
USED_LAST_OCTETS=$(sed -n 's/.*10\.8\.1\.\([0-9][0-9]*\).*/\1/p' "$WG_SERVER_CONF" | sort -n || true)
NEXT_OCTET=2
if [[ -n "$USED_LAST_OCTETS" ]]; then
  LAST=$(printf "%s\n" "$USED_LAST_OCTETS" | tail -n 1)
  NEXT_OCTET=$((LAST + 1))
  if (( NEXT_OCTET < 2 )); then NEXT_OCTET=2; fi
fi

CLIENT_IP="10.8.1.${NEXT_OCTET}/32"
CLIENT_CONF="$WG_CLIENT_DIR/${CLIENT_NAME}.conf"

# =========================
# =========================
cat > "$CLIENT_CONF" <<EOF
[Interface]
Address = $CLIENT_IP
DNS = 1.1.1.1, 1.0.0.1
PrivateKey = $CLIENT_PRIV_KEY
Jc = $SERVER_JC
Jmin = $SERVER_JMIN
Jmax = $SERVER_JMAX
S1 = $SERVER_S1
S2 = $SERVER_S2
H1 = $SERVER_H1
H2 = $SERVER_H2
H3 = $SERVER_H3
H4 = $SERVER_H4

[Peer]
PublicKey = $SERVER_PUB_KEY
PresharedKey = $CLIENT_PSK
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:$SERVER_PORT
PersistentKeepalive = 25
EOF

echo "Клиентский конфиг: $CLIENT_CONF"

# Ваш блок добавления пира (без изменений)
cp "$WG_SERVER_CONF" "${WG_SERVER_CONF}.bak.$(date +%s)"
{
  printf "\n[Peer]\n"
  printf "PublicKey = %s\n" "$CLIENT_PUB_KEY"
  printf "PresharedKey = %s\n" "$CLIENT_PSK"
  printf "AllowedIPs = %s\n" "$CLIENT_IP"
} >> "$WG_SERVER_CONF"

echo "Пир добавлен: $CLIENT_IP (бэкап создан)"

# Ваш блок перезапуска (без изменений)
set +e
wg-quick down "$WG_SERVER_CONF" 2>/dev/null || true
wg-quick up "$WG_SERVER_CONF"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  IFACE=$(basename "$WG_SERVER_CONF" .conf)
  echo "wg-quick up вернул $RC; пробуем wg-quick up $IFACE"
  set +e
  wg-quick down "$IFACE" 2>/dev/null || true
  wg-quick up "$IFACE"
  RC2=$?
  set -e
  if [[ $RC2 -ne 0 ]]; then
    echo "Ошибка запуска интерфейса"
    exit 1
  fi
fi

echo "✅ WireGuard перезапущен"
echo "Новый клиент: $CLIENT_NAME | $CLIENT_IP | $CLIENT_CONF"
exit 0
