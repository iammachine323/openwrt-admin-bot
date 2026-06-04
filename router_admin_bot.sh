#!/bin/sh
# router_admin_bot.sh – Secure Telegram admin bot for OpenWrt router
# ---------------------------------------------------------------
TOKEN='YOUR_TELEGRAM_BOT_TOKEN'
# Whitelisted Telegram user/chat IDs (space‑separated)
ALLOWED_IDS='YOUR_TELEGRAM_USER_ID'
# Use the first allowed ID as the target chat for sending messages
CHAT_ID=$ALLOWED_IDS
# File that stores the last processed update offset
OFFSET_FILE='/tmp/telegram_offset'
ALLOW_FILE='/etc/router_admin_bot.allow'

# Ensure offset file exists
[ -f "$OFFSET_FILE" ] || echo 0 > "$OFFSET_FILE"

# Ensure allowed IDs file exists
if [ ! -f "$ALLOW_FILE" ]; then
  echo "$ALLOWED_IDS" | tr ' ' '\n' > "$ALLOW_FILE"
fi

# Helper: send a message (optionally with a custom keyboard)
#   $1 – text
#   $2 – JSON string for reply_markup (optional)
send_msg(){
  # Replace literal \n text sequences with actual newlines
  local text=$(echo -e "$1")
  local markup="$2"
  local target_chat="${FROM_ID:-$CHAT_ID}"
  if [ -n "$markup" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      -d chat_id="$target_chat" \
      -d parse_mode="HTML" \
      --data-urlencode "text=${text}" \
      -d reply_markup="${markup}" >/dev/null
  else
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      -d chat_id="$target_chat" \
      -d parse_mode="HTML" \
      --data-urlencode "text=${text}" >/dev/null
  fi
}

# Helper: send a document (log file)
send_doc(){
  local file="$1"
  local caption="$2"
  local target_chat="${FROM_ID:-$CHAT_ID}"
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendDocument" \
    -F chat_id="$target_chat" -F document="@$file" -F caption="$caption" >/dev/null
}

# Helper: check HTTP connectivity to URL
check_url() {
  local url="$1"
  # Force IPv4 (-4) to prevent waiting on non-routable IPv6, and relax timeout to 6s
  local code=$(curl -4 -o /dev/null -s -w "%{http_code}" --connect-timeout 6 "$url")
  if [ "$code" -gt 0 ] 2>/dev/null; then
    echo "✅ Доступен (HTTP $code)"
  else
    echo "❌ Недоступен"
  fi
}

# Pre‑defined keyboard with 4 rows of diagnostic buttons
KEYBOARD='{"keyboard":[[{"text":"📊 Статус"},{"text":"⚡ Пинг"},{"text":"📈 Нагрузка"}],[{"text":"🔍 Диагностика"},{"text":"👥 Устройства"},{"text":"🎛 MWAN"}],[{"text":"📋 Логи"},{"text":"🔎 DNS Тест"},{"text":"🛡 Обход"}],[{"text":"💾 Бэкап"},{"text":"👤 Добавить ID"},{"text":"♻️ Перезагрузка"}]],"one_time_keyboard":false,"resize_keyboard":true}'
MWAN_KEYBOARD='{"keyboard":[[{"text":"⚖️ Баланс (50/50)"}],[{"text":"🟢 Только MGTS"},{"text":"🔵 Только Starlink"}],[{"text":"⬅️ Назад"}]],"one_time_keyboard":false,"resize_keyboard":true}'

while true; do
  OFFSET=$(cat "$OFFSET_FILE")
  RESPONSE=$(curl -s --connect-timeout 10 --max-time 45 "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=${OFFSET}&timeout=20")
  
  if ! echo "$RESPONSE" | jq -e '.ok' >/dev/null 2>&1; then
    sleep 5
    continue
  fi

  echo "$RESPONSE" | jq -c '.result[]' | while read -r update; do
    FROM_ID=$(echo "$update" | jq -r '.message.from.id')
    TEXT=$(echo "$update" | jq -r '.message.text')
    UPDATE_ID=$(echo "$update" | jq '.update_id')

    # Verify sender is whitelisted using allow file
    authorized=false
    CURRENT_ALLOWED=$(cat "$ALLOW_FILE" 2>/dev/null)
    for id in $CURRENT_ALLOWED; do
      if [ "$FROM_ID" = "$id" ]; then
        authorized=true
        break
      fi
    done
    if ! $authorized; then
      send_msg "🔒 <b>Доступ ограничен</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🆔 <b>Ваш Telegram ID:</b> <code>$FROM_ID</code>\n\n💬 Перешлите этот ID администратору @fadeev_digital для получения доступа.\n━━━━━━━━━━━━━━━━━━━━━━"
      OFFSET=$((UPDATE_ID+1))
      echo "$OFFSET" > "$OFFSET_FILE"
      continue
    fi

    # Interactive state machine check
    STATE_FILE="/tmp/bot_state_${FROM_ID}"
    if [ -f "$STATE_FILE" ]; then
      STATE=$(cat "$STATE_FILE")
      case "$TEXT" in
        "📊 Статус"|"⚡ Пинг"|"📈 Нагрузка"|"📋 Логи"|"🔎 DNS Тест"|"🛣 Трассировка"|"🛡 Обход"|"🔗 Ресурсы"|"🔍 Диагностика"|"👥 Устройства"|"🎛 MWAN"|"💾 Бэкап"|"♻️ Перезагрузка"|"👤 Добавить ID"|/start|/reboot|/logs|/status|/ping|/traffic|/dns|/trace|/bypass|/resources|/diagnose|/clients|/mwan|/backup)
          # User triggered another command, cancel state silently
          rm -f "$STATE_FILE"
          ;;
        *)
          rm -f "$STATE_FILE"
          if [ "$STATE" = "AWAIT_TRACE_TARGET" ]; then
            TARGET=$(echo "$TEXT" | tr -cd 'a-zA-Z0-9.-')
            if [ -n "$TARGET" ]; then
              send_msg "🛣 <b>Запуск трассировки до $TARGET (макс. 10 хопов)...</b>"
              TRACE_OUT=$(traceroute -I -m 10 -q 1 -w 2 "$TARGET" 2>&1)
              TRACE_ESCAPED=$(echo "$TRACE_OUT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
              send_msg "🛣 <b>Трассировка до $TARGET:</b>\n<pre>$TRACE_ESCAPED</pre>" "$KEYBOARD"
            else
              send_msg "❌ Некорректный адрес. Отменено." "$KEYBOARD"
            fi
            OFFSET=$((UPDATE_ID+1))
            echo "$OFFSET" > "$OFFSET_FILE"
            continue
          elif [ "$STATE" = "AWAIT_ADD_USER_ID" ]; then
            NEW_ID=$(echo "$TEXT" | tr -cd '0-9')
            if [ -n "$NEW_ID" ]; then
              if grep -q -w "$NEW_ID" "$ALLOW_FILE" 2>/dev/null; then
                send_msg "👤 <b>Управление доступом</b>\n━━━━━━━━━━━━━━━━━━━━━━\n⚠️ ID <code>$NEW_ID</code> уже находится в списке разрешенных.\n━━━━━━━━━━━━━━━━━━━━━━" "$KEYBOARD"
              else
                echo "$NEW_ID" >> "$ALLOW_FILE"
                send_msg "👤 <b>Управление доступом</b>\n━━━━━━━━━━━━━━━━━━━━━━\n✅ ID <code>$NEW_ID</code> успешно добавлен в список разрешенных пользователей роутера!\n━━━━━━━━━━━━━━━━━━━━━━" "$KEYBOARD"
              fi
            else
              send_msg "❌ Некорректный ID (должен состоять только из цифр). Отменено." "$KEYBOARD"
            fi
            OFFSET=$((UPDATE_ID+1))
            echo "$OFFSET" > "$OFFSET_FILE"
            continue
          elif [ "$STATE" = "AWAIT_MWAN_POLICY" ]; then
            case "$TEXT" in
              "⚖️ Баланс (50/50)")
                send_msg "⚙️ <b>Применяю политику балансировки MWAN3 (50/50)...</b>"
                uci set mwan3.default_rule_v4.use_policy='balanced'
                uci commit mwan3
                /usr/sbin/mwan3 restart >/dev/null 2>&1
                send_msg "⚖️ <b>Балансировка успешно включена!</b>\nОба провайдера задействованы 50/50." "$KEYBOARD"
                ;;
              "🟢 Только MGTS")
                send_msg "⚙️ <b>Переключаю весь трафик на MGTS...</b>"
                uci set mwan3.default_rule_v4.use_policy='wan_only'
                uci commit mwan3
                /usr/sbin/mwan3 restart >/dev/null 2>&1
                send_msg "🟢 <b>Весь трафик перенаправлен на MGTS (eth0).</b>\nStarlink находится в режиме резерва." "$KEYBOARD"
                ;;
              "🔵 Только Starlink")
                send_msg "⚙️ <b>Переключаю весь трафик на Starlink...</b>"
                uci set mwan3.default_rule_v4.use_policy='wanb_only'
                uci commit mwan3
                /usr/sbin/mwan3 restart >/dev/null 2>&1
                send_msg "🔵 <b>Весь трафик перенаправлен на Starlink (eth1).</b>\nMGTS находится в режиме резерва." "$KEYBOARD"
                ;;
              "⬅️ Назад")
                send_msg "↩️ Возврат в главное меню." "$KEYBOARD"
                ;;
              *)
                send_msg "❌ Неизвестная политика. Возвращаю меню." "$KEYBOARD"
                ;;
            esac
            OFFSET=$((UPDATE_ID+1))
            echo "$OFFSET" > "$OFFSET_FILE"
            continue
          fi
          ;;
      esac
    fi

    case "$TEXT" in
      "/start")
        send_msg "👋 Привет! Я бот-администратор твоего роутера.\nИспользуй меню кнопок ниже для управления." "$KEYBOARD"
        ;;
      "/reboot"|"♻️ Перезагрузка")
        send_msg "♻️ <b>Перезагрузка роутера...</b>" "$KEYBOARD"
        sleep 2
        reboot
        ;;
      "/logs"|"📋 Логи")
        LOGFILE="/tmp/router_last.log"
        logread > "$LOGFILE"
        
        # Escape HTML entities in logs to prevent message drop
        LAST_LOGS=$(tail -n 15 "$LOGFILE" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        send_msg "📋 <b>Последние 15 строк логов:</b>\n<pre>${LAST_LOGS}</pre>" "$KEYBOARD"
        
        send_doc "$LOGFILE" "🗒 Полный лог роутера"
        ;;
      "/status"|"📊 Статус")
        # System info fetching
        MODEL=$([ -f /tmp/sysinfo/model ] && cat /tmp/sysinfo/model || cat /proc/device-tree/model 2>/dev/null)
        [ -n "$MODEL" ] || MODEL="OpenWrt Device"
        
        OS_VER=$(grep DISTRIB_DESCRIPTION /etc/openwrt_release | cut -d"'" -f2)
        [ -n "$OS_VER" ] || OS_VER="OpenWrt"
        
        UPTIME_RAW=$(uptime)
        UPTIME=$(echo "$UPTIME_RAW" | awk -F'up ' '{print $2}' | cut -d',' -f1-2)
        LOAD_AVG=$(echo "$UPTIME_RAW" | awk -F'load average:' '{print $2}' | xargs)
        
        # Memory Info (Busybox free outputs in KB, so divide by 1024 to get MB)
        MEM_TOTAL_KB=$(free | grep Mem | awk '{print $2}')
        MEM_USED_KB=$(free | grep Mem | awk '{print $3}')
        MEM_TOTAL=$(( MEM_TOTAL_KB / 1024 ))
        MEM_USED=$(( MEM_USED_KB / 1024 ))
        MEM_PCT=$(( 100 * MEM_USED_KB / MEM_TOTAL_KB ))
        
        # Storage Info
        DF_OUT=$(df -h / | grep /)
        DISK_SIZE=$(echo "$DF_OUT" | awk '{print $2}')
        DISK_USED=$(echo "$DF_OUT" | awk '{print $3}')
        DISK_PCT=$(echo "$DF_OUT" | awk '{print $5}')
        
        # NAT Active Connections
        CONN_COUNT=$(wc -l /proc/net/nf_conntrack 2>/dev/null | awk '{print $1}')
        [ -n "$CONN_COUNT" ] || CONN_COUNT="N/A"
        CONN_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
        [ -n "$CONN_MAX" ] || CONN_MAX="N/A"
        
        WAN1_IP=$(ubus call network.interface.wan status | jq -r '.["ipv4-address"][0].address' 2>/dev/null)
        [ -n "$WAN1_IP" ] && [ "$WAN1_IP" != "null" ] || WAN1_IP="N/A"
        
        WAN2_IP=$(ubus call network.interface.wanb status | jq -r '.["ipv4-address"][0].address' 2>/dev/null)
        [ -n "$WAN2_IP" ] && [ "$WAN2_IP" != "null" ] || WAN2_IP="N/A"
        
        EXT_IP=$(curl -s --connect-timeout 3 https://api.ipify.org || echo "Offline")
        
        # Zapret Status
        if [ "$(/etc/init.d/zapret status 2>&1)" = "running" ]; then
          ZAPRET_STATUS="✅ Активен"
        else
          ZAPRET_STATUS="❌ Не активен"
        fi
        
        # Podkop Status & Config
        PODKOP_INFO=$(/usr/bin/podkop get_status 2>/dev/null)
        SB_INFO=$(/usr/bin/podkop get_sing_box_status 2>/dev/null)
        
        # Proxy Outbound Details
        PODKOP_SERVER=$(jq -r '.outbounds[] | select(.type != "direct" and .type != "dns" and .type != "block") | .server' /etc/sing-box/config.json 2>/dev/null | head -n 1)
        [ -n "$PODKOP_SERVER" ] || PODKOP_SERVER="N/A"
        
        PODKOP_IP=$(nslookup "$PODKOP_SERVER" 2>/dev/null | awk '/Address:/ {print $2}' | grep -v '127.0.0.1' | head -n 1)
        [ -n "$PODKOP_IP" ] || PODKOP_IP="N/A"
        
        if echo "$PODKOP_INFO" | grep -q '"status":"enabled"'; then
          if echo "$SB_INFO" | grep -q '"running":1'; then
            PODKOP_STATUS="✅ Активен (Sing-box: запущен)"
            
            # Check SOCKS proxy connectivity
            PROXY_TEST_IP=$(curl -s -x socks5h://127.0.0.1:4534 --connect-timeout 4 https://api.ipify.org)
            if [ -n "$PROXY_TEST_IP" ]; then
              PROXY_CONN="✅ Работает (IP: $PROXY_TEST_IP)"
            else
              PROXY_CONN="❌ Ошибка подключения"
            fi
          else
            PODKOP_STATUS="⚠️ Включен (Sing-box: остановлен)"
            PROXY_CONN="❌ Sing-box не запущен"
          fi
        else
          PODKOP_STATUS="❌ Отключен"
          PROXY_CONN="❌ Отключен"
        fi
        
        STATUS_MSG="📊 <b>Статус роутера (Rosenberg)</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🏷 <b>Модель:</b> $MODEL\n💿 <b>Система:</b> $OS_VER\n⏱ <b>Uptime:</b> $UPTIME\n📈 <b>CPU Load:</b> $LOAD_AVG\n🧠 <b>ОЗУ:</b> ${MEM_USED} MB / ${MEM_TOTAL} MB (${MEM_PCT}%)\n💾 <b>Flash (/):</b> ${DISK_USED} / ${DISK_SIZE} (${DISK_PCT})\n👥 <b>Сессии NAT:</b> <code>$CONN_COUNT / $CONN_MAX</code>\n\n🌐 <b>Сеть (Multi-WAN)</b>\n├── 📶 <b>WAN (MGTS):</b> <code>$WAN1_IP</code> (eth0)\n├── 📶 <b>WANB (Starlink):</b> <code>$WAN2_IP</code> (eth1)\n└── 🌍 <b>Внешний IP:</b> <code>$EXT_IP</code>\n\n🥷 <b>Сервисы и Обход</b>\n├── 🥷 <b>Zapret:</b> $ZAPRET_STATUS\n├── 🕵️ <b>Podkop:</b> $PODKOP_STATUS\n├── 📡 <b>Сервер:</b> <code>$PODKOP_SERVER</code> ($PODKOP_IP)\n└── 🔌 <b>Прокси-соединение:</b> $PROXY_CONN\n━━━━━━━━━━━━━━━━━━━━━━"
        send_msg "$STATUS_MSG" "$KEYBOARD"
        ;;
      "/ping"|"⚡ Пинг")
        send_msg "⚡ <b>Выполняю пинг 8.8.8.8...</b>"
        PING_OUT=$(ping -c 3 -W 2 8.8.8.8 2>&1)
        if echo "$PING_OUT" | grep -q "3 packets received" || echo "$PING_OUT" | grep -q "3 received"; then
          RTT=$(echo "$PING_OUT" | tail -n 1 | awk '{print $4}')
          MIN=$(echo "$RTT" | cut -d'/' -f1)
          AVG=$(echo "$RTT" | cut -d'/' -f2)
          MAX=$(echo "$RTT" | cut -d'/' -f3)
          send_msg "⚡ <b>Результаты пинга (8.8.8.8)</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🟢 <b>Статус:</b> Доступен\n📦 <b>Пакеты:</b> <code>3/3 получено</code>\n⏱ <b>Задержка:</b> <code>$AVG мс</code> (мин: <code>$MIN</code> / макс: <code>$MAX</code>)\n━━━━━━━━━━━━━━━━━━━━━━" "$KEYBOARD"
        else
          PING_ESCAPED=$(echo "$PING_OUT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
          send_msg "⚠️ <b>Проблема со связью!</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🔴 <b>Пинг не прошел:</b>\n<pre>$PING_ESCAPED</pre>\n━━━━━━━━━━━━━━━━━━━━━━" "$KEYBOARD"
        fi
        ;;
      "📈 Нагрузка"|"/traffic")
        send_msg "📈 <b>Замеряю скорость на WAN интерфейсах (2 сек)...</b>"
        WAN_IFACE=$(ubus call network.interface.wan status | jq -r '.l3_device' 2>/dev/null)
        [ -n "$WAN_IFACE" ] || WAN_IFACE="eth0"
        WANB_IFACE=$(ubus call network.interface.wanb status | jq -r '.l3_device' 2>/dev/null)
        [ -n "$WANB_IFACE" ] || WANB_IFACE="eth1"
        
        RX_WAN1=$(cat /sys/class/net/$WAN_IFACE/statistics/rx_bytes)
        TX_WAN1=$(cat /sys/class/net/$WAN_IFACE/statistics/tx_bytes)
        RX_WANB1=$(cat /sys/class/net/$WANB_IFACE/statistics/rx_bytes)
        TX_WANB1=$(cat /sys/class/net/$WANB_IFACE/statistics/tx_bytes)
        
        sleep 2
        
        RX_WAN2=$(cat /sys/class/net/$WAN_IFACE/statistics/rx_bytes)
        TX_WAN2=$(cat /sys/class/net/$WAN_IFACE/statistics/tx_bytes)
        RX_WANB2=$(cat /sys/class/net/$WANB_IFACE/statistics/rx_bytes)
        TX_WANB2=$(cat /sys/class/net/$WANB_IFACE/statistics/tx_bytes)
        
        RX_S1=$(( (RX_WAN2 - RX_WAN1) * 8 / 2 ))
        TX_S1=$(( (TX_WAN2 - TX_WAN1) * 8 / 2 ))
        RX_S2=$(( (RX_WANB2 - RX_WANB1) * 8 / 2 ))
        TX_S2=$(( (TX_WANB2 - TX_WANB1) * 8 / 2 ))
        
        format_speed() {
          local bps="$1"
          if [ "$bps" -ge 1048576 ]; then
            echo "$(( bps / 1048576 )).$(( (bps % 1048576) * 100 / 1048576 )) Mbps"
          else
            echo "$(( bps / 1024 )) Kbps"
          fi
        }
        
        WAN_RX=$(format_speed "$RX_S1")
        WAN_TX=$(format_speed "$TX_S1")
        WANB_RX=$(format_speed "$RX_S2")
        WANB_TX=$(format_speed "$TX_S2")
        
        TRAFFIC_MSG="📈 <b>Нагрузка на интерфейсах (mwan3)</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🌐 <b>WAN (MGTS - $WAN_IFACE):</b>\n├── 📥 <b>Входящий:</b> <code>$WAN_RX</code>\n└── 📤 <b>Исходящий:</b> <code>$WAN_TX</code>\n\n🌐 <b>WANB (Starlink - $WANB_IFACE):</b>\n├── 📥 <b>Входящий:</b> <code>$WANB_RX</code>\n└── 📤 <b>Исходящий:</b> <code>$WANB_TX</code>\n━━━━━━━━━━━━━━━━━━━━━━"
        send_msg "$TRAFFIC_MSG" "$KEYBOARD"
        ;;
      "🔎 DNS Тест"|"/dns")
        send_msg "🔎 <b>Выполняю диагностику DNS...</b>"
        RES_DIR=$(nslookup google.com 2>/dev/null | awk '/Address:/ {print $2}' | grep -v '127.0.0.1' | xargs)
        RES_BLK=$(nslookup youtube.com 2>/dev/null | awk '/Address:/ {print $2}' | grep -v '127.0.0.1' | xargs)
        
        DNS_SERVER=$(nslookup google.com 2>/dev/null | grep "Server:" | awk '{print $2}')
        [ -n "$DNS_SERVER" ] || DNS_SERVER="System Default"
        
        send_msg "🔎 <b>Результаты DNS-диагностики:</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🖥 <b>DNS Сервер:</b> <code>$DNS_SERVER</code>\n🔍 <b>google.com:</b> <code>${RES_DIR:-Ошибка}</code>\n📺 <b>youtube.com:</b> <code>${RES_BLK:-Ошибка}</code>\n━━━━━━━━━━━━━━━━━━━━━━" "$KEYBOARD"
        ;;
      "🛣 Трассировка"|"/trace")
        echo "AWAIT_TRACE_TARGET" > "/tmp/bot_state_${FROM_ID}"
        send_msg "📝 <b>Введите адрес или IP для трассировки:</b>\n(Например: <code>google.com</code> или <code>8.8.8.8</code>)"
        ;;
      "🛡 Обход"|"/bypass")
        CONN_COUNT=$(wc -l /proc/net/nf_conntrack 2>/dev/null | awk '{print $1}')
        [ -n "$CONN_COUNT" ] || CONN_COUNT="N/A"
        CONN_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
        [ -n "$CONN_MAX" ] || CONN_MAX="N/A"
        
        IP_RULES=$(ip rule | grep -E "fwmark|lookup" | head -n 4)
        [ -n "$IP_RULES" ] || IP_RULES="Правил маршрутизации обхода не найдено"
        
        NFT_CHECK=$(nft list sets 2>/dev/null | grep -E "podkop|zapret" | awk '{print $2}' | xargs)
        [ -n "$NFT_CHECK" ] || NFT_CHECK="Наборов nftables для обхода не найдено"
        
        send_msg "🛡 <b>Статус правил обхода и сессий:</b>\n━━━━━━━━━━━━━━━━━━━━━━\n👥 <b>Активные сессии NAT:</b> <code>$CONN_COUNT / $CONN_MAX</code>\n🗺 <b>Правила IP Rules:</b>\n<pre>$IP_RULES</pre>\n🧱 <b>Наборов nftables:</b>\n<code>$NFT_CHECK</code>\n━━━━━━━━━━━━━━━━━━━━━━" "$KEYBOARD"
        ;;
      "🔍 Диагностика"|"/diagnose")
        send_msg "🔍 <b>Запуск комплексной диагностики сети...</b>\nЭто займет около 15-20 секунд."
        
        # 1. Hardware Status (CPU Temp)
        CPU_TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        if [ -n "$CPU_TEMP_RAW" ]; then
          CPU_TEMP=$(( CPU_TEMP_RAW / 1000 ))
        else
          CPU_TEMP="N/A"
        fi
        
        # 2. Link Flapping check
        LINK_FLAPS=$(logread | grep -E "eth0|eth1|link down|link up" | grep -E -c "link down|link up|down|up")
        [ -n "$LINK_FLAPS" ] || LINK_FLAPS=0
        
        # --- WAN 1 (MGTS - eth0) ---
        W1_PHYS=0
        if [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ]; then
          W1_PHYS=1
        fi
        
        W1_STATUS=$(ubus call network.interface.wan status 2>/dev/null)
        W1_IP=$(echo "$W1_STATUS" | jq -r '.["ipv4-address"][0].address' 2>/dev/null)
        [ -n "$W1_IP" ] && [ "$W1_IP" != "null" ] || W1_IP=""
        
        W1_GW=$(echo "$W1_STATUS" | jq -r '.["route"][0].nexthop' 2>/dev/null)
        [ -n "$W1_GW" ] && [ "$W1_GW" != "null" ] || W1_GW=""
        
        W1_GW_PING=0
        W1_GW_LOSS=100
        W1_GW_RTT="N/A"
        if [ -n "$W1_GW" ] && [ "$W1_PHYS" -eq 1 ]; then
          PING_OUT=$(ping -I eth0 -c 3 -W 2 "$W1_GW" 2>&1)
          if echo "$PING_OUT" | grep -q -E "packets received|received"; then
            REC=$(echo "$PING_OUT" | grep -E "packets transmitted|received" | awk -F', ' '{print $2}' | awk '{print $1}')
            W1_GW_LOSS=$(( 100 - (REC * 100 / 3) ))
            if [ "$REC" -gt 0 ]; then
              W1_GW_PING=1
              W1_GW_RTT=$(echo "$PING_OUT" | tail -n 1 | awk '{print $4}' | cut -d'/' -f2)
            fi
          fi
        fi
        
        W1_INT_PING=0
        W1_INT_LOSS=100
        W1_INT_RTT="N/A"
        if [ "$W1_GW_PING" -eq 1 ]; then
          PING_OUT=$(ping -I eth0 -c 3 -W 2 8.8.8.8 2>&1)
          if echo "$PING_OUT" | grep -q -E "packets received|received"; then
            REC=$(echo "$PING_OUT" | grep -E "packets transmitted|received" | awk -F', ' '{print $2}' | awk '{print $1}')
            W1_INT_LOSS=$(( 100 - (REC * 100 / 3) ))
            if [ "$REC" -gt 0 ]; then
              W1_INT_PING=1
              W1_INT_RTT=$(echo "$PING_OUT" | tail -n 1 | awk '{print $4}' | cut -d'/' -f2)
            fi
          fi
        fi
        
        # --- WAN 2 (Starlink - eth1) ---
        W2_PHYS=0
        if [ "$(cat /sys/class/net/eth1/carrier 2>/dev/null)" = "1" ]; then
          W2_PHYS=1
        fi
        
        W2_STATUS=$(ubus call network.interface.wanb status 2>/dev/null)
        W2_IP=$(echo "$W2_STATUS" | jq -r '.["ipv4-address"][0].address' 2>/dev/null)
        [ -n "$W2_IP" ] && [ "$W2_IP" != "null" ] || W2_IP=""
        
        W2_GW=$(echo "$W2_STATUS" | jq -r '.["route"][0].nexthop' 2>/dev/null)
        [ -n "$W2_GW" ] && [ "$W2_GW" != "null" ] || W2_GW=""
        
        W2_GW_PING=0
        W2_GW_LOSS=100
        W2_GW_RTT="N/A"
        if [ -n "$W2_GW" ] && [ "$W2_PHYS" -eq 1 ]; then
          PING_OUT=$(ping -I eth1 -c 3 -W 2 "$W2_GW" 2>&1)
          if echo "$PING_OUT" | grep -q -E "packets received|received"; then
            REC=$(echo "$PING_OUT" | grep -E "packets transmitted|received" | awk -F', ' '{print $2}' | awk '{print $1}')
            W2_GW_LOSS=$(( 100 - (REC * 100 / 3) ))
            if [ "$REC" -gt 0 ]; then
              W2_GW_PING=1
              W2_GW_RTT=$(echo "$PING_OUT" | tail -n 1 | awk '{print $4}' | cut -d'/' -f2)
            fi
          fi
        fi
        
        W2_INT_PING=0
        W2_INT_LOSS=100
        W2_INT_RTT="N/A"
        if [ "$W2_GW_PING" -eq 1 ]; then
          PING_OUT=$(ping -I eth1 -c 3 -W 2 8.8.8.8 2>&1)
          if echo "$PING_OUT" | grep -q -E "packets received|received"; then
            REC=$(echo "$PING_OUT" | grep -E "packets transmitted|received" | awk -F', ' '{print $2}' | awk '{print $1}')
            W2_INT_LOSS=$(( 100 - (REC * 100 / 3) ))
            if [ "$REC" -gt 0 ]; then
              W2_INT_PING=1
              W2_INT_RTT=$(echo "$PING_OUT" | tail -n 1 | awk '{print $4}' | cut -d'/' -f2)
            fi
          fi
        fi
        
        # --- DNS & Proxy Checks ---
        DNS_OK=0
        DNS_MS="N/A"
        DNS_SERVER=$(nslookup google.com 2>/dev/null | grep "Server:" | awk '{print $2}')
        [ -n "$DNS_SERVER" ] || DNS_SERVER="System Default"
        
        START_TIME=$(date +%s%3N)
        NS_OUT=$(nslookup google.com 2>/dev/null)
        END_TIME=$(date +%s%3N)
        if echo "$NS_OUT" | grep -q "Address"; then
          DNS_OK=1
          DNS_MS=$(( END_TIME - START_TIME ))
        fi
        
        PROXY_OK=0
        PROXY_IP="N/A"
        if [ "$(/etc/init.d/zapret status 2>&1)" = "running" ] || [ "$(/etc/init.d/sing-box status 2>/dev/null || ubus call service list | grep -q sing-box)" = "running" ] || [ -f /var/run/sing-box.pid ]; then
          PROXY_TEST_IP=$(curl -s -x socks5h://127.0.0.1:4534 --connect-timeout 4 https://api.ipify.org)
          if [ -n "$PROXY_TEST_IP" ]; then
            PROXY_OK=1
            PROXY_IP="$PROXY_TEST_IP"
          fi
        fi
        
        # --- Build helper function for output styling ---
        format_wan_status() {
          local phys="$1" ip="$2" gw="$3" gw_ping="$4" gw_rtt="$5" int_ping="$6" int_rtt="$7" int_loss="$8"
          local out=""
          if [ "$phys" -eq 1 ]; then
            out="${out}├── 🔗 Линк WAN: ✅ ОК\n"
          else
            out="${out}├── 🔗 Линк WAN: ❌ Down\n"
          fi
          
          if [ -n "$ip" ]; then
            out="${out}├── 🌐 WAN IP: ✅ Получен (<code>$ip</code>)\n"
          else
            out="${out}├── 🌐 WAN IP: ❌ Не получен\n"
          fi
          
          if [ -n "$gw" ]; then
            if [ "$gw_ping" -eq 1 ]; then
              out="${out}├── 🚪 Шлюз ($gw): ✅ Доступен (<code>$gw_rtt мс</code>)\n"
            else
              out="${out}├── 🚪 Шлюз ($gw): ❌ Недоступен\n"
            fi
          else
            out="${out}├── 🚪 Шлюз: ❌ Маршрут отсутствует\n"
          fi
          
          if [ "$int_ping" -eq 1 ]; then
            out="${out}└── 🌍 Интернет (8.8.8.8): ✅ Доступен (<code>$int_rtt мс</code>, потери <code>$int_loss%</code>)"
          else
            out="${out}└── 🌍 Интернет (8.8.8.8): ❌ Недоступен"
          fi
          echo "$out"
        }
        
        WAN_TXT=$(format_wan_status "$W1_PHYS" "$W1_IP" "$W1_GW" "$W1_GW_PING" "$W1_GW_RTT" "$W1_INT_PING" "$W1_INT_RTT" "$W1_INT_LOSS")
        WANB_TXT=$(format_wan_status "$W2_PHYS" "$W2_IP" "$W2_GW" "$W2_GW_PING" "$W2_GW_RTT" "$W2_INT_PING" "$W2_INT_RTT" "$W2_INT_LOSS")
        
        # --- Build Recommendation & Verdicts ---
        REC=""
        if [ "$W1_PHYS" -eq 0 ] && [ "$W2_PHYS" -eq 0 ]; then
          REC="❌ <b>Авария:</b> Физические линки на обоих провайдерах отсутствуют! Проверьте кабели."
        elif [ "$W1_INT_PING" -eq 0 ] && [ "$W2_INT_PING" -eq 0 ]; then
          REC="❌ <b>Авария:</b> На обоих провайдерах нет доступа к интернету! Проверьте настройки или обратитесь в поддержку."
        else
          if [ "$W1_INT_PING" -eq 1 ] && [ "$W2_INT_PING" -eq 1 ]; then
            if [ "$PROXY_OK" -eq 1 ]; then
              REC="✅ <b>Диагностика успешна:</b> Все системы работают штатно. Оба WAN-канала активны, балансировка mwan3 работает, прокси-тунлель стабилен."
            else
              REC="⚠️ <b>Предупреждение:</b> Интернет доступен по обоим WAN, но VPN-туннель обхода блокировок не отвечает."
            fi
          else
            if [ "$W1_INT_PING" -eq 0 ]; then
              REC="⚠️ <b>Режим резерва:</b> Основной канал WAN (MGTS) недоступен. Трафик перенаправлен на WANB (Starlink)."
            else
              REC="⚠️ <b>Режим резерва:</b> Резервный канал WANB (Starlink) недоступен. Трафик идет через WAN (MGTS)."
            fi
            if [ "$PROXY_OK" -eq 0 ]; then
              REC="${REC}\n⚠️ Также не работает прокси-туннель обхода."
            fi
          fi
        fi
        
        if [ "$CPU_TEMP" != "N/A" ] && [ "$CPU_TEMP" -gt 75 ]; then
          REC="${REC}\n⚠️ <b>Предупреждение о температуре:</b> Процессор нагрелся до <b>${CPU_TEMP}°C</b>!"
        fi
        
        if [ "$LINK_FLAPS" -gt 5 ]; then
          REC="${REC}\n⚠️ <b>Обнаружен линк-флап:</b> Зафиксировано <b>$LINK_FLAPS</b> изменений линка WAN за сессию."
        fi
        
        DIAG_MSG="🔍 <b>Результаты диагностики сети (Rosenberg)</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🌡 <b>CPU Temp:</b> <code>${CPU_TEMP}°C</code> (линк-флап: <code>${LINK_FLAPS}</code>)\n\n🌐 <b>WAN 1: MGTS (eth0)</b>\n${WAN_TXT}\n\n🌐 <b>WAN 2: Starlink (eth1)</b>\n${WANB_TXT}\n\n⚙️ <b>Сервисы и Обход</b>\n├── 🖥 DNS (<code>$DNS_SERVER</code>): $([ "$DNS_OK" -eq 1 ] && echo "✅ Резолвит (<code>${DNS_MS} мс</code>)" || echo "❌ Сбой")\n└── 🛡 Прокси (SOCKS5): $([ "$PROXY_OK" -eq 1 ] && echo "✅ Работает (IP: <code>$PROXY_IP</code>)" || echo "❌ Ошибка")\n━━━━━━━━━━━━━━━━━━━━━━\n💡 <b>Вердикт:</b>\n$REC"
        
        send_msg "$DIAG_MSG" "$KEYBOARD"
        ;;
      "🔗 Ресурсы"|"/resources")
        send_msg "🔗 <b>Проверяю доступность веб-ресурсов...</b>"
        STATUS_TG=$(check_url "https://api.telegram.org")
        STATUS_YT=$(check_url "https://youtube.com")
        STATUS_X=$(check_url "https://x.com")
        STATUS_IG=$(check_url "https://instagram.com")
        STATUS_RZ=$(check_url "https://rezka.ag")
        
        send_msg "🔗 <b>Доступность ресурсов:</b>\n━━━━━━━━━━━━━━━━━━━━━━\n✈️ <b>Telegram API:</b> $STATUS_TG\n📺 <b>YouTube:</b> $STATUS_YT\n🐦 <b>Twitter/X:</b> $STATUS_X\n📸 <b>Instagram:</b> $STATUS_IG\n🎬 <b>HDRezka:</b> $STATUS_RZ\n━━━━━━━━━━━━━━━━━━━━━━" "$KEYBOARD"
        ;;
      "👤 Добавить ID")
        echo "AWAIT_ADD_USER_ID" > "/tmp/bot_state_${FROM_ID}"
        send_msg "👤 <b>Введите Telegram ID нового пользователя:</b>\n(Только цифры, например: <code>987654321</code>)"
        ;;
      "👥 Устройства"|"/clients")
        send_msg "👥 <b>Запрашиваю список активных устройств...</b>"
        LEASES_OUT=""
        if [ -f /var/dhcp.leases ]; then
          while read -r lease; do
            mac=$(echo "$lease" | awk '{print $2}')
            ip=$(echo "$lease" | awk '{print $3}')
            host=$(echo "$lease" | awk '{print $4}')
            [ "$host" = "*" ] && host="Unknown Device"
            LEASES_OUT="${LEASES_OUT}├── 📱 <b>$host</b>\n│   └── IP: <code>$ip</code> | MAC: <code>$mac</code>\n"
          done < /var/dhcp.leases
        fi
        if [ -n "$LEASES_OUT" ]; then
          LEASES_OUT=$(echo -e "$LEASES_OUT" | sed '$ s/├──/└──/; $ s/│  /   /')
        else
          LEASES_OUT="❌ Активных арендованных адресов (DHCP leases) не найдено."
        fi
        
        send_msg "👥 <b>Список устройств (DHCP Leases):</b>\n━━━━━━━━━━━━━━━━━━━━━━\n$LEASES_OUT\n━━━━━━━━━━━━━━━━━━━━━━" "$KEYBOARD"
        ;;
      "🎛 MWAN"|"/mwan")
        echo "AWAIT_MWAN_POLICY" > "/tmp/bot_state_${FROM_ID}"
        CUR_POL=$(uci get mwan3.default_rule_v4.use_policy 2>/dev/null || echo "N/A")
        send_msg "🎛 <b>Настройка политики Multi-WAN</b>\n━━━━━━━━━━━━━━━━━━━━━━\n⚙️ <b>Текущий режим:</b> <code>$CUR_POL</code>\n\nВыберите желаемую конфигурацию кнопками ниже:\n━━━━━━━━━━━━━━━━━━━━━━" "$MWAN_KEYBOARD"
        ;;
      "💾 Бэкап"|"/backup")
        send_msg "💾 <b>Создаю резервную копию конфигурации...</b>"
        BACKUP_FILE="/tmp/openwrt_backup_$(date '+%Y%m%d_%H%M%S').tar.gz"
        if sysupgrade --create-backup "$BACKUP_FILE" >/dev/null 2>&1; then
          send_doc "$BACKUP_FILE" "💾 Резервная копия конфигурации роутера (Rosenberg)"
          rm -f "$BACKUP_FILE"
        else
          send_msg "❌ Не удалось создать бэкап." "$KEYBOARD"
        fi
        ;;
      *)
        send_msg "🤖 Неизвестная команда. Используйте меню кнопок." "$KEYBOARD"
        ;;
    esac

    OFFSET=$((UPDATE_ID+1))
    echo "$OFFSET" > "$OFFSET_FILE"
  done
  sleep 5
done

