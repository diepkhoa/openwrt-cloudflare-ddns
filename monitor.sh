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
    
    cleanup() {
        # Tim va kill tat ca tien trinh con cua shell nay bang thuoc tinh PPID
        # (Dung ham thuan shell de thay the pkill cho cac firmware rut gon)
        for stat in /proc/[0-9]*/stat; do
            [ -f "$stat" ] || continue
            read -r line < "$stat"
            # Lay phan sau ky tu ") " de cat ten tien trinh co the chua khoang trang
            after_paren="${line#*) }"
            set -- $after_paren
            if [ "$2" = "$$" ]; then
                cpid="${stat#/proc/}"
                kill "${cpid%/stat}" 2>/dev/null
            fi
        done
        exit 0
    }
    trap cleanup TERM INT

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
    ' &

    # Cho tien trinh ngam hoan thanh (truong hop nay la vo han, cho den khi co tin hieu TERM tu procd)
    wait

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

## ==================== LUONG 3: HEALTHCHECK & CONSENSUS ====================
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

    wg_update_endpoint() {
        local target_node="$1"
        local new_ip="$2"
        
        local wg_pubkey wg_port
        config_get wg_pubkey "$target_node" wg_pubkey ""
        config_get wg_port "$target_node" wg_port ""
        
        if [ -z "$wg_pubkey" ] || [ -z "$wg_port" ] || [ -z "$new_ip" ]; then return 1; fi
        
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
        [ -f "$state_file" ] && current_state=$(cat "$state_file")
        
        local now=$(date +%s)
        local last_dns_check=0
        [ -f "$dns_time_file" ] && last_dns_check=$(cat "$dns_time_file")
        
        # ====================================================================
        # KỊCH BẢN 1: MẠNG ĐANG UP (PING TUNNEL THÀNH CÔNG)
        # ====================================================================
        if ping -c 1 -W 2 "$target_ip" > /dev/null 2>&1; then
            if [ "$current_state" != "ok" ]; then
                logger -t "diepkhoa-Monitor" "[$target_node] Mang WireGuard da phuc hoi. Danh dau OK."
                echo "ok" > "$state_file"
                
                if [ -n "$ssh_key" ]; then
                    (
                        local ssh_cmd="ssh"
                        ssh -V 2>&1 | grep -qi dropbear && ssh_cmd="ssh -y"
                        $ssh_cmd -i "$ssh_key" -o StrictHostKeyChecking=no -T 5 root@"$target_ip" "$SCRIPT_UPDATE --force $target_node" >/dev/null 2>&1
                    ) &
                fi
            fi
            
            # --- LOGIC UPGRADE LÊN IPV6 (CHỈ KHI ĐANG Ở IPV4) ---
            if [ -n "$wg_endpoint" ] && [ -n "$wg_pubkey" ]; then
                local current_ep=$(wg show all endpoints | awk -v pk="$wg_pubkey" '$2 == pk {print $3}')
                
                # Nếu đang ở IPv4 (không có dấu ngoặc vuông '[')
                if [ -n "$current_ep" ] && [ "$current_ep" != "(none)" ] && ! echo "$current_ep" | grep -q "\["; then
                    if [ $((now - last_dns_check)) -ge 60 ]; then
                        echo "$now" > "$dns_time_file"
                        local new_all_ips=$(resolve_endpoint_ips "$wg_endpoint")
                        local v6_ip=$(echo "$new_all_ips" | tr ' ' '\n' | grep ":" | head -n 1)
                        
                        if [ -n "$v6_ip" ]; then
                            #logger -t "diepkhoa-Monitor" "[$target_node] Phat hien IPv6 ($v6_ip). Dang Ping check truoc khi Upgrade..."
                            
                            # Ping thẳng vào IP Public IPv6 của đối tác
                            if ping -6 -c 1 -W 2 "$v6_ip" > /dev/null 2>&1 || ping6 -c 1 -W 2 "$v6_ip" > /dev/null 2>&1; then
                                logger -t "diepkhoa-Monitor" "[$target_node] Ping IPv6 THANH CONG! Tien hanh Upgrade Endpoint."
                                wg_update_endpoint "$target_node" "[$v6_ip]"
                                echo "$new_all_ips" > "$ep_ip_file"
                            fi
                        fi
                    fi
                fi
            fi
            return 0
        fi
        
        # ====================================================================
        # KỊCH BẢN 2: MẠNG ĐANG DOWN (PING TUNNEL THẤT BẠI)
        # ====================================================================
        
        # Kiem tra Internet ban than truoc khi phan xet
        if ! ping -c 1 -W 2 "8.8.8.8" > /dev/null 2>&1; then
            return 0
        fi
        
        if [ "$current_state" = "ok" ]; then
            logger -t "diepkhoa-Monitor" "[$target_node] Rot mang lan 1. Chuyen sang SUSPECT."
            echo "suspect" > "$state_file"
            return 0
        fi
        
        # Xử lý khi ở trạng thái SUSPECT, DOWN, RECOVERING
        if [ -n "$wg_endpoint" ]; then
            if [ $((now - last_dns_check)) -ge 60 ] || [ "$current_state" = "suspect" ]; then
                echo "$now" > "$dns_time_file"
                
                local new_all_ips=$(resolve_endpoint_ips "$wg_endpoint")
                local old_all_ips=""
                [ -f "$ep_ip_file" ] && old_all_ips=$(cat "$ep_ip_file")
                
                local v6_ip=$(echo "$new_all_ips" | tr ' ' '\n' | grep ":" | head -n 1)
                local v4_ip=$(echo "$new_all_ips" | tr ' ' '\n' | grep "\." | head -n 1)
                local current_ep=$(wg show all endpoints | awk -v pk="$wg_pubkey" '$2 == pk {print $3}')
                
                local next_ip=""
                if echo "$current_ep" | grep -q "\["; then
                    # Đang kẹt ở IPv6 -> Toggle về IPv4
                    [ -n "$v4_ip" ] && next_ip="$v4_ip"
                else
                    # Đang kẹt ở IPv4 -> Toggle lên IPv6
                    [ -n "$v6_ip" ] && next_ip="[$v6_ip]"
                fi
                
                local force_update=0
                if [ -n "$new_all_ips" ] && [ "$new_all_ips" != "$old_all_ips" ]; then
                    force_update=1
                    logger -t "diepkhoa-Monitor" "[$target_node] IP thay doi tren DNS. Cap nhat Endpoint."
                    [ -n "$v4_ip" ] && next_ip="$v4_ip" || next_ip="[$v6_ip]"
                elif [ -n "$next_ip" ] && [ -n "$current_ep" ] && [ "$current_ep" != "(none)" ]; then
                    force_update=1
                    #logger -t "diepkhoa-Monitor" "[$target_node] Van mat ket noi. Thu Switch/Toggle sang Endpoint: $next_ip"
                fi
                
                if [ "$force_update" -eq 1 ] && [ -n "$next_ip" ]; then
                    wg_update_endpoint "$target_node" "$next_ip"
                    echo "$new_all_ips" > "$ep_ip_file"
                    [ "$current_state" != "recovering" ] && echo "recovering" > "$state_file"
                else
                    if [ "$current_state" != "down" ]; then
                        logger -t "diepkhoa-Monitor" "[$target_node] Node that su DOWN (Khong con IP de thu)."
                        echo "down" > "$state_file"
                        "$SCRIPT_DELETE" "$target_node" "$MY_OWNER" > /dev/null 2>&1 &
                    fi
                fi
            fi
        fi
    }
    
    while true; do
        config_load "$CONFIG_FILE"
        config_foreach check_node node
        sleep 15
    done
fi