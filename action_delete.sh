#!/bin/sh

. /lib/functions.sh

CONFIG_FILE="cloudflare_ddns"
CF_API="https://api.cloudflare.com/client/v4"

# ==================== PHAN TICH THAM SO ====================
TARGET_TYPE="$1"  # "A", "AAAA", hoac "ALL"
shift             # Day tham so dau tien ra khoi danh sach
TARGETS="$@"      # Phan con lai la danh sach cac Muc tieu (Owner hoac Subdomain)

if [ -z "$TARGET_TYPE" ] || [ -z "$TARGETS" ]; then
    logger -t "diepkhoa-delete" "Loi Cu phap: action-delete.sh <A|AAAA|ALL> <owner1> [subdomain2] ..."
    exit 1
fi

logger -t "diepkhoa-delete" "Ì†ΩÌ∫Ä KICH HOAT DELETE [$TARGET_TYPE] CHO: $TARGETS"

# Load bien toan cuc
config_load "$CONFIG_FILE"
config_get TELEGRAM_BOT_TOKEN settings TELEGRAM_BOT_TOKEN ""
config_get TELEGRAM_CHAT_ID settings TELEGRAM_CHAT_ID ""
config_get GLOBAL_API_KEY settings API_KEY ""

send_telegram_message() {
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local message="$1"
        local encoded_message=$(printf '%b' "$message" | jq -sRr @uri)
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage?chat_id=${TELEGRAM_CHAT_ID}&text=${encoded_message}&parse_mode=Markdown" &> /dev/null &
    fi
}

# =========================================================
# GIAI DOAN 1: THU THAP DANH SACH SUBDOMAIN CAN XOA
# =========================================================
AFFECTED_LIST=$(mktemp)

# Ham tim subdomain neu target la Owner
find_owner_subdomains() {
    local section="$1"
    local target_owner="$2"
    local OWNER SUBDOMAIN
    
    config_get OWNER "$section" OWNER ""
    config_get SUBDOMAIN "$section" SUBDOMAIN ""
    
    if [ "$OWNER" = "$target_owner" ] && [ -n "$SUBDOMAIN" ]; then
        echo "$SUBDOMAIN" >> "$AFFECTED_LIST"
    fi
}

for target in $TARGETS; do
    if echo "$target" | grep -q "\."; then
        # Neu co dau cham '.' -> Day la Subdomain chi dinh -> Add luon vao list
        echo "$target" >> "$AFFECTED_LIST"
    else
        # Khong co dau cham -> Day la Owner -> Quet config de tim cac Subdomain thuoc Owner nay
        config_foreach find_owner_subdomains record "$target"
    fi
done

if [ ! -s "$AFFECTED_LIST" ]; then
    logger -t "diepkhoa-delete" "Khong co Subdomain hop le nao de xoa. Ket thuc."
    rm -f "$AFFECTED_LIST"
    exit 0
fi

# =========================================================
# GIAI DOAN 2: THUC THI XOA (Dua tren file config)
# =========================================================
delete_record() {
    local section="$1"
    local API_KEY ZONE_NAME SUBDOMAIN IPV4 IPV6 ZONE_ID RECORD_ID_V4 RECORD_ID_V6
    
    config_get SUBDOMAIN "$section" SUBDOMAIN ""
    
    # Kiem tra Subdomain nay co nam trong Danh sach Tu hinh khong
    if ! grep -q "^${SUBDOMAIN}$" "$AFFECTED_LIST"; then
        return 0 # Khong nam trong list -> Bo qua
    fi

    config_get API_KEY "$section" API_KEY "$GLOBAL_API_KEY"
    if [ -z "$API_KEY" ]; then return 0; fi

    config_get ZONE_NAME "$section" ZONE_NAME ""
    config_get IPV4 "$section" IPV4 "0"
    config_get IPV6 "$section" IPV6 "0"
    config_get ZONE_ID "$section" ZONE_ID ""
    config_get RECORD_ID_V4 "$section" RECORD_ID_V4 ""
    config_get RECORD_ID_V6 "$section" RECORD_ID_V6 ""

    logger -t "diepkhoa-delete" "--- Dang xu ly Xoa [$TARGET_TYPE] cho: $SUBDOMAIN ---"

    # Lay Zone ID neu chua co
    if [ -z "$ZONE_ID" ]; then
        ZONE_ID=$(curl -s -X GET "$CF_API/zones?name=$ZONE_NAME" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
        [ -n "$ZONE_ID" ] && uci set ${CONFIG_FILE}.${section}.ZONE_ID="$ZONE_ID" && uci commit ${CONFIG_FILE}
    fi

    # Vong lap V4 va V6
    for RECORD_TYPE in "A" "AAAA"; do
        local CURRENT_RECORD_ID=""
        local ID_KEY=""

        # Neu yeu cau khong phai ALL ma cung khong khop kieu A/AAAA -> Bo qua
        if [ "$TARGET_TYPE" != "ALL" ] && [ "$TARGET_TYPE" != "$RECORD_TYPE" ]; then
            continue
        fi

        # Kiem tra xem Config co bat kieu ban ghi nay khong
        if [ "$RECORD_TYPE" = "A" ] && { [ "$IPV4" = "true" ] || [ "$IPV4" = "1" ]; }; then
            CURRENT_RECORD_ID="$RECORD_ID_V4"
            ID_KEY="RECORD_ID_V4"
        elif [ "$RECORD_TYPE" = "AAAA" ] && { [ "$IPV6" = "true" ] || [ "$IPV6" = "1" ]; }; then
            CURRENT_RECORD_ID="$RECORD_ID_V6"
            ID_KEY="RECORD_ID_V6"
        else
            continue
        fi

        # Truy van API lay ID neu trong config bi mat
        if [ -z "$CURRENT_RECORD_ID" ]; then
            CURRENT_RECORD_ID=$(curl -s -X GET "$CF_API/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$SUBDOMAIN" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
        fi

        # Neu tren Cloudflare cung khong co -> Bo qua
        if [ -z "$CURRENT_RECORD_ID" ]; then continue; fi

        # Thuc thi DELETE
        local HTTP_CODE=$(curl -s -X DELETE "$CF_API/zones/$ZONE_ID/dns_records/$CURRENT_RECORD_ID" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -w "%{http_code}" -o /dev/null)

        if [ "$HTTP_CODE" -eq 200 ]; then
            logger -t "diepkhoa-delete" "‚úÖ XOA thanh cong $RECORD_TYPE: $SUBDOMAIN"
            # Xoa ID trong config, xoa luon ca Cache IP de update sau nay khong bi chan
            uci set ${CONFIG_FILE}.${section}.${ID_KEY}=""
            uci commit ${CONFIG_FILE}
            rm -f "/tmp/cf-ddns-${SUBDOMAIN}-${RECORD_TYPE}.ip"
            
            send_telegram_message "‚ùå*Record Deleted ($RECORD_TYPE)*\nTarget: \`$TARGETS\`\nCleared: \`$SUBDOMAIN\`"
        else
            logger -t "diepkhoa-delete" "‚ùå Loi xoa $RECORD_TYPE ban ghi $SUBDOMAIN (HTTP: $HTTP_CODE)"
        fi
    done
}

# Chay quet va xoa
config_foreach delete_record record

# Don dep file rac
rm -f "$AFFECTED_LIST"
logger -t "diepkhoa-delete" "Hoan tat chu trinh Xoa."