#!/bin/bash
# VLESS-Reality 纯净单节点版 (Debian & Alpine + 纯IPv4单栈 + 后台管理)

if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 权限运行"
    exit 1
fi

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
echo "2. 开始部署 Xray..."
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
mv -f /root/xray_temp/xray /usr/local/bin/xray-core
rm -rf /root/xray_temp
chmod +x /usr/local/bin/xray-core

echo -e "\n====================================="
echo "3. 正在生成加密凭证与分配用户 UUID..."
echo "====================================="
XRAY_BIN="/usr/local/bin/xray-core"

UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}')
SHORT_ID=$(openssl rand -hex 8)

DEST_SNI="addons.mozilla.org"
PORT=443

# 保存变量配置到持久化文件供管理脚本使用
{
    echo "PORT=\"$PORT\""
    echo "DEST_SNI=\"$DEST_SNI\""
    echo "UUID=\"$UUID\""
    echo "PUBLIC_KEY=\"$PUBLIC_KEY\""
    echo "PRIVATE_KEY=\"$PRIVATE_KEY\""
    echo "SHORT_ID=\"$SHORT_ID\""
} > /usr/local/etc/xray/params.env

echo -e "\n====================================="
echo "4. 正在生成 Xray 配置文件..."
echo "====================================="

build_inbounds_json() {
    local port="$1"
    local sni="$2"
    local uid="$3"
    local priv="$4"
    local sid="$5"

    cat << EOF
[
  {
    "tag": "vless-v4",
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$uid", "flow": "xtls-rprx-vision"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$sni:443",
        "serverNames": ["$sni"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }
]
EOF
}

{
    echo "{"
    echo '  "log": {"loglevel": "warning"},'
    echo "  \"inbounds\": $(build_inbounds_json "$PORT" "$DEST_SNI" "$UUID" "$PRIVATE_KEY" "$SHORT_ID"),"
    echo '  "outbounds": ['
    echo '    {"protocol": "freedom", "tag": "direct"},'
    echo '    {"protocol": "blackhole", "tag": "block"}'
    echo '  ]'
    echo "}"
} > /usr/local/etc/xray/config.json

echo -e "\n====================================="
echo "5. 配置系统服务..."
echo "====================================="
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/xray.service << 'EOF_SYSTEMD'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/xray-core run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 2
elif command -v rc-update >/dev/null 2>&1; then
    cat > /etc/init.d/xray << 'EOF_OPENRC'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray-core"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/var/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after network
}
EOF_OPENRC
    chmod +x /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart
    sleep 2
fi

echo -e "\n====================================="
echo "6. 获取公网 IPv4 并生成节点链接..."
echo "====================================="
SERVER_IPV4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
HOST_V4="${SERVER_IPV4:-你的本机IPv4}"

LINK="vless://${UUID}@${HOST_V4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality-Node"

{
    echo "=========================================================================="
    echo "🎉 VLESS-Reality 节点配置已就绪"
    echo "=========================================================================="
    echo "● 节点链接: ${LINK}"
    echo "--------------------------------------------------------------------------"
    echo "详细参数："
    echo "- 本机 IPv4: ${SERVER_IPV4:-未检测到 (需手动替换)}"
    echo "- Reality 端口: ${PORT}"
    echo "- 伪装域名 (SNI): ${DEST_SNI}"
    echo "- 公钥 (pbk): ${PUBLIC_KEY}"
    echo "- ShortId: ${SHORT_ID}"
    echo "- 用户 UUID: ${UUID}"
    echo "=========================================================================="
} > /usr/local/etc/xray/link.txt

# 注入 /usr/local/bin/xray 管理脚本
cat > /usr/local/bin/xray << 'EOF_MANAGEMENT_SCRIPT'
#!/bin/bash

ENV_FILE="/usr/local/etc/xray/params.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"
LINK_FILE="/usr/local/etc/xray/link.txt"
XRAY_BIN="/usr/local/bin/xray-core"

