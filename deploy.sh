#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "=================================================="
echo "    TRIỂN KHAI HẠ TẦNG DNS HOMELAB (GITOPS)      "
echo "=================================================="

# 1. Nạp cấu hình từ .env (nếu có)
if [ -f "$REPO_DIR/.env" ]; then
    echo "[+] Đang nạp cấu hình từ .env..."
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
fi

CLI_ROLE="${1:-}"

# 2. Xác định vai trò (Origin / Replica)
NODE_ROLE="${NODE_ROLE:-}"
if [[ "$CLI_ROLE" =~ ^(origin|primary|master)$ ]]; then
    NODE_ROLE="origin"
elif [[ "$CLI_ROLE" =~ ^(replica|secondary|backup|worker)$ ]]; then
    NODE_ROLE="replica"
fi

# Fallback kiểm tra hostname nếu chưa rõ vai trò
if [ -z "$NODE_ROLE" ]; then
    HOST_LOWER=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    if [[ "$HOST_LOWER" =~ (origin|primary|master) ]]; then
        NODE_ROLE="origin"
    elif [[ "$HOST_LOWER" =~ (replica|secondary|backup) ]]; then
        NODE_ROLE="replica"
    else
        NODE_ROLE="origin" # Mặc định là origin nếu không có thông tin
    fi
fi

# 3. Tự động nhận diện IP nếu chưa cấu hình
# LAN IP
if [ -z "${NODE_LAN_IP:-}" ]; then
    NODE_LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -n1 || true)
    if [ -z "$NODE_LAN_IP" ]; then
        NODE_LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
fi

