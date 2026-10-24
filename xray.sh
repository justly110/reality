#!/bin/bash
# ==============================================================================
# VLESS-Reality 直连版 (Debian & Alpine + 纯IPv4单栈)
# 特性：
# 1. 首页清晰显示管理脚本版本与 Xray 内核版本
# 2. 深度网络内核调优 (32MB TCP 动态缓冲区 + BBR + FQ，适配高延迟长肥管道)
# 3. Xray 传输层性能调优 (启用 TCP Fast Open + 15s KeepAlive，禁用服务端嗅探)
# 4. TCP BBR 状态检测、环境识别与一键网络加速调优
# 5. 修改 SNI 伪装域名自动握手与证书体积极速体检
# 6. 低内存 (<=256MB) 自动注入防 OOM 调优参数
# 7. Xray 内核与管理脚本在线独立检查升级
# ==============================================================================

SCRIPT_VERSION="0.0.14"
SCRIPT_URL="https://github.com/justly110/reality/raw/main/xray.sh"

ENV_FILE="/usr/local/etc/xray/params.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"
LINK_FILE="/usr/local/etc/xray/link.txt"
EXTRA_NODES_FILE="/usr/local/etc/xray/extra_nodes.env"
XRAY_BIN="/usr/local/bin/xray-core"

if [ "$(id -u)" != "0" ]; then
    echo "❌ 错误：请使用 root 权限运行本脚本"
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. 检查现有配置完整度与辅助工具
# ------------------------------------------------------------------------------
# JSON 字符串转义，防止密码/域名中的引号与反斜杠破坏 config.json
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

# 写入可被 source 的赋值行，值中的特殊字符一律转义
env_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//\$/\\\$}
    s=${s//\`/\\\`}
    s=${s//$'\n'/ }
    printf '%s' "$s"
}

# 深度网络内核调优 (长肥管道与高延迟优化)
optimize_network() {
    echo "====================================="
    echo "🚀 正在调优系统 TCP 缓冲区与网络参数..."
    echo "====================================="
    modprobe tcp_bbr 2>/dev/null || true

    local params=(
        "net.ipv4.tcp_window_scaling"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.rmem_default"
        "net.core.wmem_default"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_mtu_probing"
        "net.ipv4.tcp_notsent_lowat"
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
    )
    for p in "${params[@]}"; do
        sed -i "/^${p}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
    done

    cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p >/dev/null 2>&1 || true
    echo "✔ 网络参数优化完成！"
}

is_config_complete() {
    [ -f "$ENV_FILE" ] || return 1
    local PORT DEST_SNI UUID_DIRECT PUBLIC_KEY PRIVATE_KEY SHORT_ID
    eval "$(grep -E '^(PORT|DEST_SNI|UUID_DIRECT|PUBLIC_KEY|PRIVATE_KEY|SHORT_ID)=' "$ENV_FILE" 2>/dev/null)"
    [ -n "$PORT" ] && \
    [ -n "$DEST_SNI" ] && \
    [ -n "$UUID_DIRECT" ] && \
    [ -n "$PUBLIC_KEY" ] && \
    [ -n "$PRIVATE_KEY" ] && \
    [ -n "$SHORT_ID" ]
}

save_params_env() {
    {
        echo "PORT=\"$(env_quote "$PORT")\""
        echo "DEST_SNI=\"$(env_quote "$DEST_SNI")\""
        echo "UUID_DIRECT=\"$(env_quote "$UUID_DIRECT")\""
        echo "PUBLIC_KEY=\"$(env_quote "$PUBLIC_KEY")\""
        echo "PRIVATE_KEY=\"$(env_quote "$PRIVATE_KEY")\""
        echo "SHORT_ID=\"$(env_quote "$SHORT_ID")\""
    } > "$ENV_FILE"
}

install_dependencies() {
    echo "====================================="
    echo "📦 正在检查并安装基础依赖组件..."
    echo "====================================="
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add --no-cache bash curl openssl unzip cronie
    elif command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y curl openssl bash unzip cron
    fi
    mkdir -p /usr/local/bin /usr/local/etc/xray /root/xray_temp
}

install_xray_core() {
    echo "====================================="
    echo "⬇️ 正在检查/部署 Xray 核心程序..."
    echo "====================================="
    local MACHINE=$(uname -m)
    local ZIP_NAME=""
    if [ "$MACHINE" = "x86_64" ] || [ "$MACHINE" = "amd64" ]; then
        ZIP_NAME="Xray-linux-64.zip"
    elif [ "$MACHINE" = "aarch64" ] || [ "$MACHINE" = "arm64" ]; then
        ZIP_NAME="Xray-linux-arm64-v8a.zip"
    else
        echo "❌ 不支持的 CPU 架构: $MACHINE"
        exit 1
    fi

    local VERSION=$(curl -sL -m 8 -o /dev/null -w %{url_effective} https://github.com/XTLS/Xray-core/releases/latest | grep -oE '[^/]+$')
    if [ -z "$VERSION" ]; then
        if [ -f "$XRAY_BIN" ]; then
            echo "⚠️ 无法获取 GitHub 最新版本，保留现有内核继续运行。"
            return 0
        fi
        echo "❌ 无法获取 Xray 最新版本号，请检查网络！"
        exit 1
    fi

    echo "正在拉取 Xray 官方发布版 (${VERSION}) ..."
    curl -sL -o /root/xray_temp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${VERSION}/${ZIP_NAME}"
    unzip -q -o /root/xray_temp/xray.zip -d /root/xray_temp/
    mv -f /root/xray_temp/xray "$XRAY_BIN"
    rm -rf /root/xray_temp
    chmod +x "$XRAY_BIN"
    echo "✔ Xray 核心程序就绪！"
}

build_inbounds_json() {
    local port="$1"
    local sni="$2"
    local u_direct="$3"
    local priv="$4"
    local sid="$5"

    sni=$(json_escape "$sni")
    u_direct=$(json_escape "$u_direct")
    priv=$(json_escape "$priv")
    sid=$(json_escape "$sid")

    cat << EOF
[
  {
    "tag": "vless-v4",
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$u_direct", "flow": "xtls-rprx-vision", "email": "direct-local"}
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
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 15
      }
    },
    "sniffing": {"enabled": false}
  }
EOF

    # 循环追加所有扩展 Reality 节点（保证 JSON 语法永远 100% 正确）
    if [ -f "$EXTRA_NODES_FILE" ]; then
        while IFS='|' read -r e_port e_uuid e_sid e_sni e_tag; do
            [ -z "$e_port" ] && continue
            e_uuid=$(json_escape "$e_uuid")
            e_sid=$(json_escape "$e_sid")
            e_sni=$(json_escape "$e_sni")
            cat << EOF
  ,
  {
    "tag": "reality-in-$e_port",
    "listen": "0.0.0.0",
    "port": $e_port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$e_uuid", "flow": "xtls-rprx-vision", "email": "user-$e_port"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$e_sni:443",
        "serverNames": ["$e_sni"],
        "privateKey": "$priv",
        "shortIds": ["$e_sid"]
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 15
      }
    },
    "sniffing": {"enabled": false}
  }