load_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    else
        echo "❌ 找不到配置文件 $ENV_FILE"
        exit 1
    fi
}

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

do_restart() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart xray
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service xray restart
    fi
}

render_inbounds() {
    local port="$1"
    local sni="$2"
    local uid="$3"
    local priv="$4"
    local sid="$5"

    cat << EOF
[
  {
    "tag": "vless-v4",
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$uid", "flow": "xtls-rprx-vision"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$sni:443",
        "serverNames": ["$sni"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }
]
EOF
}

rebuild_and_apply() {
    echo -e "\n⏳ 正在更新配置并重启 Xray..."

    # 重构 config.json
    {
        echo "{"
        echo '  "log": {"loglevel": "warning"},'
        echo "  \"inbounds\": $(render_inbounds "$PORT" "$DEST_SNI" "$UUID" "$PRIVATE_KEY" "$SHORT_ID"),"
        echo '  "outbounds": ['
        echo '    {"protocol": "freedom", "tag": "direct"},'
        echo '    {"protocol": "blackhole", "tag": "block"}'
        echo '  ]'
        echo "}"
    } > "$CONFIG_FILE"

    # 写回参数文件
    {
        echo "PORT=\"$PORT\""
        echo "DEST_SNI=\"$DEST_SNI\""
        echo "UUID=\"$UUID\""
        echo "PUBLIC_KEY=\"$PUBLIC_KEY\""
        echo "PRIVATE_KEY=\"$PRIVATE_KEY\""
        echo "SHORT_ID=\"$SHORT_ID\""
    } > "$ENV_FILE"

    do_restart
    sleep 1

    echo "🔍 正在更新节点信息..."
    local s_v4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
    local host_v4="${s_v4:-你的本机IPv4}"

    local l_direct="vless://${UUID}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality-Node"

    {
        echo "=========================================================================="
        echo "🎉 VLESS-Reality 最新节点信息"
        echo "=========================================================================="
        echo "● 节点链接: ${l_direct}"
        echo "--------------------------------------------------------------------------"
        echo "详细参数："
        echo "- 本机 IPv4: ${s_v4:-未检测到 (需手动替换)}"
        echo "- Reality 端口: ${PORT}"
        echo "- 伪装域名 (SNI): ${DEST_SNI}"
        echo "- 公钥 (pbk): ${PUBLIC_KEY}"
        echo "- ShortId: ${SHORT_ID}"
        echo "- 用户 UUID: ${UUID}"
        echo "=========================================================================="
    } > "$LINK_FILE"

    clear
    echo -e "\033[32m✔ 配置已更新并成功重启服务！\033[0m\n"
    cat "$LINK_FILE"
    echo ""
    read -n 1 -s -r -p "按任意键返回管理菜单..."
}

modify_config() {
    load_env
    while true; do
        clear
        echo "=========================================="
        echo "           修改 Xray 节点配置             "
        echo "=========================================="
        echo " 1. 修改 Reality 端口 (当前: $PORT)"
        echo " 2. 修改 Reality 伪装域名 SNI (当前: $DEST_SNI)"
        echo " 3. 重新生成 Reality 密钥对(Keypair)及 ShortID"
        echo " 4. 重新生成用户 UUID"
        echo " 5. 手动输入新的用户 UUID"
        echo "------------------------------------------"
        echo " 0. 返回主菜单"
        echo "=========================================="
        read -p "请输入选项 [0-5]: " opt
        case "$opt" in
            1)
                read -p "请输入新的端口 (1-65535): " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    PORT="$new_port"
                    rebuild_and_apply
                    break
                else
                    echo -e "\033[31m端口输入不合法！\033[0m"; sleep 1
                fi
                ;;
            2)
                read -p "请输入新的伪装域名 SNI (如 addons.mozilla.org): " new_sni
                if [ -n "$new_sni" ]; then
                    DEST_SNI="$new_sni"
                    rebuild_and_apply
                    break
                else
                    echo -e "\033[31m域名不能为空！\033[0m"; sleep 1
                fi
                ;;
            3)
                KEYS=$($XRAY_BIN x25519)
                PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}')
                PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}')
                SHORT_ID=$(openssl rand -hex 8)
                echo -e "已重新生成公私钥对与 ShortId！"
                rebuild_and_apply
                break
                ;;
            4)
                UUID=$($XRAY_BIN uuid)
                echo -e "已重新生成 UUID: \033[32m$UUID\033[0m"
                rebuild_and_apply
                break
                ;;
            5)
                read -p "请输入新的 UUID: " custom_uid
                if [ -n "$custom_uid" ]; then
                    UUID="$custom_uid"
                    rebuild_and_apply
                    break
                fi
                ;;
            0)
                break
                ;;
            *)
                echo -e "\033[31m无效输入！\033[0m"; sleep 1
                ;;
        esac
    done
}

