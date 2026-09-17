#!/bin/bash
# VLESS-Reality 64M极限低内存优化版 (双引擎适配: Debian & Alpine + 双栈双节点 + 后台管理菜单)
# 【双栈纯净直连版：IPv4(30333) + IPv6(30334)】

if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 权限运行"
    exit 1
fi

# 尝试清理系统缓存释放内存
sync; echo 3 2>/dev/null > /proc/sys/vm/drop_caches || true

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
mv -f /root/xray_temp/xray /usr/local/bin/xray-core
rm -rf /root/xray_temp
chmod +x /usr/local/bin/xray-core

echo -e "\n====================================="
echo "3. 正在生成高强度加密凭证与端口分配..."
echo "====================================="
XRAY_BIN="/usr/local/bin/xray-core"
UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)

PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}')
SHORT_ID=$(openssl rand -hex 8)

DEST_SNI="www.java.com"
PORT_V4=30333
PORT_V6=30334

# 检查内核是否支持 IPv6
HAS_IPV6_KERNEL=true
if [ ! -f /proc/net/if_inet6 ]; then
    HAS_IPV6_KERNEL=false
    echo "⚠️ 检测到系统内核已完全禁用 IPv6，将仅启用 IPv4 监听。"
fi

# 保存变量配置到持久化文件供管理脚本使用
{
    echo "PORT_V4=\"$PORT_V4\""
    echo "PORT_V6=\"$PORT_V6\""
    echo "DEST_SNI=\"$DEST_SNI\""
    echo "UUID=\"$UUID\""
    echo "PUBLIC_KEY=\"$PUBLIC_KEY\""
    echo "PRIVATE_KEY=\"$PRIVATE_KEY\""
    echo "SHORT_ID=\"$SHORT_ID\""
    echo "HAS_IPV6_KERNEL=\"$HAS_IPV6_KERNEL\""
} > /usr/local/etc/xray/params.env

echo -e "\n====================================="
echo "4. 正在生成 Xray 配置文件 (IPv4 + IPv6)..."
echo "====================================="

build_inbounds_json() {
    local p4="$1"
    local p6="$2"
    local sni="$3"
    local uuid="$4"
    local priv="$5"
    local sid="$6"
    local has_v6="$7"

    echo "["
    echo "  {"
    echo "    \"tag\": \"vless-v4\","
    echo "    \"listen\": \"0.0.0.0\","
    echo "    \"port\": $p4,"
    echo "    \"protocol\": \"vless\","
    echo "    \"settings\": {"
    echo "      \"clients\": [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}],"
    echo "      \"decryption\": \"none\""
    echo "    },"
    echo "    \"streamSettings\": {"
    echo "      \"network\": \"tcp\","
    echo "      \"security\": \"reality\","
    echo "      \"realitySettings\": {"
    echo "        \"dest\": \"$sni:443\","
    echo "        \"serverNames\": [\"$sni\"],"
    echo "        \"privateKey\": \"$priv\","
    echo "        \"shortIds\": [\"$sid\"]"
    echo "      }"
    echo "    },"
    echo "    \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\"]}"
    echo "  }"
    if [ "$has_v6" = "true" ]; then
        echo "  ,{"
        echo "    \"tag\": \"vless-v6\","
        echo "    \"listen\": \"::\","
        echo "    \"port\": $p6,"
        echo "    \"protocol\": \"vless\","
        echo "    \"settings\": {"
        echo "      \"clients\": [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}],"
        echo "      \"decryption\": \"none\""
        echo "    },"
        echo "    \"streamSettings\": {"
        echo "      \"network\": \"tcp\","
        echo "      \"security\": \"reality\","
        echo "      \"realitySettings\": {"
        echo "        \"dest\": \"$sni:443\","
        echo "        \"serverNames\": [\"$sni\"],"
        echo "        \"privateKey\": \"$priv\","
        echo "        \"shortIds\": [\"$sid\"]"
        echo "      }"
        echo "    },"
        echo "    \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\"]}"
        echo "  }"
    fi
    echo "]"
}

