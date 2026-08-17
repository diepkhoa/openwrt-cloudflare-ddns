#!/bin/sh

MY_OWNER="$1"
if [ -z "$MY_OWNER" ]; then
    echo "Loi: Thieu tham so. Cu phap: ./sync-config.sh <ten_node_master>"
    exit 1
fi

CONFIG_FILE="cloudflare_ddns"
. /lib/functions.sh

echo "====================================================="
echo "BAT DAU DONG BO CONFIG VA SOURCE CODE TU: [$MY_OWNER]"
echo "====================================================="

config_load "$CONFIG_FILE"
config_get SCRIPT_UPDATE settings SCRIPT_UPDATE "/usr/bin/action_update.sh"
config_get SCRIPT_DELETE settings SCRIPT_DELETE "/usr/bin/action_delete.sh"
config_get SCRIPT_MONITOR settings SCRIPT_MONITOR "/usr/bin/monitor.sh"
config_get SCRIPT_SYNC settings SCRIPT_SYNC "/usr/bin/sync_config.sh"

# ========================================================
# [BƯỚC VÁ LỖI]: LẤY CHÌA KHÓA CỦA CHÍNH BẢN THÂN MASTER
# ========================================================
config_get MY_SSH_KEY "$MY_OWNER" ssh_key ""

if [ -z "$MY_SSH_KEY" ]; then
    echo "❌ Loi: Khong tim thay 'ssh_key' cua Master [$MY_OWNER] trong File Config!"
    exit 1
fi

# ==================== HAM XU LY TUNG NODE ====================
sync_to_node() {
    local section="$1"
    local NODE_IP
    
    if [ "$section" = "$MY_OWNER" ]; then return 0; fi

    config_get NODE_IP "$section" ip ""

    # (Đã xóa dòng config_get SSH_KEY ở đây)
    if [ -z "$NODE_IP" ]; then return 0; fi

    echo "-----------------------------------------------------"
    echo "Dang dong bo toi Node: [$section] (IP: $NODE_IP)..."

    # [SỬA Ở ĐÂY]: Thay bién $SSH_KEY thanh $MY_SSH_KEY
    scp -i "$MY_SSH_KEY" -o StrictHostKeyChecking=no /etc/config/$CONFIG_FILE root@${NODE_IP}:/etc/config/$CONFIG_FILE
    scp -i "$MY_SSH_KEY" -o StrictHostKeyChecking=no "$SCRIPT_UPDATE" root@${NODE_IP}:"$SCRIPT_UPDATE"
    scp -i "$MY_SSH_KEY" -o StrictHostKeyChecking=no "$SCRIPT_DELETE" root@${NODE_IP}:"$SCRIPT_DELETE"
    scp -i "$MY_SSH_KEY" -o StrictHostKeyChecking=no "$SCRIPT_MONITOR" root@${NODE_IP}:"$SCRIPT_MONITOR"
    scp -i "$MY_SSH_KEY" -o StrictHostKeyChecking=no /etc/init.d/cf-monitor root@${NODE_IP}:/etc/init.d/cf-monitor
    scp -i "$MY_SSH_KEY" -o StrictHostKeyChecking=no "$SCRIPT_SYNC" root@${NODE_IP}:"$SCRIPT_SYNC"
    
    if [ $? -eq 0 ]; then
        echo "  [OK] Dong bo File Config & Source Code thanh cong."
        
        # [SỬA Ở ĐÂY]: Thay bién $SSH_KEY thanh $MY_SSH_KEY
        ssh -i "$MY_SSH_KEY" -o StrictHostKeyChecking=no root@${NODE_IP} "
            chmod +x $SCRIPT_UPDATE $SCRIPT_DELETE $SCRIPT_MONITOR /etc/init.d/cf-monitor $SCRIPT_SYNC
            
            echo '$section' > /etc/cf_node_name
            
            /etc/init.d/cf-monitor enable
            /etc/init.d/cf-monitor restart >/dev/null 2>&1
        "
        
        echo "  [OK] Slave [$section] da Enable Init.d va khoi dong Monitor."
    else
        echo "  [ERROR] Khong the ket noi toi [$section] hoac truyen file loi."
    fi
}

# ==================== THUC THI ====================
config_foreach sync_to_node node

# ==================== KICH HOAT CHO CHINH MASTER ====================
echo "-----------------------------------------------------"
echo "Dang thiet lap dich vu cho chinh Master: [$MY_OWNER]..."

chmod +x $SCRIPT_UPDATE $SCRIPT_DELETE $SCRIPT_MONITOR $SCRIPT_SYNC /etc/init.d/cf-monitor
echo "$MY_OWNER" > /etc/cf_node_name
/etc/init.d/cf-monitor enable
/etc/init.d/cf-monitor restart >/dev/null 2>&1

echo "  [OK] Master [$MY_OWNER] da kich hoat thanh cong Monitor (Procd)."

echo "====================================================="
echo "HOAN TAT CHU TRINH OTA VA SELF-SETUP!"
echo "====================================================="