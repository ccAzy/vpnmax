#!/bin/bash
# vpnmax-speed-test.sh — 轻量级隧道速度测试
# 用于验证当前隧道质量，流量消耗约 1-5MB/次
set -euo pipefail

# ── 配置 ──────────────────────────────────────────────────
TEST_URL="https://speed.cloudflare.com/__down?bytes=5000000" # 5MB 测试文件
LATENCY_URL="https://speed.cloudflare.com/cdn-cgi/trace"
TIMEOUT=15
LOG="/etc/s-box/speed-test.log"

# ── 日志 ──────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG" 2>/dev/null || true; }

# ── 函数 ──────────────────────────────────────────────────

# 获取当前隧道连接的 edge IP
get_tunnel_edge_ip() {
    local pid
    pid=$(pgrep -f 'cloudflared.*tunnel.*--url' 2>/dev/null | head -1 || echo "")

    if [ -z "$pid" ]; then
        echo ""
        return
    fi

    # 从 ss 获取 cloudflared 的出站连接
    local edge_ip
    edge_ip=$(ss -tnp 2>/dev/null | grep "pid=$pid" |
        awk '{print $5}' | cut -d: -f1 |
        grep -v '^127\.\|^0\.\|^::' | head -1 || echo "")

    echo "$edge_ip"
}

# 延迟测试 (TCP 连接时间)
test_latency() {
    local ip="$1"
    local port="${2:-443}"

    if [ -z "$ip" ]; then
        echo "9999"
        return
    fi

    # 使用 curl 的 time_connect
    local connect_time
    connect_time=$(curl -s --connect-timeout 3 --max-time 5 \
        -w '%{time_connect}' -o /dev/null \
        "https://speed.cloudflare.com:443/cdn-cgi/trace" \
        --resolve "speed.cloudflare.com:$port:$ip" 2>/dev/null || echo "9999")

    # 转换为毫秒
    if [ "$connect_time" != "9999" ] && [ -n "$connect_time" ]; then
        echo "$connect_time" | awk '{printf "%.0f", $1 * 1000}'
    else
        echo "9999"
    fi
}

# 速度测试 (下载 5MB 文件)
test_speed() {
    local ip="$1"

    if [ -z "$ip" ]; then
        echo "0"
        return
    fi

    # 下载测试
    local speed_bps
    speed_bps=$(curl -s --connect-timeout 5 --max-time "$TIMEOUT" \
        --resolve "speed.cloudflare.com:443:$ip" \
        -o /dev/null -w '%{speed_download}' \
        "$TEST_URL" 2>/dev/null || echo "0")

    # 转换为 Mbps
    if [ "$speed_bps" != "0" ] && [ -n "$speed_bps" ]; then
        echo "$speed_bps" | awk '{printf "%.2f", $1 * 8 / 1000000}'
    else
        echo "0"
    fi
}

# 获取当前 colo
get_current_colo() {
    local ip="$1"

    if [ -z "$ip" ]; then
        echo ""
        return
    fi

    # 从 trace 获取 colo
    local trace_output
    trace_output=$(curl -s --connect-timeout 3 --max-time 5 \
        --resolve "speed.cloudflare.com:443:$ip" \
        "$LATENCY_URL" 2>/dev/null || echo "")

    echo "$trace_output" | grep -oP 'colo=\K[A-Z0-9]+' | head -1 || echo ""
}

# 综合测试
full_test() {
    local ip="$1"
    local result_file="${2:-/tmp/speed-test-result.json}"

    if [ -z "$ip" ]; then
        echo '{"error": "no_ip"}'
        return 1
    fi

    log "开始测试: IP=$ip"

    # 并行测试延迟和获取 colo
    local latency colo
    latency=$(test_latency "$ip")
    colo=$(get_current_colo "$ip")

    # 速度测试
    local speed
    speed=$(test_speed "$ip")

    # 构建结果
    local result
    result=$(
        cat <<EOF
{
    "ip": "$ip",
    "colo": "$colo",
    "latency_ms": $latency,
    "speed_mbps": $speed,
    "timestamp": "$(date -Is)",
    "test_url": "$TEST_URL"
}
EOF
    )

    # 保存结果
    echo "$result" >"$result_file" 2>/dev/null || true

    log "测试完成: colo=$colo, latency=${latency}ms, speed=${speed}Mbps"
    echo "$result"
}

# 快速检查 (只测延迟，<1KB)
quick_check() {
    local ip="$1"

    if [ -z "$ip" ]; then
        echo "9999"
        return
    fi

    test_latency "$ip"
}

# ── 主程序 ────────────────────────────────────────────────
case "${1:-}" in
--full)
    # 完整测试
    ip="${2:-$(get_tunnel_edge_ip)}"
    full_test "$ip"
    ;;
--quick)
    # 快速检查
    ip="${2:-$(get_tunnel_edge_ip)}"
    quick_check "$ip"
    ;;
--latency)
    # 只测延迟
    ip="${2:-$(get_tunnel_edge_ip)}"
    test_latency "$ip"
    ;;
--speed)
    # 只测速度
    ip="${2:-$(get_tunnel_edge_ip)}"
    test_speed "$ip"
    ;;
--colo)
    # 获取 colo
    ip="${2:-$(get_tunnel_edge_ip)}"
    get_current_colo "$ip"
    ;;
--help | -h)
    cat <<'HELP'
vpnmax-speed-test.sh — 轻量级隧道速度测试

用法:
    vpnmax-speed-test.sh --full [IP]     完整测试 (延迟+速度+colo)
    vpnmax-speed-test.sh --quick [IP]    快速检查 (只测延迟, <1KB)
    vpnmax-speed-test.sh --latency [IP]  只测延迟
    vpnmax-speed-test.sh --speed [IP]    只测速度
    vpnmax-speed-test.sh --colo [IP]     获取 colo

如果不指定 IP，会自动检测当前隧道连接的 edge IP。

流量消耗:
    --quick:  <1KB
    --full:   ~5MB
    --latency: <1KB
    --speed:   ~5MB
HELP
    ;;
*)
    # 默认：快速检查
    ip="${1:-$(get_tunnel_edge_ip)}"
    quick_check "$ip"
    ;;
esac