EOF
        done < "$EXTRA_NODES_FILE"
    fi

    echo "]"
}

render_config_json() {
    {
        echo "{"
        echo '  "log": {"loglevel": "warning"},'
        echo "  \"inbounds\": $(build_inbounds_json "$PORT" "$DEST_SNI" "$UUID_DIRECT" "$PRIVATE_KEY" "$SHORT_ID"),"
        echo '  "outbounds": ['
        echo '    {"protocol": "freedom", "tag": "direct"}'
        echo '  ],'
        echo '  "routing": {'
        echo '    "rules": ['
        echo '      {'
        echo '        "type": "field",'
        echo '        "network": "tcp,udp",'
        echo '        "outboundTag": "direct"'
        echo '      }'
        echo '    ]'
        echo '  }'
        echo "}"
    } > "$CONFIG_FILE"
}

write_service() {
    local TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    TOTAL_MEM_MB=${TOTAL_MEM_MB:-512}
    local SYSTEMD_ENV=""
    local OPENRC_ENV=""

    if [ "$TOTAL_MEM_MB" -lt 260 ]; then
        echo -e "💡 检测到当前内存较小 (\033[33m${TOTAL_MEM_MB}MB\033[0m <= 256MB)，\033[32m已自动启用低内存防 OOM 调优参数\033[0m (GOGC=20, GOMEMLIMIT=30MiB, madvdontneed=1)"
        SYSTEMD_ENV=$(cat << 'EOF'
Environment="GOGC=20"
Environment="GOMEMLIMIT=30MiB"
Environment="GODEBUG=madvdontneed=1"
EOF
)
        OPENRC_ENV=$(cat << 'EOF'
export GOGC=20
export GOMEMLIMIT=30MiB
export GODEBUG=madvdontneed=1
EOF
)
    else
        echo "💡 检测到当前机器内存充裕 (${TOTAL_MEM_MB}MB)，使用标准模式运行。"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/xray.service << EOF_SYSTEMD
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
${SYSTEMD_ENV}
ExecStart=/usr/local/bin/xray-core run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
        systemctl restart xray
    elif command -v rc-update >/dev/null 2>&1; then
        {
            echo '#!/sbin/openrc-run'
            echo ''
            echo 'name="xray"'
            echo 'description="Xray Service"'
            echo 'command="/usr/local/bin/xray-core"'
            echo 'command_args="run -c /usr/local/etc/xray/config.json"'
            echo 'command_background="yes"'
            echo 'pidfile="/var/run/${RC_SVCNAME}.pid"'
            echo ''
            [ -n "$OPENRC_ENV" ] && echo "$OPENRC_ENV"
            echo ''
            echo 'depend() {'
            echo '    need net'
            echo '    after network'
            echo '}'
        } > /etc/init.d/xray
        chmod +x /etc/init.d/xray
        rc-update add xray default >/dev/null 2>&1
        rc-service xray restart
    fi
}

