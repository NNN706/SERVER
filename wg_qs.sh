#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Поиск server wg0.conf (всю FS) - берем первый найденный
# ---------------------------
WG_SERVER_CONF=$(find / -type f -name wg0.conf 2>/dev/null | head -n 1 || true)

if [[ -z "${WG_SERVER_CONF:-}" ]]; then
  echo "Ошибка: wg0.conf не найден (искали по всему /)."
  exit 1
fi

WG_DIR=$(dirname "$WG_SERVER_CONF")
WG_CLIENT_DIR="$WG_DIR"   # сохранять клиентские конфиги в той же директории, где найден wg0.conf

echo "Найден конфиг WireGuard: $WG_SERVER_CONF"
echo "Клиентские конфиги будут сохраняться в: $WG_CLIENT_DIR"

# ---------------------------
# Проверки наличия нужных утилит
# ---------------------------
if ! command -v wg >/dev/null 2>&1; then
  echo "Ошибка: команда 'wg' не найдена. Установите wireguard-tools."
  exit 1
fi
if ! command -v wg-quick >/dev/null 2>&1; then
  echo "Ошибка: команда 'wg-quick' не найдена. Установите пакет с wg-quick."
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Ошибка: команда 'curl' не найдена. Установите curl или задайте вручную SERVER_IP и SERVER_PORT."
  exit 1
fi

# ---------------------------
# Настройки
# ---------------------------
WG_CLIENT_IP_BASE="10.8.1."   # подсеть, менять если надо
SERVER_IP=$(curl -s https://ifconfig.me || true)
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="your.server.ip"   # если не удалось получить внешний IP, заменить вручную
fi
SERVER_PORT=43142

mkdir -p "$WG_CLIENT_DIR"

# ---------------------------
# Номер следующего клиента (clientX)
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
# Получаем приватный ключ сервера (из wg0.conf) и считаем его публичный ключ
# ---------------------------
# Берём первую строку PrivateKey = ... (без пробелов по обе стороны)
SERVER_PRIV_KEY=$(awk -F'=' '/^[[:space:]]*PrivateKey[[:space:]]*=/ { gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit }' "$WG_SERVER_CONF" || true)

if [[ -z "$SERVER_PRIV_KEY" ]]; then
  echo "Ошибка: не найден PrivateKey в $WG_SERVER_CONF"
  exit 1
fi

SERVER_PUB_KEY=$(printf "%s" "$SERVER_PRIV_KEY" | wg pubkey)
if [[ -z "$SERVER_PUB_KEY" ]]; then
  echo "Ошибка: не удалось сгенерировать публичный ключ сервера из приватного."
  exit 1
fi

# ---------------------------
# Генерируем ключи клиента
# ---------------------------
CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(printf "%s" "$CLIENT_PRIV_KEY" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

# ---------------------------
# Получаем следующий свободный IP в подсети (ищем все используемые в AllowedIPs)
# ---------------------------
# Берём все октеты используемых IP 10.8.1.X из текущего конфигурационного файла
USED_LAST_OCTETS=$(sed -n 's/.*10\.8\.1\.\([0-9][0-9]*\).*/\1/p' "$WG_SERVER_CONF" | sort -n || true)

NEXT_OCTET=2
if [[ -n "$USED_LAST_OCTETS" ]]; then
  LAST=$(printf "%s\n" "$USED_LAST_OCTETS" | tail -n 1)
  # увеличиваем на 1, минимум 2
  NEXT_OCTET=$((LAST + 1))
  if (( NEXT_OCTET < 2 )); then NEXT_OCTET=2; fi
fi

CLIENT_IP="${WG_CLIENT_IP_BASE}${NEXT_OCTET}/32"
CLIENT_CONF="$WG_CLIENT_DIR/${CLIENT_NAME}.conf"

# ---------------------------
# Создаём клиентский конфиг (гарантированно записываем PrivateKey клиента)
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
# Добавляем клиента в серверный конфиг (append)
# ---------------------------
{
  printf "\n[Peer]\n"
  printf "PublicKey = %s\n" "$CLIENT_PUB_KEY"
  printf "PresharedKey = %s\n" "$CLIENT_PSK"
  printf "AllowedIPs = %s\n" "$CLIENT_IP"
} >> "$WG_SERVER_CONF"

echo "Пир добавлен в серверный конфиг: $WG_SERVER_CONF (IP: $CLIENT_IP)"

# ---------------------------
# Перезапуск wg-quick с полным путём к конфигу (down/up)
# ---------------------------
# Проверяем, принимает ли wg-quick путь к файлу (обычно да)
if wg-quick down "$WG_SERVER_CONF" 2>/dev/null; then
  true
else
  # Если wg-quick вернул ошибку — всё равно попытаемся продолжить и показать предупреждение
  echo "Предупреждение: wg-quick down вернул ошибку (возможно интерфейс не запущен). Продолжаем."
fi

if wg-quick up "$WG_SERVER_CONF"; then
  echo "WireGuard перезапущен через wg-quick с конфигом: $WG_SERVER_CONF"
else
  echo "Ошибка при 'wg-quick up $WG_SERVER_CONF'. Проверьте логи и права."
  exit 1
fi

# ---------------------------
# Вывод итоговой информации
# ---------------------------
cat <<EOF

Готово.
Новый клиент: $CLIENT_NAME
Путь к клиентскому конфигу: $CLIENT_CONF
IP клиента: $CLIENT_IP
Ключ клиента (PrivateKey) уже записан в клиентский конфиг.

Примечание:
- В клиентском конфиге указан PUBLIC KEY СЕРВЕРА, сгенерированный из PrivateKey, который взят из $WG_SERVER_CONF.
- НЕ рекомендуется вставлять приватный ключ сервера в клиентский конфиг (это ломает безопасность).
EOF

exit 0
