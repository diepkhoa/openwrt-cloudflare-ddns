#!/bin/sh

MY_OWNER="$1"
if [ -z "$MY_OWNER" ]; then
    echo "❌ Loi: Thieu tham so. Cu phap: ./sync_config.sh <ten_node_master>"
    exit 1
fi

CONFIG_FILE="cloudflare_ddns"
. /lib/functions.sh

# ==============================================================================
# 🎯 [KHU VỰC QUẢN LÝ FILE ĐỒNG BỘ]
# Sau này muốn thêm/bớt file, bạn CHỈ CẦN THÊM ĐƯỜNG DẪN VÀO DANH SÁCH DƯỚI ĐÂY:
# ==============================================================================
SYNC_FILES="
    /etc/config/cloudflare_ddns
    /etc/init.d/cf-monitor
    /usr/bin/action_update.sh
    /usr/bin/action_delete.sh
    /usr/bin/monitor.sh
    /usr/bin/sync_config.sh
"
# (Ví dụ sau này muốn thêm: chỉ cần xuống dòng thêm /usr/bin/file_moi.sh)
# ==============================================================================

echo "====================================================="
echo "BAT DAU DONG BO CONFIG VA SOURCE CODE TU: [$MY_OWNER]"
echo "====================================================="

# --- Tự động kiểm tra file tồn tại và gom danh sách cần chmod +x ---
VALID_FILES=""
CHMOD_FILES=""

for file in $SYNC_FILES; do
    if [ -e "$file" ]; then
        VALID_FILES="$VALID_FILES $file"
        # Tự động nhận diện file chạy để cấp quyền thực thi
        case "$file" in
            /usr/bin/*|/etc/init.d/*|*.sh)
                CHMOD_FILES="$CHMOD_FILES $file"
                ;;
        esac
    else
        echo "⚠️  [CANH BAO]: File [$file] khong ton tai tren Master! Bo qua."
    fi
done

# Lấy SSH Key của Master từ file config
config_load "$CONFIG_FILE"
config_get MY_SSH_KEY "$MY_OWNER" ssh_key ""

if [ -z "$MY_SSH_KEY" ]; then
    echo "❌ Loi: Khong tim thay 'ssh_key' cua Master [$MY_OWNER] trong File Config!"
    exit 1
fi

# ==================== HÀM ĐỒNG BỘ TỚI TỪNG NODE ====================
sync_to_node() {
    local section="$1"
    local NODE_IP
    
    if [ "$section" = "$MY_OWNER" ]; then return 0; fi

    config_get NODE_IP "$section" ip ""
    if [ -z "$NODE_IP" ]; then return 0; fi

    echo "-----------------------------------------------------"
    echo "🚀 Dang truyen luong Pipe toi Node: [$section] (IP: $NODE_IP)..."

    # Gói tất cả file hợp lệ và bắn qua SSH
    tar -czf - $VALID_FILES 2>/dev/null | \
    ssh -i "$MY_SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        root@"${NODE_IP}" "
            # 0. Kiem tra va cai dat phu thuoc
            for pkg in curl jq; do
                if ! command -v \$pkg >/dev/null 2>&1; then
                    echo '  [INFO] Cai dat goi bi thieu: \$pkg tren [$section]...'
                    if command -v apk >/dev/null 2>&1; then
                        apk update >/dev/null 2>&1
                        apk add \$pkg >/dev/null 2>&1
                    else
                        opkg update >/dev/null 2>&1
                        opkg install \$pkg >/dev/null 2>&1
                    fi
                fi
            done && \

            # 1. Bung nén toàn bộ file vào root /
            tar -xzf - -C / && \
            
            # 2. Tự động chmod +x các file thực thi
            chmod +x $CHMOD_FILES 2>/dev/null && \
            
            # 3. Ghi tên node định danh
            echo '$section' > /etc/cf_node_name && \
            
            # 4. Kích hoạt và khởi động lại dịch vụ
            /etc/init.d/cf-monitor enable && \
            /etc/init.d/cf-monitor restart >/dev/null 2>&1
        "
    
    if [ $? -eq 0 ]; then
        echo "  [OK] Dong bo, Giai nen & Khoi dong Monitor tren [$section] THANH CONG!"
    else
        echo "  [ERROR] Khong the ket noi hoac loi luong Pipe toi [$section]."
    fi
}

# ==================== CHẠY CHO TẤT CẢ SLAVE ====================
config_foreach sync_to_node node

# ==================== KÍCH HOẠT CHO CHÍNH MASTER ====================
echo "-----------------------------------------------------"
echo "Dang thiet lap dich vu cho chinh Master: [$MY_OWNER]..."

# 0. Kiem tra va cai dat phu thuoc cho Master
for pkg in curl jq; do
    if ! command -v $pkg >/dev/null 2>&1; then
        echo "  [INFO] Cai dat goi bi thieu: $pkg tren Master..."
        if command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1
            apk add $pkg >/dev/null 2>&1
        else
            opkg update >/dev/null 2>&1
            opkg install $pkg >/dev/null 2>&1
        fi
    fi
done

chmod +x $CHMOD_FILES 2>/dev/null
echo "$MY_OWNER" > /etc/cf_node_name
/etc/init.d/cf-monitor enable
/etc/init.d/cf-monitor restart >/dev/null 2>&1

echo "  [OK] Master [$MY_OWNER] da kich hoat thanh cong Monitor (Procd)."

echo "====================================================="
echo "✨ HOAN TAT CHU TRINH OTA VA SELF-SETUP!"
echo "====================================================="