#!/bin/sh
# Router monitoring script – sends Telegram alerts on connectivity & service state changes

TOKEN='YOUR_TELEGRAM_BOT_TOKEN'
CHAT_ID='YOUR_TELEGRAM_CHAT_ID'

# State files to persist conditions across script invocations (cron run every 5 mins)
INTERNET_STATE_FILE='/tmp/monitor_internet_down'
ZAPRET_STATE_FILE='/tmp/monitor_zapret_down'
PODKOP_STATE_FILE='/tmp/monitor_podkop_down'
PROXY_STATE_FILE='/tmp/monitor_proxy_down'

send_msg() {
  local text=$(echo -e "$1")
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=${text}" >/dev/null
}

# 1. Internet Monitoring
if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
  # Internet is UP
  if [ -f "$INTERNET_STATE_FILE" ]; then
    DOWN_TIME=$(cat "$INTERNET_STATE_FILE")
    CURRENT_TIME=$(date +%s)
    DIFF_SEC=$((CURRENT_TIME - DOWN_TIME))
    DIFF_MIN=$((DIFF_SEC / 60))
    
    DOWN_TIME_STR=$(date -d "@$DOWN_TIME" "+%d.%m %H:%M:%S")
    CURRENT_TIME_STR=$(date -d "@$CURRENT_TIME" "+%d.%m %H:%M:%S")
    
    send_msg "⚠️ <b>Соединение с интернетом восстановлено!</b>\n🔴 Отключение: <code>$DOWN_TIME_STR</code>\n🟢 Восстановление: <code>$CURRENT_TIME_STR</code>\n⏱ Отсутствовало: <code>~${DIFF_MIN} мин</code>"
    rm -f "$INTERNET_STATE_FILE"
  fi
else
  # Internet is DOWN
  if [ ! -f "$INTERNET_STATE_FILE" ]; then
    date +%s > "$INTERNET_STATE_FILE"
  fi
fi

# 2. Zapret Monitoring
if [ "$(/etc/init.d/zapret status 2>&1)" = "running" ]; then
  # Zapret is running
  if [ -f "$ZAPRET_STATE_FILE" ]; then
    send_msg "✅ <b>Сервис Zapret успешно восстановил работу!</b>"
    rm -f "$ZAPRET_STATE_FILE"
  fi
else
  # Zapret is NOT running
  if [ ! -f "$ZAPRET_STATE_FILE" ]; then
    send_msg "⚠️ <b>Внимание: Сервис Zapret упал или остановлен!</b>"
    touch "$ZAPRET_STATE_FILE"
  fi
fi

# 3. Podkop / Sing-box Monitoring
PODKOP_INFO=$(/usr/bin/podkop get_status 2>/dev/null)
SB_INFO=$(/usr/bin/podkop get_sing_box_status 2>/dev/null)
PODKOP_OK=0

if echo "$PODKOP_INFO" | grep -q '"status":"enabled"'; then
  if echo "$SB_INFO" | grep -q '"running":1'; then
    PODKOP_OK=1
  fi
fi

if [ "$PODKOP_OK" = "1" ]; then
  # Podkop is healthy
  if [ -f "$PODKOP_STATE_FILE" ]; then
    send_msg "✅ <b>Сервис Podkop (Sing-box) успешно восстановил работу!</b>"
    rm -f "$PODKOP_STATE_FILE"
  fi
  
  # 4. Podkop Proxy Connectivity Monitoring (only check proxy if sing-box is running)
  # Check connection to proxy using mixed inbound SOCKS port (adjust SOCKS port as needed)
  PROXY_IP=$(curl -s -x socks5h://127.0.0.1:4534 --connect-timeout 5 https://api.ipify.org)
  if [ -n "$PROXY_IP" ]; then
    # Proxy works
    if [ -f "$PROXY_STATE_FILE" ]; then
      send_msg "✅ <b>Соединение с прокси-сервером Podkop восстановлено!</b>"
      rm -f "$PROXY_STATE_FILE"
    fi
  else
    # Proxy does not work
    if [ ! -f "$PROXY_STATE_FILE" ] && [ ! -f "$INTERNET_STATE_FILE" ]; then
      send_msg "⚠️ <b>Внимание: Соединение с прокси-сервером Podkop пропало (хотя интернет доступен)!</b>"
      touch "$PROXY_STATE_FILE"
    fi
  fi
else
  # Podkop is NOT healthy
  if [ ! -f "$PODKOP_STATE_FILE" ]; then
    send_msg "⚠️ <b>Внимание: Сервис Podkop упал или Sing-box не запущен!</b>"
    touch "$PODKOP_STATE_FILE"
  fi
  rm -f "$PROXY_STATE_FILE"
fi
