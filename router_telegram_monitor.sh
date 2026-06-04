#!/bin/sh
# Router monitoring script – sends Telegram alerts on connectivity & service state changes
# Enhanced with Multi-WAN (mwan3) monitoring, logging, and watchdog checks.

TOKEN='YOUR_TELEGRAM_BOT_TOKEN'
CHAT_ID='YOUR_TELEGRAM_CHAT_ID'

# Log file
LOG_FILE='/var/log/router_monitor.log'
MAX_LOG_SIZE=$((5*1024*1024)) # 5 MB

# State files to persist conditions across script invocations (cron run every 5 mins)
INTERNET_STATE_FILE='/tmp/monitor_internet_down'
ZAPRET_STATE_FILE='/tmp/monitor_zapret_down'

log_msg() {
  local msg="$1"
  local ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts $msg" >> "$LOG_FILE"
  # Rotate if needed
  if [ -f "$LOG_FILE" ] && [ $(stat -f %z "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date '+%Y%m%d%H%M%S').old"
  fi
  logger -t router_monitor "$msg"
}

send_msg() {
  local text=$(echo -e "$1")
  # Added connection timeouts to prevent hanging if internet/DNS is down
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --connect-timeout 5 --max-time 15 \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=${text}" > /dev/null
  log_msg "Telegram sent: $1"
}

# ---------- WAN Interfaces Monitoring (mwan3) ----------
check_interface_state() {
  local iface="$1"
  local displayName="$2"
  local state_file="/tmp/monitor_${iface}_down"
  local status=$(ubus call mwan3 status | jq -r ".interfaces.${iface}.status" 2>/dev/null || echo "unknown")
  
  if [ "$status" = "online" ]; then
    if [ -f "$state_file" ]; then
      local DOWN_TIME=$(cat "$state_file")
      local CURRENT_TIME=$(date +%s)
      local DIFF_SEC=$((CURRENT_TIME - DOWN_TIME))
      local DIFF_MIN=$((DIFF_SEC / 60))
      local DOWN_TIME_STR=$(date -d "@$DOWN_TIME" '+%d.%m %H:%M:%S')
      local CURRENT_TIME_STR=$(date -d "@$CURRENT_TIME" '+%d.%m %H:%M:%S')
      
      send_msg "🟢 <b>Интерфейс ${displayName} восстановлен!</b>\n🔴 Упал: <code>${DOWN_TIME_STR}</code>\n🟢 Поднялся: <code>${CURRENT_TIME_STR}</code>\n⏱ Отсутствовал: <code>~${DIFF_MIN} мин</code>"
      rm -f "$state_file"
      log_msg "Interface ${iface} restored after ${DIFF_MIN} minutes"
    fi
  elif [ "$status" = "offline" ]; then
    if [ ! -f "$state_file" ]; then
      date +%s > "$state_file"
      send_msg "🔴 <b>Внимание: Интерфейс ${displayName} упал!</b>\n⚠️ Работа продолжается через резервный канал."
      log_msg "Interface ${iface} down detected"
    fi
  fi
}

# ----------------- Main monitoring loop -----------------

# 1. Interfaces & Internet Monitoring
check_interface_state "wan" "WAN (MGTS)"
check_interface_state "wanb" "WANB (Starlink)"

# 1.2 General Internet Monitoring
wan_status=$(ubus call mwan3 status | jq -r '.interfaces.wan.status' 2>/dev/null || echo 'unknown')
wanb_status=$(ubus call mwan3 status | jq -r '.interfaces.wanb.status' 2>/dev/null || echo 'unknown')

if [ "$wan_status" = "online" ] || [ "$wanb_status" = "online" ]; then
  if [ -f "$INTERNET_STATE_FILE" ]; then
    DOWN_TIME=$(cat "$INTERNET_STATE_FILE")
    CURRENT_TIME=$(date +%s)
    DIFF_SEC=$((CURRENT_TIME - DOWN_TIME))
    DIFF_MIN=$((DIFF_SEC / 60))
    DOWN_TIME_STR=$(date -d "@$DOWN_TIME" '+%d.%m %H:%M:%S')
    CURRENT_TIME_STR=$(date -d "@$CURRENT_TIME" '+%d.%m %H:%M:%S')
    send_msg "⚠️ <b>Соединение с интернетом полностью восстановлено!</b>\n🔴 Отключение: <code>$DOWN_TIME_STR</code>\n🟢 Восстановление: <code>$CURRENT_TIME_STR</code>\n⏱ Отсутствовало: <code>~${DIFF_MIN} мин</code>"
    rm -f "$INTERNET_STATE_FILE"
    log_msg "Internet fully restored after $DIFF_MIN minutes"
  fi
else
  if [ "$wan_status" = "offline" ] && [ "$wanb_status" = "offline" ]; then
    if [ ! -f "$INTERNET_STATE_FILE" ]; then
      date +%s > "$INTERNET_STATE_FILE"
      send_msg "🚨 <b>Соединение с интернетом полностью потеряно!</b>\n🔴 Все провайдеры (MGTS и Starlink) недоступны."
      log_msg "All WAN interfaces down, internet lost"
    fi
  fi
fi

# 2. Zapret Monitoring (original, with logging)
if [ "$(/etc/init.d/zapret status 2>&1)" = "running" ]; then
  if [ -f "$ZAPRET_STATE_FILE" ]; then
    send_msg "✅ <b>Сервис Zapret успешно восстановил работу!</b>"
    rm -f "$ZAPRET_STATE_FILE"
    log_msg "Zapret service restored"
  fi
else
  if [ ! -f "$ZAPRET_STATE_FILE" ]; then
    send_msg "⚠️ <b>Внимание: Сервис Zapret упал или остановлен!</b>\n🔄 Пытаюсь перезапустить автоматически..."
    touch "$ZAPRET_STATE_FILE"
    /etc/init.d/zapret restart >/dev/null 2>&1
    log_msg "Zapret service was down, attempted restart"
  fi
fi

# 3. Podkop / Sing-box Monitoring (Delegated to singbox-watchdog)
if ! pgrep -f "singbox-watchdog" >/dev/null; then
  if [ ! -f "/tmp/monitor_watchdog_down" ]; then
    send_msg "⚠️ <b>Внимание: Скрипт singbox-watchdog не запущен!</b>\n🔄 Пытаюсь запустить службу watchdog..."
    touch "/tmp/monitor_watchdog_down"
    /etc/init.d/singbox-watchdog restart >/dev/null 2>&1
    log_msg "singbox-watchdog was down, attempted restart"
  fi
else
  if [ -f "/tmp/monitor_watchdog_down" ]; then
    send_msg "✅ <b>Служба singbox-watchdog восстановлена и активна!</b>"
    rm -f "/tmp/monitor_watchdog_down"
    log_msg "singbox-watchdog service recovered"
  fi
fi

# End of script
