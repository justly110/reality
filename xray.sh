#!/bin/bash
# VLESS-Reality 64M极限低内存优化版 (双引擎适配: Debian & Alpine)

if [ "$(id -u)" != "0" ]; then
   echo "错误：请使用 root 权限运行"
   exit 1
fi

# 尝试清理系统缓存释放内存 (在 LXC 容器中可能失效，所以加了 || true)
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

echo "====================================="
echo "1. 自动检测系统并安装必备依赖组件..."
echo "====================================="
if command -v apk >/dev/null 2>&1; then
    apk update
    apk add --no-cache bash curl openssl unzip grep
elif command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl openssl bash unzip grep
fi

# 提前创建所需的所有目录
mkdir -p /usr/local/bin /usr/local/etc/xray /usr/local/share/xray /root/xray_temp

echo -e "\n====================================="
echo "2. 极限低内存模式：开始下载并部署 Xray..."
echo "====================================="
# 为了防止 64M 小鸡爆内存，我们统统放弃官方脚本，全程手动在【硬盘】中操作
MACHINE=$(uname -m)
if [ "$MACHINE" = "x86_64" ]; then
    ZIP_NAME="Xray-linux-64.zip"
elif [ "$MACHINE" = "aarch64" ]; then
    ZIP_NAME="Xray-linux-arm64-v8a.zip"
else
    echo "❌ 不支持的架构: $MACHINE"
    exit 1
fi

VERSION=$(curl -sL -o /dev/null -w %{url_effective} https://github.com/XTLS/Xray-core/releases/latest | grep -oE '[^/]+$')

echo "⬇️ 正在下载 Xray ${VERSION} (直接写入硬盘以防 OOM)..."
# 下载到 /root 目录下 (硬盘) 而不是 /tmp (内存)
curl -sL -o /root/xray_temp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${VERSION}/${ZIP_NAME}"

echo "📦 正在解压..."
unzip -q -o /root/xray_temp/xray.zip -d /root/xray_temp/
mv -f /root/xray_temp/xray /usr/local/bin/

# 【极限优化】直接删除自带的庞大 Geo 数据库文件，不移动，也不让 Xray 载入，节省 10M+ 内存
echo "🗑️ 抛弃臃肿的 Geo 数据文件以节省内存..."
rm -rf /root/xray_temp
chmod +x /usr/local/bin/xray

echo -e "\n====================================="
echo "3. 正在生成高强度加密凭证..."
echo "====================================="
XRAY_BIN="/usr/local/bin/xray"
UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

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
                    "tls"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOF

echo -e "\n====================================="
echo "5. 配置系统服务并限制其内存使用上限..."
echo "====================================="
if command -v systemctl >/dev/null 2>&1; then
    echo "🔧 使用 systemd 注册服务..."
    
    # 写入 systemd 配置文件并注入 Go 内存限制参数
    cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
# 注入内存压缩环境变量
Environment="GOGC=20"
Environment="GOMEMLIMIT=30MiB"
Environment="GODEBUG=madvdontneed=1"
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo "✅ Xray 服务已成功启动！"
    else
        echo "❌ 启动失败，可能是内存仍不足。"
    fi

elif command -v rc-update >/dev/null 2>&1; then
    echo "🔧 使用 OpenRC 注册服务 (Alpine 特供)..."
    
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/var/run/${RC_SVCNAME}.pid"

# 注入内存压缩环境变量
export GOGC=20
export GOMEMLIMIT=30MiB
export GODEBUG=madvdontneed=1

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
        echo "❌ 启动失败，请检查。"
    fi
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
printf "📌 节点端口为 \033[33m%s\033[0m，如果是 NAT 服务器，别忘了配置内网端口映射！\n" "$PORT"
printf "==========================================================================\n"
