#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Поиск wg0.conf (по всей FS, первый найденный)
# ---------------------------
WG_SERVER_CONF=$(find / -type f -name wg0.conf 2>/dev/null | head -n 1 || true)

if [[ -z "${WG_SERVER_CONF:-}" ]]; then
  echo "Ошибка: wg0.conf не найден (искали по всему /)."
  exit 1
fi

WG_DIR=$(dirname "$WG_SERVER_CONF")
WG_CLIENT_DIR="$WG_DIR"   # сохраняем клиентские конфиги в той же директории, где найден wg0.conf

echo "Найден конфиг WireGuard: $WG_SERVER_CONF"
echo "Клиентские конфиги будут в: $WG_CLIENT_DIR"

# ---------------------------
# Проверки наличия утилит
# ---------------------------
for cmd in wg wg-quick curl awk sed tr; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Ошибка: требуется утилита '$cmd' — установите пакет с этой утилитой."
    exit 1
  fi
done

# ---------------------------
# Настройки
# ---------------------------
WG_CLIENT_IP_BASE="10.8.1."   # подсеть
SERVER_IP=$(curl -s https://ifconfig.me || true)
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="your.server.ip"
fi
SERVER_PORT=43142

mkdir -p "$WG_CLIENT_DIR"

# ---------------------------
# Определяем следующий clientX
# ---------------------------
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

CLIENT_NUMBER=$(next_client_number)
CLIENT_NAME="client${CLIENT_NUMBER}"

# ---------------------------
# Извлекаем PrivateKey сервера (и очищаем)
# ---------------------------
# Берём первую встречающуюся строку PrivateKey = <val>
SERVER_PRIV_KEY_RAW=$(awk -F'=' '/^[[:space:]]*PrivateKey[[:space:]]*=/ { val=$2; gsub(/^[ \t]+|[ \t]+$/,"",val); print val; exit }' "$WG_SERVER_CONF" || true)
# Убираем возможные CR и кавычки
SERVER_PRIV_KEY=$(printf "%s" "$SERVER_PRIV_KEY_RAW" | tr -d '\r' | sed 's/^["'\'']\|["'\'']$//g' | tr -d ' ')

if [[ -z "$SERVER_PRIV_KEY" ]]; then
  echo "Ошибка: в $WG_SERVER_CONF не найден PrivateKey (пусто)."
  exit 1
fi

# Проверка базового формата base64 (буквы, цифры, +/, =)
if ! printf "%s" "$SERVER_PRIV_KEY" | grep -E -q '^[A-Za-z0-9+/]+=*$'; then
  echo "Ошибка: извлечённый PrivateKey содержит недопустимые символы."
  echo "Извлечённая строка (masked): $(printf "%s" "$SERVER_PRIV_KEY" | sed -E 's/(.{4}).*(.{4})/\1... \2/')"
  exit 1
fi

# Проверяем длину (ожидается 44 символа для приватного ключа wireguard)
len=${#SERVER_PRIV_KEY}
if [[ $len -ne 44 ]]; then
  echo "Предупреждение: длина извлечённого PrivateKey = $len (ожидалось 44)."
  echo "Если ключ хранится в другом формате — исправьте конфиг или вставьте приватный ключ сервера."
  # но всё же пробуем сгенерировать публичный ключ — возможно, это всё равно валидно
fi

# Генерация публичного ключа сервера
set +e
SERVER_PUB_KEY=$(printf "%s" "$SERVER_PRIV_KEY" | wg pubkey 2>/dev/null) || true
set -e
if [[ -z "${SERVER_PUB_KEY:-}" ]]; then
  echo "Ошибка: не удалось получить PublicKey сервера из PrivateKey (wg pubkey вернул ошибку)."
  echo "Проверьте корректность PrivateKey в $WG_SERVER_CONF."
  exit 1
fi

# ---------------------------
# Генерируем ключи клиента
# ---------------------------
CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(printf "%s" "$CLIENT_PRIV_KEY" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

# ---------------------------
# Определяем следующий свободный IP в подсети (из AllowedIPs в wg0.conf)
# ---------------------------
USED_LAST_OCTETS=$(sed -n 's/.*10\.8\.1\.\([0-9][0-9]*\).*/\1/p' "$WG_SERVER_CONF" | sort -n || true)

NEXT_OCTET=2
if [[ -n "$USED_LAST_OCTETS" ]]; then
  LAST=$(printf "%s\n" "$USED_LAST_OCTETS" | tail -n 1)
  NEXT_OCTET=$((LAST + 1))
  if (( NEXT_OCTET < 2 )); then NEXT_OCTET=2; fi
fi

CLIENT_IP="${WG_CLIENT_IP_BASE}${NEXT_OCTET}/32"
CLIENT_CONF="$WG_CLIENT_DIR/${CLIENT_NAME}.conf"

# ---------------------------
# Записываем клиентский конфиг (гарантируем запись PrivateKey клиента)
# ---------------------------
cat > "$CLIENT_CONF" <<EOF
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
PublicKey = $SERVER_PUB_KEY
PresharedKey = $CLIENT_PSK
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:$SERVER_PORT
PersistentKeepalive = 25
EOF

echo "Клиентский конфиг создан: $CLIENT_CONF"

# ---------------------------
# Добавляем клиента в server wg0.conf
# ---------------------------
{
  printf "\n[Peer]\n"
  printf "PublicKey = %s\n" "$CLIENT_PUB_KEY"
  printf "PresharedKey = %s\n" "$CLIENT_PSK"
  printf "AllowedIPs = %s\n" "$CLIENT_IP"
} >> "$WG_SERVER_CONF"

echo "Пир добавлен в $WG_SERVER_CONF (IP: $CLIENT_IP)"

# ---------------------------
# Перезагрузка wg-quick: сначала пробуем wg-quick down/up с полным путём к файлу
# ---------------------------
# (некоторые версии wg-quick принимают путь, некоторые — только имя интерфейса)
set +e
wg-quick down "$WG_SERVER_CONF" 2>/dev/null
RC_DOWN=$?
wg-quick up "$WG_SERVER_CONF"
RC_UP=$?
set -e

if [[ $RC_UP -ne 0 ]]; then
  # Пытаемся альтернативно: взять имя интерфейса из имени файла (wg0.conf -> wg0)
  IFACE=$(basename "$WG_SERVER_CONF" .conf)
  echo "wg-quick с полным путём не сработал (RC=$RC_UP). Пробуем по имени интерфейса: $IFACE"
  set +e
  wg-quick down "$IFACE" 2>/dev/null || true
  wg-quick up "$IFACE"
  RC_ALT=$?
  set -e
  if [[ $RC_ALT -ne 0 ]]; then
    echo "Ошибка: не удалось поднять интерфейс через wg-quick. Проверьте права и место хранения конфига."
    echo "Попробуйте вручную: wg-quick up \"$WG_SERVER_CONF\" или wg-quick up $IFACE"
    exit 1
  fi
fi

# ---------------------------
# Итоги
# ---------------------------
cat <<EOF

Успех.
Новый клиент: $CLIENT_NAME
Клиентский конфиг: $CLIENT_CONF
IP клиента: $CLIENT_IP

SERVER_PRIV_KEY длина: ${#SERVER_PRIV_KEY}
(первые/последние символы ключа сервера (masked): $(printf "%s" "$SERVER_PRIV_KEY" | sed -E 's/(.{4}).*(.{4})/\1... \2/'))

PrivateKey клиента записан в клиентский конфиг и PublicKey клиента добавлен в $WG_SERVER_CONF.

EOF

exit 0
