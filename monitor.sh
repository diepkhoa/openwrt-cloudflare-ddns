#!/bin/sh

MY_OWNER="$1"
MODE="$2" # Tham so moi: 'ubus' hoac 'ddos'

if [ -z "$MY_OWNER" ] || [ -z "$MODE" ]; then
    logger -t "diepkhoa-Monitor" "Loi: Cu phap: monitor.sh <owner> <ubus|ddos>"
    exit 1
fi

. /lib/functions.sh
CONFIG_FILE="cloudflare_ddns"

config_load "$CONFIG_FILE"
config_get ENABLED settings enabled "0"
if [ "$ENABLED" != "1" ]; then exit 0; fi

config_get WAN_IFACE "$MY_OWNER" wan_iface "wan"
config_get MAX_CONNECTIONS "$MY_OWNER" ddos_threshold "5000"

config_get SCRIPT_UPDATE settings SCRIPT_UPDATE ""
config_get SCRIPT_DELETE settings SCRIPT_DELETE ""

if [ -z "$SCRIPT_UPDATE" ] || [ -z "$SCRIPT_DELETE" ] || [ ! -f "$SCRIPT_UPDATE" ] || [ ! -f "$SCRIPT_DELETE" ]; then
    logger -t "diepkhoa-Monitor" "‚ùå LOI NGHIEM TRONG: Thieu duong dan hoac file SCRIPT khong ton tai!"
    exit 1
fi

DDOS_HIDE_LOCK="/tmp/cf-ddos-hide-${MY_OWNER}.lock"
STRIKE_TIME_FILE="/tmp/cf-ddos-strike-${MY_OWNER}.time"

config_get TELEGRAM_BOT_TOKEN settings TELEGRAM_BOT_TOKEN ""
config_get TELEGRAM_CHAT_ID settings TELEGRAM_CHAT_ID ""

send_telegram_message() {
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local msg=$(printf '%b' "$1")
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "parse_mode=Markdown" \
            --data-urlencode "text=${msg}" > /dev/null 2>&1 &
    fi
}

# ==================== LUONG 1: UBUS EVENT ====================
if [ "$MODE" = "ubus" ]; then
    logger -t "diepkhoa-Monitor" "Bat dau luong UBUS (Node: $MY_OWNER | Cong: $WAN_IFACE)"
    
    # Chay truc tiep o Foreground, khong dung ky hieu '&' nua
    ubus listen network.interface | awk -v wan_if="$WAN_IFACE" -v hide_lock="$DDOS_HIDE_LOCK" -v owner="$MY_OWNER" -v script_update="$SCRIPT_UPDATE" '
        /ifup|ifupdate/ && $0 ~ "\""wan_if"\"" {
            system("if [ ! -f " hide_lock " ]; then logger -t diepkhoa-Monitor \"Mang UP -> Goi Update.\"; \"" script_update "\" --force " owner " > /dev/null 2>&1 & fi")
            fflush()
        }
    '

# ==================== LUONG 2: QUET DDOS ====================
elif [ "$MODE" = "ddos" ]; then
    logger -t "diepkhoa-Monitor" "Bat dau luong DDOS (Node: $MY_OWNER | Nguong: $MAX_CONNECTIONS)"
    rm -f "$DDOS_HIDE_LOCK" "$STRIKE_TIME_FILE"
    
    while true; do
        CURRENT_CONNS=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
        
        if [ -n "$CURRENT_CONNS" ] && [ "$CURRENT_CONNS" -gt "$MAX_CONNECTIONS" ]; then
            logger -t "diepkhoa-Monitor" "Ì†ΩÌ∫® CANH BAO: Tran ket noi ($CURRENT_CONNS / $MAX_CONNECTIONS)"
            
            NOW=$(date +%s)
            LAST_STRIKE=0
            if [ -f "$STRIKE_TIME_FILE" ]; then LAST_STRIKE=$(cat "$STRIKE_TIME_FILE"); fi
            
            DIFF=$((NOW - LAST_STRIKE))

            if [ "$DIFF" -lt 300 ]; then
                logger -t "diepkhoa-Monitor" "Ì†ΩÌ¥• DDOS STRIKE 2: Hacker dang bam theo Domain! An nap."
                rm -f "$STRIKE_TIME_FILE" 
                touch "$DDOS_HIDE_LOCK"
                
                ifdown "$WAN_IFACE"
                sleep 5
                ifup "$WAN_IFACE"
                while ! ping -c 1 -W 2 "1.1.1.1" > /dev/null 2>&1; do sleep 2; done
                
                logger -t "diepkhoa-Monitor" "Mang da thong, bat dau CASCADE DELETE cho [$MY_OWNER]..."
                "$SCRIPT_DELETE" ALL "$MY_OWNER" > /dev/null 2>&1
                
                sleep 600
                rm -f "$DDOS_HIDE_LOCK"
                "$SCRIPT_UPDATE" --force "$MY_OWNER" > /dev/null 2>&1 &
            else
                logger -t "diepkhoa-Monitor" "‚ö†Ô∏è DDOS STRIKE 1: Reset IP de cat duoi."
                echo "$NOW" > "$STRIKE_TIME_FILE"
                
                send_telegram_message "‚ö†Ô∏è *High Connections ($MY_OWNER)*\nConns: \`$CURRENT_CONNS\`\nAction: Resetting PPPoE."
                
                ifdown "$WAN_IFACE"
                sleep 5
                ifup "$WAN_IFACE"
                sleep 30
            fi
        fi
        sleep 5
    done
fi