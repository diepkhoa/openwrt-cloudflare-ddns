#!/bin/sh

# ==============================================================================
# CLOUDFLARE DDNS & ANTI-DDOS AUTO-INSTALLER cho Node Mới (Worker Node)
# ==============================================================================
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

REPO_URL="https://raw.githubusercontent.com/diepkhoa/openwrt-cloudflare-ddns/refs/heads/main"

echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}  CAI DAT CLOUDFLARE DDNS & ANTI-DDOS MESH (OPENWRT) ${NC}"
echo -e "${CYAN}======================================================${NC}"

# 1. KIEM TRA MOI TRUONG
echo -e "\n${YELLOW}[1/4] Kiem tra he thong...${NC}"
if ! command -v uci >/dev/null 2>&1; then echo -e "${RED}❌ Khong phai OpenWrt!${NC}"; exit 1; fi

MISSING_PKGS=""
command -v jq >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS jq"
command -v curl >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS curl"
if [ -n "$MISSING_PKGS" ]; then
    echo -e "Dang cai dat cac goi con thieu: $MISSING_PKGS..."
    opkg update >/dev/null 2>&1 && opkg install $MISSING_PKGS >/dev/null 2>&1
fi
echo -e "✅ He thong du dieu kien."

# 2. TAI SOURCE CODE TU GITHUB
echo -e "\n${YELLOW}[2/4] Dang tai Source Code tu Github...${NC}"

mkdir -p /usr/bin /www/cgi-bin /etc/config

# Tải các file
curl -fL -s -o /usr/bin/action_update.sh "$REPO_URL/action_update.sh"
curl -fL -s -o /usr/bin/action_delete.sh "$REPO_URL/action_delete.sh"
curl -fL -s -o /usr/bin/monitor.sh "$REPO_URL/monitor.sh"
curl -fL -s -o /usr/bin/sync_config.sh "$REPO_URL/sync_config.sh"
curl -fL -s -o /etc/init.d/cf-monitor "$REPO_URL/cf-monitor"
# Tuỳ chọn file failover
# curl -fL -s -o /www/cgi-bin/failover "$REPO_URL/failover"

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Loi khi tai file tu Github! Vui long kiem tra lai REPO_URL.${NC}"
    exit 1
fi

chmod +x /usr/bin/action_update.sh /usr/bin/action_delete.sh /usr/bin/monitor.sh /usr/bin/sync_config.sh /etc/init.d/cf-monitor
echo -e "✅ Tai file va phan quyen thanh cong."

# 3. KHOI TAO CONFIG GOC & DAT TEN NODE
echo -e "\n${YELLOW}[3/4] Khoi tao Cau hinh...${NC}"

# Tạo config cơ bản
touch /etc/config/cloudflare_ddns
uci -q delete cloudflare_ddns.settings
uci set cloudflare_ddns.settings='global'
uci set cloudflare_ddns.settings.enabled='1'
uci set cloudflare_ddns.settings.SCRIPT_UPDATE='/usr/bin/action_update.sh'
uci set cloudflare_ddns.settings.SCRIPT_DELETE='/usr/bin/action_delete.sh'
uci set cloudflare_ddns.settings.SCRIPT_MONITOR='/usr/bin/monitor.sh'
uci set cloudflare_ddns.settings.SCRIPT_SYNC='/usr/bin/sync_config.sh'
uci commit cloudflare_ddns

# Lấy Hostname của router làm tên node
NODE_NAME=$(uci -q get system.@system[0].hostname)
if [ -z "$NODE_NAME" ]; then
    NODE_NAME=$(cat /proc/sys/kernel/hostname)
fi
echo "$NODE_NAME" > /etc/cf_node_name

echo -e "✅ Da tao config mau tai /etc/config/cloudflare_ddns"
echo -e "✅ Da dat ten node la: ${CYAN}$NODE_NAME${NC}"

# 4. KHOI DONG DICH VU
echo -e "\n${YELLOW}[4/4] Khoi dong dich vu...${NC}"
/etc/init.d/cf-monitor enable
/etc/init.d/cf-monitor start
echo -e "✅ Dich vu giam sat (cf-monitor) da duoc bat va khoi dong."

# 5. HOAN TAT
echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 Cai dat thanh cong tren node ${CYAN}$NODE_NAME${GREEN}!${NC}"
echo -e "Node nay khong co endpoint nen ban khong can them gi vao config."
echo -e "Giam sat va dong bo da hoat dong. Khi co thay doi config tu Master,"
echo -e "node nay se nhan duoc qua scp (neu Master da duoc cau hinh SSH key)."
echo -e "${CYAN}======================================================${NC}"
