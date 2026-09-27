#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# Nạp cấu hình từ .env nếu có
if [ -f "$REPO_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
fi

PRIMARY_HOST="${PRIMARY_HOST:-}"
SECONDARY_HOST="${SECONDARY_HOST:-}"
REMOTE_USER="${REMOTE_USER:-$USER}"
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

# Hàm deploy tới một node từ xa
deploy_node() {
    local host="$1"
    local role="$2"
    local label="$3"

    echo "--------------------------------------------------"
    echo "[*] Bắt đầu triển khai trên ${label} (${REMOTE_USER}@${host})..."

    # 1. Kiểm tra và clone/pull repo trên node từ xa
    ssh -o BatchMode=no "${REMOTE_USER}@${host}" bash -s -- "${REMOTE_DIR}" "${REPO_URL}" << 'EOF'
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
    expanded_remote_dir=$(ssh "${REMOTE_USER}@${host}" "echo ${REMOTE_DIR}")

    # Truyền clients.local.yaml nếu có
    if [ -f "$REPO_DIR/adguard/clients.local.yaml" ]; then
        echo "[+] Đang truyền adguard/clients.local.yaml sang ${host}..."
        scp -q "$REPO_DIR/adguard/clients.local.yaml" "${REMOTE_USER}@${host}:${expanded_remote_dir}/adguard/clients.local.yaml"
    fi

    # Truyền .env nếu có
    if [ -f "$REPO_DIR/.env" ]; then
        echo "[+] Đang truyền file cấu hình .env sang ${host}..."
        scp -q "$REPO_DIR/.env" "${REMOTE_USER}@${host}:${expanded_remote_dir}/.env"
    fi

    # 3. Chạy script deploy.sh trên node từ xa
    echo "[+] Đang chạy deploy.sh (${role}) trên ${host}..."
    ssh -o BatchMode=no "${REMOTE_USER}@${host}" bash -s -- "${REMOTE_DIR}" "${role}" << 'EOF'
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
if command -v dig >/dev/null 2>&1; then
    echo -n "Kiểm tra chặn quảng cáo trên Primary (${PRIMARY_HOST}): "
    res_primary=$(dig @"${PRIMARY_HOST}" doubleclick.net +short +time=2 +tries=1 || true)
    if [[ "$res_primary" =~ "0.0.0.0" ]]; then
        echo "PASS (0.0.0.0)"
    else
        echo "FAILED ($res_primary)"
    fi

    echo -n "Kiểm tra chặn quảng cáo trên Secondary (${SECONDARY_HOST}): "
    res_secondary=$(dig @"${SECONDARY_HOST}" doubleclick.net +short +time=2 +tries=1 || true)
    if [[ "$res_secondary" =~ "0.0.0.0" ]]; then
        echo "PASS (0.0.0.0)"
    else
        echo "FAILED ($res_secondary)"
    fi

    echo -n "Kiểm tra phân giải recursive internet qua Unbound (cloudflare.com): "
    res_cf=$(dig @"${PRIMARY_HOST}" cloudflare.com +short +time=2 +tries=1 || true)
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