clean_traffic_cron() {
    rm -f /etc/cron.d/xray-traffic 2>/dev/null || true
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "xray -s" | grep -v "xray --sync-traffic" | crontab - 2>/dev/null || true
    fi
}

update_links_info() {
    local s_v4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
    local host_v4="${s_v4:-你的本机IPv4}"

    local l_direct="vless://${UUID_DIRECT}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#9929-DE"

    {
        echo "=========================================================================="
        echo "🎉 VLESS-Reality 节点配置列表"
        echo "=========================================================================="
        echo "【主节点：本机直连 (direct-local)】"
        echo "● 节点链接: ${l_direct}"
        echo ""
        echo "--------------------------------------------------------------------------"
        echo "主节点详细参数："
        echo "- 本机 IPv4: ${s_v4:-未检测到 (需手动替换)}"
        echo "- Reality 端口: ${PORT}"
        echo "- 伪装域名 (SNI): ${DEST_SNI}"
        echo "- 公钥 (pbk): ${PUBLIC_KEY}"
        echo "- ShortId: ${SHORT_ID}"
        echo "- 本机直连 UUID: ${UUID_DIRECT}"

        if [ -f "$EXTRA_NODES_FILE" ] && [ -s "$EXTRA_NODES_FILE" ]; then
            echo "=========================================================================="
            echo "【扩展 Reality 节点列表】"
            while IFS='|' read -r e_port e_uuid e_sid e_sni e_tag; do
                [ -z "$e_port" ] && continue
                local e_link="vless://${e_uuid}@${host_v4}:${e_port}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${e_sni}&sid=${e_sid}#${e_tag}"
                echo ""
                echo "● 扩展节点: ${e_tag} (端口: ${e_port})"
                echo "  链接: ${e_link}"
            done < "$EXTRA_NODES_FILE"
        fi
        echo "=========================================================================="
    } > "$LINK_FILE"
}

