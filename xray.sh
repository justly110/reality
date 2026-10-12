#!/bin/bash
# ==============================================================================
# VLESS-Reality 分流中转版 (Debian & Alpine + 纯IPv4单栈 + 本机/落地双用户分流)
# 特性：
# 1. 智能配置检测与平滑升级 (已有配置免改参)
# 2. 默认每月24日重置月度流量 (持久化存盘，进程重启不丢失)
# 3. 流量超额自动熔断关停保护
# 4. 落地机 TCP 毫秒握手延迟与连通性测试
# 5. TCP BBR 状态检测与环境识别 (支持机器开启，容器小鸡友好提示)
# 6. 修改 SNI 伪装域名自动握手与证书体积极速体检
# 7. 低内存 (<=256MB) 自动注入防 OOM 调优参数
# 8. Xray 内核与管理脚本在线独立检查升级
# ==============================================================================

SCRIPT_VERSION="0.0.3"
SCRIPT_URL="https://github.com/justly110/reality/raw/main/xray.sh"

ENV_FILE="/usr/local/etc/xray/params.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"
LINK_FILE="/usr/local/etc/xray/link.txt"
TRAFFIC_FILE="/usr/local/etc/xray/traffic.env"
XRAY_BIN="/usr/local/bin/xray-core"

if [ "$(id -u)" != "0" ]; then
    echo "❌ 错误：请使用 root 权限运行本脚本"
    exit 1
fi

# 释放系统缓存
sync; echo 3 2>/dev/null > /proc/sys/vm/drop_caches || true

# ------------------------------------------------------------------------------
# 1. 检查现有配置完整度
# ------------------------------------------------------------------------------
is_config_complete() {
    [ -f "$ENV_FILE" ] || return 1
    local p_port p_sni p_u1 p_u2 p_pub p_priv p_sid p_ss_addr p_ss_port p_ss_pass p_ss_method
    eval $(grep -E '^(PORT|DEST_SNI|UUID_DIRECT|UUID_RELAY|PUBLIC_KEY|PRIVATE_KEY|SHORT_ID|SS_ADDR|SS_PORT|SS_PASS|SS_METHOD)=' "$ENV_FILE" 2>/dev/null)
    [ -n "$PORT" ] && \
    [ -n "$DEST_SNI" ] && \
    [ -n "$UUID_DIRECT" ] && \
    [ -n "$UUID_RELAY" ] && \
    [ -n "$PUBLIC_KEY" ] && \
    [ -n "$PRIVATE_KEY" ] && \
    [ -n "$SHORT_ID" ] && \
    [ -n "$SS_ADDR" ] && \
    [ -n "$SS_PORT" ] && \
    [ -n "$SS_PASS" ] && \
    [ -n "$SS_METHOD" ]
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
    local u_relay="$4"
    local priv="$5"
    local sid="$6"

    cat << EOF
[
  {
    "tag": "vless-v4",
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$u_direct", "flow": "xtls-rprx-vision", "email": "direct-local"},
        {"id": "$u_relay", "flow": "xtls-rprx-vision", "email": "relay-egress"}
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
  },
  {
    "tag": "api",
    "listen": "127.0.0.1",
    "port": 10085,
    "protocol": "dokodemo-door",
    "settings": {
      "address": "127.0.0.1"
    }
  }
]
EOF
}

