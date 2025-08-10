#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Полный скрипт: create client and append peer to wg0.conf
# Исправлена проблема: извлечение PrivateKey сервера не обрезает завершающий '='
# ---------------------------

# Поиск wg0.conf (первый найденный)
WG_SERVER_CONF=$(find / -type f -name wg0.conf 2>/dev/null | head -n 1 || true)

if [[ -z "${WG_SERVER_CONF:-}" ]]; then
  echo "Ошибка: wg0.conf не найден (искали по всему /)."
  exit 1
fi

WG_DIR=$(dirname "$WG_SERVER_CONF")
WG_CLIENT_DIR="$WG_DIR"   # сохранять клиентские конфиги в той же директории, где найден wg0.conf

echo "Найден конфиг WireGuard: $WG_SERVER_CONF"
echo "Клиентские конфиги будут сохраняться в: $WG_CLIENT_DIR"

# Проверки наличия нужных утилит
for cmd in wg wg-quick curl sed awk grep tr od; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Ошибка: требуется утилита '$cmd' — установите соответствующий пакет."
    exit 1
  fi
done

# Параметры
WG_CLIENT_IP_BASE="10.8.1."
SERVER_IP=$(curl -s https://ifconfig.me || true)
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="your.server.ip"
fi
SERVER_PORT=43142

mkdir -p "$WG_CLIENT_DIR"

# Номер следующего clientX
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

# =========================
# ВАЖНО: корректное извлечение PrivateKey СЕРВЕРА
# Используем sed, чтобы удалить префикс "PrivateKey = " и сохранить всё остальное (включая trailing '=')
# =========================
SERVER_PRIV_KEY=$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$WG_SERVER_CONF" | head -n 1 || true)
# Удаляем CR и кавычки и лишние пробелы по краям, но НЕ удаляем trailing '='
SERVER_PRIV_KEY=$(printf "%s" "$SERVER_PRIV_KEY" | tr -d '\r' | sed -E "s/^['\"]|['\"]$//g" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

if [[ -z "$SERVER_PRIV_KEY" ]]; then
  echo "Ошибка: PrivateKey сервера не найден в $WG_SERVER_CONF"
  exit 1
fi

# Проверка базового формата
if ! printf "%s" "$SERVER_PRIV_KEY" | grep -Eq '^[A-Za-z0-9+/]+=*$'; then
  echo "Ошибка: извлечённая строка не похожа на base64 (недопустимые символы)."
  echo "Masked: $(printf "%s" "$SERVER_PRIV_KEY" | sed -E 's/(.{4}).*(.{4})/\1... \2/')"
  exit 1
fi

echo "PrivateKey length: ${#SERVER_PRIV_KEY}"

# Попытка сгенерировать публичный ключ сервера
set +e
SERVER_PUB_KEY=$(printf "%s" "$SERVER_PRIV_KEY" | wg pubkey 2>/tmp/_wg_err.$$) || true
WG_RC=$?
set -e

if [[ $WG_RC -ne 0 || -z "${SERVER_PUB_KEY:-}" ]]; then
  echo "Ошибка: не удалось сгенерировать public key из private key (wg pubkey вернул ошибку)."
  echo "Проверяй корректность PrivateKey в $WG_SERVER_CONF"
  echo "wg stderr:"
  sed -n '1,200p' /tmp/_wg_err.$$ || true
  rm -f /tmp/_wg_err.$$ || true
  exit 1
fi
rm -f /tmp/_wg_err.$$ || true
echo "Server public key OK."

# =========================
# Генерация ключей клиента
# =========================
CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(printf "%s" "$CLIENT_PRIV_KEY" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

# =========================
# Определение следующего IP в подсети (ищем Used AllowedIPs в server conf)
# =========================
USED_LAST_OCTETS=$(sed -n 's/.*10\.8\.1\.\([0-9][0-9]*\).*/\1/p' "$WG_SERVER_CONF" | sort -n || true)
NEXT_OCTET=2
if [[ -n "$USED_LAST_OCTETS" ]]; then
  LAST=$(printf "%s\n" "$USED_LAST_OCTETS" | tail -n 1)
  NEXT_OCTET=$((LAST + 1))
  if (( NEXT_OCTET < 2 )); then NEXT_OCTET=2; fi
fi

CLIENT_IP="${WG_CLIENT_IP_BASE}${NEXT_OCTET}/32"
CLIENT_CONF="$WG_CLIENT_DIR/${CLIENT_NAME}.conf"

# =========================
# Запись клиентского конфига (гарантированно пишем PrivateKey клиента)
# =========================
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

# =========================
# Добавляем пира в серверный конфиг
# =========================
cp "$WG_SERVER_CONF" "${WG_SERVER_CONF}.bak.$(date +%s)"
{
  printf "\n[Peer]\n"
  printf "PublicKey = %s\n" "$CLIENT_PUB_KEY"
  printf "PresharedKey = %s\n" "$CLIENT_PSK"
  printf "AllowedIPs = %s\n" "$CLIENT_IP"
} >> "$WG_SERVER_CONF"

echo "Пир добавлен в серверный конфиг $WG_SERVER_CONF с IP $CLIENT_IP (бэкап сохранён)."

# =========================
# Перезапуск wg-quick с полным путём
# =========================
set +e
wg-quick down "$WG_SERVER_CONF" 2>/dev/null || true
wg-quick up "$WG_SERVER_CONF"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  IFACE=$(basename "$WG_SERVER_CONF" .conf)
  echo "wg-quick up вернул код $RC; пробуем wg-quick up $IFACE"
  set +e
  wg-quick down "$IFACE" 2>/dev/null || true
  wg-quick up "$IFACE"
  RC2=$?
  set -e
  if [[ $RC2 -ne 0 ]]; then
    echo "Ошибка при запуске интерфейса. Проверьте логи и права."
    exit 1
  fi
fi

echo "WireGuard перезапущен успешно."
echo "Новый клиент: $CLIENT_NAME"
echo "Клиентский файл: $CLIENT_CONF"
echo "IP клиента: $CLIENT_IP"

exit 0
