#!/bin/bash
# VLESS-Reality 一键自动化部署脚本 (双引擎适配版：支持 Debian/Ubuntu & Alpine)

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
    apk add --no-cache bash curl openssl
elif command -v apt >/dev/null 2>&1; then
    echo "✅ 检测到 Debian/Ubuntu (systemd)，正在使用 apt 安装依赖..."
    apt update -y
    apt install -y curl openssl bash
else
    echo "⚠️ 警告：未识别到 apt 或 apk 包管理器，将尝试跳过依赖安装..."
fi

echo -e "\n====================================="
echo "2. 开始安装最新版 Xray-core..."
echo "====================================="
# 调用官方脚本，官方脚本内部会自动根据 x86/arm 架构下载对应文件
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

echo -e "\n====================================="
echo "3. 正在生成高强度加密凭证..."
echo "====================================="
UUID=$(xray uuid)
KEYS=$(xray x25519)
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
    # Debian / Ubuntu 的 systemd 启动逻辑
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
    # Alpine 的 OpenRC 启动逻辑
    echo "🔧 使用 OpenRC 注册服务 (Alpine 特供)..."
    
    # 写入 OpenRC 守护脚本
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
    # 赋予执行权限并加入开机自启
    chmod +x /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart
    sleep 2
    
    # 检查运行状态
    if rc-service xray status | grep -q "started"; then
        echo "✅ Xray 服务已成功启动！"
    else
        echo "❌ 警告：Xray 服务未成功启动，请使用 rc-service xray status 检查。"
    fi
else
    echo "⚠️ 警告：系统不支持 systemctl 或 rc-update，无法配置开机自启。请手动运行 Xray。"
fi

echo -e "\n====================================="
echo "6. 生成节点分享链接..."
echo "====================================="
# 获取公网 IPv4
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
