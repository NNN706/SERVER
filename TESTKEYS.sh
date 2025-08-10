#!/usr/bin/env bash
set -euo pipefail

# Скрипт: вывод проблемной строки PrivateKey из найденного wg0.conf
# Usage: ./wg_debug_key.sh [path/to/wg0.conf]
# Если путь не указан — ищет первый wg0.conf в системе.

WG_CFG="${1:-}"

if [[ -z "$WG_CFG" ]]; then
  WG_CFG=$(find / -type f -name wg0.conf 2>/dev/null | head -n 1 || true)
fi

if [[ -z "$WG_CFG" ]]; then
  echo "Ошибка: wg0.conf не найден. Передайте путь как аргумент."
  exit 1
fi

if [[ ! -f "$WG_CFG" ]]; then
  echo "Ошибка: файл $WG_CFG не существует или недоступен."
  exit 1
fi

echo "Используем файл: $WG_CFG"
echo

# Проверки
for cmd in awk sed tr od wg; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Требуется утилита: $cmd"
    exit 1
  fi
done

# Извлекаем первую строку PrivateKey = ...
RAW_LINE=$(awk -F'=' '/^[[:space:]]*PrivateKey[[:space:]]*=/ { print $2; exit }' "$WG_CFG" || true)

# Показываем raw (как есть), чтобы видеть ведущие/замыкающие пробелы — в кавычках
echo "---- RAW extracted fragment (between quotes) ----"
printf '"%s"\n' "$RAW_LINE"
echo

# очищаем (удаляем CR, кавычки, пробелы по краям) — но сохраним исход для отладки
CLEAN_KEY=$(printf "%s" "$RAW_LINE" | tr -d '\r' | sed -E "s/^['\"]|['\"]$//g" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

echo "---- CLEANED key (крайние пробелы и CR удалены) ----"
printf '"%s"\n' "$CLEAN_KEY"
echo

# masked view: первые 4 / последние 4
MASKED=$(printf "%s" "$CLEAN_KEY" | sed -E 's/(.{4}).*(.{4})/\1... \2/')
echo "Masked: $MASKED"

LEN=$(printf "%s" "$CLEAN_KEY" | wc -c)
echo "Length (bytes/chars): $LEN"
echo

# hex dump (один ряд) — покажет невидимые символы (0d = CR, 20 = space и т.д.)
echo "---- HEX dump of CLEANED key (one line) ----"
printf "%s" "$CLEAN_KEY" | od -An -t x1 | sed -n '1,5p'
echo

# также показать однобайтовый вывод RAW_LINE (чтобы увидеть, есть ли \r в исходе)
echo "---- HEX dump of RAW extracted fragment (to detect hidden CR before cleaning) ----"
printf "%s" "$RAW_LINE" | od -An -t x1 | sed -n '1,5p'
echo

# Попытка сгенерировать публичный ключ (wg pubkey)
echo "Пробуем wg pubkey с CLEANED key..."
set +e
printf "%s" "$CLEAN_KEY" | wg pubkey >/tmp/_wg_pubkey.$$ 2>/tmp/_wg_err.$$ 
WG_RET=$?
set -e

if [[ $WG_RET -eq 0 && -s /tmp/_wg_pubkey.$$ ]]; then
  echo "wg pubkey OK — публичный ключ сгенерирован успешно."
  echo "PublicKey (masked):"
  awk '{printf "%s\n", substr($0,1,4) "..." substr($0,length($0)-3,4)}' /tmp/_wg_pubkey.$$ || true
  rm -f /tmp/_wg_pubkey.$$ /tmp/_wg_err.$$ || true
  exit 0
else
  echo "wg pubkey вернул ошибку (код $WG_RET)."
  echo "---- stderr from wg pubkey ----"
  sed -n '1,200p' /tmp/_wg_err.$$ || true
  rm -f /tmp/_wg_pubkey.$$ /tmp/_wg_err.$$ || true
  echo
  echo "Рекомендации:"
  echo " - Проверьте, нет ли лишних невидимых символов (CR, пробелы)."
  echo " - Если длина = 43, возможно отсутствует символ '=' в конце (padding)."
  echo " - НЕЛЬЗЯ публиковать полный приватный ключ публично. При необходимости покажите замаскированный вывод выше."
  echo
  if [[ "$LEN" -eq 43 ]]; then
    echo "Если хочешь, можно попытаться автоматически добавить '=' в конец и проверить — запусти скрипт 'auto_fix' (или скажи мне, и я дам команду)."
  fi
  exit 1
fi
