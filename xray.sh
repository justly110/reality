#!/bin/bash
# VLESS-Reality 64M极限低内存优化版 (双引擎适配: Debian & Alpine)
# 【纯净直连版：去除 WARP 分流，直接通过本机网络出站】

if [ "$(id -u)" != "0" ]; then
   echo "错误：请使用 root 权限运行"
   exit 1
fi

# 尝试清理系统缓存释放内存
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

echo "====================================="
echo "1. 安装必备依赖组件..."
echo "====================================="
if command -v apk >/dev/null 2>&1; then
    apk update
    apk add --no-cache bash curl openssl unzip awk
elif command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl openssl bash unzip awk
fi

mkdir -p /usr/local/bin /usr/local/etc/xray /root/xray_temp

echo -e "\n====================================="
echo "2. 极限低内存模式：开始部署 Xray..."
echo "====================================="
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
if [ -z "$VERSION" ]; then
    echo "❌ 无法获取 Xray 最新版本号，请检查网络。"
    exit 1
fi

echo "⬇️ 正在下载 Xray ${VERSION} ..."
curl -sL -o /root/xray_temp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${VERSION}/${ZIP_NAME}"

unzip -q -o /root/xray_temp/xray.zip -d /root/xray_temp/
mv -f /root/xray_temp/xray /usr/local/bin/
rm -rf /root/xray_temp
chmod +x /usr/local/bin/xray

echo -e "\n====================================="
echo "3. 正在生成高强度加密凭证..."
echo "====================================="
XRAY_BIN="/usr/local/bin/xray"
UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)

PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}')
SHORT_ID=$(openssl rand -hex 8)

DEST_SNI="itunes.apple.com"
PORT=30333

echo -e "\n====================================="
echo "4. 正在生成 Xray 配置文件 (纯直连模式)..."
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
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOF

echo -e "\n====================================="
echo "5. 配置系统服务并限制内存..."
echo "====================================="
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
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
elif command -v rc-update >/dev/null 2>&1; then
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/var/run/${RC_SVCNAME}.pid"

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
echo "vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality"
printf "\n==========================================================================\n"
printf "📌 节点配置信息 (纯直连版)：\n"
printf "  - 内网端口：\033[33m%s\033[0m (务必去面板设置外网端口映射！)\n" "$PORT"
printf "  - 公钥 (pbk)：\033[33m%s\033[0m\n" "$PUBLIC_KEY"
printf "==========================================================================\n"
