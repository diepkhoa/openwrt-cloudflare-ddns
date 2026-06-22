#!/bin/sh

# ==============================================================================
# CLOUDFLARE DDNS & ANTI-DDOS AUTO-INSTALLER
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

mkdir -p /usr/bin /www/cgi-bin

# Tải các file (Thêm cờ -fL để bắt lỗi tải file)
curl -fL -s -o /usr/bin/action_update.sh "$REPO_URL/action_update.sh"
curl -fL -s -o /usr/bin/action_delete.sh "$REPO_URL/action_delete.sh"
curl -fL -s -o /usr/bin/monitor.sh "$REPO_URL/monitor.sh"
curl -fL -s -o /usr/bin/sync_config.sh "$REPO_URL/sync_config.sh"
curl -fL -s -o /etc/init.d/cf-monitor "$REPO_URL/cf-monitor"
curl -fL -s -o /www/cgi-bin/failover "$REPO_URL/failover"

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Loi khi tai file tu Github! Vui long kiem tra lai REPO_URL.${NC}"
    exit 1
fi

chmod +x /usr/bin/action_update.sh /usr/bin/action_delete.sh /usr/bin/monitor.sh /usr/bin/sync_config.sh /etc/init.d/cf-monitor /www/cgi-bin/failover
echo -e "✅ Tai file va phan quyen thanh cong."

# 3. KHOI TAO CONFIG GOC
echo -e "\n${YELLOW}[3/4] Khoi tao Cau hinh...${NC}"
touch /etc/config/cloudflare_ddns
uci -q delete cloudflare_ddns.settings
uci set cloudflare_ddns.settings='global'
uci set cloudflare_ddns.settings.enabled='1'
uci set cloudflare_ddns.settings.SCRIPT_UPDATE='/usr/bin/action_update.sh'
uci set cloudflare_ddns.settings.SCRIPT_DELETE='/usr/bin/action_delete.sh'
uci set cloudflare_ddns.settings.SCRIPT_MONITOR='/usr/bin/monitor.sh'
uci set cloudflare_ddns.settings.SCRIPT_SYNC='/usr/bin/sync_config.sh'
uci commit cloudflare_ddns
echo -e "✅ Da tao file Config mau tai /etc/config/cloudflare_ddns"

# 4. HOAN TAT
echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 Cai dat ma nguon thanh cong!${NC}"
echo -e "De hoan tat thiet lap Node nay, vui long:"
echo -e "1. Sua file config: vi /etc/config/cloudflare_ddns"
echo -e "2. Dat ten danh tinh cho Node: echo 'ten_node' > /etc/cf_node_name"
echo -e "3. Khoi dong giam sat: /etc/init.d/cf-monitor enable && /etc/init.d/cf-monitor start"
echo -e "${CYAN}======================================================${NC}"