# ------------------------------------------------------------------------------
# 2. 写入全局管理脚本 /usr/local/bin/xray
# ------------------------------------------------------------------------------
write_management_cli() {
    cat > /usr/local/bin/xray << 'EOF_MANAGEMENT_SCRIPT'
#!/bin/bash

SCRIPT_VERSION="0.0.14"
SCRIPT_URL="https://github.com/justly110/reality/raw/main/xray.sh"

ENV_FILE="/usr/local/etc/xray/params.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"
LINK_FILE="/usr/local/etc/xray/link.txt"
EXTRA_NODES_FILE="/usr/local/etc/xray/extra_nodes.env"
XRAY_BIN="/usr/local/bin/xray-core"

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

env_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//\$/\\\$}
    s=${s//\`/\\\`}
    s=${s//$'\n'/ }
    printf '%s' "$s"
}

load_env() {
    if [ -f "$ENV_FILE" ]; then source "$ENV_FILE"; else echo "❌ 缺少 $ENV_FILE"; exit 1; fi
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

get_xray_core_version() {
    local v=$($XRAY_BIN version 2>/dev/null | head -n 1 | awk '{print $2}')
    [ -n "$v" ] && echo "$v" || echo "未知"
}

# 基础控制封装
do_restart() {
    if command -v systemctl >/dev/null 2>&1; then systemctl restart xray; elif command -v rc-service >/dev/null 2>&1; then rc-service xray restart; fi
}
do_start() {
    if command -v systemctl >/dev/null 2>&1; then systemctl start xray; elif command -v rc-service >/dev/null 2>&1; then rc-service xray start; fi
}
do_stop() {
    if command -v systemctl >/dev/null 2>&1; then systemctl stop xray; elif command -v rc-service >/dev/null 2>&1; then rc-service xray stop; fi
}

# 应用 32MB TCP 动态缓冲区与长肥管道网络参数
apply_sysctl_optimization() {
    modprobe tcp_bbr 2>/dev/null || true
    local params=(
        "net.ipv4.tcp_window_scaling"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.rmem_default"
        "net.core.wmem_default"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_mtu_probing"
        "net.ipv4.tcp_notsent_lowat"
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
    )
    for p in "${params[@]}"; do
        sed -i "/^${p}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
    done
    cat >> /etc/sysctl.conf << 'EOF_SYSCTL'
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF_SYSCTL
    sysctl -p >/dev/null 2>&1 || true
}

# ----------------- TCP BBR 状态检测与网络调优 -----------------
manage_bbr() {
    clear
    echo "=========================================="
    echo "       TCP BBR 加速与网络内核调优         "
    echo "=========================================="
    local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || cat /proc/sys/net/core/default_qdisc 2>/dev/null)
    local cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || true)
    local virt=$(systemd-detect-virt 2>/dev/null || true)

    echo "当前拥塞控制算法 : ${cur_cc:-未知}"
    echo "当前网络队列算法 : ${cur_qdisc:-未知}"
    [ -n "$cur_rmem" ] && echo "核心读缓冲区上限 : $((cur_rmem / 1024 / 1024)) MB"
    [ -n "$virt" ] && echo "底层虚拟化架构   : $virt"
    echo "------------------------------------------"

    local is_container=0
    if [ "$virt" = "lxc" ] || [ "$virt" = "openvz" ] || [ ! -w "/proc/sys/net/ipv4/tcp_congestion_control" ]; then
        is_container=1
    fi

    if [ "$is_container" -eq 1 ]; then
        echo -e "\033[33m⚠️ 提示: 当前 VPS 处于容器虚拟化架构 ($virt) 或内核只读环境。\033[0m"
        echo "该架构下网络协议栈由母鸡宿主机统一接管，无需且无法在小鸡内单独修改 BBR。"
        echo ""
        read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
        return
    fi

    if [ "$cur_cc" = "bbr" ]; then
        echo -e "\033[32m✔ 系统已成功启用 BBR 拥塞控制算法。\033[0m"
        read -p "是否重新应用/刷新 32MB TCP 动态缓冲区参数？[y/N]: " re_opt </dev/tty
        if [[ "$re_opt" =~ ^[yY]$ ]]; then
            apply_sysctl_optimization
            echo -e "\033[32m🎉 网络优化参数刷新成功！\033[0m"
        fi
        echo ""
        read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
        return
    fi

    echo "当前未开启 BBR，系统支持开启。"
    read -p "是否现在一键开启 BBR + FQ 加速并优化 TCP 缓冲区 (32MB)？[Y/n]: " do_bbr </dev/tty
    if [[ ! "$do_bbr" =~ ^[nN]$ ]]; then
        apply_sysctl_optimization
        sleep 1
        local check_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [ "$check_cc" = "bbr" ]; then
            echo -e "\033[32m🎉 BBR 及高带宽 TCP 缓冲区配置成功！\033[0m"
        else
            echo -e "\033[31m❌ 开启失败，可能需要更新系统内核。\033[0m"
        fi
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
}

# ----------------- SNI 伪装域名自动握手与体检 -----------------
verify_sni_health() {
    local sni="$1"
    echo -e "\n⏳ 正在对域名 [$sni] 进行安全与兼容性体检..."

    if ! getent hosts "$sni" >/dev/null 2>&1 && ! ping -c 1 -W 2 "$sni" >/dev/null 2>&1; then
        echo -e "\033[31m❌ 警告: 无法解析域名 $sni，该域名可能不存在！\033[0m"
        read -p "是否强制忽略警告继续使用？[y/N]: " f_use </dev/tty
        [[ "$f_use" =~ ^[yY]$ ]] && return 0 || return 1
    fi

    local tls_out=$(timeout 5 openssl s_client -connect "${sni}:443" -servername "${sni}" -tls1_3 </dev/null 2>&1)
    if ! echo "$tls_out" | grep -qE "Protocol *: *TLSv1.3"; then
        echo -e "\033[31m❌ 严重不推荐: 该域名未通过 TLS 1.3 握手！\033[0m"
        echo -e "   Reality 协议严格依赖 TLS 1.3，使用此域名极易导致客户端断连。"
        read -p "是否强制忽略警告继续使用？[y/N]: " f_use </dev/tty
        [[ "$f_use" =~ ^[yY]$ ]] && return 0 || return 1
    fi

    local cert_bytes=$(echo "$tls_out" | openssl x509 -outform DER 2>/dev/null | wc -c)
    cert_bytes=${cert_bytes:-0}

    if [ "$cert_bytes" -gt 6000 ]; then
        echo -e "\033[33m⚠️ 警告: 该域名证书体积较大 (约 $((cert_bytes/1024)) KB)！\033[0m"
        echo -e "   小内存 VPS 上有超出 Xray 8KB 缓冲区风险，推荐选用小于 5KB 的站点（如 addons.mozilla.org）。"
        read -p "是否确认使用此域名？[Y/n]: " c_use </dev/tty
        [[ "$c_use" =~ ^[nN]$ ]] && return 1
    else
        echo -e "✔ 体检通过: 完美支持 TLS 1.3，证书体积安全 (${cert_bytes} 字节)。"
    fi
    return 0
}

# ----------------- 基础服务与节点重构 -----------------
build_inbounds_json() {
    local port="$1"; local sni="$2"; local u_direct="$3"; local priv="$4"; local sid="$5"
    sni=$(json_escape "$sni"); u_direct=$(json_escape "$u_direct")
    priv=$(json_escape "$priv"); sid=$(json_escape "$sid")
    cat << EOF
[
  {
    "tag": "vless-v4",
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$u_direct", "flow": "xtls-rprx-vision", "email": "direct-local"}
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
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 15
      }
    },
    "sniffing": {"enabled": false}
  }
EOF

    if [ -f "$EXTRA_NODES_FILE" ]; then
        while IFS='|' read -r e_port e_uuid e_sid e_sni e_tag; do
            [ -z "$e_port" ] && continue
            e_uuid=$(json_escape "$e_uuid"); e_sid=$(json_escape "$e_sid"); e_sni=$(json_escape "$e_sni")
            cat << EOF
  ,
  {
    "tag": "reality-in-$e_port",
    "listen": "0.0.0.0",
    "port": $e_port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$e_uuid", "flow": "xtls-rprx-vision", "email": "user-$e_port"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$e_sni:443",
        "serverNames": ["$e_sni"],
        "privateKey": "$priv",
        "shortIds": ["$e_sid"]
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 15
      }
    },
    "sniffing": {"enabled": false}
  }
