#!/bin/bash
# VLESS-Reality 64M极限低内存优化版 (双引擎适配: Debian & Alpine + 后台管理菜单)
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
    apk add --no-cache bash curl openssl unzip
elif command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl openssl bash unzip
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
# 将核心程序命名为 xray-core，避免与管理命令冲突
mv -f /root/xray_temp/xray /usr/local/bin/xray-core
rm -rf /root/xray_temp
chmod +x /usr/local/bin/xray-core

echo -e "\n====================================="
echo "3. 正在生成高强度加密凭证..."
echo "====================================="
XRAY_BIN="/usr/local/bin/xray-core"
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
ExecStart=/usr/local/bin/xray-core run -config /usr/local/etc/xray/config.json
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
command="/usr/local/bin/xray-core"
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
echo "6. 生成节点分享链接与管理菜单..."
echo "====================================="
SERVER_IP=$(curl -s -4 ip.sb)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s -4 ifconfig.me)
fi

NODE_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality"

# 保存节点信息到文件，供管理菜单随时查看
cat > /usr/local/etc/xray/link.txt <<EOF
==========================================================================
🎉 VLESS-Reality 节点信息：
==========================================================================
链接：
${NODE_LINK}

详细配置：
- 地址 (Address)：${SERVER_IP}
- 端口 (Port)：${PORT}
- 用户ID (UUID)：${UUID}
- 流控 (Flow)：xtls-rprx-vision
- 传输协议 (Network)：tcp
- 伪装域名 (SNI)：${DEST_SNI}
- 公钥 (pbk)：${PUBLIC_KEY}
- ShortId：${SHORT_ID}
==========================================================================
EOF

# 生成 /usr/local/bin/xray 管理命令
cat > /usr/local/bin/xray << 'EOF'
#!/bin/bash

# 获取运行状态
get_status() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet xray; then
            echo -e "\033[32m● 正在运行 (Running)\033[0m"
        else
            echo -e "\033[31m○ 未运行 (Stopped)\033[0m"
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service xray status 2>/dev/null | grep -q "started"; then
            echo -e "\033[32m● 正在运行 (Running)\033[0m"
        else
            echo -e "\033[31m○ 未运行 (Stopped)\033[0m"
        fi
    fi
}

# 重启
restart_xray() {
    echo -e "\n正在重启 Xray 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart xray
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service xray restart
    fi
    sleep 1
    echo -e "\033[32m重启成功！\033[0m"
    read -n 1 -s -r -p "按任意键继续..."
}

# 启动
start_xray() {
    echo -e "\n正在启动 Xray 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start xray
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service xray start
    fi
    sleep 1
    echo -e "\033[32m启动完成！\033[0m"
    read -n 1 -s -r -p "按任意键继续..."
}

# 停止
stop_xray() {
    echo -e "\n正在停止 Xray 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop xray
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service xray stop
    fi
    sleep 1
    echo -e "\033[33m已停止！\033[0m"
    read -n 1 -s -r -p "按任意键继续..."
}

# 查看节点链接
show_info() {
    clear
    if [ -f /usr/local/etc/xray/link.txt ]; then
        cat /usr/local/etc/xray/link.txt
    else
        echo "未找到节点配置信息！"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# 查看日志
show_logs() {
    echo -e "\n正在获取最近 30 行日志 (Ctrl+C 退出)：\n"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u xray -n 30 --no-pager
    else
        echo "当前系统未启用 journalctl"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# 主菜单循环
while true; do
    clear
    echo "=========================================="
    echo "       Xray-Reality 极简后台管理          "
    echo "=========================================="
    echo -e "服务状态: $(get_status)"
    echo "------------------------------------------"
    echo " 1. 重启 Xray"
    echo " 2. 启动 Xray"
    echo " 3. 停止 Xray"
    echo " 4. 查看节点链接及配置"
    echo " 5. 查看实时运行日志"
    echo " 0. 退出菜单"
    echo "=========================================="
    read -p "请输入选项 [0-5]: " choice
    case "$choice" in
        1) restart_xray ;;
        2) start_xray ;;
        3) stop_xray ;;
        4) show_info ;;
        5) show_logs ;;
        0) clear; exit 0 ;;
        *) 
            echo -e "\033[31m无效输入，请重新选择！\033[0m"
            sleep 1
            ;;
    esac
done
EOF

chmod +x /usr/local/bin/xray

# 打印初始信息
cat /usr/local/etc/xray/link.txt
echo -e "\033[36m💡 提示：后台管理已安装完成！以后只需在终端输入 \033[1;33mxray\033[0;36m 即可随时打开管理菜单。\033[0m\n"
