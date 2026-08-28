#!/bin/bash
# VLESS-Reality 一键自动化部署脚本 (双引擎适配版)

# 1. 确保以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "错误：请使用 root 权限运行此脚本"
   exit 1
fi

echo "====================================="
echo "1. 自动检测系统并安装必备依赖组件..."
echo "====================================="
if command -v apk >/dev/null 2>&1; then
    echo "✅ 检测到 Alpine Linux (OpenRC)，正在使用 apk 安装依赖..."
    apk update
    apk add --no-cache bash curl openssl unzip grep
elif command -v apt >/dev/null 2>&1; then
    echo "✅ 检测到 Debian/Ubuntu (systemd)，正在使用 apt 安装依赖..."
    apt update -y
    apt install -y curl openssl bash unzip grep
else
    echo "⚠️ 警告：未识别到 apt 或 apk 包管理器，将尝试跳过依赖安装..."
fi

# 提前创建所需的所有目录
mkdir -p /usr/local/bin /usr/local/etc/xray /usr/local/share/xray

echo -e "\n====================================="
echo "2. 开始安装最新版 Xray-core..."
echo "====================================="
if command -v systemctl >/dev/null 2>&1; then
    echo "✅ 系统支持 systemd，调用官方一键安装脚本..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
else
    echo "✅ 系统为 Alpine (非 systemd)，正在手动下载部署 Xray-core..."
    
    # 获取 CPU 架构
    MACHINE=$(uname -m)
    if [ "$MACHINE" = "x86_64" ]; then
        ZIP_NAME="Xray-linux-64.zip"
    elif [ "$MACHINE" = "aarch64" ]; then
        ZIP_NAME="Xray-linux-arm64-v8a.zip"
    else
        echo "❌ 不支持的架构: $MACHINE"
        exit 1
    fi
    
    # 动态获取最新版本号 (绕过 GitHub API 请求限制)
    VERSION=$(curl -sL -o /dev/null -w %{url_effective} https://github.com/XTLS/Xray-core/releases/latest | grep -oE '[^/]+$')
    
    if [ -z "$VERSION" ]; then
        echo "❌ 无法获取 Xray 最新版本号，请检查网络。"
        exit 1
    fi
    
    echo "⬇️ 正在下载 Xray ${VERSION} (${ZIP_NAME})..."
    curl -sL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${VERSION}/${ZIP_NAME}"
    
    echo "📦 正在解压并配置环境变量..."
    unzip -q -o /tmp/xray.zip -d /tmp/xray_ext
    mv -f /tmp/xray_ext/xray /usr/local/bin/
    mv -f /tmp/xray_ext/geoip.dat /usr/local/share/xray/
    mv -f /tmp/xray_ext/geosite.dat /usr/local/share/xray/
    chmod +x /usr/local/bin/xray
    rm -rf /tmp/xray.zip /tmp/xray_ext
fi

echo -e "\n====================================="
echo "3. 正在生成高强度加密凭证..."
echo "====================================="
# 强制使用绝对路径执行，防止 Alpine 下环境变量未刷新
XRAY_BIN="/usr/local/bin/xray"

if [ ! -f "$XRAY_BIN" ]; then
    echo "❌ 致命错误：Xray 核心二进制文件不存在，安装失败！"
    exit 1
fi

UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# 自定义配置（SNI 与 端口）
DEST_SNI="itunes.apple.com"
PORT=30333

echo -e "\n====================================="
echo "4. 正在生成 Xray 配置文件..."
echo "====================================="
cat > /usr/local/etc/xray/config.json <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": $PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$DEST_SNI:443",
                    "serverNames": [
                        "$DEST_SNI"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [
                        "$SHORT_ID"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOF

echo -e "\n====================================="
echo "5. 配置系统服务并启动 Xray..."
echo "====================================="
if command -v systemctl >/dev/null 2>&1; then
    # Debian / Ubuntu 逻辑
    echo "🔧 使用 systemd 注册服务..."
    systemctl enable xray
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo "✅ Xray 服务已成功启动！"
    else
        echo "❌ 警告：Xray 服务未成功启动，请使用 systemctl status xray 检查错误日志。"
    fi

elif command -v rc-update >/dev/null 2>&1; then
    # Alpine 逻辑
    echo "🔧 使用 OpenRC 注册服务 (Alpine 特供)..."
    
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/var/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after network
}
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart
    sleep 2
    
    if rc-service xray status | grep -q "started"; then
        echo "✅ Xray 服务已成功启动！"
    else
        echo "❌ 警告：Xray 服务未成功启动，请使用 rc-service xray status 检查。"
    fi
else
    echo "⚠️ 警告：系统不支持 systemctl 或 rc-update，请手动运行 Xray。"
fi

echo -e "\n====================================="
echo "6. 生成节点分享链接..."
echo "====================================="
SERVER_IP=$(curl -s -4 ip.sb)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s -4 ifconfig.me)
fi

printf "\n==========================================================================\n"
printf "\033[32m🎉 部署成功！请复制以下 VLESS 链接，导入至客户端：\033[0m\n"
printf "==========================================================================\n\n"
echo "vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#VLESS-Reality-Apple"
printf "\n==========================================================================\n"
printf "📌 温馨提示：\n"
printf "1. 您的节点端口为 \033[33m%s\033[0m，如果是 NAT 服务器，请务必在面板配置内网映射！\n" "$PORT"
printf "2. SNI 伪装域名为 \033[33m%s\033[0m。\n" "$DEST_SNI"
printf "==========================================================================\n"
