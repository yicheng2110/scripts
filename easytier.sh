#!/bin/bash
# ============================================================
# EasyTier 服务模式一键部署脚本 (改进版)
# 功能：自动安装依赖，下载最新版，从外部模板生成配置，
#       安装为系统服务（systemd）
# ============================================================
set -euo pipefail

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- 1. 依赖检测与安装 ---
install_deps() {
    info "正在检测并安装依赖 (curl, unzip, jq)..."
    if command -v curl &>/dev/null && command -v unzip &>/dev/null && command -v jq &>/dev/null; then
        info "所有依赖已满足。"
        return
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_LIKE="${ID_LIKE:-}"
    else
        error "无法识别操作系统！"
    fi

    install_cmd=""
    if [[ "$OS_ID" =~ ^(debian|ubuntu)$ || "$OS_LIKE" =~ (debian|ubuntu) ]]; then
        install_cmd="sudo apt update && sudo apt install -y curl unzip jq"
    elif [[ "$OS_ID" =~ ^(centos|rhel|fedora|ol|rocky|almalinux)$ || "$OS_LIKE" =~ (rhel|fedora) ]]; then
        if command -v dnf &>/dev/null; then
            install_cmd="sudo dnf install -y curl unzip jq"
        else
            install_cmd="sudo yum install -y curl unzip jq"
        fi
    elif [[ "$OS_ID" =~ ^(alpine)$ ]]; then
        install_cmd="sudo apk add curl unzip jq"
    elif [[ "$OS_ID" =~ ^(arch|manjaro)$ ]]; then
        install_cmd="sudo pacman -Syu --noconfirm curl unzip jq"
    elif [[ "$OS_ID" =~ ^(opensuse|sles)$ ]]; then
        install_cmd="sudo zypper install -y curl unzip jq"
    else
        warn "未识别的发行版，请手动安装 curl, unzip, jq 后重试。"
        exit 1
    fi

    echo "执行: $install_cmd"
    eval "$install_cmd" || error "依赖安装失败，请手动安装。"
}

# --- 2. 环境检测与架构映射 ---
OWNER="EasyTier"
REPO="EasyTier"
OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64)   ARCH_PATTERN="x86_64" ;;
    aarch64|arm64) ARCH_PATTERN="aarch64" ;;
    *)        error "不支持的架构: $ARCH_RAW" ;;
esac
PATTERN="${OS_TYPE}-${ARCH_PATTERN}"

# --- 3. 用户交互输入 ---
echo "=========================================="
echo "    EasyTier 服务模式一键部署脚本"
echo "=========================================="

read -p "请输入 GitHub 加速地址 (如 https://ghproxy.com/，不填则直连): " PROXY_URL
[[ -n "$PROXY_URL" && ! "$PROXY_URL" =~ /$ ]] && PROXY_URL="${PROXY_URL}/"

read -p "请输入主机名 [默认: $(hostname)]: " INPUT_HOSTNAME
FINAL_HOSTNAME=${INPUT_HOSTNAME:-$(hostname)}