render_config_json() {
    {
        echo "{"
        echo '  "log": {"loglevel": "warning"},'
        echo '  "stats": {},'
        echo '  "api": {"tag": "api", "services": ["StatsService"]},'
        echo '  "policy": {'
        echo '    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},'
        echo '    "system": {"statsInboundUplink": true, "statsInboundDownlink": true}'
        echo '  },'
        echo "  \"inbounds\": $(build_inbounds_json "$PORT" "$DEST_SNI" "$UUID_DIRECT" "$UUID_RELAY" "$PRIVATE_KEY" "$SHORT_ID"),"
        echo '  "outbounds": ['
        echo '    {"protocol": "freedom", "tag": "direct"},'
        echo '    {"protocol": "blackhole", "tag": "block"},'
        echo '    {'
        echo '      "tag": "to-egress-ss",'
        echo '      "protocol": "shadowsocks",'
        echo '      "settings": {'
        echo '        "servers": ['
        echo '          {'
        echo "            \"address\": \"$SS_ADDR\","
        echo "            \"port\": $SS_PORT,"
        echo "            \"method\": \"$SS_METHOD\","
        echo "            \"password\": \"$SS_PASS\""
        echo '          }'
        echo '        ]'
        echo '      },'
        echo '      "streamSettings": {'
        echo '        "network": "tcp"'
        echo '      },'
        echo '      "mux": {'
        echo '        "enabled": true,'
        echo '        "concurrency": 8'
        echo '      }'
        echo '    }'
        echo '  ],'
        echo '  "routing": {'
        echo '    "domainStrategy": "IPIfNonMatch",'
        echo '    "rules": ['
        echo '      {'
        echo '        "type": "field",'
        echo '        "inboundTag": ["api"],'
        echo '        "outboundTag": "api"'
        echo '      },'
        echo '      {'
        echo '        "type": "field",'
        echo '        "user": ["relay-egress"],'
        echo '        "outboundTag": "to-egress-ss"'
        echo '      },'
        echo '      {'
        echo '        "type": "field",'
        echo '        "user": ["direct-local"],'
        echo '        "outboundTag": "direct"'
        echo '      },'
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

init_traffic_db() {
    if [ ! -f "$TRAFFIC_FILE" ]; then
        cat > "$TRAFFIC_FILE" << 'EOF'
RESET_DAY=24
TRAFFIC_LIMIT_GB=0
LAST_RESET_MONTH=""
U1_UP=0
U1_DOWN=0
U2_UP=0
U2_DOWN=0
FUSED=0
EOF
    fi

    # 配置 Cron 定时任务（每 10 分钟同步流量存盘与配额熔断检查）
    if [ -d "/etc/cron.d" ]; then
        echo "*/10 * * * * root /usr/local/bin/xray --sync-traffic >/dev/null 2>&1" > /etc/cron.d/xray-traffic
        chmod 644 /etc/cron.d/xray-traffic
    elif command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "xray --sync-traffic"; echo "*/10 * * * * /usr/local/bin/xray --sync-traffic >/dev/null 2>&1") | crontab -
    fi

    # Alpine 确保 crond 运行
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    fi
}

update_links_info() {
    local s_v4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
    local host_v4="${s_v4:-你的本机IPv4}"

    local l_direct="vless://${UUID_DIRECT}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#9929-DE"
    local l_relay="vless://${UUID_RELAY}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#9929-US"

    {
        echo "=========================================================================="
        echo "🎉 VLESS-Reality 分流节点配置已就绪"
        echo "=========================================================================="
        echo "【节点 1：本机直连 (direct-local)】"
        echo "● 节点链接: ${l_direct}"
        echo ""
        echo "【节点 2：落地转发 (relay-egress -> Shadowsocks)】"
        echo "● 节点链接: ${l_relay}"
        echo "--------------------------------------------------------------------------"
        echo "详细参数："
        echo "- 本机 IPv4: ${s_v4:-未检测到 (需手动替换)}"
        echo "- Reality 端口: ${PORT}"
        echo "- 伪装域名 (SNI): ${DEST_SNI}"
        echo "- 公钥 (pbk): ${PUBLIC_KEY}"
        echo "- ShortId: ${SHORT_ID}"
        echo "- 本机直连 UUID: ${UUID_DIRECT}"
        echo "- 落地转发 UUID: ${UUID_RELAY}"
        echo "--------------------------------------------------------------------------"
        echo "落地机 Shadowsocks 配置："
        echo "- 落地地址: ${SS_ADDR}:${SS_PORT}"
        echo "- 加密方式: ${SS_METHOD}"
        echo "- 落地密码: ${SS_PASS}"
        echo "=========================================================================="
    } > "$LINK_FILE"
}

# ------------------------------------------------------------------------------
# 2. 写入全局管理脚本 /usr/local/bin/xray
# ------------------------------------------------------------------------------
write_management_cli() {
    cat > /usr/local/bin/xray << 'EOF_MANAGEMENT_SCRIPT'
#!/bin/bash

SCRIPT_VERSION="0.0.3"
SCRIPT_URL="https://github.com/justly110/reality/raw/main/xray.sh"

ENV_FILE="/usr/local/etc/xray/params.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"
LINK_FILE="/usr/local/etc/xray/link.txt"
TRAFFIC_FILE="/usr/local/etc/xray/traffic.env"
XRAY_BIN="/usr/local/bin/xray-core"

load_env() {
    if [ -f "$ENV_FILE" ]; then source "$ENV_FILE"; else echo "❌ 缺少 $ENV_FILE"; exit 1; fi
}

load_traffic_env() {
    RESET_DAY=24; TRAFFIC_LIMIT_GB=0; LAST_RESET_MONTH=""; U1_UP=0; U1_DOWN=0; U2_UP=0; U2_DOWN=0; FUSED=0
    [ -f "$TRAFFIC_FILE" ] && source "$TRAFFIC_FILE"
}

save_traffic_env() {
    cat > "$TRAFFIC_FILE" << EOF
RESET_DAY=${RESET_DAY:-24}
TRAFFIC_LIMIT_GB=${TRAFFIC_LIMIT_GB:-0}
LAST_RESET_MONTH="${LAST_RESET_MONTH}"
U1_UP=${U1_UP:-0}
U1_DOWN=${U1_DOWN:-0}
U2_UP=${U2_UP:-0}
U2_DOWN=${U2_DOWN:-0}
FUSED=${FUSED:-0}
EOF
}

get_status() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet xray; then
            echo -e "\033[32m● 正在运行 (Running)\033[0m"
        else
            [ "${FUSED:-0}" -eq 1 ] && echo -e "\033[31m⛔ 已熔断关停 (超额保护)\033[0m" || echo -e "\033[31m○ 未运行 (Stopped)\033[0m"
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service xray status 2>/dev/null | grep -q "started"; then
            echo -e "\033[32m● 正在运行 (Running)\033[0m"
        else
            [ "${FUSED:-0}" -eq 1 ] && echo -e "\033[31m⛔ 已熔断关停 (超额保护)\033[0m" || echo -e "\033[31m○ 未运行 (Stopped)\033[0m"
        fi
    fi
}

do_restart() {
    if command -v systemctl >/dev/null 2>&1; then systemctl restart xray; elif command -v rc-service >/dev/null 2>&1; then rc-service xray restart; fi
}
do_start() {
    if command -v systemctl >/dev/null 2>&1; then systemctl start xray; elif command -v rc-service >/dev/null 2>&1; then rc-service xray start; fi
}
do_stop() {
    if command -v systemctl >/dev/null 2>&1; then systemctl stop xray; elif command -v rc-service >/dev/null 2>&1; then rc-service xray stop; fi
}

format_bytes() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN {
        if (b < 1024) printf "%.2f B", b
        else if (b < 1048576) printf "%.2f KB", b / 1024
        else if (b < 1073741824) printf "%.2f MB", b / 1048576
        else printf "%.2f GB", b / 1073741824
    }'
}