EOF
        done < "$EXTRA_NODES_FILE"
    fi

    echo "]"
}

rebuild_and_apply() {
    echo -e "\n⏳ 正在更新配置并重启 Xray..."
    {
        echo "{"
        echo '  "log": {"loglevel": "warning"},'
        echo "  \"inbounds\": $(build_inbounds_json "$PORT" "$DEST_SNI" "$UUID_DIRECT" "$PRIVATE_KEY" "$SHORT_ID"),"
        echo '  "outbounds": ['
        echo '    {"protocol": "freedom", "tag": "direct"}'
        echo '  ],'
        echo '  "routing": {'
        echo '    "rules": ['
        echo '      {'
        echo '        "type": "field",'
        echo '        "network": "tcp,udp",'
        echo '        "outboundTag": "direct"'
        echo '      }'
        echo '    ]'
        echo '  }'
        echo "}"
    } > "$CONFIG_FILE"

    {
        echo "PORT=\"$(env_quote "$PORT")\""
        echo "DEST_SNI=\"$(env_quote "$DEST_SNI")\""
        echo "UUID_DIRECT=\"$(env_quote "$UUID_DIRECT")\""
        echo "PUBLIC_KEY=\"$(env_quote "$PUBLIC_KEY")\""
        echo "PRIVATE_KEY=\"$(env_quote "$PRIVATE_KEY")\""
        echo "SHORT_ID=\"$(env_quote "$SHORT_ID")\""
    } > "$ENV_FILE"

    do_restart
    sleep 1

    local s_v4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
    local host_v4="${s_v4:-你的本机IPv4}"
    local l_direct="vless://${UUID_DIRECT}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#9929-DE"

    {
        echo "=========================================================================="
        echo "🎉 VLESS-Reality 节点配置列表"
        echo "=========================================================================="
        echo "【主节点：本机直连 (direct-local)】"
        echo "● 节点链接: ${l_direct}"
        echo ""
        echo "--------------------------------------------------------------------------"
        echo "主节点详细参数："
        echo "- 本机 IPv4: ${s_v4:-未检测到 (需手动替换)}"
        echo "- Reality 端口: ${PORT}"
        echo "- 伪装域名 (SNI): ${DEST_SNI}"
        echo "- 公钥 (pbk): ${PUBLIC_KEY}"
        echo "- ShortId: ${SHORT_ID}"
        echo "- 本机直连 UUID: ${UUID_DIRECT}"

        if [ -f "$EXTRA_NODES_FILE" ] && [ -s "$EXTRA_NODES_FILE" ]; then
            echo "=========================================================================="
            echo "【扩展 Reality 节点列表】"
            while IFS='|' read -r e_port e_uuid e_sid e_sni e_tag; do
                [ -z "$e_port" ] && continue
                local e_link="vless://${e_uuid}@${host_v4}:${e_port}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${e_sni}&sid=${e_sid}#${e_tag}"
                echo ""
                echo "● 扩展节点: ${e_tag} (端口: ${e_port})"
                echo "  链接: ${e_link}"
            done < "$EXTRA_NODES_FILE"
        fi
        echo "=========================================================================="
    } > "$LINK_FILE"

    clear
    echo -e "\033[32m✔ 配置已更新并成功重启服务！\033[0m\n"
    cat "$LINK_FILE"
    echo ""
    read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
}

