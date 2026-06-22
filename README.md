# OpenWrt Cloudflare DDNS & Anti-DDoS Mesh

An advanced, decentralized, dual-stack (IPv4/IPv6) DDNS orchestrator and automated failover/anti-DDoS system designed specifically for OpenWrt routers. This project allows seamless, zero-touch dynamic IP tracking and robust security evasion, shifting traffic dynamically between direct high-speed routes and secure Cloudflare Tunnels
---

## 🌟 Key Features

*   **⚡ Native Dual-Stack (IPv4/IPv6):** Independently tracks and updates both IPv4 (`A`) and IPv6 (`AAAA`) records on Cloudflare.
*   **🔍 SLAAC IPv6 Target-MAC Tracking:** The master router automatically sniffs its local neighbor table (`ip -6 neigh`) using the MAC address of a target LAN device (e.g., OMV or NAS) to fetch its Global Unicast IPv6 and update DNS without running any local agent on the client.
*   **🛡️ Edge-Level Anti-DDoS (2-Strike Rule):** Automatically monitors local network state table connections (`nf_conntrack_count`). 
    *   *Strike 1:* Temporarily re-dials WAN/PPPoE to shed volumetric attacks.
    *   *Strike 2 (Within 5 mins):* Deep-hides DNS records on Cloudflare and goes into a 10-minute stealth cooldown, forcing clients onto the Cloudflare Tunnel.
*   **🚀 Cascade Failover (The Death Pact):** Integrated with Uptime Kuma. If an edge node goes down, the master automatically cascades-deletes all associated `A` and `AAAA` records, forcing DNS resolution to fall back to the secure Wildcard CNAME Tunnel.
*   **⚙️ Centralized IaC Deployment (OTA Sync):** Fully managed on the Master node. Configure once and push configuration/script updates over-the-air (OTA) to all defined Slaves with a single command.
*   **🤖 Procd Managed Daemon:** Runs as native lightweight OpenWrt system services (`init.d` / `procd`) with automatic crash respawn.

---

## 📐 Architecture Overview

```text
                  +----------------------------------+
                  |         Cloudflare DNS           |
                  +----------------------------------+
                        ^                      ^
             Direct IPv4|                      |Direct IPv6
               (Grey)   |                      | (Grey)
                        v                      v
                  +------------+         +------------+
                  | Router1     | <====== | Router2   |
                  | (IPv4 Edge)| Tailscale (Master)   |
                  +------------+   P2P   +------------+
                                               |
                                               | LAN
                                               v
                                         +------------+
                                         |Local server|
                                         | (Services) |
                                         +------------+
                                               |
         +-------------------------------------+
         v
  [Failover Path] -> Cloudflare Tunnel (Orange Cloud)
```

---

## 🚀 Quick Installation

Execute this one-liner on your main OpenWrt Master router (HK1):

```bash
curl -s -L https://raw.githubusercontent.com/diepkhoa/openwrt-cloudflare-ddns/refs/heads/main/install.sh | sh
```

---

## ⚙️ Configuration Schema

The unified configuration is located at `/etc/config/cloudflare_ddns` on your master node. It governs all nodes and domain routing records:

```text
config global 'settings'
    option enabled '1'
    option API_KEY 'your_global_cloudflare_api_token_here'
    option TELEGRAM_BOT_TOKEN 'your_bot_token_here'
    option TELEGRAM_CHAT_ID 'your_chat_id_here'
    option SCRIPT_UPDATE '/usr/bin/action_update.sh'
    option SCRIPT_DELETE '/usr/bin/action_delete.sh'
    option SCRIPT_MONITOR '/usr/bin/monitor.sh'
    option SCRIPT_SYNC '/usr/bin/sync_config.sh'

# --- NODE DEFINITIONS ---
config node 'router1'
    option ip '100.91.64.111'
    option ssh_key '/root/.ssh/key1'
    option wan_iface 'wan'
    option ddos_threshold '8000' #Connection

config node 'router2'
    option ip '100.86.98.49'
    option ssh_key '/root/.ssh/key2'
    option wan_iface 'pppoe-wan'
    option ddos_threshold '5000'

# --- ROUTING RECORDS ---
config record 'record1'
    option OWNER 'router1'
    option ZONE_NAME 'domain.com'
    option SUBDOMAIN 'sub.domain.com'
    option PROXIED 'false'
    option IPV4 '1'
    option IPV6 '0'
    option TARGET_MAC 'aa:bb:cc:dd:ee:ff' # Default is owner's mac
    option ZONE_ID ''
    option RECORD_ID_V4 ''
    option RECORD_ID_V6 ''
```

---

## 🛠️ CLI Operations

### 1. Over-The-Air (OTA) Sync
Deploy configuration changes and script updates from the Master to all Slaves:
```bash
/usr/bin/sync_config.sh router1
```

### 2. Manual Force Update
Force a state verification and DNS update (verifies remote IP state before issuing API updates):
```bash
/usr/bin/action_update.sh --force local_router
```

### 3. Smart Cascade Deletion
Delete specific records. If `ALL` is selected, it cascades-deletes both `A` and `AAAA` records for all subdomains associated with the target owner to cleanly trigger the Tunnel fallback:
```bash
/usr/bin/action_delete.sh ALL router2
```

---

## 🤖 Uptime Kuma Webhook Integration

Configure a **Webhook** notification in Uptime Kuma with the following URL structure:
```text
http://<router1IP>:8082/cgi-bin/failover?owner=router2
```
*   **Method:** `POST`
*   **Request Body:** `Preset - application/json`

When a node goes down, the `failover` CGI script on Router1 parses Kuma's heartbeat JSON, matches the owner, and triggers the local `action-delete.sh` to failover to the Tunnel. Upon recovery, it automatically SSHes into the slave and triggers a forced update.

---

## 📄 License
This project is licensed under the MIT License - see the LICENSE file for details.
```eof
