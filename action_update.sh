#!/bin/sh

. /lib/functions.sh

CONFIG_FILE="cloudflare_ddns"
CF_API="https://api.cloudflare.com/client/v4"
LOCK_FILE="/tmp/cloudflare-ddns-action.lock"
COOLDOWN_FILE="/tmp/cloudflare-ddns-action.cooldown"

# Phan tich tham so truyen vao
FORCE_MODE=0
MY_OWNER=""

for arg in "$@"; do
    if [ "$arg" = "--force" ]; then
        FORCE_MODE=1
    else
        MY_OWNER="$arg"
    fi
done

if [ -z "$MY_OWNER" ]; then
    logger -t "diepkhoa-action" "Loi: Thieu tham so OWNER. Cú pháp: action.sh [--force] <owner>"
    exit 1
fi

# ==================== KHOA LUONG & DEBOUNCE ====================
NOW=$(date +%s)
if [ "$FORCE_MODE" -eq 0 ]; then
    if [ -f "$COOLDOWN_FILE" ]; then
        LAST_RUN=$(cat "$COOLDOWN_FILE")
        if [ $((NOW - LAST_RUN)) -lt 10 ]; then exit 0; fi
    fi
    echo "$NOW" > "$COOLDOWN_FILE"
fi

exec 9>"$LOCK_FILE"
flock -n 9 || exit 1

logger -t "diepkhoa-action" "BAT DAU UPDATE DDNS CHO OWNER: [$MY_OWNER] (Force=$FORCE_MODE)"

# ==================== LAY BIEN TOAN CUC ====================
config_load "$CONFIG_FILE"
config_get TELEGRAM_BOT_TOKEN settings TELEGRAM_BOT_TOKEN
config_get TELEGRAM_CHAT_ID settings TELEGRAM_CHAT_ID

# Lay IPv4 cua Interface hien tai (Dung cho V4)
# LAY CONG MANG VAT LY CUA CHINH NODE NAY
config_get WAN_IFACE "$MY_OWNER" wan_iface "wan"

# LAY IPV4 TOAN CUC
GLOBAL_V4_IP=$(ubus call network.interface.$WAN_IFACE status 2>/dev/null | jq -r '.["ipv4-address"][0].address // empty')

send_telegram_message() {
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local message="$1"
        local encoded_message=$(printf '%b' "$message" | jq -sRr @uri)
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage?chat_id=${TELEGRAM_CHAT_ID}&text=${encoded_message}&parse_mode=Markdown" &> /dev/null &
    fi
}