# ----------------- 流量统计、同步与熔断核心 -----------------
sync_traffic_data() {
    load_traffic_env
    local cur_y=$(date +%Y)
    local cur_m=$(date +%m)
    local cur_d=$(date +%-d)
    local r_day=${RESET_DAY:-24}

    # 1. 检查是否达到设定的重置日
    if [ "$cur_d" -ge "$r_day" ]; then
        local this_cycle_tag="${cur_y}-${cur_m}"
        if [ "$LAST_RESET_MONTH" != "$this_cycle_tag" ]; then
            U1_UP=0; U1_DOWN=0; U2_UP=0; U2_DOWN=0; LAST_RESET_MONTH="$this_cycle_tag"
            if [ "$FUSED" -eq 1 ]; then
                FUSED=0; do_start
            fi
        fi
    fi

    # 2. 调用 API 读取增量 (带 -reset=true 原子清空内存计数)
    local query_out=$($XRAY_BIN api statsquery --server=127.0.0.1:10085 -reset=true 2>/dev/null)
    if [ -n "$query_out" ]; then
        local delta_u1_up=$(echo "$query_out" | grep -A 2 'user>>>direct-local>>>traffic>>>uplink' | grep '"value":' | awk '{print $2}' | tr -d '",')
        local delta_u1_down=$(echo "$query_out" | grep -A 2 'user>>>direct-local>>>traffic>>>downlink' | grep '"value":' | awk '{print $2}' | tr -d '",')
        local delta_u2_up=$(echo "$query_out" | grep -A 2 'user>>>relay-egress>>>traffic>>>uplink' | grep '"value":' | awk '{print $2}' | tr -d '",')
        local delta_u2_down=$(echo "$query_out" | grep -A 2 'user>>>relay-egress>>>traffic>>>downlink' | grep '"value":' | awk '{print $2}' | tr -d '",')

        U1_UP=$((U1_UP + ${delta_u1_up:-0}))
        U1_DOWN=$((U1_DOWN + ${delta_u1_down:-0}))
        U2_UP=$((U2_UP + ${delta_u2_up:-0}))
        U2_DOWN=$((U2_DOWN + ${delta_u2_down:-0}))
    fi

    # 3. 超额熔断检查
    local total_bytes=$((U1_UP + U1_DOWN + U2_UP + U2_DOWN))
    if [ "${TRAFFIC_LIMIT_GB:-0}" -gt 0 ]; then
        local limit_bytes=$((TRAFFIC_LIMIT_GB * 1024 * 1024 * 1024))
        if [ "$total_bytes" -ge "$limit_bytes" ]; then
            if [ "$FUSED" -ne 1 ]; then
                FUSED=1
                do_stop
            fi
        fi
    fi

    save_traffic_env
}

# 支持后台 cron 脚本直接调用
if [ "$1" = "--sync-traffic" ]; then
    sync_traffic_data
    exit 0
fi

