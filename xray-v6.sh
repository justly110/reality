#!/bin/bash
# VLESS-Reality IPv6 专用部署脚本
#
# 与 xray.sh 完全隔离：
#   配置目录：/usr/local/etc/xray-ipv6
#   服务名称：xray-ipv6
#   管理命令：xray6
#
# 节点使用 IPv6 时，地址必须写成 [2001:db8::1] 这种方括号格式。

set -u

SCRIPT_VERSION="1.0.0"
BASE_DIR="/usr/local/etc/xray-ipv6"
ENV_FILE="$BASE_DIR/params.env"
CONFIG_FILE="$BASE_DIR/config.json"
LINK_FILE="$BASE_DIR/link.txt"
XRAY_BIN="/usr/local/bin/xray-core-ipv6"
CLI_FILE="/usr/local/bin/xray6"
SERVICE_NAME="xray-ipv6"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
API_PORT=10086

if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 权限运行本脚本"
    exit 1
fi

env_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//"/\\"}
    value=${value//\$/\\\$}
    value=${value//\`/\\\`}
    value=${value//$'\n'/ }
    printf '%s' "$value"
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//"/\\"}
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    printf '%s' "$value"
}

is_ipv6() {
    [[ "$1" == *:* ]] && [[ "$1" != *[!0-9a-fA-F:]* ]]
}

install_dependencies() {
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add --no-cache bash curl openssl unzip
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y bash curl openssl unzip
    else
        echo "错误：仅支持 Debian/Ubuntu 或 Alpine Linux"
        exit 1
    fi
    mkdir -p "$BASE_DIR" /usr/local/bin /root/xray-ipv6-temp
}

install_xray_core() {
    local machine zip_name version temp_dir
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64) zip_name="Xray-linux-64.zip" ;;
        aarch64|arm64) zip_name="Xray-linux-arm64-v8a.zip" ;;
        *) echo "错误：不支持的 CPU 架构：$machine"; exit 1 ;;
    esac

    if [ -x "$XRAY_BIN" ]; then
        return 0
    fi

    version=$(curl -fsSL -m 10 -o /dev/null -w '%{url_effective}' \
        https://github.com/XTLS/Xray-core/releases/latest | grep -oE '[^/]+$') || true
    if [ -z "${version:-}" ]; then
        echo "错误：无法获取 Xray 最新版本"
        exit 1
    fi

    temp_dir=$(mktemp -d)
    if ! curl -fsSL -o "$temp_dir/xray.zip" \
        "https://github.com/XTLS/Xray-core/releases/download/${version}/${zip_name}"; then
        rm -rf "$temp_dir"
        echo "错误：Xray 下载失败"
        exit 1
    fi
    unzip -q "$temp_dir/xray.zip" xray -d "$temp_dir"
    install -m 755 "$temp_dir/xray" "$XRAY_BIN"
    rm -rf "$temp_dir"
}