# ==================== XU LY TUNG TEN MIEN CUA OWNER ====================
update_domain_record() {
    local section="$1"
    local OWNER API_KEY ZONE_NAME SUBDOMAIN PROXIED IPV4 IPV6 TARGET_MAC ZONE_ID RECORD_ID_V4 RECORD_ID_V6
    
    config_get OWNER "$section" OWNER ""
    
    # 1. BO QUA NGAY neu khong phai do minh so huu
    if [ "$OWNER" != "$MY_OWNER" ]; then return 0; fi
    
    config_get API_KEY "$section" API_KEY ""
    config_get ZONE_NAME "$section" ZONE_NAME ""
    config_get SUBDOMAIN "$section" SUBDOMAIN ""
    config_get PROXIED "$section" PROXIED "false"
    config_get IPV4 "$section" IPV4 "0"
    config_get IPV6 "$section" IPV6 "0"
    config_get TARGET_MAC "$section" TARGET_MAC ""
    config_get ZONE_ID "$section" ZONE_ID ""
    config_get RECORD_ID_V4 "$section" RECORD_ID_V4 ""
    config_get RECORD_ID_V6 "$section" RECORD_ID_V6 ""

    if [ -z "$API_KEY" ] || [ -z "$SUBDOMAIN" ]; then return 0; fi

    logger -t "diepkhoa-action" "--- Xu ly domain: $SUBDOMAIN ---"

    # Lay ZONE_ID
    if [ -z "$ZONE_ID" ]; then
        ZONE_ID=$(curl -s -X GET "$CF_API/zones?name=$ZONE_NAME" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
        [ -n "$ZONE_ID" ] && uci set ${CONFIG_FILE}.${section}.ZONE_ID="$ZONE_ID" && uci commit ${CONFIG_FILE}
    fi

    # ================= LAY IPV6 (QUET MAC) =================
    LOCAL_V6_IP=""
    if [ "$IPV6" = "true" ] || [ "$IPV6" = "1" ]; then
        if [ -n "$TARGET_MAC" ]; then
            LOCAL_V6_IP=$(ip -6 neigh show | grep -i "$TARGET_MAC" | grep -v "^fe80" | awk '{print $1}' | head -n 1)
        else
            LOCAL_V6_IP=$(ubus call network.interface.$WAN_IFACE status 2>/dev/null | jq -r '.["ipv6-address"][0].address // empty')
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

        # CACHE LOCAL IP
        local CACHE_FILE="/tmp/cf-ddns-${SUBDOMAIN}-${RECORD_TYPE}.ip"
        local LAST_IP=""
        if [ -f "$CACHE_FILE" ]; then LAST_IP=$(cat "$CACHE_FILE"); fi

        if [ "$FORCE_MODE" -eq 0 ] && [ "$TARGET_IP" = "$LAST_IP" ]; then continue; fi

        # KIEM TRA TREN CLOUDFLARE (Neu force hoac chua co ID)
        local REMOTE_IP=""
        if [ "$FORCE_MODE" -eq 1 ] || [ -z "$CURRENT_RECORD_ID" ]; then
            # GET 1 lan de lay ca ID lan IP hien tai tren Cloudflare
            local GET_RESP=$(curl -s -X GET "$CF_API/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$SUBDOMAIN" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json")
            CURRENT_RECORD_ID=$(echo "$GET_RESP" | jq -r '.result[0].id // empty')
            REMOTE_IP=$(echo "$GET_RESP" | jq -r '.result[0].content // empty')
            
            # Luu ID vao config neu tim thay
            [ -n "$CURRENT_RECORD_ID" ] && uci set ${CONFIG_FILE}.${section}.${ID_KEY}="$CURRENT_RECORD_ID" && uci commit ${CONFIG_FILE}
        fi

        # LOGIC FORCE: Neu IP tren CF da giong IP hien tai -> Khong can PUT nua
        if [ "$FORCE_MODE" -eq 1 ] && [ -n "$REMOTE_IP" ] && [ "$TARGET_IP" = "$REMOTE_IP" ]; then
            logger -t "diepkhoa-action" "Force Mode: Remote IP $RECORD_TYPE da khop ($TARGET_IP). Bo qua thao tac PUT."
            echo -n "$TARGET_IP" > "$CACHE_FILE"
            continue
        fi

        while true; do
            local HTTP_METHOD="PUT"
            local API_ENDPOINT="$CF_API/zones/$ZONE_ID/dns_records/$CURRENT_RECORD_ID"
            if [ -z "$CURRENT_RECORD_ID" ]; then
                HTTP_METHOD="POST"
                API_ENDPOINT="$CF_API/zones/$ZONE_ID/dns_records"
            fi

            local RESPONSE_BODY=$(mktemp)
            local HTTP_CODE=$(curl -s -X $HTTP_METHOD "$API_ENDPOINT" \
                -H "Authorization: Bearer $API_KEY" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$SUBDOMAIN\",\"content\":\"$TARGET_IP\",\"ttl\":120,\"proxied\":${PROXIED}}" \
                -w "%{http_code}" -o "$RESPONSE_BODY")
            local CURL_EXIT_CODE=$?

            if [ "$CURL_EXIT_CODE" -eq 0 ] && { [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; }; then
                if [ "$HTTP_METHOD" = "POST" ]; then
                    local NEW_REC_ID=$(cat "$RESPONSE_BODY" | jq -r '.result.id // empty')
                    uci set ${CONFIG_FILE}.${section}.${ID_KEY}="$NEW_REC_ID" && uci commit ${CONFIG_FILE}
                fi
                echo -n "$TARGET_IP" > "$CACHE_FILE"
                logger -t "diepkhoa-action" "✅ Update $RECORD_TYPE thanh cong: $TARGET_IP"
                send_telegram_message "✅ *IP Updated ($RECORD_TYPE)*\\nRoute: \`${SUBDOMAIN}\`\\nIP: \`${TARGET_IP}\`"
                rm -f "$RESPONSE_BODY"
                break
            else
                local ERROR_DETAILS=$(cat "$RESPONSE_BODY" | jq -r '.errors[0].message // empty')
                rm -f "$RESPONSE_BODY"
                
                # Check mat mang -> Thoat vong lap de xu ly tiep (Vi Kuma se lo)
                if [ "$CURL_EXIT_CODE" -ne 0 ] || [ "$HTTP_CODE" -eq 0 ]; then break; fi

                # Check mat ID
                if echo "$ERROR_DETAILS" | grep -qi "not a valid" || echo "$ERROR_DETAILS" | grep -qi "not found" || echo "$ERROR_DETAILS" | grep -qi "does not exist"; then
                    uci set ${CONFIG_FILE}.${section}.${ID_KEY}="" && uci commit ${CONFIG_FILE}
                    CURRENT_RECORD_ID=""
                    continue
                fi
                break
            fi
        done
    done
}

config_foreach update_domain_record record
logger -t "diepkhoa-action" "Hoan tat Update cho: $MY_OWNER"