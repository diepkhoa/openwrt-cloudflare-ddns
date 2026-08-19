#!/bin/sh

MY_OWNER="$1"
MODE="$2" # Tham so: 'ubus', 'ddos', hoac 'healthcheck'

if [ -z "$MY_OWNER" ] || [ -z "$MODE" ]; then
    logger -t "diepkhoa-Monitor" "Loi: Cu phap: monitor.sh <owner> <ubus|ddos|healthcheck>"
    exit 1
fi

. /lib/functions.sh
CONFIG_FILE="cloudflare_ddns"

config_load "$CONFIG_FILE"
config_get ENABLED settings enabled "0"
if [ "$ENABLED" != "1" ]; then exit 0; fi

config_get WAN_IFACE_V4 "$MY_OWNER" wan_iface_v4 "wan"
config_get WAN_IFACE_V6 "$MY_OWNER" wan_iface_v6 ""
config_get MAX_CONNECTIONS "$MY_OWNER" ddos_threshold "5000"

config_get SCRIPT_UPDATE settings SCRIPT_UPDATE ""
config_get SCRIPT_DELETE settings SCRIPT_DELETE ""

if [ -z "$SCRIPT_UPDATE" ] || [ -z "$SCRIPT_DELETE" ] || [ ! -f "$SCRIPT_UPDATE" ] || [ ! -f "$SCRIPT_DELETE" ]; then
    logger -t "diepkhoa-Monitor" "Loi Nghiem Trong: Thieu duong dan hoac file SCRIPT khong ton tai!"
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
    logger -t "diepkhoa-Monitor" "Bat dau luong UBUS (Node: $MY_OWNER | IPv4: $WAN_IFACE_V4 | IPv6: ${WAN_IFACE_V6:-khong co})"
    
    ubus listen network.interface | awk -v wan_v4="$WAN_IFACE_V4" -v wan_v6="$WAN_IFACE_V6" -v hide_lock="$DDOS_HIDE_LOCK" -v owner="$MY_OWNER" -v script_update="$SCRIPT_UPDATE" '
        BEGIN {
            # Tao regex khop chinh xac tung interface ("wan" hoac "wan6")
            if_regex = "\"" wan_v4 "\""
            if (wan_v6 != "") if_regex = if_regex "|\"" wan_v6 "\""
        }
        /ifup|ifupdate/ && $0 ~ if_regex {
            system("if [ ! -f " hide_lock " ]; then logger -t diepkhoa-Monitor \"Mang UP (su kien " wan_v4 "/" wan_v6 ") -> Goi Update.\"; \"" script_update "\" --force " owner " > /dev/null 2>&1 & fi")
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
            logger -t "diepkhoa-Monitor" "CANH BAO: Tran ket noi ($CURRENT_CONNS / $MAX_CONNECTIONS)"
            
            NOW=$(date +%s)
            LAST_STRIKE=0
            if [ -f "$STRIKE_TIME_FILE" ]; then LAST_STRIKE=$(cat "$STRIKE_TIME_FILE"); fi
            
            DIFF=$((NOW - LAST_STRIKE))

            if [ "$DIFF" -lt 300 ]; then
                logger -t "diepkhoa-Monitor" "DDOS STRIKE 2: Hacker dang bam theo Domain! An nap."
                rm -f "$STRIKE_TIME_FILE" 
                touch "$DDOS_HIDE_LOCK"
                
                ifdown "$WAN_IFACE_V4"
                sleep 5
                ifup "$WAN_IFACE_V4"
                while ! ping -c 1 -W 2 "1.1.1.1" > /dev/null 2>&1; do sleep 2; done
                
                logger -t "diepkhoa-Monitor" "Mang da thong, bat dau CASCADE DELETE cho [$MY_OWNER]..."
                "$SCRIPT_DELETE" "$MY_OWNER" > /dev/null 2>&1
                
                sleep 600
                rm -f "$DDOS_HIDE_LOCK"
                "$SCRIPT_UPDATE" --force "$MY_OWNER" > /dev/null 2>&1 &
            else
                logger -t "diepkhoa-Monitor" "DDOS STRIKE 1: Reset IP de cat duoi."
                echo "$NOW" > "$STRIKE_TIME_FILE"
                
                send_telegram_message "*High Connections ($MY_OWNER)*\nConns: \`$CURRENT_CONNS\`\nAction: Resetting PPPoE."
                
                ifdown "$WAN_IFACE_V4"
                sleep 5
                ifup "$WAN_IFACE_V4"
                sleep 30
            fi
        fi
        sleep 5
    done

# ==================== LUONG 3: HEALTHCHECK & CONSENSUS (HTTP) ====================
elif [ "$MODE" = "healthcheck" ]; then
    logger -t "diepkhoa-Monitor" "Bat dau luong Healthcheck (Node: $MY_OWNER)"
    
    resolve_endpoint_ips() {
        local ep="$1"
        if echo "$ep" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$'; then
            echo "$ep"
            return 0
        fi
        nslookup "$ep" 2>/dev/null | awk '
            /^Name:/ {seen=1}
            /^Address/ && seen {
                for (i=2; i<=NF; i++) {
                    if (($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $i ~ /:/) && $i !~ /^[0-9]+:$/) {
                        print $i
                    }
                }
            }
        ' | sort | tr '\n' ' ' | awk '{$1=$1; print $0}'
    }

    # trich xuat IP ngon nhat (Uu tien IPv6) tu danh sach tren
    extract_best_ip() {
        local all_ips="$1"
        local v6=$(echo "$all_ips" | tr ' ' '\n' | grep ":" | head -n 1)
        local v4=$(echo "$all_ips" | tr ' ' '\n' | grep "\." | head -n 1)
        
        if [ -n "$v6" ]; then
            echo "[$v6]"
        elif [ -n "$v4" ]; then
            echo "$v4"
        fi
    }

    #Ham cap nhat endpoint WG bang IP cu the
    wg_update_endpoint() {
        local target_node="$1"
        local new_ip="$2"
        
        local wg_pubkey wg_port
        config_get wg_pubkey "$target_node" wg_pubkey ""
        config_get wg_port "$target_node" wg_port ""
        
        if [ -z "$wg_pubkey" ] || [ -z "$wg_port" ] || [ -z "$new_ip" ]; then
            return 1
        fi
        
        local iface=$(wg show all dump | awk -v pk="$wg_pubkey" '$2 == pk {print $1; exit}')
        
        if [ -n "$iface" ]; then
            logger -t "diepkhoa-Monitor" "[$target_node] wg set $iface peer ... endpoint $new_ip:$wg_port"
            wg set "$iface" peer "$wg_pubkey" endpoint "${new_ip}:${wg_port}"
        fi
    }

    check_node() {
        local target_node="$1"
        if [ "$target_node" = "$MY_OWNER" ]; then return 0; fi
        
        local target_ip wg_endpoint ssh_key wg_pubkey
        config_get target_ip "$target_node" ip ""
        config_get wg_endpoint "$target_node" wg_endpoint ""
        config_get ssh_key "$MY_OWNER" ssh_key ""
        config_get wg_pubkey "$target_node" wg_pubkey ""
        
        if [ -z "$target_ip" ]; then return 0; fi
        
        local state_file="/tmp/cf_hc_state_${target_node}"
        local ep_ip_file="/tmp/cf_hc_ep_ip_${target_node}"
        local dns_time_file="/tmp/cf_hc_dns_time_${target_node}"
        
        local current_state="ok"
        if [ -f "$state_file" ]; then current_state=$(cat "$state_file"); fi
        
        local now=$(date +%s)
        local last_dns_check=0
        if [ -f "$dns_time_file" ]; then last_dns_check=$(cat "$dns_time_file"); fi
        
        # 1. Ping WG IP
        if ping -c 1 -W 2 "$target_ip" > /dev/null 2>&1; then
            if [ "$current_state" != "ok" ]; then
                logger -t "diepkhoa-Monitor" "[$target_node] Mang WireGuard da phuc hoi. Danh dau ok."
                echo "ok" > "$state_file"
                
                if [ -n "$ssh_key" ]; then
                    logger -t "diepkhoa-Monitor" "[$target_node] Goi SSH de nhac nho Update DNS..."
                    (
                        local ssh_cmd="ssh"
                        ssh -V 2>&1 | grep -qi dropbear && ssh_cmd="ssh -y"
                        local ssh_out
                        ssh_out=$($ssh_cmd -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$target_ip" "$SCRIPT_UPDATE --force $target_node" < /dev/null 2>&1)
                        if [ $? -ne 0 ]; then
                            logger -t "diepkhoa-Monitor" "[$target_node] Loi SSH: $ssh_out"
                        fi
                    ) &
                fi
            fi
            
            # --- LOGIC NANG CAP IPV6 NONG (HOT-UPGRADE) ---
            if [ -n "$wg_endpoint" ] && [ -n "$wg_pubkey" ]; then
                local current_ep=$(wg show all endpoints | awk -v pk="$wg_pubkey" '$2 == pk {print $3}')
                
                if [ -n "$current_ep" ] && ! echo "$current_ep" | grep -q "\["; then
                    if [ $((now - last_dns_check)) -ge 60 ]; then
                        echo "$now" > "$dns_time_file"
                        local new_all_ips=$(resolve_endpoint_ips "$wg_endpoint")
                        local best_ip=$(extract_best_ip "$new_all_ips")
                        
                        if echo "$best_ip" | grep -q "\["; then
                            local raw_ipv6=$(echo "$best_ip" | sed 's/^\[//;s/\].*//')
                            if ping -c 1 -W 2 "$raw_ipv6" > /dev/null 2>&1 || ping6 -c 1 -W 2 "$raw_ipv6" > /dev/null 2>&1; then
                                logger -t "diepkhoa-Monitor" "[$target_node] Phat hien IPv6 moi ($best_ip) va ping thanh cong. Nang cap Endpoint tu IPv4 len IPv6!"
                                wg_update_endpoint "$target_node" "$best_ip"
                                echo "$new_all_ips" > "$ep_ip_file"
                            else
                                logger -t "diepkhoa-Monitor" "[$target_node] Phat hien IPv6 moi ($best_ip) nhung ping that bai. Khong nang cap!"
                            fi
                        fi
                    fi
                fi
            fi
            return 0
        fi
        
        # That bai ping WG IP
        # 2. Kiem tra Internet ban than
        if ! ping -c 1 -W 2 "8.8.8.8" > /dev/null 2>&1; then
            logger -t "diepkhoa-Monitor" "[$target_node] Ban than rot mang. Tu choi danh gia!"
            return 0
        fi
        
        # 3. Trang thai hien tai ok -> chuyen suspect
        if [ "$current_state" = "ok" ]; then
            logger -t "diepkhoa-Monitor" "[$target_node] Rot mang lan 1. Chuyen sang suspect."
            echo "suspect" > "$state_file"
            return 0
        fi
        
        # 4. Trang thai suspect
        if [ "$current_state" = "suspect" ]; then
            if [ -n "$wg_endpoint" ]; then
                local new_all_ips=$(resolve_endpoint_ips "$wg_endpoint")
                local old_all_ips=""
                if [ -f "$ep_ip_file" ]; then old_all_ips=$(cat "$ep_ip_file"); fi
                
                # SO SANH TOAN BO DANH SACH IP
                if [ -n "$new_all_ips" ] && [ "$new_all_ips" != "$old_all_ips" ]; then
                    logger -t "diepkhoa-Monitor" "[$target_node] IP Endpoint thay doi ($old_all_ips -> $new_all_ips). Re-resolve WG."
                    
                    # Trich xuat IP tot nhat de nap vao WG
                    local best_ip=$(extract_best_ip "$new_all_ips")
                    wg_update_endpoint "$target_node" "$best_ip"
                    
                    echo "$new_all_ips" > "$ep_ip_file"
                    echo "$now" > "$dns_time_file"
                    echo "recovering" > "$state_file"
                else
                    logger -t "diepkhoa-Monitor" "[$target_node] IP Endpoint khong doi. Node that su DOWN."
                    echo "down" > "$state_file"
                    if [ -n "$new_all_ips" ]; then echo "$new_all_ips" > "$ep_ip_file"; fi
                    "$SCRIPT_DELETE" "$target_node" "$MY_OWNER" > /dev/null 2>&1 &
                fi
            else
                logger -t "diepkhoa-Monitor" "[$target_node] Khong co endpoint. Node that su DOWN."
                echo "down" > "$state_file"
                "$SCRIPT_DELETE" "$target_node" "$MY_OWNER" > /dev/null 2>&1 &
            fi
            return 0
        fi
        
        # 5/6. Trang thai down / recovering
        if [ "$current_state" = "down" ] || [ "$current_state" = "recovering" ]; then
            if [ -n "$wg_endpoint" ]; then
                if [ $((now - last_dns_check)) -ge 60 ]; then
                    echo "$now" > "$dns_time_file"
                    
                    local new_all_ips=$(resolve_endpoint_ips "$wg_endpoint")
                    local old_all_ips=""
                    if [ -f "$ep_ip_file" ]; then old_all_ips=$(cat "$ep_ip_file"); fi
                    
                    # So sanh toan bo danh sach IP
                    if [ -n "$new_all_ips" ] && [ "$new_all_ips" != "$old_all_ips" ]; then
                        logger -t "diepkhoa-Monitor" "[$target_node] IP Endpoint thay doi khi dang chờ ($old_all_ips -> $new_all_ips). Re-resolve WG."
                        
                        # Trich xuat IP tot nhat (Uu tien IPv6) de nap vao WG
                        local best_ip=$(extract_best_ip "$new_all_ips")
                        wg_update_endpoint "$target_node" "$best_ip"
                        
                        # Luu lai danh sach IP moi
                        echo "$new_all_ips" > "$ep_ip_file"
                        if [ "$current_state" = "down" ]; then echo "recovering" > "$state_file"; fi
                    fi
                fi
            fi
            return 0
        fi
    }
    
    while true; do
        config_load "$CONFIG_FILE"
        config_foreach check_node node
        sleep 15
    done
fi