read -p "请输入虚拟 IPv4 地址 (例如 10.1.1.2): " USER_IP
while [[ ! $USER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
    read -p "[-] IP 格式错误，请重新输入: " USER_IP
done

read -p "请输入网络名称: " NET_NAME
read -p "请输入网络密码: " NET_SECRET

read -p "请输入程序安装目录 [默认: /opt/easytier]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/easytier}

read -p "请输入配置模板文件路径 [默认: ./config.toml.template]: " TEMPLATE_FILE
TEMPLATE_FILE=${TEMPLATE_FILE:-./config.toml.template}

read -p "请输入EasyTier节点地址: " EASYTIER_NODE
EASYTIER_NODE=${EASYTIER_NODE:-tcp://0.0.0.0:11010}

# --- 4. 安装依赖 ---
install_deps

# --- 5. 处理配置模板 ---
if [ ! -f "$TEMPLATE_FILE" ]; then
    warn "未找到模板文件 '$TEMPLATE_FILE'，将使用内置默认模板。"
    # 内置模板
    TEMPLATE_FILE=$(mktemp /tmp/easytier-template-XXXXXX.toml)
    cat > "$TEMPLATE_FILE" <<'EOFINNER'
hostname = "__HOSTNAME__"
instance_name = "easytier-instance"
instance_id = "__INSTANCE_ID__"
ipv4 = "__IPV4__/24"
dhcp = false
listeners = [
    "tcp://0.0.0.0:11010",
    "udp://0.0.0.0:11010",
    "wg://0.0.0.0:11011",
]
rpc_portal = "0.0.0.0:0"

[network_identity]
network_name = "__NETWORK_NAME__"
network_secret = "__NETWORK_SECRET__"

[[peer]]
uri = "__EASYTIER_NODE__"

[flags]
disable_p2p = true
enable_kcp_proxy = true
enable_quic_proxy = true
latency_first = true
EOFINNER
fi

# 生成 instance_id
INSTANCE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "easy-$(date +%s)")

# 生成最终配置文件到 /etc/easytier/config.toml
sudo mkdir -p /etc/easytier

info "正在从模板生成配置文件 /etc/easytier/config.toml ..."
sed -e "s/__HOSTNAME__/${FINAL_HOSTNAME}/g" \
    -e "s/__INSTANCE_ID__/${INSTANCE_ID}/g" \
    -e "s/__IPV4__/${USER_IP}/g" \
    -e "s/__NETWORK_NAME__/${NET_NAME}/g" \
    -e "s/__NETWORK_SECRET__/${NET_SECRET}/g" \
    -e "s|__EASYTIER_NODE__|${EASYTIER_NODE}|g" \
    "$TEMPLATE_FILE" | sudo tee /etc/easytier/config.toml > /dev/null

# --- 6. 下载最新版本 ---
info "正在查询 GitHub 最新 Release 版本..."
API_URL="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
else
    AUTH_HEADER=""
fi
RELEASE_JSON=$(curl -s ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$API_URL")
RAW_URL=$(echo "$RELEASE_JSON" | jq -r --arg PATTERN "$PATTERN" \
    '.assets[] | select(.name | contains($PATTERN)) | select(.name | contains("sha256") | not) | select(.name | contains("gui") | not) | .browser_download_url' | head -1)

if [ -z "$RAW_URL" ] || [ "$RAW_URL" == "null" ]; then
    error "未找到匹配 $PATTERN 的发布资产，请确认架构正确。"
fi

DOWNLOAD_URL="${PROXY_URL}${RAW_URL}"
info "下载地址: $DOWNLOAD_URL"

TMP_FILE=$(mktemp /tmp/easytier-XXXXXX.zip)
curl -L -o "$TMP_FILE" "$DOWNLOAD_URL" || error "下载失败！"

# --- 7. 解压并安装到指定目录 ---
info "正在安装到 ${INSTALL_DIR} ..."
sudo mkdir -p "$INSTALL_DIR"

UNZIP_DIR=$(mktemp -d /tmp/easytier-unzip-XXXXXX)
unzip -q -o "$TMP_FILE" -d "$UNZIP_DIR"

# 全局搜索二进制文件（不依赖目录名）
CORE_FILE=$(find "$UNZIP_DIR" -type f -name easytier-core | head -1)
CLI_FILE=$( find "$UNZIP_DIR" -type f -name easytier-cli  | head -1)

if [[ -z "$CORE_FILE" || -z "$CLI_FILE" ]]; then
    warn "解压后的目录结构（前20个文件）："
    find "$UNZIP_DIR" -type f | head -20
    error "解压后未找到 easytier-core 或 easytier-cli，请检查下载的资产是否正确。"
fi

info "找到 easytier-core: $CORE_FILE"
info "找到 easytier-cli : $CLI_FILE"

sudo cp "$CORE_FILE" "$INSTALL_DIR/easytier-core"
sudo cp "$CLI_FILE"  "$INSTALL_DIR/easytier-cli"
sudo chmod +x "${INSTALL_DIR}/easytier-core" "${INSTALL_DIR}/easytier-cli"

# 创建符号链接方便全局使用
sudo ln -sf "${INSTALL_DIR}/easytier-core" /usr/local/bin/easytier-core
sudo ln -sf "${INSTALL_DIR}/easytier-cli"  /usr/local/bin/easytier-cli

# 清理临时文件
rm -f "$TMP_FILE"
rm -rf "$UNZIP_DIR"

# --- 8. 清理已存在的旧服务 ---
info "检查并清理旧的 EasyTier 服务..."
if systemctl list-unit-files | grep -q '^easytier-core.service'; then
    warn "发现已存在的 easytier-core 服务，正在停止并移除..."
    sudo systemctl stop easytier-core.service 2>/dev/null || true
    sudo systemctl disable easytier-core.service 2>/dev/null || true
    # 尝试卸载（如果旧版 easytier-cli 可用）
    if command -v easytier-cli &>/dev/null; then
        sudo easytier-cli service uninstall 2>/dev/null || true
    fi
    # 手动清理残余的 systemd 文件
    sudo rm -f /etc/systemd/system/easytier-core.service
    sudo rm -f /usr/lib/systemd/system/easytier-core.service
    sudo rm -f /etc/systemd/system/multi-user.target.wants/easytier-core.service
    sudo systemctl daemon-reload
    info "旧服务已清理完毕。"
else
    info "未发现已存在的服务。"
fi

# --- 9. 注册并启动系统服务 ---
info "正在注册系统服务..."
sudo easytier-cli service install -c /etc/easytier/config.toml
info "正在启动服务..."
sudo easytier-cli service start

echo "=========================================="
echo -e "${GREEN}[√] EasyTier 已作为系统服务安装并启动！${NC}"
echo "程序路径: ${INSTALL_DIR}"
echo "配置文件: /etc/easytier/config.toml"
echo "查看状态: sudo systemctl status easytier-core"
echo "查看日志: sudo journalctl -u easytier-core -f"
echo "=========================================="

# 清理内部创建的临时模板（仅当它是我们生成的）
if [[ "$TEMPLATE_FILE" == /tmp/easytier-template-* ]]; then
    rm -f "$TEMPLATE_FILE"
fi