modify_config() {
    load_env
    while true; do
        clear
        echo "=========================================="
        echo "           修改 Xray 节点配置             "
        echo "=========================================="
        echo " [基础 Reality 设置]"
        echo " 1. 修改 Reality 端口 (当前: $PORT)"
        echo " 2. 修改 Reality 伪装域名 SNI (带自动体检，当前: $DEST_SNI)"
        echo " 3. 重新生成 Reality 密钥对(Keypair)及 ShortID"
        echo "------------------------------------------"
        echo " [主节点 UUID 管理]"
        echo " 4. 重新生成【本机直连】UUID"
        echo " 5. 手动输入新的【本机直连】UUID"
        echo "------------------------------------------"
        echo " 0. 返回主菜单"
        echo "=========================================="
        read -p "请输入选项 [0-5]: " opt </dev/tty
        case "$opt" in
            1)
                read -p "请输入新的端口 (1-65535): " new_port </dev/tty
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    PORT="$new_port"; rebuild_and_apply; break
                else echo -e "\033[31m端口不合法！\033[0m"; sleep 1; fi
                ;;
            2)
                read -p "请输入新的伪装域名 SNI: " new_sni </dev/tty
                if [ -n "$new_sni" ]; then
                    if verify_sni_health "$new_sni"; then
                        DEST_SNI="$new_sni"; rebuild_and_apply; break
                    fi
                fi
                ;;
            3)
                KEYS=$($XRAY_BIN x25519)
                PRIVATE_KEY=$(echo "$KEYS" | awk '/^PrivateKey:/ {print $2}')
                PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey|Password/ {print $NF}')
                if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
                    echo -e "\033[31m密钥解析失败，已取消。\033[0m"; echo "$KEYS"; sleep 2; break
                fi
                SHORT_ID=$(openssl rand -hex 8)
                rebuild_and_apply; break
                ;;
            4) UUID_DIRECT=$($XRAY_BIN uuid); rebuild_and_apply; break ;;
            5)
                read -p "请输入新的【本机直连】UUID: " custom_uid_dir </dev/tty
                [ -n "$custom_uid_dir" ] && { UUID_DIRECT="$custom_uid_dir"; rebuild_and_apply; break; }
                ;;
            0) break ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