# 计算账单周期字符串
get_cycle_range() {
    local r_day="${RESET_DAY:-24}"
    local cur_y=$(date +%Y)
    local cur_m=$(date +%m)
    local cur_d=$(date +%-d)
    local start_date=""
    local end_date=""
    local r_str=""
    printf -v r_str "%02d" "$r_day"

    if [ "$cur_d" -ge "$r_day" ]; then
        start_date="${cur_y}-${cur_m}-${r_str}"
        local next_m=$((10#$cur_m + 1))
        local next_y=$cur_y
        if [ "$next_m" -gt 12 ]; then next_m=1; next_y=$((cur_y + 1)); fi
        local next_m_str=""
        printf -v next_m_str "%02d" "$next_m"
        end_date="${next_y}-${next_m_str}-${r_str} (前一日)"
    else
        local prev_m=$((10#$cur_m - 1))
        local prev_y=$cur_y
        if [ "$prev_m" -lt 1 ]; then prev_m=12; prev_y=$((cur_y - 1)); fi
        local prev_m_str=""
        printf -v prev_m_str "%02d" "$prev_m"
        start_date="${prev_y}-${prev_m_str}-${r_str}"
        end_date="${cur_y}-${cur_m}-${r_str} (前一日)"
    fi
    echo "${start_date} ~ ${end_date}"
}

show_traffic_menu() {
    while true; do
        sync_traffic_data
        load_traffic_env
        clear
        local total_u1=$((U1_UP + U1_DOWN))
        local total_u2=$((U2_UP + U2_DOWN))
        local grand_total=$((total_u1 + total_u2))

        echo "=========================================="
        echo "          月度流量统计与熔断设置          "
        echo "=========================================="
        echo "【当前账单周期】: $(get_cycle_range)"
        echo "【每月重置日期】: 每月 ${RESET_DAY:-24} 日"
        if [ "${TRAFFIC_LIMIT_GB:-0}" -gt 0 ]; then
            local pct=$(awk -v cur="$grand_total" -v lim="$TRAFFIC_LIMIT_GB" 'BEGIN { printf "%.1f", (cur / (lim*1024*1024*1024)) * 100 }')
            echo "【月度流量限额】: ${TRAFFIC_LIMIT_GB} GB (已用: ${pct}%)"
            [ "$FUSED" -eq 1 ] && echo -e "【熔断防护状态】: \033[31m⛔ 已触发熔断，服务已关停！\033[0m" || echo -e "【熔断防护状态】: \033[32m✔ 正常运行中\033[0m"
        else
            echo "【月度流量限额】: 未设置 (不限用量)"
        fi
        echo "------------------------------------------"
        echo "【节点 1：本机直连 (direct-local)】"
        echo "  ↑ 上行: $(format_bytes $U1_UP) | ↓ 下行: $(format_bytes $U1_DOWN)"
        echo "  ∑ 合计: $(format_bytes $total_u1)"
        echo ""
        echo "【节点 2：落地转发 (relay-egress)】"
        echo "  ↑ 上行: $(format_bytes $U2_UP) | ↓ 下行: $(format_bytes $U2_DOWN)"
        echo "  ∑ 合计: $(format_bytes $total_u2)"
        echo "------------------------------------------"
        echo -e "【本周期总消耗】: \033[1;32m$(format_bytes $grand_total)\033[0m"
        echo "=========================================="
        echo " 1. 修改每月重置日期 (当前: 每月 ${RESET_DAY} 号)"
        echo " 2. 设置月度流量熔断阈值 (当前: ${TRAFFIC_LIMIT_GB} GB)"
        echo " 3. 手动清零当前周期流量 / 强制解除熔断"
        echo " 0. 返回主管理菜单"
        echo "=========================================="
        read -p "请输入选项 [0-3]: " t_opt </dev/tty
        case "$t_opt" in
            1)
                read -p "请输入新的重置日 [1-31] (默认 24): " new_rday </dev/tty
                if [[ "$new_rday" =~ ^[0-9]+$ ]] && [ "$new_rday" -ge 1 ] && [ "$new_rday" -le 31 ]; then
                    RESET_DAY="$new_rday"
                    save_traffic_env
                    echo -e "\033[32m✔ 重置日已修改为每月 ${RESET_DAY} 日！\033[0m"; sleep 1
                else
                    echo -e "\033[31m输入不合法！\033[0m"; sleep 1
                fi
                ;;
            2)
                read -p "请输入每月流量限额 (单位 GB，输入 0 则不限制): " new_lim </dev/tty
                if [[ "$new_lim" =~ ^[0-9]+$ ]]; then
                    TRAFFIC_LIMIT_GB="$new_lim"
                    save_traffic_env
                    echo -e "\033[32m✔ 流量配额已更新！\033[0m"; sleep 1
                else
                    echo -e "\033[31m输入不合法！\033[0m"; sleep 1
                fi
                ;;
            3)
                read -p "确认清零本周期全部已用流量并解除熔断？[y/N]: " cf_rst </dev/tty
                if [[ "$cf_rst" =~ ^[yY]$ ]]; then
                    U1_UP=0; U1_DOWN=0; U2_UP=0; U2_DOWN=0; FUSED=0
                    save_traffic_env
                    do_start
                    echo -e "\033[32m✔ 流量已归零，服务已恢复！\033[0m"; sleep 1
                fi
                ;;
            0) break ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

# ----------------- 落地机连通性与握手延迟测试 -----------------
test_landing_server() {
    load_env
    clear
    echo "=========================================="
    echo "          落地机连通性与握手延迟测试       "
    echo "=========================================="
    echo "测试目标 (落地 Shadowsocks): $SS_ADDR:$SS_PORT"
    echo "------------------------------------------"
    echo "⏳ 正在发起 TCP 握手测速..."

    local t_start=$(date +%s%3N 2>/dev/null)
    [ -z "$t_start" ] && t_start=$(date +%s)

    if timeout 4 bash -c "</dev/tcp/$SS_ADDR/$SS_PORT" 2>/dev/null; then
        local t_end=$(date +%s%3N 2>/dev/null)
        if [ -n "$t_end" ] && [ "$t_end" -ge "$t_start" ]; then
            local rtt=$((t_end - t_start))
            echo -e "✔ TCP 端口状态 : \033[32m成功建立握手\033[0m"
            echo -e "✔ 节点握手延迟 : \033[1;36m${rtt} ms\033[0m"
        else
            echo -e "✔ TCP 端口状态 : \033[32m成功建立握手 (端口开放)\033[0m"
        fi
    else
        echo -e "❌ TCP 握手状态 : \033[31m连接超时 / 失败\033[0m"
        echo -e "   可能原因: 落地机 IP 填写错误、防火墙未放行端口 $SS_PORT，或落地 SS 未运行。"
    fi

    echo "------------------------------------------"
    echo "⏳ 正在测试 ICMP Ping 丢包情况..."
    ping -c 3 -W 2 "$SS_ADDR" 2>/dev/null | tail -n 2
    echo "=========================================="
    read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
}

# ----------------- TCP BBR 状态检测与管理 -----------------
manage_bbr() {
    clear
    echo "=========================================="
    echo "         TCP BBR 加速状态与环境检测       "
    echo "=========================================="
    local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || cat /proc/sys/net/core/default_qdisc 2>/dev/null)
    local virt=$(systemd-detect-virt 2>/dev/null || true)

    echo "当前拥塞控制算法 : ${cur_cc:-未知}"
    echo "当前网络队列算法 : ${cur_qdisc:-未知}"
    [ -n "$virt" ] && echo "底层虚拟化架构   : $virt"
    echo "------------------------------------------"

    # 检查是否为只读或容器架构
    local is_container=0
    if [ "$virt" = "lxc" ] || [ "$virt" = "openvz" ] || [ ! -w "/proc/sys/net/ipv4/tcp_congestion_control" ]; then
        is_container=1
    fi

    if [ "$cur_cc" = "bbr" ]; then
        echo -e "\033[32m✔ 恭喜！当前系统已成功启用 BBR 拥塞控制算法。\033[0m"
        echo ""
        read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
        return
    fi

    if [ "$is_container" -eq 1 ]; then
        echo -e "\033[33m⚠️ 提示: 当前 VPS 处于容器虚拟化架构 ($virt) 或内核只读环境。\033[0m"
        echo "该架构下网络协议栈由母鸡宿主机统一接管，无需且无法在小鸡内单独修改 BBR。"
        echo ""
        read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
        return
    fi

    echo "当前未开启 BBR，系统支持开启。"
    read -p "是否现在一键开启 BBR + FQ 加速？[Y/n]: " do_bbr </dev/tty
    if [[ ! "$do_bbr" =~ ^[nN]$ ]]; then
        modprobe tcp_bbr 2>/dev/null || true
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        sleep 1
        local check_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [ "$check_cc" = "bbr" ]; then
            echo -e "\033[32m🎉 BBR 开启成功！\033[0m"
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

    # 1. 域名解析测试
    if ! getent hosts "$sni" >/dev/null 2>&1 && ! ping -c 1 -W 2 "$sni" >/dev/null 2>&1; then
        echo -e "\033[31m❌ 警告: 无法解析域名 $sni，该域名可能不存在！\033[0m"
        read -p "是否强制忽略警告继续使用？[y/N]: " f_use </dev/tty
        [[ "$f_use" =~ ^[yY]$ ]] && return 0 || return 1
    fi

    # 2. TLS 1.3 协议支持测试 (Reality 硬性要求)
    local tls_out=$(timeout 5 openssl s_client -connect "${sni}:443" -servername "${sni}" -tls1_3 </dev/null 2>&1)
    if ! echo "$tls_out" | grep -qE "Protocol *: *TLSv1.3"; then
        echo -e "\033[31m❌ 严重不推荐: 该域名未通过 TLS 1.3 握手！\033[0m"
        echo -e "   Reality 协议严格依赖 TLS 1.3，使用此域名极易导致客户端断连。"
        read -p "是否强制忽略警告继续使用？[y/N]: " f_use </dev/tty
        [[ "$f_use" =~ ^[yY]$ ]] && return 0 || return 1
    fi

    # 3. 证书体积测试 (防 8KB 缓冲区溢出)
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
render_inbounds() {
    local port="$1"; local sni="$2"; local u_direct="$3"; local u_relay="$4"; local priv="$5"; local sid="$6"
    cat << EOF
[
  {
    "tag": "vless-v4",
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$u_direct", "flow": "xtls-rprx-vision", "email": "direct-local"},
        {"id": "$u_relay", "flow": "xtls-rprx-vision", "email": "relay-egress"}
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
  },
  {
    "tag": "api",
    "listen": "127.0.0.1",
    "port": 10085,
    "protocol": "dokodemo-door",
    "settings": {
      "address": "127.0.0.1"
    }
  }
]
EOF
}

rebuild_and_apply() {
    echo -e "\n⏳ 正在更新配置并重启 Xray..."
    {
        echo "{"
        echo '  "log": {"loglevel": "warning"},'
        echo '  "stats": {},'
        echo '  "api": {"tag": "api", "services": ["StatsService"]},'
        echo '  "policy": {'
        echo '    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},'
        echo '    "system": {"statsInboundUplink": true, "statsInboundDownlink": true}'
        echo '  },'
        echo "  \"inbounds\": $(render_inbounds "$PORT" "$DEST_SNI" "$UUID_DIRECT" "$UUID_RELAY" "$PRIVATE_KEY" "$SHORT_ID"),"
        echo '  "outbounds": ['
        echo '    {"protocol": "freedom", "tag": "direct"},'
        echo '    {"protocol": "blackhole", "tag": "block"},'
        echo '    {'
        echo '      "tag": "to-egress-ss",'
        echo '      "protocol": "shadowsocks",'
        echo '      "settings": {'
        echo '        "servers": ['
        echo '          {'
        echo "            \"address\": \"$SS_ADDR\","
        echo "            \"port\": $SS_PORT,"
        echo "            \"method\": \"$SS_METHOD\","
        echo "            \"password\": \"$SS_PASS\""
        echo '          }'
        echo '        ]'
        echo '      },'
        echo '      "streamSettings": {'
        echo '        "network": "tcp"'
        echo '      },'
        echo '      "mux": {'
        echo '        "enabled": true,'
        echo '        "concurrency": 8'
        echo '      }'
        echo '    }'
        echo '  ],'
        echo '  "routing": {'
        echo '    "domainStrategy": "IPIfNonMatch",'
        echo '    "rules": ['
        echo '      {'
        echo '        "type": "field",'
        echo '        "inboundTag": ["api"],'
        echo '        "outboundTag": "api"'
        echo '      },'
        echo '      {'
        echo '        "type": "field",'
        echo '        "user": ["relay-egress"],'
        echo '        "outboundTag": "to-egress-ss"'
        echo '      },'
        echo '      {'
        echo '        "type": "field",'
        echo '        "user": ["direct-local"],'
        echo '        "outboundTag": "direct"'
        echo '      },'
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
        echo "PORT=\"$PORT\""
        echo "DEST_SNI=\"$DEST_SNI\""
        echo "UUID_DIRECT=\"$UUID_DIRECT\""
        echo "UUID_RELAY=\"$UUID_RELAY\""
        echo "PUBLIC_KEY=\"$PUBLIC_KEY\""
        echo "PRIVATE_KEY=\"$PRIVATE_KEY\""
        echo "SHORT_ID=\"$SHORT_ID\""
        echo "SS_ADDR=\"$SS_ADDR\""
        echo "SS_PORT=\"$SS_PORT\""
        echo "SS_PASS=\"$SS_PASS\""
        echo "SS_METHOD=\"$SS_METHOD\""
    } > "$ENV_FILE"

    do_restart
    sleep 1

    local s_v4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
    local host_v4="${s_v4:-你的本机IPv4}"
    local l_direct="vless://${UUID_DIRECT}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#9929-DE"
    local l_relay="vless://${UUID_RELAY}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#9929-US"

    {
        echo "=========================================================================="
        echo "🎉 VLESS-Reality 最新节点信息"
        echo "=========================================================================="
        echo "【节点 1：本机直连 (direct-local)】"
        echo "● 节点链接: ${l_direct}"
        echo ""
        echo "【节点 2：落地转发 (relay-egress -> Shadowsocks)】"
        echo "● 节点链接: ${l_relay}"
        echo "--------------------------------------------------------------------------"
        echo "详细参数："
        echo "- 本机 IPv4: ${s_v4:-未检测到 (需手动替换)}"
        echo "- Reality 端口: ${PORT}"
        echo "- 伪装域名 (SNI): ${DEST_SNI}"
        echo "- 公钥 (pbk): ${PUBLIC_KEY}"
        echo "- ShortId: ${SHORT_ID}"
        echo "- 本机直连 UUID: ${UUID_DIRECT}"
        echo "- 落地转发 UUID: ${UUID_RELAY}"
        echo "--------------------------------------------------------------------------"
        echo "落地机 Shadowsocks 配置："
        echo "- 落地地址: ${SS_ADDR}:${SS_PORT}"
        echo "- 加密方式: ${SS_METHOD}"
        echo "- 落地密码: ${SS_PASS}"
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
        echo " [用户 UUID 管理]"
        echo " 4. 重新生成【本机直连】UUID"
        echo " 5. 重新生成【落地转发】UUID"
        echo " 6. 手动输入新的【本机直连】UUID"
        echo " 7. 手动输入新的【落地转发】UUID"
        echo "------------------------------------------"
        echo " [落地机 Shadowsocks 设置]"
        echo " 8. 修改落地机 IP/域名 (当前: $SS_ADDR)"
        echo " 9. 修改落地机 端口 (当前: $SS_PORT)"
        echo " 10. 修改落地机 密码 (当前: $SS_PASS)"
        echo " 11. 一键修改落地机全部信息 (IP + 端口 + 密码)"
        echo "------------------------------------------"
        echo " 0. 返回主菜单"
        echo "=========================================="
        read -p "请输入选项 [0-11]: " opt </dev/tty
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
                PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}')
                PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}')
                SHORT_ID=$(openssl rand -hex 8)
                rebuild_and_apply; break
                ;;
            4) UUID_DIRECT=$($XRAY_BIN uuid); rebuild_and_apply; break ;;
            5) UUID_RELAY=$($XRAY_BIN uuid); rebuild_and_apply; break ;;
            6)
                read -p "请输入新的【本机直连】UUID: " custom_uid_dir </dev/tty
                [ -n "$custom_uid_dir" ] && { UUID_DIRECT="$custom_uid_dir"; rebuild_and_apply; break; }
                ;;
            7)
                read -p "请输入新的【落地转发】UUID: " custom_uid_rel </dev/tty
                [ -n "$custom_uid_rel" ] && { UUID_RELAY="$custom_uid_rel"; rebuild_and_apply; break; }
                ;;
            8)
                read -p "请输入新的落地机 IP/域名: " new_ss_addr </dev/tty
                [ -n "$new_ss_addr" ] && { SS_ADDR="$new_ss_addr"; rebuild_and_apply; break; }
                ;;
            9)
                read -p "请输入新的落地机 SS 端口: " new_ss_port </dev/tty
                if [[ "$new_ss_port" =~ ^[0-9]+$ ]] && [ "$new_ss_port" -ge 1 ] && [ "$new_ss_port" -le 65535 ]; then
                    SS_PORT="$new_ss_port"; rebuild_and_apply; break
                fi
                ;;
            10)
                read -p "请输入新的落地机 SS 密码: " new_ss_pass </dev/tty
                [ -n "$new_ss_pass" ] && { SS_PASS="$new_ss_pass"; rebuild_and_apply; break; }
                ;;
            11)
                read -p "请输入落地机 IP/域名 (留空保持 $SS_ADDR): " b_addr </dev/tty
                read -p "请输入落地机 端口 (留空保持 $SS_PORT): " b_port </dev/tty
                read -p "请输入落地机 密码 (留空保持不变): " b_pass </dev/tty
                [ -n "$b_addr" ] && SS_ADDR="$b_addr"
                [ -n "$b_port" ] && SS_PORT="$b_port"
                [ -n "$b_pass" ] && SS_PASS="$b_pass"
                rebuild_and_apply; break
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
    local cur_ver=$($XRAY_BIN version 2>/dev/null | head -n 1 | awk '{print $2}')
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
    if curl -sL "$SCRIPT_URL" -o /tmp/xray_new.sh; then
        chmod +x /tmp/xray_new.sh
        bash /tmp/xray_new.sh --auto-upgrade </dev/tty
        rm -f /tmp/xray_new.sh
        echo -e "\033[32m🎉 管理脚本升级完成！\033[0m"
        exit 0
    fi
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
            crontab -l 2>/dev/null | grep -v "xray --sync-traffic" | crontab - 2>/dev/null || true
            rm -f /usr/local/bin/xray-core /usr/local/bin/xray
            rm -rf /usr/local/etc/xray /root/xray_temp
            echo -e "\033[32m🎉 卸载清理完成！\033[0m"
            exit 0
            ;;
        *) echo -e "\033[33m已取消卸载。\033[0m"; sleep 1 ;;
    esac
}