{
    echo "{"
    echo '  "log": {"loglevel": "warning"},'
    echo "  \"inbounds\": $(build_inbounds_json "$PORT_V4" "$PORT_V6" "$DEST_SNI" "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$HAS_IPV6_KERNEL"),"
    echo '  "outbounds": ['
    echo '    {"protocol": "freedom", "tag": "direct"},'
    echo '    {"protocol": "blackhole", "tag": "block"}'
    echo '  ]'
    echo "}"
} > /usr/local/etc/xray/config.json

echo -e "\n====================================="
echo "5. 配置系统服务并限制内存..."
echo "====================================="
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/xray.service << 'EOF_SYSTEMD'
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

export GOGC=20
export GOMEMLIMIT=30MiB
export GODEBUG=madvdontneed=1

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
echo "6. 获取公网 IP 并生成节点链接..."
echo "====================================="
SERVER_IPV4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
SERVER_IPV6=$(curl -s6 -m 5 ip.sb 2>/dev/null || curl -s6 -m 5 ifconfig.me 2>/dev/null || curl -s6 -m 5 api64.ipify.org 2>/dev/null)

if [ -n "$SERVER_IPV4" ]; then
    NODE_LINK_V4="vless://${UUID}@${SERVER_IPV4}:${PORT_V4}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality-IPv4"
else
    NODE_LINK_V4="未检测到公网 IPv4，请手动替换 IP: vless://${UUID}@你的IPv4:${PORT_V4}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality-IPv4"
fi

if [ -n "$SERVER_IPV6" ]; then
    NODE_LINK_V6="vless://${UUID}@[${SERVER_IPV6}]:${PORT_V6}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality-IPv6"
else
    NODE_LINK_V6="未检测到公网 IPv6 地址（若机器带有 IPv6，可自行填入 [IPv6] 使用）"
fi

{
    echo "=========================================================================="
    echo "🎉 VLESS-Reality 节点信息 (双栈双节点版)："
    echo "=========================================================================="
    echo "【1. IPv4 节点】(端口: ${PORT_V4})："
    echo "${NODE_LINK_V4}"
    echo ""
    echo "--------------------------------------------------------------------------"
    echo "【2. IPv6 节点】(端口: ${PORT_V6})："
    echo "${NODE_LINK_V6}"
    echo ""
    echo "--------------------------------------------------------------------------"
    echo "详细参数："
    echo "- IPv4 地址：${SERVER_IPV4:-无} (端口: ${PORT_V4})"
    echo "- IPv6 地址：${SERVER_IPV6:-无} (端口: ${PORT_V6})"
    echo "- 用户ID (UUID)：${UUID}"
    echo "- 流控 (Flow)：xtls-rprx-vision"
    echo "- 传输协议 (Network)：tcp"
    echo "- 伪装域名 (SNI)：${DEST_SNI}"
    echo "- 公钥 (pbk)：${PUBLIC_KEY}"
    echo "- ShortId：${SHORT_ID}"
    echo "=========================================================================="
} > /usr/local/etc/xray/link.txt

