#!/bin/sh
# Router monitoring script – sends Telegram alerts on connectivity & service state changes
# Enhanced to dynamically resolve recipients from ALLOWED_IDS and /etc/router_admin_bot.allow

TOKEN='8294185650:AAHWU5N5OgX-AUmp3roZCDIKeaSV1lsG7w0'

# Hardcoded whitelisted Telegram user/chat IDs (space‑separated)
ALLOWED_IDS='867086686 519835093'
ALLOW_FILE='/etc/router_admin_bot.allow'

# Log file
LOG_FILE='/var/log/router_monitor.log'
MAX_LOG_SIZE=$((5*1024*1024)) # 5 MB

# State files to persist conditions across script invocations (cron run every 5 mins)
INTERNET_STATE_FILE='/tmp/monitor_internet_down'
ZAPRET_STATE_FILE='/tmp/monitor_zapret_down'
PODKOP_STATE_FILE='/tmp/monitor_podkop_down'
PROXY_STATE_FILE='/tmp/monitor_proxy_down'

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

# Function to get all active chat IDs (returns unique list)
get_chat_ids() {
  local ids=""
  # Add hardcoded IDs
  for id in $ALLOWED_IDS; do
    ids="$ids $id"
  done
  # Add IDs from the dynamically modified bot whitelist file
  if [ -f "$ALLOW_FILE" ]; then
    while read -r line; do
      local cleaned=$(echo "$line" | tr -cd '0-9')
      if [ -n "$cleaned" ]; then
        ids="$ids $cleaned"
      fi
    done < "$ALLOW_FILE"
  fi
  # Output unique IDs
  echo "$ids" | tr ' ' '\n' | sort -u | xargs
}

send_msg() {
  local text=$(echo -e "$1")
  local target_chats=$(get_chat_ids)
  
  for chat in $target_chats; do
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      -d chat_id="$chat" \
      -d parse_mode="HTML" \
      --data-urlencode "text=${text}" > /dev/null
  done
  log_msg "Telegram sent to [$target_chats]: $1"
}

# ---------- DoH health check ----------
check_doh() {
  local url="$1"
  local code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  [ "$code" -eq 200 ]
}

# Set DNS fallback to DoH proxies (Cloudflare 5053, Google 5054, OpenDNS 443)
set_dns_fallback() {
  # Desired upstream list
  local upstreams="127.0.0.1#5053,127.0.0.1#5054,127.0.0.1#443"
  # Check DoH health before applying
  local healthy=true
  for port in 5053 5054 443; do
    if ! check_doh "https://127.0.0.1:${port}/dns-query?name=example.com"; then
      log_msg "DoH endpoint 127.0.0.1:${port} is unreachable"
      healthy=false
    else
      log_msg "DoH endpoint 127.0.0.1:${port} is healthy"
    fi
  done
  if [ "$healthy" = false ]; then
    log_msg "Skipping DNS switch because one or more DoH endpoints are unhealthy"
    return 0
  fi
  # Update podkop DNS setting if needed
  local current=$(uci get podkop.settings.dns_upstream 2>/dev/null || echo '')
  if [ "$current" != "$upstreams" ]; then
    uci set podkop.settings.dns_upstream="$upstreams"
    uci commit podkop
    /etc/init.d/podkop restart >/dev/null 2>&1
    log_msg "Podkop DNS upstream switched to DoH: $upstreams"
    # Also adjust dnsmasq upstream servers
    uci set dhcp.@dnsmasq[0].server='127.0.0.1#5053,127.0.0.1#5054,127.0.0.1#443'
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    log_msg "dnsmasq restarted with DoH upstreams"
    send_msg "✅ <b>DNS переключён на DoH‑fallback (Cloudflare, Google, OpenDNS)</b>"
  fi
}

# ---------- WAN Interfaces Monitoring (mwan3) ----------
# Adjusted to handle both mwan3 status or native system interfaces when mwan3 is disabled
check_interface_state() {
  local iface="$1"
  local displayName="$2"
  local state_file="/tmp/monitor_${iface}_down"
  
  # When mwan3 is active, check via ubus. When mwan3 is disabled, check kernel link status
  local status="unknown"
  if /etc/init.d/mwan3 enabled 2>/dev/null; then
    status=$(ubus call mwan3 status | jq -r ".interfaces.${iface}.status" 2>/dev/null || echo "unknown")
  else
    # Check system interface running state (e.g. eth0, eth1)
    local dev_name=""
    if [ "$iface" = "wan" ]; then
      dev_name="eth0"
    elif [ "$iface" = "wanb" ]; then
      dev_name="eth1"
    fi
    if [ -n "$dev_name" ]; then
      if ip link show dev "$dev_name" | grep -q "LOWER_UP"; then
        status="online"
      else
        status="offline"
      fi
    fi
  fi
  
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

# 0. Ensure DNS fallback is configured on each run
set_dns_fallback

# 1. Interfaces & Internet Monitoring
check_interface_state "wan" "WAN (MGTS)"
check_interface_state "wanb" "WANB (Starlink)"

# 1.2 General Internet Monitoring
wan_status="unknown"
wanb_status="unknown"

if /etc/init.d/mwan3 enabled 2>/dev/null; then
  wan_status=$(ubus call mwan3 status | jq -r '.interfaces.wan.status' 2>/dev/null || echo 'unknown')
  wanb_status=$(ubus call mwan3 status | jq -r '.interfaces.wanb.status' 2>/dev/null || echo 'unknown')
else
  # Check native interface states when balancing is off
  if ip link show dev eth0 2>/dev/null | grep -q "LOWER_UP"; then wan_status="online"; else wan_status="offline"; fi
  if ip link show dev eth1 2>/dev/null | grep -q "LOWER_UP"; then wanb_status="online"; else wanb_status="offline"; fi
fi

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
if [ "$(/etc/init.d/zapret2 status 2>&1)" = "running" ]; then
  if [ -f "$ZAPRET_STATE_FILE" ]; then
    send_msg "✅ <b>Сервис Zapret успешно восстановил работу!</b>"
    rm -f "$ZAPRET_STATE_FILE"
    log_msg "Zapret service restored"
  fi
else
  if [ ! -f "$ZAPRET_STATE_FILE" ]; then
    send_msg "⚠️ <b>Внимание: Сервис Zapret упал или остановлен!</b>\n🔄 Пытаюсь перезапустить автоматически..."
    touch "$ZAPRET_STATE_FILE"
    /etc/init.d/zapret2 restart >/dev/null 2>&1
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