# ----------------- 主菜单 -----------------
while true; do
    sync_traffic_data
    load_traffic_env
    clear
    local total_cur=$((U1_UP + U1_DOWN + U2_UP + U2_DOWN))
    local lim_str="不限"
    [ "${TRAFFIC_LIMIT_GB:-0}" -gt 0 ] && lim_str="${TRAFFIC_LIMIT_GB} GB"

    echo "=========================================="
    echo "      Xray-Reality 流量分流管理后台       "
    echo "=========================================="
    echo -e "服务状态: $(get_status)"
    echo -e "月度流量: 已用 \033[1;33m$(format_bytes $total_cur)\033[0m / 限额 ${lim_str} (重置日: 每月 ${RESET_DAY:-24} 号)"
    echo "------------------------------------------"
    echo " 1. 重启 Xray"
    echo " 2. 启动 Xray"
    echo " 3. 停止 Xray"
    echo " 4. 查看节点链接及详细信息"
    echo " 5. 查看月度流量统计与熔断设置"
    echo " 6. 修改节点配置 (独立修改端口/SNI/UUID/落地机)"
    echo " 7. 测试落地机连通性与握手延迟"
    echo " 8. TCP BBR 加速状态与管理"
    echo " 9. 检查与升级 (Xray内核 / 管理脚本)"
    echo " 10. 查看运行日志"
    echo " 11. 彻底卸载 Xray"
    echo " 0. 退出菜单"
    echo "=========================================="
    read -p "请输入选项 [0-11]: " choice </dev/tty
    case "$choice" in
        1) restart_xray ;;
        2) start_xray ;;
        3) stop_xray ;;
        4) show_info ;;
        5) show_traffic_menu ;;
        6) modify_config ;;
        7) test_landing_server ;;
        8) manage_bbr ;;
        9) update_menu ;;
        10) show_logs ;;
        11) uninstall_xray ;;
        0) clear; exit 0 ;;
        *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
    esac
