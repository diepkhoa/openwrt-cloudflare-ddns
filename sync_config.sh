#!/bin/sh

MY_OWNER="$1"
if [ -z "$MY_OWNER" ]; then
    echo "‚ùå Loi: Thieu tham so. Cu phap: ./sync-config.sh <ten_node_master>"
    exit 1
fi

CONFIG_FILE="cloudflare_ddns"
. /lib/functions.sh

echo "====================================================="
echo "Ì†ΩÌ∫Ä BAT DAU DONG BO CONFIG VA SOURCE CODE TU: [$MY_OWNER]"
echo "====================================================="

config_load "$CONFIG_FILE"
config_get SCRIPT_UPDATE settings SCRIPT_UPDATE "/usr/bin/action_update.sh"
config_get SCRIPT_DELETE settings SCRIPT_DELETE "/usr/bin/action_delete.sh"
config_get SCRIPT_MONITOR settings SCRIPT_MONITOR "/usr/bin/monitor.sh"
config_get SCRIPT_SYNC settings SCRIPT_SYNC "/usr/bin/sync_config.sh"

# ==================== HAM XU LY TUNG NODE ====================
sync_to_node() {
    local section="$1"
    local NODE_IP SSH_KEY
    
    if [ "$section" = "$MY_OWNER" ]; then return 0; fi

    config_get NODE_IP "$section" ip ""
    config_get SSH_KEY "$section" ssh_key ""

    if [ -z "$NODE_IP" ] || [ -z "$SSH_KEY" ]; then return 0; fi

    echo "-----------------------------------------------------"
    echo "Ì†ΩÌ¥Ñ Dang dong bo toi Node: [$section] (IP: $NODE_IP)..."

    # 1. Day toan bo File (Them file init.d vao danh sach copy)
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /etc/config/$CONFIG_FILE root@${NODE_IP}:/etc/config/$CONFIG_FILE
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SCRIPT_UPDATE" root@${NODE_IP}:"$SCRIPT_UPDATE"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SCRIPT_DELETE" root@${NODE_IP}:"$SCRIPT_DELETE"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SCRIPT_MONITOR" root@${NODE_IP}:"$SCRIPT_MONITOR"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /etc/init.d/cf-monitor root@${NODE_IP}:/etc/init.d/cf-monitor
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SCRIPT_SYNC" root@${NODE_IP}:"$SCRIPT_SYNC"
    
    if [ $? -eq 0 ]; then
        echo "  ‚úÖ [OK] Dong bo File Config & Source Code thanh cong."
        
        # 2. Ghi the Dinh danh (Node Identity) va Khoi dong dich vu Procd
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@${NODE_IP} "
            chmod +x $SCRIPT_UPDATE $SCRIPT_DELETE $SCRIPT_MONITOR /etc/init.d/cf-monitor
            
            # Ghi ten section (VD: x96air) vao file nhan dien
            echo '$section' > /etc/cf_node_name
            
            # Kich hoat va khoi dong lai dich vu (Procd se lo viec kill tien trinh cu)
            # PROCD se tu dong tat tien trinh cu va khoi dong tien trinh moi cuc ky sach se
            /etc/init.d/cf-monitor enable
            /etc/init.d/cf-monitor restart >/dev/null 2>&1
        "
        
        echo "  ‚úÖ [OK] Slave [$section] da Enable Init.d va chay Monitor (Procd)."
    else
        echo "  ‚ùå [ERROR] Khong the ket noi toi [$section]."
    fi
}

# ==================== THUC THI ====================
config_foreach sync_to_node node

# ==================== KICH HOAT CHO CHINH MASTER ====================
echo "-----------------------------------------------------"
echo "‚öôÔ∏è Dang thiet lap dich vu cho chinh Master: [$MY_OWNER]..."

# 1. Cap quyen thuc thi cho file tren Master
chmod +x $SCRIPT_UPDATE $SCRIPT_DELETE $SCRIPT_MONITOR $SCRIPT_SYNC /etc/init.d/cf-monitor

# 2. Ghi the Dinh danh cho Master
echo "$MY_OWNER" > /etc/cf_node_name

# 3. Kich hoat va khoi dong Monitor tren Master
/etc/init.d/cf-monitor enable
/etc/init.d/cf-monitor restart >/dev/null 2>&1

echo "  ‚úÖ [OK] Master [$MY_OWNER] da kich hoat thanh cong Monitor (Procd)."

echo "====================================================="
echo "Ì†ºÌæâ HOAN TAT CHU TRINH OTA VA SELF-SETUP!"
echo "====================================================="
echo "====================================================="
echo "Ì†ºÌæâ HOAN TAT CHU TRINH OTA (OVER-THE-AIR) UPDATE!"
echo "====================================================="