# 注入 /usr/local/bin/xray 管理工具 (完全无嵌套 Here-Doc 架构)
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
    local p4="$1"
    local p6="$2"
    local sni="$3"
    local uuid="$4"
    local priv="$5"
    local sid="$6"
    local has_v6="$7"

    echo "["
    echo "  {"
    echo "    \"tag\": \"vless-v4\","
    echo "    \"listen\": \"0.0.0.0\","
    echo "    \"port\": $p4,"
    echo "    \"protocol\": \"vless\","
    echo "    \"settings\": {"
    echo "      \"clients\": [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}],"
    echo "      \"decryption\": \"none\""
    echo "    },"
    echo "    \"streamSettings\": {"
    echo "      \"network\": \"tcp\","
    echo "      \"security\": \"reality\","
    echo "      \"realitySettings\": {"
    echo "        \"dest\": \"$sni:443\","
    echo "        \"serverNames\": [\"$sni\"],"
    echo "        \"privateKey\": \"$priv\","
    echo "        \"shortIds\": [\"$sid\"]"
    echo "      }"
    echo "    },"
    echo "    \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\"]}"
    echo "  }"
    if [ "$has_v6" = "true" ]; then
        echo "  ,{"
        echo "    \"tag\": \"vless-v6\","
        echo "    \"listen\": \"::\","
        echo "    \"port\": $p6,"
        echo "    \"protocol\": \"vless\","
        echo "    \"settings\": {"
        echo "      \"clients\": [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}],"
        echo "      \"decryption\": \"none\""
        echo "    },"
        echo "    \"streamSettings\": {"
        echo "      \"network\": \"tcp\","
        echo "      \"security\": \"reality\","
        echo "      \"realitySettings\": {"
        echo "        \"dest\": \"$sni:443\","
        echo "        \"serverNames\": [\"$sni\"],"
        echo "        \"privateKey\": \"$priv\","
        echo "        \"shortIds\": [\"$sid\"]"
        echo "      }"
        echo "    },"
        echo "    \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\"]}"
        echo "  }"
    fi
    echo "]"
}