done
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
    echo "  - 落地转发 UUID: $UUID_RELAY"
    echo "  - 落地 SS 目标: $SS_ADDR:$SS_PORT"
    echo "----------------------------------------------------------"

    if [ "$1" = "--auto-upgrade" ]; then
        mode_choice=1
    else
        echo "请选择运行模式："
        echo "  1. 保留现有全部配置平滑升级 (推荐：自动补全月度流量/熔断/BBR/落地测速)"
        echo "  2. 重新配置 (覆盖已有参数，重新输入落地机及生成新 UUID)"
        echo "----------------------------------------------------------"
        read -p "请输入选项 [1-2] (默认 1): " mode_choice </dev/tty
        mode_choice=${mode_choice:-1}
    fi

    if [ "$mode_choice" = "1" ]; then
        echo -e "\n⏳ 正在执行无缝平滑升级（原节点链接完全保持不变）..."
        [ ! -f "$XRAY_BIN" ] && install_xray_core
        render_config_json
        write_service
        init_traffic_db
        write_management_cli
        update_links_info
        echo -e "\033[32m🎉 平滑升级完成！原有节点链接无需重新导入。\033[0m"
        echo -e "在终端直接输入 \033[1;33mxray\033[0m 即可体验新增功能。\n"
        exit 0
    fi
