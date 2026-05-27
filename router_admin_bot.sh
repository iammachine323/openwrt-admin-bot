#!/bin/sh
# router_admin_bot.sh – Secure Telegram admin bot for OpenWrt router
# ---------------------------------------------------------------
TOKEN='YOUR_TELEGRAM_BOT_TOKEN'
# Whitelisted Telegram user/chat IDs (space‑separated)
ALLOWED_IDS='YOUR_TELEGRAM_CHAT_ID'
# Use the first allowed ID as the target chat for sending messages
CHAT_ID=$ALLOWED_IDS
# File that stores the last processed update offset
OFFSET_FILE='/tmp/telegram_offset'

# Ensure offset file exists
[ -f "$OFFSET_FILE" ] || echo 0 > "$OFFSET_FILE"

# Helper: send a message (optionally with a custom keyboard)
#   $1 – text
#   $2 – JSON string for reply_markup (optional)
send_msg(){
  # Replace literal \n text sequences with actual newlines
  local text=$(echo -e "$1")
  local markup="$2"
  if [ -n "$markup" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      -d chat_id="$CHAT_ID" \
      -d parse_mode="HTML" \
      --data-urlencode "text=${text}" \
      -d reply_markup="${markup}" >/dev/null
  else
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      -d chat_id="$CHAT_ID" \
      -d parse_mode="HTML" \
      --data-urlencode "text=${text}" >/dev/null
  fi
}

# Helper: send a document (log file)
send_doc(){
  local file="$1"
  local caption="$2"
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendDocument" \
    -F chat_id="$CHAT_ID" -F document="@$file" -F caption="$caption" >/dev/null
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

# Pre‑defined keyboard with 3 rows of diagnostic buttons
KEYBOARD='{"keyboard":[[{"text":"📊 Статус"},{"text":"⚡ Пинг"},{"text":"📈 Нагрузка"}],[{"text":"📋 Логи"},{"text":"🔎 DNS Тест"},{"text":"🛣 Трассировка"}],[{"text":"🛡 Обход"},{"text":"🔗 Ресурсы"},{"text":"🔍 Диагностика"}],[{"text":"♻️ Перезагрузка"}]],"one_time_keyboard":false,"resize_keyboard":true}'

while true; do
  OFFSET=$(cat "$OFFSET_FILE")
  RESPONSE=$(curl -s --connect-timeout 10 "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=${OFFSET}&timeout=20")
  
  if ! echo "$RESPONSE" | jq -e '.ok' >/dev/null 2>&1; then
    sleep 5
    continue
  fi

  echo "$RESPONSE" | jq -c '.result[]' | while read -r update; do
    FROM_ID=$(echo "$update" | jq -r '.message.from.id')
    TEXT=$(echo "$update" | jq -r '.message.text')
    UPDATE_ID=$(echo "$update" | jq '.update_id')

    # Verify sender is whitelisted
    authorized=false
    for id in $ALLOWED_IDS; do
      if [ "$FROM_ID" = "$id" ]; then
        authorized=true
        break
      fi
    done
    if ! $authorized; then
      send_msg "❌ Unauthorized user (ID: $FROM_ID)" "$KEYBOARD"
      OFFSET=$((UPDATE_ID+1))
      echo "$OFFSET" > "$OFFSET_FILE"
      continue
    fi

    # Interactive state machine check
    STATE_FILE="/tmp/bot_state_${FROM_ID}"
    if [ -f "$STATE_FILE" ]; then
      STATE=$(cat "$STATE_FILE")
      case "$TEXT" in
        "📊 Статус"|"⚡ Пинг"|"📈 Нагрузка"|"📋 Логи"|"🔎 DNS Тест"|"🛣 Трассировка"|"🛡 Обход"|"🔗 Ресурсы"|"🔍 Диагностика"|"♻️ Перезагрузка"|/start|/reboot|/logs|/status|/ping|/traffic|/dns|/trace|/bypass|/resources|/diagnose)
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
        
        WAN_IP=$(ubus call network.interface.wan status | jq -r '.["ipv4-address"][0].address' 2>/dev/null)
        [ -n "$WAN_IP" ] || WAN_IP="N/A"
        
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
              PROXY_CONN="❌ Ошибка подключения к прокси"
            fi
          else
            PODKOP_STATUS="⚠️ Включен (Sing-box: остановлен)"
            PROXY_CONN="❌ Sing-box не запущен"
          fi
        else
          PODKOP_STATUS="❌ Отключен"
          PROXY_CONN="❌ Отключен"
        fi
        
        STATUS_MSG="📊 <b>Статус роутера (Rosenberg)</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🏷 <b>Модель:</b> $MODEL\n💿 <b>Система:</b> $OS_VER\n⏱ <b>Uptime:</b> $UPTIME\n📈 <b>CPU Load:</b> $LOAD_AVG\n🧠 <b>ОЗУ:</b> ${MEM_USED} MB / ${MEM_TOTAL} MB (${MEM_PCT}%)\n💾 <b>Flash (/):</b> ${DISK_USED} / ${DISK_SIZE} (${DISK_PCT})\n👥 <b>Сессии NAT:</b> <code>$CONN_COUNT / $CONN_MAX</code>\n🌐 <b>WAN IP:</b> $WAN_IP\n🌍 <b>Внешний IP:</b> $EXT_IP\n━━━━━━━━━━━━━━━━━━━━━━\n🥷 <b>Zapret:</b> $ZAPRET_STATUS\n🕵️ <b>Podkop:</b> $PODKOP_STATUS\n📡 <b>Сервер:</b> <code>$PODKOP_SERVER</code> ($PODKOP_IP)\n🔌 <b>Соединение прокси:</b> $PROXY_CONN\n━━━━━━━━━━━━━━━━━━━━━━"
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
          send_msg "✅ <b>Интернет доступен!</b>\nПакеты: 3/3 успешно получены\nЗадержка: <b>$AVG мс</b> (мин: $MIN / макс: $MAX)" "$KEYBOARD"
        else
          PING_ESCAPED=$(echo "$PING_OUT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
          send_msg "⚠️ <b>Проблема со связью!</b>\nПинг 8.8.8.8 не прошел:\n<pre>$PING_ESCAPED</pre>" "$KEYBOARD"
        fi
        ;;
      "📈 Нагрузка"|"/traffic")
        send_msg "📈 <b>Замеряю скорость на WAN интерфейсе (2 сек)...</b>"
        WAN_IFACE=$(ubus call network.interface.wan status | jq -r '.l3_device' 2>/dev/null)
        [ -n "$WAN_IFACE" ] || WAN_IFACE="eth0"
        
        RX_1=$(cat /sys/class/net/$WAN_IFACE/statistics/rx_bytes)
        TX_1=$(cat /sys/class/net/$WAN_IFACE/statistics/tx_bytes)
        sleep 2
        RX_2=$(cat /sys/class/net/$WAN_IFACE/statistics/rx_bytes)
        TX_2=$(cat /sys/class/net/$WAN_IFACE/statistics/tx_bytes)
        
        RX_SPEED_BPS=$(( (RX_2 - RX_1) * 8 / 2 ))
        TX_SPEED_BPS=$(( (TX_2 - TX_1) * 8 / 2 ))
        
        if [ "$RX_SPEED_BPS" -ge 1048576 ]; then
          RX_SPEED="$(( RX_SPEED_BPS / 1048576 )).$(( (RX_SPEED_BPS % 1048576) * 100 / 1048576 )) Mbps"
        else
          RX_SPEED="$(( RX_SPEED_BPS / 1024 )) Kbps"
        fi
        
        if [ "$TX_SPEED_BPS" -ge 1048576 ]; then
          TX_SPEED="$(( TX_SPEED_BPS / 1048576 )).$(( (TX_SPEED_BPS % 1048576) * 100 / 1048576 )) Mbps"
        else
          TX_SPEED="$(( TX_SPEED_BPS / 1024 )) Kbps"
        fi
        
        send_msg "📈 <b>Нагрузка WAN ($WAN_IFACE):</b>\n📥 <b>Входящий:</b> $RX_SPEED\n📤 <b>Исходящий:</b> $TX_SPEED" "$KEYBOARD"
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
        LINK_FLAPS=$(logread | grep -E "eth0|link down|link up" | grep -E -c "link down|link up|down|up")
        [ -n "$LINK_FLAPS" ] || LINK_FLAPS=0
        
        # 3. Physical Link Check (eth0 carrier)
        CARRIER_STATE=$(cat /sys/class/net/eth0/carrier 2>/dev/null)
        if [ "$CARRIER_STATE" = "1" ]; then
          PHYS_LINK="✅ Физический линк: ОК (eth0 up)"
          LINK_UP=1
        else
          PHYS_LINK="❌ Физический линк: Отсутствует (eth0 down)"
          LINK_UP=0
        fi
        
        # 4. DHCP WAN IP check
        WAN_STATUS=$(ubus call network.interface.wan status 2>/dev/null)
        WAN_IP=$(echo "$WAN_STATUS" | jq -r '.["ipv4-address"][0].address' 2>/dev/null)
        if [ -n "$WAN_IP" ] && [ "$WAN_IP" != "null" ]; then
          WAN_IP_STATE="✅ WAN IP получен: <code>$WAN_IP</code>"
          HAS_WAN_IP=1
        else
          WAN_IP_STATE="❌ WAN IP: Не получен"
          HAS_WAN_IP=0
        fi
        
        # 5. Local Gateway Ping Check
        GATEWAY=$(echo "$WAN_STATUS" | jq -r '.["route"][0].nexthop' 2>/dev/null)
        [ -n "$GATEWAY" ] && [ "$GATEWAY" != "null" ] || GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n 1)
        [ -n "$GATEWAY" ] || GATEWAY="192.168.1.254"
        
        GW_PING_OK=0
        GW_LOSS=100
        GW_RTT="N/A"
        if [ "$LINK_UP" -eq 1 ]; then
          GW_PING_OUT=$(ping -c 5 -W 2 "$GATEWAY" 2>&1)
          if echo "$GW_PING_OUT" | grep -q -E "packets received|received"; then
            GW_REC=$(echo "$GW_PING_OUT" | grep -E "packets transmitted|received" | awk -F', ' '{print $2}' | awk '{print $1}')
            GW_LOSS=$(( 100 - (GW_REC * 20) ))
            if [ "$GW_REC" -gt 0 ]; then
              GW_PING_OK=1
              GW_RTT=$(echo "$GW_PING_OUT" | tail -n 1 | awk '{print $4}' | cut -d'/' -f2)
            fi
          fi
        fi
        
        # 6. Internet Routing Ping Check (8.8.8.8)
        INT_PING_OK=0
        INT_LOSS=100
        INT_RTT="N/A"
        if [ "$GW_PING_OK" -eq 1 ]; then
          INT_PING_OUT=$(ping -c 5 -W 2 8.8.8.8 2>&1)
          if echo "$INT_PING_OUT" | grep -q -E "packets received|received"; then
            INT_REC=$(echo "$INT_PING_OUT" | grep -E "packets transmitted|received" | awk -F', ' '{print $2}' | awk '{print $1}')
            INT_LOSS=$(( 100 - (INT_REC * 20) ))
            if [ "$INT_REC" -gt 0 ]; then
              INT_PING_OK=1
              INT_RTT=$(echo "$INT_PING_OUT" | tail -n 1 | awk '{print $4}' | cut -d'/' -f2)
            fi
          fi
        fi
        
        # 7. DNS Check
        DNS_OK=0
        DNS_MS="N/A"
        DNS_SERVER=$(nslookup google.com 2>/dev/null | grep "Server:" | awk '{print $2}')
        [ -n "$DNS_SERVER" ] || DNS_SERVER="System Default"
        
        if [ "$INT_PING_OK" -eq 1 ]; then
          START_TIME=$(date +%s%3N)
          NS_OUT=$(nslookup google.com 2>/dev/null)
          END_TIME=$(date +%s%3N)
          if echo "$NS_OUT" | grep -q "Address"; then
            DNS_OK=1
            DNS_MS=$(( END_TIME - START_TIME ))
          fi
        fi
        
        # 8. Proxy / VPN Check (SOCKS connection)
        PROXY_OK=0
        PROXY_IP="N/A"
        if [ "$(/etc/init.d/zapret status 2>&1)" = "running" ] || [ "$(/etc/init.d/sing-box status 2>/dev/null || ubus call service list | grep -q sing-box)" = "running" ] || [ -f /var/run/sing-box.pid ]; then
          PROXY_TEST_IP=$(curl -s -x socks5h://127.0.0.1:4534 --connect-timeout 4 https://api.ipify.org)
          if [ -n "$PROXY_TEST_IP" ]; then
            PROXY_OK=1
            PROXY_IP="$PROXY_TEST_IP"
          fi
        fi
        
        # 9. Build Recommendation
        REC=""
        if [ "$LINK_UP" -eq 0 ]; then
          REC="❌ <b>Критическая ошибка:</b> Физический кабель провайдера не подключен или поврежден. Проверьте WAN-порт роутера."
        elif [ "$HAS_WAN_IP" -eq 0 ]; then
          REC="❌ <b>Ошибка:</b> Физическое соединение с провайдером есть, но IP-адрес не получен. Возможно, порт заблокирован за неуплату или проводятся тех. работы."
        elif [ "$GW_PING_OK" -eq 0 ]; then
          REC="❌ <b>Ошибка:</b> Локальный шлюз провайдера (<code>$GATEWAY</code>) не отвечает на пинги. Проблема на оборудовании провайдера в подъезде/доме."
        elif [ "$INT_PING_OK" -eq 0 ]; then
          REC="❌ <b>Ошибка:</b> Локальная сеть работает, но нет выхода в глобальный интернет. Возможна авария на стороне провайдера."
        elif [ "$INT_LOSS" -gt 20 ]; then
          REC="⚠️ <b>Предупреждение:</b> Интернет работает нестабильно, обнаружено <b>$INT_LOSS% потерь пакетов</b>. Возможен плохой контакт кабеля."
        elif [ "$DNS_OK" -eq 0 ]; then
          REC="❌ <b>Ошибка DNS:</b> Интернет доступен по IP, но имена не резолвятся. Проверьте DNS-серверы (текущий: <code>$DNS_SERVER</code>)."
        elif [ "$PROXY_OK" -eq 0 ]; then
          REC="⚠️ <b>Предупреждение:</b> Обычный интернет доступен, но заблокированные ресурсы не откроются. VPN-туннель (Sing-box) не активен."
        else
          REC="✅ <b>Диагностика успешна:</b> Все системы работают штатно. Соединение стабильное, DNS работает, прокси-туннель активен."
        fi
        
        if [ "$CPU_TEMP" != "N/A" ] && [ "$CPU_TEMP" -gt 75 ]; then
          REC="${REC}\n⚠️ <b>Предупреждение о перегреве:</b> Процессор роутера нагрелся до <b>${CPU_TEMP}°C</b>! Обеспечьте вентиляцию."
        fi
        
        if [ "$LINK_FLAPS" -gt 0 ]; then
          REC="${REC}\n⚠️ <b>Предупреждение о линке:</b> Зафиксировано <b>$LINK_FLAPS</b> изменений статуса линка WAN. Возможны проблемы с кабелем."
        fi
        
        DIAG_MSG="🔍 <b>Результаты полной диагностики сети:</b>\n━━━━━━━━━━━━━━━━━━━━━━\n🌡 <b>CPU Temp:</b> <code>${CPU_TEMP}°C</code> (Линк-флап: ${LINK_FLAPS})\n🔗 <b>Линк WAN:</b> $([ "$LINK_UP" -eq 1 ] && echo "✅ ОК" || echo "❌ Down")\n🌐 <b>WAN IP:</b> $([ "$HAS_WAN_IP" -eq 1 ] && echo "✅ Получен ($WAN_IP)" || echo "❌ Нет")\n🚪 <b>Шлюз ($GATEWAY):</b> $([ "$GW_PING_OK" -eq 1 ] && echo "✅ Доступен (RTT: ${GW_RTT} мс, потери: ${GW_LOSS}%)" || echo "❌ Недоступен")\n🌍 <b>Интернет (8.8.8.8):</b> $([ "$INT_PING_OK" -eq 1 ] && echo "✅ Доступен (RTT: ${INT_RTT} мс, потери: ${INT_LOSS}%)" || echo "❌ Недоступен")\n🖥 <b>DNS ($DNS_SERVER):</b> $([ "$DNS_OK" -eq 1 ] && echo "✅ Резолвит (${DNS_MS} мс)" || echo "❌ Сбой")\n🛡 <b>Прокси-соединение:</b> $([ "$PROXY_OK" -eq 1 ] && echo "✅ Работает (IP: $PROXY_IP)" || echo "❌ Ошибка")\n━━━━━━━━━━━━━━━━━━━━━━\n💡 <b>Вердикт:</b>\n$REC"
        
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
      *)
        send_msg "🤖 Неизвестная команда. Используйте меню кнопок." "$KEYBOARD"
        ;;
    esac

    OFFSET=$((UPDATE_ID+1))
    echo "$OFFSET" > "$OFFSET_FILE"
  done
  sleep 5
done