# ----------------- 独立在线升级模块 -----------------
check_and_update_core() {
    clear
    echo "=========================================="
    echo "           检查 Xray 内核更新             "
    echo "=========================================="
    local cur_ver=$(get_xray_core_version)
    cur_ver="v${cur_ver#v}"
    echo "正在获取官方最新版本信息..."
    local latest_ver=$(curl -sL -m 8 -o /dev/null -w %{url_effective} https://github.com/XTLS/Xray-core/releases/latest | grep -oE '[^/]+$')
    latest_ver="v${latest_ver#v}"

    if [ -z "$latest_ver" ] || [ "$latest_ver" = "v" ]; then
        echo -e "\033[31m❌ 无法获取最新版本号，请检查网络！\033[0m"
        read -n 1 -s -r -p "按任意键返回..." </dev/tty
        return
    fi

    echo "当前本地内核版本: $cur_ver"
    echo "官方最新内核版本: $latest_ver"
    echo "------------------------------------------"

    if [ "$cur_ver" = "$latest_ver" ]; then
        echo -e "\033[32m✔ 当前已是最新内核，无需更新！\033[0m"
        read -p "是否强制重新下载覆盖？[y/N]: " force_up </dev/tty
        [[ ! "$force_up" =~ ^[yY]$ ]] && return
    else
        read -p "检测到内核更新，是否立即升级？[Y/n]: " do_up </dev/tty
        [[ "$do_up" =~ ^[nN]$ ]] && return
    fi

    echo -e "\n⏳ 正在拉取 Xray ${latest_ver}..."
    local MACHINE=$(uname -m)
    local ZIP_NAME=""
    [ "$MACHINE" = "x86_64" ] || [ "$MACHINE" = "amd64" ] && ZIP_NAME="Xray-linux-64.zip"
    [ "$MACHINE" = "aarch64" ] || [ "$MACHINE" = "arm64" ] && ZIP_NAME="Xray-linux-arm64-v8a.zip"

    mkdir -p /tmp/xray_update
    if curl -sL -o /tmp/xray_update/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/${ZIP_NAME}"; then
        unzip -q -o /tmp/xray_update/xray.zip -d /tmp/xray_update/
        mv -f /tmp/xray_update/xray "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        rm -rf /tmp/xray_update
        do_restart
        echo -e "\033[32m🎉 Xray 内核已成功更新至 ${latest_ver}！\033[0m"
    else
        echo -e "\033[31m❌ 下载失败，请检查网络！\033[0m"
        rm -rf /tmp/xray_update
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回..." </dev/tty
}

check_and_update_script() {
    clear
    echo "=========================================="
    echo "           检查管理脚本更新               "
    echo "=========================================="
    echo "当前本地脚本版本: $SCRIPT_VERSION"
    local remote_ver=$(curl -sL -m 8 "$SCRIPT_URL" 2>/dev/null | grep -m 1 '^SCRIPT_VERSION=' | cut -d'"' -f2)

    if [ -z "$remote_ver" ]; then
        echo -e "\033[31m❌ 无法获取远程版本，请检查网络！\033[0m"
        read -n 1 -s -r -p "按任意键返回..." </dev/tty
        return
    fi
    echo "远程最新脚本版本: $remote_ver"
    echo "------------------------------------------"

    if [ "$SCRIPT_VERSION" = "$remote_ver" ]; then
        echo -e "\033[32m✔ 当前管理脚本已是最新版本！\033[0m"
        read -p "是否强制重新覆盖？[y/N]: " force_sc </dev/tty
        [[ ! "$force_sc" =~ ^[yY]$ ]] && return
    else
        read -p "检测到脚本更新，是否立即升级？[Y/n]: " do_sc </dev/tty
        [[ "$do_sc" =~ ^[nN]$ ]] && return
    fi

    echo -e "\n⏳ 正在拉取最新脚本并平滑升级..."
    if curl -fsSL "$SCRIPT_URL" -o /tmp/xray_new.sh \
        && grep -q '^SCRIPT_VERSION="' /tmp/xray_new.sh \
        && grep -q 'write_management_cli' /tmp/xray_new.sh; then
        chmod +x /tmp/xray_new.sh
        if ! bash /tmp/xray_new.sh --auto-upgrade </dev/tty; then
            rm -f /tmp/xray_new.sh
            echo "管理脚本升级失败，请检查上方错误信息。"
            return 1
        fi
        rm -f /tmp/xray_new.sh
        echo -e "\033[32m🎉 管理脚本升级完成！\033[0m"
        exit 0
    fi
    rm -f /tmp/xray_new.sh
    echo -e "\033[31m❌ 下载内容校验失败，已取消升级。\033[0m"
    read -n 1 -s -r -p "按任意键返回..." </dev/tty
}

update_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "           Xray 与管理脚本在线更新        "
        echo "=========================================="
        echo " 1. 单独检查并更新 Xray 内核 (xray-core)"
        echo " 2. 单独检查并更新 管理脚本 (xray.sh)"
        echo " 3. 一键检查并更新全部 (内核 + 脚本)"
        echo " 0. 返回主菜单"
        echo "=========================================="
        read -p "请输入选项 [0-3]: " u_opt </dev/tty
        case "$u_opt" in
            1) check_and_update_core ;;
            2) check_and_update_script ;;
            3) check_and_update_core; check_and_update_script ;;
            0) break ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

restart_xray() { echo -e "\n正在重启 Xray..."; do_restart; sleep 1; echo -e "\033[32m重启完成！\033[0m"; read -n 1 -s -r -p "按任意键继续..." </dev/tty; }
start_xray() { echo -e "\n正在启动 Xray..."; do_start; sleep 1; echo -e "\033[32m启动完成！\033[0m"; read -n 1 -s -r -p "按任意键继续..." </dev/tty; }
stop_xray() { echo -e "\n正在停止 Xray..."; do_stop; sleep 1; echo -e "\033[33m已停止！\033[0m"; read -n 1 -s -r -p "按任意键继续..." </dev/tty; }
show_info() { clear; [ -f "$LINK_FILE" ] && cat "$LINK_FILE" || echo "未找到节点信息！"; echo ""; read -n 1 -s -r -p "按任意键返回菜单..." </dev/tty; }
show_logs() {
    echo -e "\n正在获取最近 30 行日志 (Ctrl+C 退出)：\n"
    if command -v journalctl >/dev/null 2>&1; then journalctl -u xray -n 30 --no-pager; else echo "Alpine 请查看: /var/log/messages"; fi
    echo ""; read -n 1 -s -r -p "按任意键返回菜单..." </dev/tty
}

