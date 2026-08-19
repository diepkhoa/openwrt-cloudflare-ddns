#!/bin/sh

. /lib/functions.sh

CONFIG_FILE="cloudflare_ddns"
CF_API="https://api.cloudflare.com/client/v4"
LOCK_FILE="/var/lock/cf_update.lock"
COOLDOWN_FILE="/tmp/cf_update_cooldown"

# Phan tich tham so truyen vao
FORCE_MODE=0
RECOVER_MODE=0
MY_OWNER=""
TARGET_SUBDOMAIN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE_MODE=1
            shift
            ;;
        --recover)
            RECOVER_MODE=1
            shift
            ;;
        *)
            if [ -z "$MY_OWNER" ]; then
                MY_OWNER="$1"
            elif [ -z "$TARGET_SUBDOMAIN" ]; then
                TARGET_SUBDOMAIN="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$MY_OWNER" ]; then
    logger -t "diepkhoa-action" "Loi: Thieu tham so OWNER. Cu phap: action_update.sh [--force|--recover] <owner> [subdomain]"
    exit 1
fi

send_telegram_message() {
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local msg=$(printf '%b' "$1")
        # Bo chay ngam va ghi log de debug
        local response=$(curl -s --connect-timeout 10 --max-time 30 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "parse_mode=Markdown" \
            --data-urlencode "text=${msg}")
        
        logger -t "diepkhoa-Telegram" "Phan hoi tu Telegram: $response"
    else
        logger -t "diepkhoa-Telegram" "LOI: Thieu Token hoac Chat ID trong config!"
    fi
}
# ==================== KHOA LUONG & DEBOUNCE ====================
NOW=$(date +%s)
if [ "$FORCE_MODE" -eq 0 ] && [ "$RECOVER_MODE" -eq 0 ]; then
    if [ -f "$COOLDOWN_FILE" ]; then
        LAST_RUN=$(cat "$COOLDOWN_FILE")
        if [ $((NOW - LAST_RUN)) -lt 10 ]; then exit 0; fi
    fi
    echo "$NOW" > "$COOLDOWN_FILE"
fi

exec 9>"$LOCK_FILE"
flock -n 9 || exit 1

logger -t "diepkhoa-action" "BAT DAU UPDATE DDNS CHO OWNER: [$MY_OWNER] (Force=$FORCE_MODE, Recover=$RECOVER_MODE, Subdomain=$TARGET_SUBDOMAIN)"



# ==================== LAY BIEN TOAN CUC ====================
config_load "$CONFIG_FILE"
config_get TELEGRAM_BOT_TOKEN settings TELEGRAM_BOT_TOKEN ""
config_get TELEGRAM_CHAT_ID settings TELEGRAM_CHAT_ID ""

# ==================== HAM LAY IP THONG MINH ====================
config_get WAN_IFACE_V4 "$MY_OWNER" wan_iface_v4 "wan"
config_get WAN_IFACE_V6 "$MY_OWNER" wan_iface_v6 ""

