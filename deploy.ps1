$MASTER_IP = "192.168.10.1"
$MASTER_USER = "root"
$IDENTITY_FILE = "C:\Users\PCK\.ssh\windows\id_ed25519"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " BAT DAU DEPLOY CODE TU WINDOWS LEN HK1" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# 1. Đẩy file cấu hình
Write-Host "[1/3] Dang day file config cloudflare_ddns..."
scp -O -i $IDENTITY_FILE -o StrictHostKeyChecking=no cloudflare_ddns ${MASTER_USER}@${MASTER_IP}:/etc/config/cloudflare_ddns

# 2. Đẩy các file script
Write-Host "[2/3] Dang day cac file sh..."
scp -O -i $IDENTITY_FILE -o StrictHostKeyChecking=no action_update.sh action_delete.sh monitor.sh sync_config.sh ${MASTER_USER}@${MASTER_IP}:/usr/bin/
scp -O -i $IDENTITY_FILE -o StrictHostKeyChecking=no cf-monitor ${MASTER_USER}@${MASTER_IP}:/etc/init.d/cf-monitor

# 3. Chạy script đồng bộ trên Master
Write-Host "[3/3] Chuyen tiep toan bo..."
ssh -i $IDENTITY_FILE -o StrictHostKeyChecking=no ${MASTER_USER}@${MASTER_IP} "chmod +x /usr/bin/*.sh /etc/init.d/cf-monitor && cd /usr/bin && ./sync_config.sh snr3053"

Write-Host "=========================================" -ForegroundColor Green
Write-Host " DEPLOY HOAN TAT!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
