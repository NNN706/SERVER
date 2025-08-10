#!/usr/bin/env bash
set -euo pipefail

# ---------------- Configurable ----------------
SEARCH_START="/"               # где начинать поиск wg0.conf
SERVER_PORT_DEFAULT=43142
CLIENT_SUBNET_BASE="10.8.1."
# --------------------------------------------

# 1) find wg0.conf
WG_SERVER_CONF=$(find "$SEARCH_START" -type f -name wg0.conf 2>/dev/null | head -n 1 || true)
if [[ -z "$WG_SERVER_CONF" ]]; then
  echo "Ошибка: wg0.conf не найден"
  exit 1
fi
WG_DIR=$(dirname "$WG_SERVER_CONF")
WG_CLIENT_DIR="$WG_DIR"
echo "Найден: $WG_SERVER_CONF"
echo "Клиентские конфиги будут в: $WG_CLIENT_DIR"

# 2) sanity: required programs
for util in awk sed grep wg wg-quick curl; do
  if ! command -v "$util" >/dev/null 2>&1; then
    echo "Требуется утилита: $util"
    exit 1
  fi
done

# 3) backup original
cp -a "$WG_SERVER_CONF" "${WG_SERVER_CONF}.bak.$(date +%s)"

# 4) extract & clean server private key
SERVER_PRIV_RAW=$(awk -F'=' '/^[[:space:]]*PrivateKey[[:space:]]*=/ { val=$2; gsub(/^[ \t]+|[ \t]+$/,"",val); print val; exit }' "$WG_SERVER_CONF" || true)
SERVER_PRIV=$(printf "%s" "$SERVER_PRIV_RAW" | tr -d '\r' | sed -E "s/^['\"]|['\"]$//g" | tr -d ' ')
if [[ -z "$SERVER_PRIV" ]]; then
  echo "Ошибка: не найден PrivateKey в $WG_SERVER_CONF"
  exit 1
fi
echo "PrivateKey length: ${#SERVER_PRIV}"
if ! printf "%s" "$SERVER_PRIV" | grep -Eq '^[A-Za-z0-9+/]+=*$'; then
  echo "Ошибка: приватный ключ содержит недопустимые символы"
  exit 1
fi

# 5) try generate server public key
set +e
SERVER_PUB=$(printf "%s" "$SERVER_PRIV" | wg pubkey 2>/tmp/wg_pub_err || true)
RC=$?
set -e
if [[ $RC -ne 0 || -z "$SERVER_PUB" ]]; then
  echo "Ошибка: не удалось сгенерировать public key из private key (wg pubkey)."
  echo "Содержимое /tmp/wg_pub_err:"
  sed -n '1,200p' /tmp/wg_pub_err || true
  rm -f /tmp/wg_pub_err
  exit 1
fi
rm -f /tmp/wg_pub_err
echo "Server public key OK."

# 6) check duplicates in AllowedIPs (detect same last octet)
mapfile -t USED < <(sed -n 's/.*'"${CLIENT_SUBNET_BASE%?}"'\([0-9][0-9]*\).*/\1/p' "$WG_SERVER_CONF" | sort -n | uniq || true)
if [[ ${#USED[@]} -ne 0 ]]; then
  # find duplicates (same IP used >1)
  dup_found=0
  while read -r ip; do
    count=$(grep -c "AllowedIPs = .*${CLIENT_SUBNET_BASE}${ip}" "$WG_SERVER_CONF" || true)
    if (( count > 1 )); then
      echo "ВНИМАНИЕ: IP ${CLIENT_SUBNET_BASE}${ip} встречается ${count} раз в AllowedIPs (конфликт)."
      dup_found=1
    fi
  done < <(printf "%s\n" "${USED[@]}")
  if (( dup_found )); then
    echo "Исправьте конфликты AllowedIPs прежде чем добавлять нового клиента."
    exit 1
  fi
fi

# 7) decide new client number and IP
mkdir -p "$WG_CLIENT_DIR"
next_num=1
for f in "$WG_CLIENT_DIR"/client*.conf; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .conf | sed 's/^client//' || echo "")
  if [[ "$n" =~ ^[0-9]+$ && $n -ge $next_num ]]; then
    next_num=$((n+1))
  fi
done
CLIENT_NAME="client${next_num}"

# find last used octet and add one, start at 2
last_octet=1
if [[ -n "${USED[*]:-}" ]]; then
  last_octet=$(printf "%s\n" "${USED[@]}" | tail -n1)
fi
next_octet=$((last_octet+1))
if (( next_octet < 2 )); then next_octet=2; fi
CLIENT_IP="${CLIENT_SUBNET_BASE}${next_octet}/32"

# 8) generate client keys
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(printf "%s" "$CLIENT_PRIV" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

# 9) obtain server external ip if possible
SERVER_IP=$(curl -s https://ifconfig.me || true)
if [[ -z "$SERVER_IP" ]]; then SERVER_IP="your.server.ip"; fi
SERVER_PORT=$SERVER_PORT_DEFAULT

CLIENT_CONF_PATH="$WG_CLIENT_DIR/${CLIENT_NAME}.conf"

# 10) write client conf
cat > "$CLIENT_CONF_PATH" <<EOF
[Interface]
Address = $CLIENT_IP
DNS = 1.1.1.1, 1.0.0.1
PrivateKey = $CLIENT_PRIV
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
PublicKey = $SERVER_PUB
PresharedKey = $CLIENT_PSK
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:$SERVER_PORT
PersistentKeepalive = 25
EOF

echo "Создан клиентский файл: $CLIENT_CONF_PATH"

# 11) append to server wg0.conf
{
  printf "\n[Peer]\n"
  printf "PublicKey = %s\n" "$CLIENT_PUB"
  printf "PresharedKey = %s\n" "$CLIENT_PSK"
  printf "AllowedIPs = %s\n" "$CLIENT_IP"
} >> "$WG_SERVER_CONF"

echo "Пир добавлен в $WG_SERVER_CONF"

# 12) try wg-quick down/up with full path, else by iface name
set +e
wg-quick down "$WG_SERVER_CONF" 2>/dev/null
wg-quick up "$WG_SERVER_CONF"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  IFACE=$(basename "$WG_SERVER_CONF" .conf)
  echo "wg-quick up по полному пути вернул код $rc, пробуем wg-quick up $IFACE"
  set +e
  wg-quick down "$IFACE" 2>/dev/null || true
  wg-quick up "$IFACE"
  rc2=$?
  set -e
  if [[ $rc2 -ne 0 ]]; then
    echo "Не удалось поднять интерфейс: попробуйте вручную: wg-quick up \"$WG_SERVER_CONF\" или wg-quick up $IFACE"
    exit 1
  fi
fi

echo "Готово. Клиент: $CLIENT_NAME, файл: $CLIENT_CONF_PATH, IP: $CLIENT_IP"
exit 0