# Ham lay IPv4 (Chi tra ve IP hoac rong)
get_ipv4() {
    # Buoc 1: Doc truc tiep tu UBUS cong WAN IPv4
    local ip=$(ubus call network.interface.$WAN_IFACE_V4 status 2>/dev/null | jq -r '.["ipv4-address"][0].address // empty')

    # Buoc 2: Fallback - lay L3 device tu UBUS roi doc IP tu kernel
    if [ -z "$ip" ]; then
        local l3_dev=$(ubus call network.interface.$WAN_IFACE_V4 status 2>/dev/null | jq -r '.l3_device // empty')
        [ -n "$l3_dev" ] && [ "$l3_dev" != "null" ] && \
            ip=$(ip -4 addr show dev "$l3_dev" 2>/dev/null | grep -w "inet" | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    fi

    # Buoc 3: Fallback cuoi - lay interface co default IPv4 route (bo qua VPN/WireGuard)
    if [ -z "$ip" ]; then
        local gw_dev=$(ip -4 route show default 2>/dev/null | grep -v -E 'wg[0-9]|warp|tun' | awk '{print $5}' | head -n 1)
        [ -n "$gw_dev" ] && \
            ip=$(ip -4 addr show dev "$gw_dev" 2>/dev/null | grep -w "inet" | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    fi

    echo "$ip"
}

# Ham lay IPv6 (Chi tra ve IP hoac rong)
get_ipv6() {
    local mac="$1"
    local ip=""

    if [ -n "$mac" ]; then
        # =========================================================================
        # 1. QUÉT IPV6 CỦA THIẾT BỊ LAN THEO MAC
        # =========================================================================
        ip=$(ip -6 neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | grep -E "^[23]" | head -n 1)
        if [ -z "$ip" ]; then
            ping -c 1 -W 1 ff02::1%br-lan >/dev/null 2>&1
            ip=$(ip -6 neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | grep -E "^[23]" | head -n 1)
        fi
    else
        # =========================================================================
        # 2. LẤY IPV6 PUBLIC CỦA CHÍNH CỔNG WAN ROUTER
        # =========================================================================

        # BƯỚC 1: Xác định chính xác tên card mạng L3 của cổng WAN IPv6 (tránh xa wg*, warp*)
        local wan_dev=""
        for iface in "$WAN_IFACE_V6" "$WAN_IFACE_V4" "wan6" "wan"; do
            [ -z "$iface" ] && continue
            wan_dev=$(ubus call network.interface."$iface" status 2>/dev/null | jq -r '.l3_device // .device // empty' 2>/dev/null)
            [ -n "$wan_dev" ] && [ "$wan_dev" != "null" ] && break
        done

        # Fallback nếu ubus chưa load: Lấy device có Default Gateway IPv4 (bỏ qua VPN)
        if [ -z "$wan_dev" ] || [ "$wan_dev" = "null" ]; then
            wan_dev=$(ip -4 route show default 2>/dev/null | grep -v -E "wg|warp|tun|br-" | awk '{print $5}' | head -n 1)
        fi

        # BƯỚC 2: Đọc trực tiếp từ Kernel trên card mạng WAN đó (Lấy IP Public SLAAC/GUA chuẩn nhất)
        if [ -n "$wan_dev" ]; then
            ip=$(ip -6 addr show dev "$wan_dev" scope global 2>/dev/null | grep -E "inet6 [23]" | grep -v "deprecated" | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
        fi

        # BƯỚC 3: Nếu vẫn chưa có, thử đọc từ UBUS của WAN IPv6
        if [ -z "$ip" ]; then
            for iface in "$WAN_IFACE_V6" "$WAN_IFACE_V4" "wan6" "wan"; do
                [ -z "$iface" ] && continue
                ip=$(ubus call network.interface."$iface" status 2>/dev/null | jq -r '.["ipv6-address"][]?.address // empty' 2>/dev/null | grep -E "^[23]" | head -n 1)
                [ -n "$ip" ] && break
            done
        fi

        # BƯỚC 4: Fallback cuối cùng nếu đi qua NAT: Gọi ra ngoài nhưng BIND CHẶT qua card WAN
        if [ -z "$ip" ] && [ -n "$wan_dev" ]; then
            ip=$(curl -6 -s --interface "$wan_dev" --max-time 3 https://api64.ipify.org 2>/dev/null | grep -E "^[23]")
        fi
    fi

    echo "$ip"
}

# ==================== LAY IP SONG SONG (PARALLEL - toi da 30s) ====================
_V4_TMP=$(mktemp)
_V6_TMP=$(mktemp)

# --- Luong IPv4: chay nen ---
(
    logger -t "diepkhoa-action" "Dang kiem tra IPv4..."
    _retry=0
    while [ $_retry -lt 6 ]; do
        _ip=$(get_ipv4)
        if [ -n "$_ip" ]; then echo -n "$_ip" > "$_V4_TMP"; break; fi
        sleep 5
        _retry=$((_retry + 1))
    done
) &
_PID_V4=$!

# --- Luong IPv6: chay nen (neu IPV6 duoc bat trong config) ---
_PID_V6=""
if grep -qE "option IPV6 '1'|option IPV6 'true'" /etc/config/$CONFIG_FILE 2>/dev/null; then
    (
        logger -t "diepkhoa-action" "Dang kiem tra IPv6..."
        _retry=0
        while [ $_retry -lt 6 ]; do
            _ip=$(get_ipv6 "")
            if [ -n "$_ip" ]; then echo -n "$_ip" > "$_V6_TMP"; break; fi
            sleep 5
            _retry=$((_retry + 1))
        done
    ) &
    _PID_V6=$!
fi

# --- Cho ca 2 luong hoan thanh ---
wait $_PID_V4
[ -n "$_PID_V6" ] && wait $_PID_V6

GLOBAL_V4_IP=$(cat "$_V4_TMP" 2>/dev/null)
GLOBAL_V6_IP=$(cat "$_V6_TMP" 2>/dev/null)
rm -f "$_V4_TMP" "$_V6_TMP"

[ -n "$GLOBAL_V4_IP" ] && logger -t "diepkhoa-action" "Da lay duoc IPv4: $GLOBAL_V4_IP" \
    || logger -t "diepkhoa-action" "Khong co IPv4."
if [ -n "$_PID_V6" ]; then
    [ -n "$GLOBAL_V6_IP" ] && logger -t "diepkhoa-action" "Da lay duoc IPv6: $GLOBAL_V6_IP" \
        || logger -t "diepkhoa-action" "Khong co IPv6."
fi

# Neu ca 2 IP deu rong -> Mang thuc su chua co -> Thoat de nha khoa Flock
if [ -z "$GLOBAL_V4_IP" ] && [ -z "$GLOBAL_V6_IP" ]; then
    logger -t "diepkhoa-action" "Khong lay duoc bat ky IP nao. Thoat script."
    exit 0
fi

# ==================== KIEM TRA INTERNET (CO GIOI HAN TIMEOUT) ====================
logger -t "diepkhoa-action" "IP da san sang. Dang kiem tra ket noi Internet..."
INTERNET_OK=0
# Chi thu ping toi da 4 lan (~20 giay)
for i in 1 2 3 4; do
    if ping -c 1 -W 2 "1.1.1.1" > /dev/null 2>&1; then
        INTERNET_OK=1
        break
    fi
    sleep 5
done

if [ "$INTERNET_OK" -eq 0 ]; then
    logger -t "diepkhoa-action" "Internet chua thong. Thoat script de cho su kien tiep theo."
    exit 0
fi
logger -t "diepkhoa-action" "Internet da thong! Tien hanh update DDNS."

# ==================== XU LY TUNG BAN GHI CUA OWNER ====================
# Luu danh sach cascade de xu ly sau cung
CASCADE_LIST=$(mktemp)
UPDATE_SUCCESS_COUNT=0
UPDATE_FAIL_COUNT=0

update_domain_record() {
    local section="$1"
    local OWNER DOMAIN_REF SUBDOMAIN PROXIED IPV4 IPV6 TARGET_MAC RECORD_ID_V4 RECORD_ID_V6 CASCADE_ON_DOWN
    
    config_get OWNER "$section" OWNER ""
    
    # Chi update nhung gi thuoc ve minh
    if [ "$OWNER" != "$MY_OWNER" ]; then return 0; fi
    
    config_get SUBDOMAIN "$section" SUBDOMAIN ""
    
    # Neu la che do recover va co chi dinh subdomain, bo qua cac subdomain khac
    if [ "$RECOVER_MODE" -eq 1 ] && [ -n "$TARGET_SUBDOMAIN" ] && [ "$SUBDOMAIN" != "$TARGET_SUBDOMAIN" ]; then
        return 0
    fi
    
    config_get DOMAIN_REF "$section" DOMAIN ""
    local API_KEY ZONE_ID
    config_get API_KEY "$DOMAIN_REF" API_KEY ""
    config_get ZONE_ID "$DOMAIN_REF" ZONE_ID ""

    if [ -z "$API_KEY" ] || [ -z "$SUBDOMAIN" ]; then return 0; fi

    config_get PROXIED "$section" PROXIED "false"
    config_get IPV4 "$section" IPV4 "0"
    config_get IPV6 "$section" IPV6 "0"
    config_get TARGET_MAC "$section" TARGET_MAC ""
    config_get RECORD_ID_V4 "$section" RECORD_ID_V4 ""
    config_get RECORD_ID_V6 "$section" RECORD_ID_V6 ""
    config_get CASCADE_ON_DOWN "$section" CASCADE_ON_DOWN "0"

    logger -t "diepkhoa-action" "--- Xu ly domain: $SUBDOMAIN ---"

    # Ghi nhan yeu cau CASCADE de danh thuc dong doi (chi ap dung khi FORCE)
    if [ "$FORCE_MODE" -eq 1 ] && [ "$CASCADE_ON_DOWN" = "1" ]; then
        echo "$SUBDOMAIN" >> "$CASCADE_LIST"
    fi

    # ================= LAY IPV6 (Goi Ham) =================
    LOCAL_V6_IP=""
    if [ "$IPV6" = "true" ] || [ "$IPV6" = "1" ]; then
        if [ -z "$TARGET_MAC" ]; then
            # Lay luon bien Global da get tu dau de tranh bi loop treo tung record
            LOCAL_V6_IP="$GLOBAL_V6_IP"
        else
            # Chi quet MAC mang LAN 1 lan de tranh block tien trinh
            LOCAL_V6_IP=$(get_ipv6 "$TARGET_MAC")
            if [ -z "$LOCAL_V6_IP" ]; then
                logger -t "diepkhoa-action" "Loi: Khong tim thay IPv6 cho thiet bi LAN co MAC $TARGET_MAC"
            else
                logger -t "diepkhoa-action" "Da lay duoc IPv6 LAN: $LOCAL_V6_IP"
            fi
        fi
    fi
    # ================= VONG LAP A & AAAA =================
    for RECORD_TYPE in "A" "AAAA"; do
        local TARGET_IP=""
        local CURRENT_RECORD_ID=""
        local ID_KEY=""

        if [ "$RECORD_TYPE" = "A" ] && { [ "$IPV4" = "true" ] || [ "$IPV4" = "1" ]; }; then
            TARGET_IP="$GLOBAL_V4_IP"
            CURRENT_RECORD_ID="$RECORD_ID_V4"
            ID_KEY="RECORD_ID_V4"
        elif [ "$RECORD_TYPE" = "AAAA" ] && { [ "$IPV6" = "true" ] || [ "$IPV6" = "1" ]; }; then
            TARGET_IP="$LOCAL_V6_IP"
            CURRENT_RECORD_ID="$RECORD_ID_V6"
            ID_KEY="RECORD_ID_V6"
        else
            continue
        fi

        if [ -z "$TARGET_IP" ]; then continue; fi

        local CACHE_FILE="/tmp/cf-ddns-${SUBDOMAIN}-${RECORD_TYPE}.ip"
        local LAST_IP=""
        if [ -f "$CACHE_FILE" ]; then LAST_IP=$(cat "$CACHE_FILE"); fi

        # Neu khong co cờ ep buoc va IP chua doi -> Bo qua
        if [ "$FORCE_MODE" -eq 0 ] && [ "$RECOVER_MODE" -eq 0 ] && [ "$TARGET_IP" = "$LAST_IP" ]; then continue; fi

        # Kiem tra va don dep cac ban ghi trung lap/sai IP tren Cloudflare
        local REMOTE_IP=""
        if [ "$FORCE_MODE" -eq 1 ] || [ "$RECOVER_MODE" -eq 1 ] || [ -z "$CURRENT_RECORD_ID" ]; then
            local GET_RESP=""
            local GET_RETRY=0
            while [ $GET_RETRY -lt 3 ]; do
                GET_RESP=$(curl -s --connect-timeout 10 --max-time 30 -X GET "$CF_API/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$SUBDOMAIN" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json")
                local GET_EXIT=$?
                if [ $GET_EXIT -eq 0 ] && [ -n "$GET_RESP" ] && echo "$GET_RESP" | jq -e '.success' >/dev/null 2>&1; then
                    break
                fi
                GET_RETRY=$((GET_RETRY + 1))
                logger -t "diepkhoa-action" "LOI: Query $RECORD_TYPE cho $SUBDOMAIN that bai (curl=$GET_EXIT). Thu lai lan $GET_RETRY/3..."
                GET_RESP=""
                [ $GET_RETRY -lt 3 ] && sleep 5
            done

            if [ -z "$GET_RESP" ]; then
                logger -t "diepkhoa-action" "LOI: Khong the truy van CF API cho $SUBDOMAIN $RECORD_TYPE sau 3 lan thu. Bo qua."
                UPDATE_FAIL_COUNT=$((UPDATE_FAIL_COUNT + 1))
                continue
            fi

            local RECORD_COUNT=$(echo "$GET_RESP" | jq -r '.result | length')
            local FOUND_CORRECT_ID=""
            
            if [ -n "$RECORD_COUNT" ] && [ "$RECORD_COUNT" -gt 0 ] && [ "$RECORD_COUNT" != "null" ]; then
                for i in $(seq 0 $((RECORD_COUNT - 1))); do
                    local rec_id=$(echo "$GET_RESP" | jq -r ".result[$i].id")
                    local rec_ip=$(echo "$GET_RESP" | jq -r ".result[$i].content")
                    
                    if [ "$rec_ip" = "$TARGET_IP" ]; then
                        if [ -z "$FOUND_CORRECT_ID" ]; then
                            FOUND_CORRECT_ID="$rec_id"
                        else
                            # IP dung nhung bi thua -> Xoa
                            logger -t "diepkhoa-action" "Phat hien ban ghi $RECORD_TYPE thua thai cho $SUBDOMAIN. Dang xoa $rec_id..."
                            curl -s --connect-timeout 10 --max-time 30 -X DELETE "$CF_API/zones/$ZONE_ID/dns_records/$rec_id" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" >/dev/null
                        fi
                    else
                        # IP sai (stale) -> Xoa
                        logger -t "diepkhoa-action" "Phat hien ban ghi $RECORD_TYPE sai IP ($rec_ip) cho $SUBDOMAIN. Dang xoa $rec_id..."
                        curl -s --connect-timeout 10 --max-time 30 -X DELETE "$CF_API/zones/$ZONE_ID/dns_records/$rec_id" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" >/dev/null
                    fi
                done
            fi
            
            CURRENT_RECORD_ID="$FOUND_CORRECT_ID"
            if [ -n "$CURRENT_RECORD_ID" ]; then
                REMOTE_IP="$TARGET_IP"
                uci set ${CONFIG_FILE}.${section}.${ID_KEY}="$CURRENT_RECORD_ID" && uci commit ${CONFIG_FILE}
            fi
        fi

        # Neu IP remote da dung -> Khong can POST/PUT 
        if [ -n "$REMOTE_IP" ] && [ "$TARGET_IP" = "$REMOTE_IP" ]; then
            logger -t "diepkhoa-action" "Remote IP $RECORD_TYPE da khop ($TARGET_IP). Bo qua thao tac PUT."
            echo -n "$TARGET_IP" > "$CACHE_FILE"
            continue
        fi

        local CF_RETRY=0
        local CF_UPDATE_OK=0
        while [ $CF_RETRY -lt 3 ]; do
            local HTTP_METHOD="PUT"
            local API_ENDPOINT="$CF_API/zones/$ZONE_ID/dns_records/$CURRENT_RECORD_ID"
            if [ -z "$CURRENT_RECORD_ID" ]; then
                HTTP_METHOD="POST"
                API_ENDPOINT="$CF_API/zones/$ZONE_ID/dns_records"
            fi

            local RESPONSE_BODY=$(mktemp)
            local HTTP_CODE=$(curl -s --connect-timeout 10 --max-time 30 -X $HTTP_METHOD "$API_ENDPOINT" \
                -H "Authorization: Bearer $API_KEY" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$SUBDOMAIN\",\"content\":\"$TARGET_IP\",\"ttl\":60,\"proxied\":${PROXIED}}" \
                -w "%{http_code}" -o "$RESPONSE_BODY")
            local CURL_EXIT_CODE=$?

            if [ "$CURL_EXIT_CODE" -eq 0 ] && { [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; }; then
                if [ "$HTTP_METHOD" = "POST" ]; then
                    local NEW_REC_ID=$(cat "$RESPONSE_BODY" | jq -r '.result.id // empty')
                    uci set ${CONFIG_FILE}.${section}.${ID_KEY}="$NEW_REC_ID" && uci commit ${CONFIG_FILE}
                fi
                echo -n "$TARGET_IP" > "$CACHE_FILE"
                logger -t "diepkhoa-action" "o. Update $RECORD_TYPE thanh cong: $TARGET_IP ($SUBDOMAIN)"
                send_telegram_message "*IP Updated ($RECORD_TYPE)*\\nRoute: \`${SUBDOMAIN}\`\\nIP: \`${TARGET_IP}\`"
                rm -f "$RESPONSE_BODY"
                CF_UPDATE_OK=1
                break
            else
                local ERROR_DETAILS=$(cat "$RESPONSE_BODY" | jq -r '.errors[0].message // empty')
                rm -f "$RESPONSE_BODY"
                
                if [ "$CURL_EXIT_CODE" -ne 0 ] || [ "$HTTP_CODE" -eq 0 ]; then
                    CF_RETRY=$((CF_RETRY + 1))
                    logger -t "diepkhoa-action" "LOI: $HTTP_METHOD $RECORD_TYPE cho $SUBDOMAIN that bai (curl=$CURL_EXIT_CODE, http=$HTTP_CODE). Thu lai lan $CF_RETRY/3..."
                    [ $CF_RETRY -lt 3 ] && sleep 5
                    continue
                fi

                if echo "$ERROR_DETAILS" | grep -qi -e "not a valid" -e "not found" -e "does not exist"; then
                    logger -t "diepkhoa-action" "Record ID khong hop le. Chuyen sang POST..."
                    uci set ${CONFIG_FILE}.${section}.${ID_KEY}="" && uci commit ${CONFIG_FILE}
                    CURRENT_RECORD_ID=""
                    continue
                fi
                logger -t "diepkhoa-action" "LOI: CF API tra ve loi: $ERROR_DETAILS (HTTP: $HTTP_CODE)"
                break
            fi
        done
        if [ "$CF_UPDATE_OK" -eq 1 ]; then
            UPDATE_SUCCESS_COUNT=$((UPDATE_SUCCESS_COUNT + 1))
        else
            UPDATE_FAIL_COUNT=$((UPDATE_FAIL_COUNT + 1))
        fi
    done
}

# ==================== VONG LAP RETRY TOAN CUC ====================
GLOBAL_RETRY=0
MAX_GLOBAL_RETRY=3
while [ $GLOBAL_RETRY -lt $MAX_GLOBAL_RETRY ]; do
    UPDATE_SUCCESS_COUNT=0
    UPDATE_FAIL_COUNT=0
    config_foreach update_domain_record record

    if [ $UPDATE_FAIL_COUNT -eq 0 ]; then
        # Khong co loi nao -> thoat vong lap
        break
    fi

    GLOBAL_RETRY=$((GLOBAL_RETRY + 1))
    if [ $GLOBAL_RETRY -lt $MAX_GLOBAL_RETRY ]; then
        logger -t "diepkhoa-action" "Co $UPDATE_FAIL_COUNT ban ghi that bai, $UPDATE_SUCCESS_COUNT thanh cong. Thu lai toan bo lan $((GLOBAL_RETRY + 1))/$MAX_GLOBAL_RETRY sau 15s..."
        sleep 15
        # Reload config de cap nhat RECORD_ID moi (neu da POST thanh cong o vong truoc)
        config_load "$CONFIG_FILE"
    else
        logger -t "diepkhoa-action" "LOI: Van con $UPDATE_FAIL_COUNT ban ghi that bai sau $MAX_GLOBAL_RETRY lan thu."
    fi
done
logger -t "diepkhoa-action" "KET THUC UPDATE: $UPDATE_SUCCESS_COUNT thanh cong, $UPDATE_FAIL_COUNT that bai."

# ==================== DIEU PHOI PHUC HOI CHEO ====================
if [ "$FORCE_MODE" -eq 1 ] && [ -s "$CASCADE_LIST" ]; then
    sort -u "$CASCADE_LIST" -o "$CASCADE_LIST"
    
    local MY_SSH_KEY=""
    config_get MY_SSH_KEY "$MY_OWNER" ssh_key ""
    local SCRIPT_UPDATE=""
    config_get SCRIPT_UPDATE settings SCRIPT_UPDATE "/usr/bin/cloudflare-ddns-action.sh"
    
    notify_cascade_node() {
        local section="$1"
        local OTHER_OWNER OTHER_SUBDOMAIN
        config_get OTHER_OWNER "$section" OWNER ""
        config_get OTHER_SUBDOMAIN "$section" SUBDOMAIN ""
        
        # Khong bao cho chinh minh
        if [ "$OTHER_OWNER" = "$MY_OWNER" ]; then return 0; fi
        
        # Neu subdomain thuoc danh sach cascade
        if grep -q "^${OTHER_SUBDOMAIN}$" "$CASCADE_LIST"; then
            local target_ip
            config_get target_ip "$OTHER_OWNER" ip ""
            
            if [ -n "$target_ip" ] && [ -n "$MY_SSH_KEY" ]; then
                logger -t "diepkhoa-action" "Thong bao Cascade Recover cho [$OTHER_OWNER] (Subdomain: $OTHER_SUBDOMAIN)"
                (
                    local ssh_cmd="ssh"
                    ssh -V 2>&1 | grep -qi dropbear && ssh_cmd="ssh -y"
                    local ssh_out
                    ssh_out=$($ssh_cmd -i "$MY_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$target_ip" "$SCRIPT_UPDATE --recover $OTHER_OWNER $OTHER_SUBDOMAIN" < /dev/null 2>&1)
                    if [ $? -ne 0 ]; then
                        logger -t "diepkhoa-action" "Loi SSH toi [$OTHER_OWNER]: $ssh_out"
                    fi
                ) &
            fi
        fi
    }
    
    logger -t "diepkhoa-action" "Bat dau quet kiem tra Cascade Recover cac node lien doi..."
    config_foreach notify_cascade_node record
fi