restart_xray() {
    echo -e "\n正在重启 Xray 服务..."
    do_restart
    sleep 1
    echo -e "\033[32m重启成功！\033[0m"
    read -n 1 -s -r -p "按任意键继续..."
}

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

show_info() {
    clear
    if [ -f "$LINK_FILE" ]; then
        cat "$LINK_FILE"
    else
        echo "未找到节点配置信息！"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

show_logs() {
    echo -e "\n正在获取最近 30 行日志 (Ctrl+C 退出)：\n"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u xray -n 30 --no-pager
    else
        echo "Alpine 或未开启 journalctl 的系统请查看: /var/log/messages"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

uninstall_xray() {
    echo ""
    read -p "⚠️ 确定要彻底卸载 Xray 及其配置与管理脚本吗？[y/N]: " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY])
            echo -e "\n正在停止并清理服务..."
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop xray 2>/dev/null || true
                systemctl disable xray 2>/dev/null || true
                rm -f /etc/systemd/system/xray.service
                systemctl daemon-reload
            elif command -v rc-service >/dev/null 2>&1; then
                rc-service xray stop 2>/dev/null || true
                rc-update del xray default 2>/dev/null || true
                rm -f /etc/init.d/xray
            fi

            echo "正在删除核心程序与配置目录..."
            rm -f /usr/local/bin/xray-core
            rm -rf /usr/local/etc/xray
            rm -rf /root/xray_temp

            echo "正在移除管理脚本..."
            rm -f /usr/local/bin/xray

            echo -e "\033[32m🎉 卸载清理完成！\033[0m"
            exit 0
            ;;
        *)
            echo -e "\033[33m已取消卸载。\033[0m"
            sleep 1
            ;;
    esac
}

while true; do
    clear
    echo "=========================================="
    echo "          Xray-Reality 管理后台           "
    echo "=========================================="
    echo -e "服务状态: $(get_status)"
    echo "------------------------------------------"
    echo " 1. 重启 Xray"
    echo " 2. 启动 Xray"
    echo " 3. 停止 Xray"
    echo " 4. 查看节点链接及详细信息"
    echo " 5. 修改节点配置 (端口/SNI/密钥/UUID)"
    echo " 6. 查看运行日志"
    echo " 7. 彻底卸载 Xray"
    echo " 0. 退出菜单"
    echo "=========================================="
    read -p "请输入选项 [0-7]: " choice
    case "$choice" in
        1) restart_xray ;;
        2) start_xray ;;
        3) stop_xray ;;
        4) show_info ;;
        5) modify_config ;;
        6) show_logs ;;
        7) uninstall_xray ;;
        0) clear; exit 0 ;;
        *) 
            echo -e "\033[31m无效输入，请重新选择！\033[0m"
            sleep 1
            ;;
    esac
done
EOF_MANAGEMENT_SCRIPT

chmod +x /usr/local/bin/xray

# 打印初始信息
cat /usr/local/etc/xray/link.txt
echo -e "\033[36m💡 提示：部署完成！以后只需在终端输入 \033[1;33mxray\033[0;36m 即可随时打开管理菜单独立修改各项配置。\033[0m\n"