write_env() {
    {
        echo "IPV6_ADDR=\"$(env_quote "$IPV6_ADDR")\""
        echo "PORT=\"$(env_quote "$PORT")\""
        echo "DEST_SNI=\"$(env_quote "$DEST_SNI")\""
        echo "UUID_DIRECT=\"$(env_quote "$UUID_DIRECT")\""
        echo "UUID_RELAY=\"$(env_quote "$UUID_RELAY")\""
        echo "PUBLIC_KEY=\"$(env_quote "$PUBLIC_KEY")\""
        echo "PRIVATE_KEY=\"$(env_quote "$PRIVATE_KEY")\""
        echo "SHORT_ID=\"$(env_quote "$SHORT_ID")\""
        echo "SS_ADDR=\"$(env_quote "$SS_ADDR")\""
        echo "SS_PORT=\"$(env_quote "$SS_PORT")\""
        echo "SS_PASS=\"$(env_quote "$SS_PASS")\""
        echo "SS_METHOD=\"$(env_quote "$SS_METHOD")\""
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

render_config() {
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {"loglevel": "warning"},
  "stats": {},
  "api": {"tag": "api-ipv6", "services": ["StatsService"]},
  "policy": {"levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}}},
  "inbounds": [
    {
      "tag": "vless-ipv6",
      "listen": "::",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "$(json_escape "$UUID_DIRECT")", "flow": "xtls-rprx-vision", "email": "direct-ipv6"},
          {"id": "$(json_escape "$UUID_RELAY")", "flow": "xtls-rprx-vision", "email": "relay-ipv6"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$(json_escape "$DEST_SNI"):443",
          "serverNames": ["$(json_escape "$DEST_SNI")"],
          "privateKey": "$(json_escape "$PRIVATE_KEY")",
          "shortIds": ["$(json_escape "$SHORT_ID")"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    },
    {
      "tag": "api-ipv6",
      "listen": "::1",
      "port": $API_PORT,
      "protocol": "dokodemo-door",
      "settings": {"address": "::1"},
      "streamSettings": {"network": "tcp"}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "shadowsocks", "tag": "to-egress-ss", "settings": {"servers": [{"address": "$(json_escape "$SS_ADDR")", "port": $SS_PORT, "method": "$(json_escape "$SS_METHOD")", "password": "$(json_escape "$SS_PASS")"}]}}
  ],
  "routing": {"rules": [
    {"type": "field", "inboundTag": ["api-ipv6"], "outboundTag": "direct"},
    {"type": "field", "user": ["relay-ipv6"], "outboundTag": "to-egress-ss"},
    {"type": "field", "user": ["direct-ipv6"], "outboundTag": "direct"}
  ]}
}
EOF
}

write_links() {
    local host="[${IPV6_ADDR}]"
    {
        echo "============================================================"
        echo "VLESS-Reality IPv6 节点配置"
        echo "============================================================"
        echo "IPv6 地址：${IPV6_ADDR}"
        echo "监听端口：${PORT}"
        echo "SNI：${DEST_SNI}"
        echo
        echo "【IPv6 本机直连】"
        echo "vless://${UUID_DIRECT}@${host}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#IPv6-Direct"
        echo
        echo "【IPv6 落地转发】"
        echo "vless://${UUID_RELAY}@${host}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#IPv6-Relay"
        echo "============================================================"
    } > "$LINK_FILE"
    chmod 600 "$LINK_FILE"
}

write_service() {
    if command -v systemctl >/dev/null 2>&1; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray VLESS Reality IPv6 Service
After=network-online.target

[Service]
ExecStart=$XRAY_BIN run -config $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
        systemctl restart "$SERVICE_NAME"
    elif command -v rc-update >/dev/null 2>&1; then
        cat > "/etc/init.d/$SERVICE_NAME" <<EOF
#!/sbin/openrc-run
command="$XRAY_BIN"
command_args="run -config $CONFIG_FILE"
command_background="yes"
pidfile="/run/$SERVICE_NAME.pid"
depend() { need net; after network; }
EOF
        chmod +x "/etc/init.d/$SERVICE_NAME"
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rc-service "$SERVICE_NAME" restart
    else
        echo "警告：未找到 systemd 或 OpenRC，请手动启动 Xray。"
    fi
}

write_cli() {
    cat > "$CLI_FILE" <<'EOF'
#!/bin/bash
BASE_DIR="/usr/local/etc/xray-ipv6"
ENV_FILE="$BASE_DIR/params.env"
LINK_FILE="$BASE_DIR/link.txt"
SERVICE_NAME="xray-ipv6"
[ "$(id -u)" = 0 ] || { echo "请使用 root 权限运行"; exit 1; }
[ -f "$ENV_FILE" ] && source "$ENV_FILE" || { echo "缺少 IPv6 配置"; exit 1; }
status() {
  if command -v systemctl >/dev/null 2>&1; then systemctl is-active --quiet "$SERVICE_NAME" && echo "运行中" || echo "未运行"
  elif command -v rc-service >/dev/null 2>&1; then rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q started && echo "运行中" || echo "未运行"
  else echo "未知"
  fi
}
while true; do
  clear
  echo "=========================================="
  echo "       Xray-Reality IPv6 管理后台         "
  echo "=========================================="
  echo "服务状态：$(status)"
  echo "IPv6 地址：[$IPV6_ADDR]:$PORT"
  echo "------------------------------------------"
  echo "1. 查看 IPv6 节点链接"
  echo "2. 重启 Xray IPv6"
  echo "3. 启动 Xray IPv6"
  echo "4. 停止 Xray IPv6"
  echo "5. 查看运行日志"
  echo "0. 退出"
  read -r -p "请输入选项 [0-5]: " choice </dev/tty
  case "$choice" in
    1) cat "$LINK_FILE"; read -n 1 -s -r -p "按任意键返回..." </dev/tty ;;
    2) systemctl restart "$SERVICE_NAME" 2>/dev/null || rc-service "$SERVICE_NAME" restart; sleep 1 ;;
    3) systemctl start "$SERVICE_NAME" 2>/dev/null || rc-service "$SERVICE_NAME" start; sleep 1 ;;
    4) systemctl stop "$SERVICE_NAME" 2>/dev/null || rc-service "$SERVICE_NAME" stop; sleep 1 ;;
    5) journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null || tail -n 30 /var/log/messages; read -n 1 -s -r -p "按任意键返回..." </dev/tty ;;
    0) exit 0 ;;
  esac
done
EOF
    chmod 755 "$CLI_FILE"
}

initial_config() {
    read -r -p "请输入服务器公网 IPv6 地址：" IPV6_ADDR </dev/tty
    if ! is_ipv6 "$IPV6_ADDR"; then
        echo "错误：请输入合法 IPv6 地址，例如 2001:db8::1"
        exit 1
    fi
    read -r -p "Reality 端口（默认 443）：" PORT </dev/tty
    PORT=${PORT:-443}
    read -r -p "伪装域名（默认 addons.mozilla.org）：" DEST_SNI </dev/tty
    DEST_SNI=${DEST_SNI:-addons.mozilla.org}
    read -r -p "落地机 IPv6/域名（可留空）：" SS_ADDR </dev/tty
    SS_ADDR=${SS_ADDR:-::1}
    read -r -p "落地 SS 端口（默认 30333）：" SS_PORT </dev/tty
    SS_PORT=${SS_PORT:-30333}
    read -r -s -p "落地 SS 密码（可留空）：" SS_PASS </dev/tty
    echo
    SS_PASS=${SS_PASS:-YOUR_SS_PASSWORD_HERE}
    SS_METHOD="2022-blake3-aes-128-gcm"
    UUID_DIRECT=$($XRAY_BIN uuid)
    UUID_RELAY=$($XRAY_BIN uuid)
    local keys
    keys=$($XRAY_BIN x25519)
    PRIVATE_KEY=$(echo "$keys" | awk '/^PrivateKey:/ {print $2}')
    PUBLIC_KEY=$(echo "$keys" | awk '/PublicKey|Password/ {print $NF}')
    SHORT_ID=$(openssl rand -hex 8)
}

install_dependencies
install_xray_core
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo "检测到已有 IPv6 配置，正在平滑更新服务。"
else
    initial_config
    write_env
fi
render_config
write_service
write_links
write_cli
echo
cat "$LINK_FILE"
echo
echo "部署完成。以后输入 xray6 可打开 IPv6 管理后台。"
