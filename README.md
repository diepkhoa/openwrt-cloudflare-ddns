# OpenWrt Cloudflare DDNS & Anti-DDoS Multi-Node Mesh

Hệ thống quản lý DDNS và bảo vệ Anti-DDoS multi-node tự động dành cho OpenWrt, tích hợp Cloudflare API và thông báo Telegram.

## 🌟 Tính năng chính

- **Cloudflare DDNS Auto-Update**: Cập nhật bản ghi A (IPv4) và AAAA (IPv6) tự động khi WAN đổi IP.
- **Failover & Healthcheck**: Giám sát kết nối các node trong mạng mesh thông qua WireGuard / Ping.
- **Tự động khôi phục (Cascade Recover)**: Phối hợp cập nhật DNS khi node gặp sự cố hoặc khôi phục.
- **Bảo vệ Anti-DDoS**: Tự động hạ giao diện WAN hoặc xóa bản ghi DNS tạm thời khi phát hiện lượng kết nối vượt ngưỡng (`ddos_threshold`).
- **Thông báo Telegram**: Gửi cảnh báo IP update, xóa record hoặc nghẽn mạng qua Telegram Bot.
- **Đồng bộ tự động (OTA Sync)**: Master node tự đồng bộ cấu hình và các file thực thi sang các Worker node qua SSH/SCP.

## 📁 Cấu trúc lưu trữ

- `install.sh`: Script cài đặt tự động dành cho Worker node.
- `sync_config.sh`: Script đồng bộ cấu hình từ Master node sang các Worker node.
- `action_update.sh`: Xử lý cập nhật IP lên Cloudflare DNS API.
- `action_delete.sh`: Xử lý xóa bản ghi DNS khi node bị DOWN hoặc bị DDoS.
- `monitor.sh`: Chạy các luồng giám sát ubus (WAN state), DDoS (conntrack) và Healthcheck.
- `cf-monitor`: Service init.d (procd) quản lý các tiến trình giám sát.
- `cloudflare_ddns.example`: File cấu hình mẫu UCI (OpenWrt).
- `deploy.ps1`: Script PowerShell hỗ trợ deploy từ máy Windows tới Router Master.

## 🚀 Hướng dẫn cài đặt

### 1. Tạo file cấu hình từ file mẫu

Copy file cấu hình mẫu sang `/etc/config/cloudflare_ddns` trên Router Master và điền thông tin thực tế:

```bash
cp cloudflare_ddns.example /etc/config/cloudflare_ddns
nano /etc/config/cloudflare_ddns
```

### 2. Cài đặt trên Worker Node

Chạy lệnh tự động trên các node phụ:

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/diepkhoa/openwrt-cloudflare-ddns/refs/heads/main/install.sh)"
```

### 3. Đồng bộ từ Master Node

Chạy script đồng bộ trên Master node để phân phối cấu hình và khởi chạy các service trên toàn bộ mạng:

```bash
/usr/bin/sync_config.sh <ten_node_master>
```

## ⚠️ Lưu ý bảo mật

- Không push file `/etc/config/cloudflare_ddns` chứa API key thực tế lên Git repository công khai.
- File `.gitignore` đã được cấu hình mặc định để bỏ qua file `cloudflare_ddns`.
