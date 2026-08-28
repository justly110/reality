#!/bin/bash
# VLESS-Reality 一键自动化部署脚本

# 1. 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 权限运行此脚本"
   exit 1
fi

echo "====================================="
echo "1. 开始安装最新版 Xray-core..."
echo "====================================="
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

echo -e "\n====================================="
echo "2. 正在生成高强度加密凭证..."
echo "====================================="
# 生成随机凭证
UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# 自定义配置（SNI 与 端口）
DEST_SNI="itunes.apple.com"
PORT=30333

echo -e "\n====================================="
echo "3. 正在生成 Xray 配置文件..."
echo "====================================="
# 写入标准 Reality 配置
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
echo "4. 重启 Xray 服务并设置开机自启..."
echo "====================================="
systemctl enable xray
systemctl restart xray
sleep 2

# 简单检查一下服务状态
if systemctl is-active --quiet xray; then
    echo "Xray 服务已成功启动！"
else
    echo "警告：Xray 服务未成功启动，请使用 systemctl status xray 检查错误日志。"
fi

echo -e "\n====================================="
echo "5. 生成节点分享链接..."
echo "====================================="
# 获取公网 IPv4
SERVER_IP=$(curl -s -4 ip.sb)
# 如果获取失败，尝试备用接口
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s -4 ifconfig.me)
fi

echo -e "\n=========================================================================="
echo -e "\033[32m部署成功！请复制以下 VLESS 链接，导入至客户端 (v2rayN / Shadowrocket 等)：\033[0m"
echo -e "==========================================================================\n"
echo "vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#VLESS-Reality-Apple"
echo -e "\n=========================================================================="
echo -e "温馨提示："
echo -e "1. 您的节点端口为 \033[33m${PORT}\033[0m，请确保云服务商的防火墙（安全组）已放行此 TCP 端口。"
echo -e "2. SNI 伪装域名为 \033[33m${DEST_SNI}\033[0m。"
echo -e "=========================================================================="