rebuild_and_apply() {
    echo -e "\n⏳ 正在更新配置并重启 Xray..."

    # 重构 config.json
    {
        echo "{"
        echo '  "log": {"loglevel": "warning"},'
        echo "  \"inbounds\": $(render_inbounds "$PORT_V4" "$PORT_V6" "$DEST_SNI" "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$HAS_IPV6_KERNEL"),"
        echo '  "outbounds": ['
        echo '    {"protocol": "freedom", "tag": "direct"},'
        echo '    {"protocol": "blackhole", "tag": "block"}'
        echo '  ]'
        echo "}"
    } > "$CONFIG_FILE"

    # 写回参数文件
    {
        echo "PORT_V4=\"$PORT_V4\""
        echo "PORT_V6=\"$PORT_V6\""
        echo "DEST_SNI=\"$DEST_SNI\""
        echo "UUID=\"$UUID\""
        echo "PUBLIC_KEY=\"$PUBLIC_KEY\""
        echo "PRIVATE_KEY=\"$PRIVATE_KEY\""
        echo "SHORT_ID=\"$SHORT_ID\""
        echo "HAS_IPV6_KERNEL=\"$HAS_IPV6_KERNEL\""
    } > "$ENV_FILE"

    do_restart
    sleep 1

    echo "🔍 正在更新节点信息..."
    local s_v4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
    local s_v6=$(curl -s6 -m 5 ip.sb 2>/dev/null || curl -s6 -m 5 ifconfig.me 2>/dev/null || curl -s6 -m 5 api64.ipify.org 2>/dev/null)

    local link_v4=""
    local link_v6=""

    if [ -n "$s_v4" ]; then
        link_v4="vless://${UUID}@${s_v4}:${PORT_V4}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality-IPv4"
    else
        link_v4="未检测到公网 IPv4: vless://${UUID}@你的IPv4:${PORT_V4}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality-IPv4"
    fi

    if [ -n "$s_v6" ]; then
        link_v6="vless://${UUID}@[${s_v6}]:${PORT_V6}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#Reality-IPv6"
    else
        link_v6="未检测到公网 IPv6 地址"
    fi

    {
        echo "=========================================================================="
        echo "🎉 VLESS-Reality 最新节点信息："
        echo "=========================================================================="
        echo "【1. IPv4 节点】(端口: ${PORT_V4})："
        echo "${link_v4}"
        echo ""
        echo "--------------------------------------------------------------------------"
        echo "【2. IPv6 节点】(端口: ${PORT_V6})："
        echo "${link_v6}"
        echo ""
        echo "--------------------------------------------------------------------------"
        echo "详细参数："
        echo "- IPv4 地址：${s_v4:-无} (端口: ${PORT_V4})"
        echo "- IPv6 地址：${s_v6:-无} (端口: ${PORT_V6})"
        echo "- 用户ID (UUID)：${UUID}"
        echo "- 流控 (Flow)：xtls-rprx-vision"
        echo "- 传输协议 (Network)：tcp"
        echo "- 伪装域名 (SNI)：${DEST_SNI}"
        echo "- 公钥 (pbk)：${PUBLIC_KEY}"
        echo "- ShortId：${SHORT_ID}"
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
        echo " 1. 修改 IPv4 监听端口 (当前: $PORT_V4)"
        echo " 2. 修改 IPv6 监听端口 (当前: $PORT_V6)"
        echo " 3. 修改 Reality 伪装域名 (SNI) (当前: $DEST_SNI)"
        echo " 4. 重新生成 UUID (更换用户凭证)"
        echo " 5. 重新生成 Reality 密钥对(Keypair)及 ShortID"
        echo " 6. 批量修改 (IPv4端口 + IPv6端口 + SNI)"
        echo " 0. 返回主菜单"
        echo "=========================================="
        read -p "请输入选项 [0-6]: " opt
        case "$opt" in
            1)
                read -p "请输入新的 IPv4 端口 (1-65535): " new_v4
                if [[ "$new_v4" =~ ^[0-9]+$ ]] && [ "$new_v4" -ge 1 ] && [ "$new_v4" -le 65535 ]; then
                    PORT_V4="$new_v4"
                    rebuild_and_apply
                    break
                else
                    echo -e "\033[31m端口输入不合法！\033[0m"; sleep 1
                fi
                ;;
            2)
                read -p "请输入新的 IPv6 端口 (1-65535): " new_v6
                if [[ "$new_v6" =~ ^[0-9]+$ ]] && [ "$new_v6" -ge 1 ] && [ "$new_v6" -le 65535 ]; then
                    PORT_V6="$new_v6"
                    rebuild_and_apply
                    break
                else
                    echo -e "\033[31m端口输入不合法！\033[0m"; sleep 1
                fi
                ;;
            3)
                read -p "请输入新的伪装域名 SNI (如 www.microsoft.com): " new_sni
                if [ -n "$new_sni" ]; then
                    DEST_SNI="$new_sni"
                    rebuild_and_apply
                    break
                else
                    echo -e "\033[31m域名不能为空！\033[0m"; sleep 1
                fi
                ;;
            4)
                UUID=$($XRAY_BIN uuid)
                echo -e "已生成新 UUID: \033[32m$UUID\033[0m"
                rebuild_and_apply
                break
                ;;
            5)
                KEYS=$($XRAY_BIN x25519)
                PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}')
                PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}')
                SHORT_ID=$(openssl rand -hex 8)
                echo -e "已重新生成公私钥对与 ShortId！"
                rebuild_and_apply
                break
                ;;
            6)
                read -p "请输入新 IPv4 端口 (留空保持 $PORT_V4): " b_v4
                read -p "请输入新 IPv6 端口 (留空保持 $PORT_V6): " b_v6
                read -p "请输入新伪装 SNI (留空保持 $DEST_SNI): " b_sni
                [ -n "$b_v4" ] && PORT_V4="$b_v4"
                [ -n "$b_v6" ] && PORT_V6="$b_v6"
                [ -n "$b_sni" ] && DEST_SNI="$b_sni"
                rebuild_and_apply
                break
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
    read -p "⚠️  确定要彻底卸载 Xray 及其配置与管理脚本吗？[y/N]: " confirm
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
    echo "       Xray-Reality 极简后台管理          "
    echo "=========================================="
    echo -e "服务状态: $(get_status)"
    echo "------------------------------------------"
    echo " 1. 重启 Xray"
    echo " 2. 启动 Xray"
    echo " 3. 停止 Xray"
    echo " 4. 查看节点链接及配置 (IPv4 + IPv6)"
    echo " 5. 修改节点配置 (端口/SNI/UUID/密钥)"
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
echo -e "\033[36m💡 提示：后台管理已安装完成！以后只需在终端输入 \033[1;33mxray\033[0;36m 即可随时打开管理菜单修改配置。\033[0m\n"
