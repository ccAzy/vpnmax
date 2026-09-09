#!/bin/bash
# cloudflared-argo-start.sh — 读取配置并启动 cloudflared
set -euo pipefail

# 配置文件
SB_JSON="/etc/s-box/sb.json"
EXTRA_CONF="/etc/s-box/argo-extra.conf"

# 1. 获取 WS 端口
get_ws_port() {
    local port
    # 优先取 vless+ws 传输的 inbound
    port=$(jq -r '[.inbounds[] | select(.type=="vless" and .transport.type=="ws") | .listen_port][0] // empty' "$SB_JSON" 2>/dev/null)

    # 退化取 inbounds[1]
    if [ -z "$port" ] || [ "$port" = "null" ]; then
        port=$(jq -r '.inbounds[1].listen_port // empty' "$SB_JSON" 2>/dev/null)
    fi

    echo "${port:-8443}"
}

# 2. 获取 cloudflared 路径
get_cf_bin() {
    local cfbin
    cfbin=$(command -v cloudflared 2>/dev/null)
    [ -x "${cfbin:-}" ] || cfbin=$(ls /etc/s-box/cloudflared /usr/local/bin/cloudflared 2>/dev/null | head -1)
    echo "${cfbin:-/usr/local/bin/cloudflared}"
}

# 3. 读取优选参数
get_extra_args() {
    if [ -f "$EXTRA_CONF" ]; then
        grep -v '^#' "$EXTRA_CONF" 2>/dev/null | tr '\n' ' ' || true
    else
        echo ""
    fi
}

# 主逻辑
main() {
    local ws_port cf_bin extra_args

    ws_port=$(get_ws_port)
    cf_bin=$(get_cf_bin)
    extra_args=$(get_extra_args)

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动 cloudflared: port=$ws_port, extra=$extra_args"

    # 启动 cloudflared
    exec "$cf_bin" tunnel \
        --url "http://localhost:$ws_port" \
        --no-autoupdate \
        --protocol auto \
        --edge-ip-version 4 \
        $extra_args
}

main "$@"
