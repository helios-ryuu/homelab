#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# Nạp cấu hình từ .env nếu có
if [ -f "$REPO_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
fi

PRIMARY_HOST="${PRIMARY_HOST:-imac}"
SECONDARY_HOST="${SECONDARY_HOST:-hp}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_DIR="${REMOTE_DIR:-~/homelab}"
REPO_URL="${REPO_URL:-$(git remote get-url origin 2>/dev/null || echo '')}"

echo "=================================================="
echo "    ĐIỀU PHỐI TRIỂN KHAI HOMELAB DNS TỪ FEDORA    "
echo "=================================================="

if [ -z "$PRIMARY_HOST" ] || [ -z "$SECONDARY_HOST" ]; then
    echo "[-] LỖI: Chưa cấu hình PRIMARY_HOST hoặc SECONDARY_HOST!"
    echo "    Vui lòng thiết lập các biến này trong file .env hoặc truyền qua biến môi trường."
    echo "    Ví dụ: PRIMARY_HOST=192.168.1.10 SECONDARY_HOST=192.168.1.20 ./deploy-remote.sh"
    exit 1
fi

# 1. Kiểm tra Git repo cục bộ & push lên origin
echo "[1/4] Kiểm tra Git repo trên Fedora..."
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "[!] Cảnh báo: Có thay đổi chưa commit trên Fedora."
    read -rp "Bạn có muốn tiếp tục push các thay đổi đã commit không? (y/N): " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo "Hủy bỏ triển khai."
        exit 1
    fi
fi

echo "[+] Đang đẩy mã nguồn mới nhất lên Git..."
git push origin main || {
    echo "[-] Lỗi: Không thể push lên Git remote origin main!"
    exit 1
}

# Xác định định dạng đích SSH (ưu tiên giữ nguyên SSH alias như 'imac', 'hp' để dùng custom port)
get_ssh_target() {
    local host="$1"
    if [[ "$host" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        # Là alias trong ~/.ssh/config, giữ nguyên để nhận đúng Port, User, Key
        echo "${host}"
    elif [ -n "${REMOTE_USER:-}" ]; then
        echo "${REMOTE_USER}@${host}"
    else
        echo "${host}"
    fi
}

# Hàm deploy tới một node từ xa
deploy_node() {
    local host="$1"
    local role="$2"
    local label="$3"
    local target
    target=$(get_ssh_target "$host")

    echo "--------------------------------------------------"
    echo "[*] Bắt đầu triển khai trên ${label} (SSH: ${target})..."

    # 1. Kiểm tra và clone/pull repo trên node từ xa
    ssh -o BatchMode=no "${target}" bash -s -- "${REMOTE_DIR}" "${REPO_URL}" << 'EOF'
        set -euo pipefail
        target_dir="$1"
        repo_url="$2"
        # Mở rộng dấu ~ thành thư mục HOME
        target_dir="${target_dir/#\~/$HOME}"

        if [ ! -d "$target_dir/.git" ]; then
            echo "[+] Thư mục repo chưa có trên node đích. Đang clone mới từ Git..."
            mkdir -p "$target_dir"
            git clone "$repo_url" "$target_dir"
        else
            echo "[+] Repo đã tồn tại. Đang cập nhật (git pull)..."
            cd "$target_dir"
            git pull origin main
        fi
EOF

    # 2. Đồng bộ các file cấu hình bảo mật cục bộ (gitignored) từ Fedora sang node đích
    local expanded_remote_dir
    expanded_remote_dir=$(ssh "${target}" "echo ${REMOTE_DIR}")

    # Truyền clients.local.yaml nếu có
    if [ -f "$REPO_DIR/adguard/clients.local.yaml" ]; then
        echo "[+] Đang truyền adguard/clients.local.yaml sang ${host}..."
        scp -q "$REPO_DIR/adguard/clients.local.yaml" "${target}:${expanded_remote_dir}/adguard/clients.local.yaml"
    fi

    # Truyền .env nếu có
    if [ -f "$REPO_DIR/.env" ]; then
        echo "[+] Đang truyền file cấu hình .env sang ${host}..."
        scp -q "$REPO_DIR/.env" "${target}:${expanded_remote_dir}/.env"
    fi

    # 3. Chạy script deploy.sh trên node từ xa
    echo "[+] Đang chạy deploy.sh (${role}) trên ${host}..."
    ssh -o BatchMode=no "${target}" bash -s -- "${REMOTE_DIR}" "${role}" << 'EOF'
        set -euo pipefail
        target_dir="$1"
        role="$2"
        target_dir="${target_dir/#\~/$HOME}"
        cd "$target_dir"
        chmod +x deploy.sh
        ./deploy.sh "$role"
EOF
    echo "[+] Hoàn tất triển khai trên ${label}!"
}

# 2. Triển khai Secondary Node (Replica) trước
echo "[2/4] Triển khai Secondary Node (Replica)..."
deploy_node "${SECONDARY_HOST}" "replica" "Secondary Node (Replica)"

# 3. Triển khai Primary Node (Origin) sau
echo "[3/4] Triển khai Primary Node (Origin)..."
deploy_node "${PRIMARY_HOST}" "origin" "Primary Node (Origin)"

# 4. Kiểm thử sau triển khai (Canary Verification)
echo "--------------------------------------------------"
echo "[4/4] Kiểm thử Canary DNS..."
test_node_dns() {
    local host="$1"
    local label="$2"
    local target
    target=$(get_ssh_target "$host")

    # Lấy IP thực tế của máy đích để query DNS
    local query_ip
    query_ip=$(ssh -o BatchMode=no "${target}" "tailscale ip -4 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -n1 || hostname -I | awk '{print \$1}'" 2>/dev/null || true)
    query_ip=$(echo "$query_ip" | tr -d '[:space:]')
    if [ -z "$query_ip" ]; then
        query_ip="$host"
    fi

    echo -n "Kiểm tra chặn quảng cáo trên ${label} (${query_ip}): "
    local res
    res=$(dig @"${query_ip}" doubleclick.net +short +time=2 +tries=1 2>/dev/null || true)
    if [[ "$res" =~ "0.0.0.0" ]]; then
        echo "PASS (0.0.0.0)"
    else
        echo "FAILED ($res)"
    fi
}

if command -v dig >/dev/null 2>&1; then
    test_node_dns "${PRIMARY_HOST}" "Primary Node"
    test_node_dns "${SECONDARY_HOST}" "Secondary Node"

    # Kiểm tra phân giải internet recursive
    primary_target=$(get_ssh_target "${PRIMARY_HOST}")
    primary_ip=$(ssh -o BatchMode=no "${primary_target}" "tailscale ip -4 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -n1 || hostname -I | awk '{print \$1}'" 2>/dev/null || echo "${PRIMARY_HOST}")
    primary_ip=$(echo "$primary_ip" | tr -d '[:space:]')
    echo -n "Kiểm tra phân giải recursive internet qua Unbound (${primary_ip}): "
    res_cf=$(dig @"${primary_ip}" cloudflare.com +short +time=2 +tries=1 2>/dev/null || true)
    if [ -n "$res_cf" ]; then
        echo "PASS ($res_cf)"
    else
        echo "FAILED"
    fi
else
    echo "Lệnh 'dig' không có sẵn trên máy Fedora để thực hiện kiểm thử tự động."
fi

echo "=================================================="
echo "    TRIỂN KHAI TOÀN CỤM DNS HOMELAB HOÀN TẤT      "
echo "=================================================="
