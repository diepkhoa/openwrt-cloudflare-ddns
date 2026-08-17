#!/bin/sh

. /lib/functions.sh

CONFIG_FILE="cloudflare_ddns"
CF_API="https://api.cloudflare.com/client/v4"

TARGET_OWNER="$1"
CALLER="$2"

if [ -z "$TARGET_OWNER" ]; then
    logger -t "diepkhoa-delete" "Loi Cu phap: action_delete.sh <owner> [caller]"
    exit 1
fi

logger -t "diepkhoa-delete" "? KICH HOAT DELETE CHO OWNER: $TARGET_OWNER (CALLER: $CALLER)"

config_load "$CONFIG_FILE"
config_get TELEGRAM_BOT_TOKEN settings TELEGRAM_BOT_TOKEN ""
config_get TELEGRAM_CHAT_ID settings TELEGRAM_CHAT_ID ""

send_telegram_message() {
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local message="$1"
        local encoded_message=$(printf '%b' "$message" | jq -sRr @uri)
        curl -s --connect-timeout 10 --max-time 30 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage?chat_id=${TELEGRAM_CHAT_ID}&text=${encoded_message}&parse_mode=Markdown" &> /dev/null &
    fi
}

# =========================================================
# GIAI DOAN 1: THU THAP DANH SACH CAN XOA
# =========================================================
# Luu tru danh sach cac record can xoa vao /tmp
DELETE_RECORDS_LIST=$(mktemp)

# Quet file config de tim cac record bi anh huong boi OWNER down
find_affected_records() {
    local section="$1"
    local OWNER SUBDOMAIN DELETE_IF_DOWN CASCADE_ON_DOWN
    
    config_get OWNER "$section" OWNER ""
    config_get SUBDOMAIN "$section" SUBDOMAIN ""
    config_get DELETE_IF_DOWN "$section" DELETE_IF_DOWN "1"
    config_get CASCADE_ON_DOWN "$section" CASCADE_ON_DOWN "0"
    
    if [ "$OWNER" = "$TARGET_OWNER" ]; then
        if [ "$DELETE_IF_DOWN" = "0" ]; then
            logger -t "diepkhoa-delete" "Bo qua record cua $SUBDOMAIN vi DELETE_IF_DOWN=0"
            return 0
        fi
        
        if [ -n "$CALLER" ]; then
            local partner_list=""
            config_get partner_list "$section" partner ""
            if [ -n "$partner_list" ]; then
                local is_partner=0
                for p in $partner_list; do
                    [ "$p" = "$CALLER" ] && is_partner=1
                done
                if [ "$is_partner" = "0" ]; then
                    logger -t "diepkhoa-delete" "Bo qua $SUBDOMAIN vi caller=$CALLER khong phai partner"
                    return 0
                fi
            fi
        fi
        
        # Add ban than record nay vao danh sach xoa
        echo "$section" >> "$DELETE_RECORDS_LIST"
        
        # Neu co cascade, quet lai toan bo config de tim cac record khac cung subdomain
        if [ "$CASCADE_ON_DOWN" = "1" ]; then
            logger -t "diepkhoa-delete" "Kich hoat CASCADE DELETE cho $SUBDOMAIN"
            find_cascade_records() {
                local inner_sec="$1"
                local inner_sub inner_del
                config_get inner_sub "$inner_sec" SUBDOMAIN ""
                config_get inner_del "$inner_sec" DELETE_IF_DOWN "1"
                if [ "$inner_sub" = "$SUBDOMAIN" ] && [ "$inner_sec" != "$section" ] && [ "$inner_del" != "0" ]; then
                    echo "$inner_sec" >> "$DELETE_RECORDS_LIST"
                fi
            }
            config_foreach find_cascade_records record
        fi
    fi
}

config_foreach find_affected_records record

if [ ! -s "$DELETE_RECORDS_LIST" ]; then
    logger -t "diepkhoa-delete" "Khong co record hop le nao de xoa. Ket thuc."
    rm -f "$DELETE_RECORDS_LIST"
    exit 0
fi

# Loai bo trung lap trong danh sach
sort -u "$DELETE_RECORDS_LIST" -o "$DELETE_RECORDS_LIST"

# =========================================================
# GIAI DOAN 2: THUC THI XOA TREN CLOUDFLARE
# =========================================================
delete_cloudflare_record() {
    local section="$1"
    local DOMAIN_REF SUBDOMAIN IPV4 IPV6 RECORD_ID_V4 RECORD_ID_V6
    
    config_get DOMAIN_REF "$section" DOMAIN ""
    config_get SUBDOMAIN "$section" SUBDOMAIN ""
    config_get IPV4 "$section" IPV4 "0"
    config_get IPV6 "$section" IPV6 "0"
    config_get RECORD_ID_V4 "$section" RECORD_ID_V4 ""
    config_get RECORD_ID_V6 "$section" RECORD_ID_V6 ""
    
    # Lay thong tin tu Domain Cha
    local API_KEY ZONE_ID
    config_get API_KEY "$DOMAIN_REF" API_KEY ""
    config_get ZONE_ID "$DOMAIN_REF" ZONE_ID ""
    
    if [ -z "$API_KEY" ] || [ -z "$ZONE_ID" ]; then
        logger -t "diepkhoa-delete" "Loi: Thieu API_KEY hoac ZONE_ID cho domain ref $DOMAIN_REF"
        return 0
    fi
    
    logger -t "diepkhoa-delete" "--- Dang xu ly Xoa cho record: $section ($SUBDOMAIN) ---"
    
    for RECORD_TYPE in "A" "AAAA"; do
        local CURRENT_RECORD_ID=""
        local ID_KEY=""

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
            CURRENT_RECORD_ID=$(curl -s --connect-timeout 10 --max-time 30 -X GET "$CF_API/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$SUBDOMAIN" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
        fi
        
        if [ -z "$CURRENT_RECORD_ID" ]; then continue; fi
        
        # Thuc thi DELETE
        local HTTP_CODE=$(curl -s --connect-timeout 10 --max-time 30 -X DELETE "$CF_API/zones/$ZONE_ID/dns_records/$CURRENT_RECORD_ID" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -w "%{http_code}" -o /dev/null)

        if [ "$HTTP_CODE" -eq 200 ]; then
            logger -t "diepkhoa-delete" "o. XOA thanh cong $RECORD_TYPE: $SUBDOMAIN (Owner: $(uci -q get ${CONFIG_FILE}.${section}.OWNER))"
            uci set ${CONFIG_FILE}.${section}.${ID_KEY}=""
            uci commit ${CONFIG_FILE}
            rm -f "/tmp/cf-ddns-${SUBDOMAIN}-${RECORD_TYPE}.ip"
            send_telegram_message "*Record Deleted ($RECORD_TYPE)*\nTarget: \`$TARGET_OWNER (DOWN)\`\nCleared: \`$SUBDOMAIN\`"
        else
            logger -t "diepkhoa-delete" "?O Loi xoa $RECORD_TYPE ban ghi $SUBDOMAIN (HTTP: $HTTP_CODE)"
        fi
    done
}

while read -r section; do
    delete_cloudflare_record "$section"
done < "$DELETE_RECORDS_LIST"

rm -f "$DELETE_RECORDS_LIST"
logger -t "diepkhoa-delete" "Hoan tat chu trinh Xoa."