uninstall_xray() {
    echo ""
    read -p "⚠️ 确定要彻底卸载 Xray 及其配置与管理脚本吗？[y/N]: " confirm </dev/tty
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
            rm -f /etc/cron.d/xray-traffic 2>/dev/null || true
            crontab -l 2>/dev/null | grep -v "xray -s" | grep -v "xray --sync-traffic" | crontab - 2>/dev/null || true
            rm -f /usr/local/bin/xray-core /usr/local/bin/xray
            rm -rf /usr/local/etc/xray /root/xray_temp
            echo -e "\033[32m🎉 卸载清理完成！\033[0m"
            exit 0
            ;;
        *) echo -e "\033[33m已取消卸载。\033[0m"; sleep 1 ;;
    esac
}

# ----------------- 主菜单 -----------------
main_menu() {
    while true; do
        clear
        local core_v=$(get_xray_core_version)

        echo "=========================================="
        echo "      Xray-Reality 直连节点管理后台       "
        echo "=========================================="
        echo -e "程序版本: 脚本 \033[1;36mv${SCRIPT_VERSION}\033[0m | 内核 \033[1;32mv${core_v#v}\033[0m"
        echo -e "服务状态: $(get_status)"
        echo "------------------------------------------"
        echo " 1. 重启 Xray"
        echo " 2. 启动 Xray"
        echo " 3. 停止 Xray"
        echo " 4. 查看全部节点链接及详细配置"
        echo " 5. 修改主节点配置 (端口/SNI/UUID/密钥)"
        echo " 6. TCP BBR 加速与网络调优"
        echo " 7. 检查与升级 (Xray内核 / 管理脚本)"
        echo " 8. 查看运行日志"
        echo " 9. 彻底卸载 Xray"
        echo " 0. 退出菜单"
        echo "=========================================="
        read -p "请输入选项 [0-9]: " choice </dev/tty
        case "$choice" in
            1) restart_xray ;;
            2) start_xray ;;
            3) stop_xray ;;
            4) show_info ;;
            5) modify_config ;;
            6) manage_bbr ;;
            7) update_menu ;;
            8) show_logs ;;
            9) uninstall_xray ;;
            0) clear; exit 0 ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

main_menu
EOF_MANAGEMENT_SCRIPT
    chmod +x /usr/local/bin/xray
}

# ------------------------------------------------------------------------------
# 3. 脚本主安装 / 升级执行入口
# ------------------------------------------------------------------------------
install_dependencies

if is_config_complete; then
    echo "=========================================================="
    echo -e "\033[32m✔ 检测到本机已存在完整的 Xray Reality 配置！\033[0m"
    echo "=========================================================="
    source "$ENV_FILE"
    echo "  - 端口: $PORT"
    echo "  - 伪装 SNI: $DEST_SNI"
    echo "  - 本机直连 UUID: $UUID_DIRECT"
    echo "----------------------------------------------------------"

    if [ "$1" = "--auto-upgrade" ]; then
        mode_choice=1
    else
        echo "请选择运行模式："
        echo "  1. 保留直连及扩展节点配置升级 (应用网络与传输层调优)"
        echo "  2. 重新配置 (覆盖已有参数，生成新的直连 UUID 及密钥)"
        echo "----------------------------------------------------------"
        read -p "请输入选项 [1-2] (默认 1): " mode_choice </dev/tty
        mode_choice=${mode_choice:-1}
    fi

    if [ "$mode_choice" = "1" ]; then
        echo -e "\n⏳ 正在执行直连配置升级..."
        write_management_cli
        clean_traffic_cron
        optimize_network
        if [ "$1" != "--auto-upgrade" ]; then
            install_xray_core
        fi
        save_params_env
        render_config_json
        write_service
        update_links_info
        echo -e "\033[32m🎉 升级完成！已成功应用 TCP 缓冲区与传输层性能调优。\033[0m"
        echo -e "在终端直接输入 \033[1;33mxray\033[0m 即可体验新增功能。\n"
        exit 0
    fi
fi

# 全新部署流程
echo -e "\n====================================="
echo "开始全新部署流程..."
echo "====================================="
install_xray_core
optimize_network

UUID_DIRECT=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | awk '/^PrivateKey:/ {print $2}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey|Password/ {print $NF}')
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "❌ 密钥解析失败，xray x25519 输出格式无法识别："
    echo "$KEYS"
    exit 1
fi
SHORT_ID=$(openssl rand -hex 8)

DEST_SNI="addons.mozilla.org"
PORT=443

save_params_env

render_config_json
write_service
clean_traffic_cron
write_management_cli
update_links_info

cat "$LINK_FILE"
echo -e "\033[36m💡 部署完成！以后在终端输入 \033[1;33mxray\033[0;36m 即可随时打开管理后台。\033[0m\n"
