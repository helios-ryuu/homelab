#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# Nạp cấu hình từ .env nếu có
if [ -f "$REPO_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
fi

# Giá trị mặc định từ .env hoặc alias
PRIMARY_HOST="${PRIMARY_HOST:-imac}"
PRIMARY_PORT="${PRIMARY_PORT:-}"
PRIMARY_USER="${PRIMARY_USER:-}"

SECONDARY_HOST="${SECONDARY_HOST:-hp}"
SECONDARY_PORT="${SECONDARY_PORT:-}"
SECONDARY_USER="${SECONDARY_USER:-}"

REMOTE_USER="${REMOTE_USER:-}"
REMOTE_DIR="${REMOTE_DIR:-~/homelab}"
REPO_URL="${REPO_URL:-$(git remote get-url origin 2>/dev/null || echo '')}"

show_help() {
    cat << EOF
CÁCH SỬ DỤNG:
    ./deploy-remote.sh [TÙY CHỌN] [SECONDARY_TARGET] [PRIMARY_TARGET]

TÙY CHỌN CHI TIẾT:
    -p, --primary <HOST/ALIAS>      Chỉ định host hoặc SSH alias cho node chính (mặc định: imac)
    -s, --secondary <HOST/ALIAS>    Chỉ định host hoặc SSH alias cho node phụ (mặc định: hp)
    --primary-port <PORT>           Custom SSH port cho node chính (vd: 60222)
    --secondary-port <PORT>         Custom SSH port cho node phụ (vd: 59222)
    -u, --user <USER>               User SSH (nếu không dùng alias)
    -d, --dir <DIR>                 Thư mục repo trên máy đích (mặc định: ~/homelab)
    -h, --help                      Hiển thị hướng dẫn này

VÍ DỤ SỬ DỤNG:
    1. Sử dụng SSH alias trong ~/.ssh/config (Khuyên dùng khi khác port):
       ./deploy-remote.sh hp imac
       HOẶC:
       ./deploy-remote.sh --secondary hp --primary imac

    2. Sử dụng IP và Custom Port chi tiết trực tiếp:
       ./deploy-remote.sh --secondary 100.120.80.88 --secondary-port 59222 \\
                          --primary 100.120.64.5 --primary-port 60222 --user helios

    3. Không truyền tham số (Sử dụng cấu hình đã định nghĩa trong file .env):
       ./deploy-remote.sh
EOF
    exit 0
}

# Phân tích tham số CLI
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -p|--primary)
            PRIMARY_HOST="$2"
            shift 2
            ;;
        --primary-port)
            PRIMARY_PORT="$2"
            shift 2
            ;;
        --primary-user)
            PRIMARY_USER="$2"
            shift 2
            ;;
        -s|--secondary)
            SECONDARY_HOST="$2"
            shift 2
            ;;
        --secondary-port)
            SECONDARY_PORT="$2"
            shift 2
            ;;
        --secondary-user)
            SECONDARY_USER="$2"
            shift 2
            ;;
        -u|--user)
            REMOTE_USER="$2"
            shift 2
            ;;
        -d|--dir)
            REMOTE_DIR="$2"
            shift 2
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Xử lý tham số vị trí: ./deploy-remote.sh <secondary> <primary> HOẶC ngược lại
if [ ${#POSITIONAL_ARGS[@]} -ge 2 ]; then
    SECONDARY_HOST="${POSITIONAL_ARGS[0]}"
    PRIMARY_HOST="${POSITIONAL_ARGS[1]}"
elif [ ${#POSITIONAL_ARGS[@]} -eq 1 ]; then
    SECONDARY_HOST="${POSITIONAL_ARGS[0]}"
fi

# Áp dụng REMOTE_USER chung nếu user con chưa đặt
PRIMARY_USER="${PRIMARY_USER:-$REMOTE_USER}"
SECONDARY_USER="${SECONDARY_USER:-$REMOTE_USER}"

echo "=================================================="
echo "    ĐIỀU PHỐI TRIỂN KHAI HOMELAB DNS TỪ FEDORA    "
echo "=================================================="
echo "[*] Secondary Node: ${SECONDARY_HOST}${SECONDARY_PORT:+ (Port: $SECONDARY_PORT)}${SECONDARY_USER:+ (User: $SECONDARY_USER)}"
echo "[*] Primary Node:   ${PRIMARY_HOST}${PRIMARY_PORT:+ (Port: $PRIMARY_PORT)}${PRIMARY_USER:+ (User: $PRIMARY_USER)}"
echo "--------------------------------------------------"

if [ -z "$PRIMARY_HOST" ] || [ -z "$SECONDARY_HOST" ]; then
    echo "[-] LỖI: Bắt buộc phải xác định PRIMARY_HOST và SECONDARY_HOST!"
    echo "    Chạy ./deploy-remote.sh --help để xem hướng dẫn chi tiết."
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

# Hàm thực thi SSH với hỗ trợ alias hoặc custom port
ssh_exec() {
    local host="$1"
    local port="$2"
    local user="$3"
    shift 3

    local ssh_args=("-o" "BatchMode=no")
    if [ -n "$port" ]; then
        ssh_args+=("-p" "$port")
    fi

    local target="$host"
    if [ -n "$user" ] && [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        target="${user}@${host}"
    fi

    ssh "${ssh_args[@]}" "$target" "$@"
}

# Hàm thực thi SCP với hỗ trợ alias hoặc custom port
scp_exec() {
    local port="$1"
    local user="$2"
    local src="$3"
    local host="$4"
    local dest="$5"

    local scp_args=("-q")
    if [ -n "$port" ]; then
        scp_args+=("-P" "$port")
    fi

    local target="$host"
    if [ -n "$user" ] && [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        target="${user}@${host}"
    fi

    scp "${scp_args[@]}" "$src" "${target}:${dest}"
}

# Hàm deploy tới một node từ xa
deploy_node() {
    local host="$1"
    local port="$2"
    local user="$3"
    local role="$4"
    local label="$5"

    echo "--------------------------------------------------"
    echo "[*] Bắt đầu triển khai trên ${label} (${host}${port:+:$port})..."

    # 1. Kiểm tra và clone/pull repo trên node từ xa
    ssh_exec "$host" "$port" "$user" bash -s -- "${REMOTE_DIR}" "${REPO_URL}" << 'EOF'
        set -euo pipefail
        target_dir="$1"
        repo_url="$2"
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

    # 2. Lấy đường dẫn thư mục đích mở rộng trên máy đích
    local expanded_remote_dir
    expanded_remote_dir=$(ssh_exec "$host" "$port" "$user" "echo ${REMOTE_DIR}")

    # Truyền clients.local.yaml nếu có
    if [ -f "$REPO_DIR/adguard/clients.local.yaml" ]; then
        echo "[+] Đang truyền adguard/clients.local.yaml sang ${host}..."
        scp_exec "$port" "$user" "$REPO_DIR/adguard/clients.local.yaml" "$host" "${expanded_remote_dir}/adguard/clients.local.yaml"
    fi

    # Truyền .env nếu có
    if [ -f "$REPO_DIR/.env" ]; then
        echo "[+] Đang truyền file cấu hình .env sang ${host}..."
        scp_exec "$port" "$user" "$REPO_DIR/.env" "$host" "${expanded_remote_dir}/.env"
    fi

    # 3. Chạy script deploy.sh với tham số role rõ ràng trên node từ xa
    echo "[+] Đang chạy deploy.sh (${role}) trên ${host}..."
    ssh_exec "$host" "$port" "$user" bash -s -- "${REMOTE_DIR}" "${role}" << 'EOF'
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
deploy_node "${SECONDARY_HOST}" "${SECONDARY_PORT}" "${SECONDARY_USER}" "replica" "Secondary Node (Replica)"

# 3. Triển khai Primary Node (Origin) sau
echo "[3/4] Triển khai Primary Node (Origin)..."
deploy_node "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${PRIMARY_USER}" "origin" "Primary Node (Origin)"

# 4. Kiểm thử sau triển khai (Canary Verification)
echo "--------------------------------------------------"
echo "[4/4] Kiểm thử Canary DNS..."
test_node_dns() {
    local host="$1"
    local port="$2"
    local user="$3"
    local label="$4"

    # Lấy IP thực tế của máy đích để query DNS
    local query_ip
    query_ip=$(ssh_exec "$host" "$port" "$user" "tailscale ip -4 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -n1 || hostname -I | awk '{print \$1}'" 2>/dev/null || true)
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
    test_node_dns "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${PRIMARY_USER}" "Primary Node"
    test_node_dns "${SECONDARY_HOST}" "${SECONDARY_PORT}" "${SECONDARY_USER}" "Secondary Node"

    # Kiểm tra phân giải internet recursive qua Primary node
    primary_ip=$(ssh_exec "${PRIMARY_HOST}" "${PRIMARY_PORT}" "${PRIMARY_USER}" "tailscale ip -4 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -n1 || hostname -I | awk '{print \$1}'" 2>/dev/null || echo "${PRIMARY_HOST}")
    primary_ip=$(echo "$primary_ip" | tr -d '[:space:]')
    echo -n "Kiểm tra phân giải recursive internet qua Unbound (${primary_ip}): "
    res_cf=$(dig @"${primary_ip}" cloudflare.com +short +time=2 +tries=1 2>/dev/null || true)
    if [ -n "$res_cf" ] && [[ ! "$res_cf" =~ (error|refused) ]]; then
        echo "PASS ($res_cf)"
    else
        echo "FAILED (${res_cf:-no response})"
    fi
else
    echo "Lệnh 'dig' không có sẵn trên máy Fedora để thực hiện kiểm thử tự động."
fi

echo "=================================================="
echo "    TRIỂN KHAI TOÀN CỤM DNS HOMELAB HOÀN TẤT      "
echo "=================================================="