# Tailscale IP
if [ -z "${NODE_TS_IP:-}" ]; then
    if command -v tailscale >/dev/null 2>&1; then
        NODE_TS_IP=$(tailscale ip -4 2>/dev/null || true)
    elif ip -4 addr show tailscale0 >/dev/null 2>&1; then
        NODE_TS_IP=$(ip -4 addr show tailscale0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
    fi
fi

# Web Bind Address
if [ -n "${NODE_TS_IP:-}" ]; then
    NODE_WEB_BIND="${NODE_TS_IP}:8080"
else
    NODE_WEB_BIND="0.0.0.0:8080"
fi


echo "[*] Node Role:       ${NODE_ROLE^^}"
echo "[*] LAN IP:          ${NODE_LAN_IP:-Chưa xác định}"
echo "[*] Tailscale IP:    ${NODE_TS_IP:-Không phát hiện}"
echo "[*] Web UI Address:  ${NODE_WEB_BIND}"
echo "--------------------------------------------------"

# 4. Bước 1: Khởi tạo & Chạy Unbound Recursive DNS
echo "[1/4] Khởi động Unbound Recursive DNS (127.0.0.1:5335)..."
(
    cd "$REPO_DIR/unbound"
    docker compose up -d
)

echo "[+] Kiểm tra phân giải nội bộ qua Unbound..."
unbound_ready=false
for i in {1..5}; do
    if dig @127.0.0.1 -p 5335 cloudflare.com +short +time=2 +tries=1 > /dev/null 2>&1; then
        unbound_ready=true
        echo "[+] Unbound Recursive DNS hoạt động hoàn hảo!"
        break
    else
        echo "[!] Unbound đang nạp root hints (lần $i/5)..."
        sleep 2
    fi
done

if [ "$unbound_ready" = false ]; then
    echo "[!] Cảnh báo: Unbound chưa sẵn sàng phản hồi ngay, tiếp tục tiến trình..."
fi

# 5. Bước 2: Chuẩn hóa cấu hình AdGuard Home
echo "[2/4] Chuẩn hóa cấu hình AdGuard Home..."
mkdir -p "$REPO_DIR/adguard/confdir" "$REPO_DIR/adguard/workdir"

ADGUARD_CONF="$REPO_DIR/adguard/confdir/AdGuardHome.yaml"
if [ -f "$ADGUARD_CONF" ]; then
    BACKUP_FILE="${ADGUARD_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$ADGUARD_CONF" "$BACKUP_FILE"
    echo "[+] Đã tạo backup cấu hình: $(basename "$BACKUP_FILE")"
fi

# Xác định Password Hash
PW_HASH="${ADGUARD_PASSWORD_HASH:-}"
if [ -z "$PW_HASH" ] && [ -f "$ADGUARD_CONF" ]; then
    PW_HASH=$(grep -m1 "password:" "$ADGUARD_CONF" | awk '{print $2}' || true)
fi
if [ -z "$PW_HASH" ]; then
    # Hash bcrypt mặc định cho mật khẩu 'admin' nếu chưa có cấu hình
    PW_HASH='$2a$10$7mrbv2jBXTFTp34/A14kaOPYKNowDjH6/l8GnNOVu9HxLw6IVCNc2'
fi


# Render template AdGuardHome.yaml an toàn bằng Python
export TEMPLATE_FILE="$REPO_DIR/adguard/AdGuardHome.yaml.template"
export TARGET_FILE="$ADGUARD_CONF"
export NODE_WEB_BIND
export ADGUARD_ADMIN_USER="${ADGUARD_ADMIN_USER:-admin}"
export PW_HASH
export NODE_LAN_IP="${NODE_LAN_IP:-}"
export NODE_TS_IP="${NODE_TS_IP:-}"
export TAILSCALE_DOMAIN="${TAILSCALE_DOMAIN:-}"
export TAILSCALE_DNS_IP="${TAILSCALE_DNS_IP:-100.100.100.100}"
export CLIENTS_FILE="$REPO_DIR/adguard/clients.local.yaml"

python3 - << 'EOF'
import os, re

template_file = os.environ["TEMPLATE_FILE"]
target_file = os.environ["TARGET_FILE"]

with open(template_file, "r") as f:
    content = f.read()

content = content.replace("__NODE_WEB_BIND__", os.environ.get("NODE_WEB_BIND", "0.0.0.0:8080"))
content = content.replace("__ADGUARD_ADMIN_USER__", os.environ.get("ADGUARD_ADMIN_USER", "admin"))
content = content.replace("__ADGUARD_PASSWORD_HASH__", os.environ.get("PW_HASH", ""))

# Xây dựng danh sách bind_hosts
lan_ip = os.environ.get("NODE_LAN_IP", "").strip()
ts_ip = os.environ.get("NODE_TS_IP", "").strip()
hosts = []
if ts_ip:
    hosts.append(f"    - {ts_ip}")
if lan_ip:
    hosts.append(f"    - {lan_ip}")
if not hosts:
    hosts.append("    - 0.0.0.0")
content = content.replace("__NODE_BIND_HOSTS__", "\n".join(hosts))

# Xây dựng upstream Tailscale MagicDNS
ts_domain = os.environ.get("TAILSCALE_DOMAIN", "").strip()
ts_dns_ip = os.environ.get("TAILSCALE_DNS_IP", "100.100.100.100").strip()
if ts_domain:
    content = content.replace("__TAILSCALE_UPSTREAM__", f"    - '[/{ts_domain}/]{ts_dns_ip}'")
else:
    content = content.replace("__TAILSCALE_UPSTREAM__\n", "")

# Xây dựng persistent clients
clients_file = os.environ.get("CLIENTS_FILE", "")
if os.path.isfile(clients_file):
    with open(clients_file, "r") as f:
        clients_raw = f.read().strip()
    if clients_raw:
        clients_indented = re.sub(r'(?m)^', '    ', clients_raw)
        content = content.replace("__CLIENTS_PERSISTENT__", clients_indented)
    else:
        content = content.replace("__CLIENTS_PERSISTENT__", "    []")
else:
    content = content.replace("__CLIENTS_PERSISTENT__", "    []")

with open(target_file, "w") as f:
    f.write(content)
EOF

echo "[+] Đã sinh AdGuardHome.yaml từ template chuẩn hóa."

(
    cd "$REPO_DIR/adguard"
    docker compose restart adguardhome 2>/dev/null || docker compose up -d
)
echo "[+] Container AdGuard Home đã được cập nhật."

# 6. Bước 3: Kiểm tra phân giải qua AdGuard Home
echo "[3/4] Kiểm tra dịch vụ AdGuard Home..."
sleep 2
TEST_IP="${NODE_LAN_IP:-127.0.0.1}"
if dig @"$TEST_IP" cloudflare.com +short +time=2 +tries=1 > /dev/null 2>&1; then
    echo "[+] AdGuard Home (${TEST_IP}:53) phân giải thành công!"
else
    echo "[!] AdGuard Home đang hoàn tất khởi động."
fi

# 7. Bước 4: Thiết lập AdGuardHome-Sync (Nếu là node Origin)
echo "[4/4] Kiểm tra cấu hình AdGuardHome-Sync..."
if [ "$NODE_ROLE" = "origin" ]; then
    SYNC_CONF="$REPO_DIR/adguard-sync/adguardhome-sync.yaml"
    TEMPLATE_SYNC="$REPO_DIR/adguard-sync/adguardhome-sync.yaml.template"

    if [ -z "${ADGUARD_ADMIN_PASSWORD:-}" ] || [ -z "${SYNC_ORIGIN_URL:-}" ] || [ -z "${SYNC_REPLICA_URL:-}" ]; then
        echo "[!] Cảnh báo: Chưa cấu hình đầy đủ ADGUARD_ADMIN_PASSWORD hoặc SYNC_ORIGIN_URL / SYNC_REPLICA_URL trong .env!"
        echo "    Vui lòng thiết lập .env để kích hoạt tự động đồng bộ sang replica."
    else
        sed -e "s|\${SYNC_ORIGIN_URL}|${SYNC_ORIGIN_URL}|g" \
            -e "s|\${SYNC_REPLICA_URL}|${SYNC_REPLICA_URL}|g" \
            -e "s|\${ADGUARD_ADMIN_USER}|${ADGUARD_ADMIN_USER:-admin}|g" \
            -e "s|\${ADGUARD_ADMIN_PASSWORD}|${ADGUARD_ADMIN_PASSWORD}|g" \
            "$TEMPLATE_SYNC" > "$SYNC_CONF"
        chmod 600 "$SYNC_CONF"

        (
            cd "$REPO_DIR/adguard-sync"
            docker compose restart adguardhome-sync 2>/dev/null || docker compose up -d
        )
        echo "[+] AdGuardHome-Sync container đã khởi chạy trên node Origin."
        echo "[+] Trạng thái log sync mới nhất:"
        docker logs --tail 10 adguardhome-sync 2>&1 || true
    fi
else
    echo "[+] Node này đóng vai trò Replica (tiếp nhận cấu hình đồng bộ qua API)."
fi

echo "=================================================="
echo "          TRIỂN KHAI HOÀN TẤT THÀNH CÔNG         "
echo "=================================================="