fi

# 全新部署流程
echo -e "\n====================================="
echo "开始全新部署流程..."
echo "====================================="
install_xray_core

echo -e "\n====================================="
echo "配置落地机 Shadowsocks 转发参数..."
echo "====================================="
read -p "请输入落地机 IP / 域名 (留空则预留占位符): " INPUT_SS_ADDR </dev/tty
read -p "请输入落地机 SS 端口 (默认 30333): " INPUT_SS_PORT </dev/tty
read -p "请输入落地机 SS 密码 (留空则预留占位符): " INPUT_SS_PASS </dev/tty

SS_ADDR="${INPUT_SS_ADDR:-127.0.0.1}"
SS_PORT="${INPUT_SS_PORT:-30333}"
SS_PASS="${INPUT_SS_PASS:-YOUR_SS_PASSWORD_HERE}"
SS_METHOD="2022-blake3-aes-128-gcm"

UUID_DIRECT=$($XRAY_BIN uuid)
UUID_RELAY=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}')
SHORT_ID=$(openssl rand -hex 8)

DEST_SNI="addons.mozilla.org"
PORT=443

{
    echo "PORT=\"$PORT\""
    echo "DEST_SNI=\"$DEST_SNI\""
    echo "UUID_DIRECT=\"$UUID_DIRECT\""
    echo "UUID_RELAY=\"$UUID_RELAY\""
    echo "PUBLIC_KEY=\"$PUBLIC_KEY\""
    echo "PRIVATE_KEY=\"$PRIVATE_KEY\""
    echo "SHORT_ID=\"$SHORT_ID\""
    echo "SS_ADDR=\"$SS_ADDR\""
    echo "SS_PORT=\"$SS_PORT\""
    echo "SS_PASS=\"$SS_PASS\""
    echo "SS_METHOD=\"$SS_METHOD\""
} > "$ENV_FILE"

render_config_json
write_service
init_traffic_db
write_management_cli
update_links_info

cat "$LINK_FILE"
echo -e "\033[36m💡 部署完成！以后在终端输入 \033[1;33mxray\033[0;36m 即可随时打开管理后台。\033[0m\n"