#!/bin/bash
# vpnmax-edge-monitor.sh — Argo 隧道质量监控 + 自动重选
# 保活循环：检查 → 不达标则触发优选 → 写入 → 继续循环
set -euo pipefail

# ── 配置 ──────────────────────────────────────────────────
STATE_FILE="/etc/s-box/edge-monitor.state"
EXTRA_CONF="/etc/s-box/argo-extra.conf"
CFST_BIN="/usr/local/bin/cfst"
CFST_PIN="v2.3.5" # vpnmax: 固定版本（原为跟随 latest）；升级 = 改这里
LOG="/etc/s-box/edge-monitor.log"
LOCK="/var/lock/vpnmax-edge-monitor.lock"

# 阈值
LATENCY_THRESHOLD=500 # 延迟上限 (ms)
SPEED_THRESHOLD=100   # 速度下限 (Mbps)
CHECK_INTERVAL=180    # 检查间隔 (秒)
MAX_FAIL_COUNT=3      # 连续失败 N 次才重启
COOLDOWN=300          # 重启后冷却 (秒)
# 优选策略：速度优先，延迟折中
# 1. 速度必须 >= 100Mbps
# 2. 延迟必须 <= 500ms
# 3. 在满足条件的 IP 中，优先选速度最快的
# 4. 速度相同时，选延迟最低的

# ── 日志 ──────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG" 2>/dev/null || true; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }
error() { log "ERROR: $*"; }

# ── 互斥锁 ────────────────────────────────────────────────
exec 9>"$LOCK" 2>/dev/null || exit 0
flock -n 9 2>/dev/null || {
    info "已有监控实例运行，跳过"
    exit 0
}

# ── 状态管理 ──────────────────────────────────────────────
load_state() {
    if [ -f "$STATE_FILE" ]; then
        LAST_GOOD_COLO=$(grep -oP 'LAST_GOOD_COLO=\K.*' "$STATE_FILE" 2>/dev/null || echo "")
        LAST_GOOD_IP=$(grep -oP 'LAST_GOOD_IP=\K.*' "$STATE_FILE" 2>/dev/null || echo "")
        LAST_TEST_TS=$(grep -oP 'LAST_TEST_TS=\K.*' "$STATE_FILE" 2>/dev/null || echo "0")
        LAST_SPEED=$(grep -oP 'LAST_SPEED=\K.*' "$STATE_FILE" 2>/dev/null || echo "0")
        FAIL_COUNT=$(grep -oP 'FAIL_COUNT=\K.*' "$STATE_FILE" 2>/dev/null || echo "0")
        LAST_RESTART_TS=$(grep -oP 'LAST_RESTART_TS=\K.*' "$STATE_FILE" 2>/dev/null || echo "0")
    else
        LAST_GOOD_COLO=""
        LAST_GOOD_IP=""
        LAST_TEST_TS="0"
        LAST_SPEED="0"
        FAIL_COUNT="0"
        LAST_RESTART_TS="0"
    fi
}

save_state() {
    cat >"$STATE_FILE" <<EOF
LAST_GOOD_COLO=${LAST_GOOD_COLO:-}
LAST_GOOD_IP=${LAST_GOOD_IP:-}
LAST_TEST_TS=${LAST_TEST_TS:-0}
LAST_SPEED=${LAST_SPEED:-0}
FAIL_COUNT=${FAIL_COUNT:-0}
LAST_RESTART_TS=${LAST_RESTART_TS:-0}
EOF
}

# ── 检查函数 ──────────────────────────────────────────────

# 1. 检查隧道进程
check_tunnel_alive() {
    pgrep -f 'cloudflared.*tunnel.*--url' >/dev/null 2>&1
}

# 2. 获取当前 colo
get_current_colo() {
    local log_file="/etc/s-box/argo.log"
    if [ -f "$log_file" ]; then
        # 从 cloudflared 日志提取 colo
        grep -aoP 'colo=[A-Z0-9]+' "$log_file" 2>/dev/null | tail -1 | cut -d= -f2 || echo ""
    else
        echo ""
    fi
}

# 3. 获取当前连接的 edge IP
get_current_edge_ip() {
    local pid
    pid=$(pgrep -f 'cloudflared.*tunnel.*--url' 2>/dev/null | head -1 || echo "")
    if [ -n "$pid" ]; then
        # 从 /proc 获取连接信息
        ss -tnp 2>/dev/null | grep "pid=$pid" | awk '{print $5}' | cut -d: -f1 | head -1 || echo ""
    else
        echo ""
    fi
}

# 4. 延迟测试 (TCPing)
test_latency() {
    local ip="$1"
    local port="${2:-443}"
    local timeout=3

    # 使用 curl 测试 TCP 连接延迟
    local start end latency
    start=$(date +%s%N)
    if curl -s --connect-timeout "$timeout" --max-time "$timeout" "https://speed.cloudflare.com/cdn-cgi/trace" --resolve "speed.cloudflare.com:$port:$ip" -o /dev/null 2>/dev/null; then
        end=$(date +%s%N)
        latency=$(((end - start) / 1000000)) # 转换为毫秒
        echo "$latency"
    else
        echo "9999"
    fi
}

# 5. 速度测试 (下载测试)
test_speed() {
    local ip="$1"
    local test_url="https://speed.cloudflare.com/__down?bytes=10000000" # 10MB
    local timeout=15

    local speed
    speed=$(curl -s --connect-timeout 5 --max-time "$timeout" \
        --resolve "speed.cloudflare.com:443:$ip" \
        -o /dev/null -w '%{speed_download}' \
        "$test_url" 2>/dev/null || echo "0")

    # 转换为 Mbps
    if [ "$speed" != "0" ] && [ -n "$speed" ]; then
        echo "$speed" | awk '{printf "%.2f", $1 * 8 / 1000000}'
    else
        echo "0"
    fi
}

# 6. 检查是否在优选列表中
check_in_preferred_list() {
    local current_colo="$1"
    local extra_conf="$EXTRA_CONF"

    if [ ! -f "$extra_conf" ]; then
        return 1 # 配置文件不存在
    fi

    # 读取优选记录中的 colo
    local preferred_colo
    preferred_colo=$(grep -oP '最优 colo \K[A-Z0-9]+' "$extra_conf" 2>/dev/null | head -1 || echo "")

    if [ -z "$preferred_colo" ]; then
        return 1 # 没有优选记录
    fi

    [ "$current_colo" = "$preferred_colo" ]
}

# ── 优选触发 ──────────────────────────────────────────────
trigger_optimization() {
    info "触发重新优选..."

    # 下载 CFST (如果不存在)
    if [ ! -f "$CFST_BIN" ]; then
        info "下载 CloudflareSpeedTest..."
        # vpnmax: ①固定版本（原为 latest）②按架构取包（原硬编码 amd64，arm64 机器会装错架构的二进制）
        local cfst_arch
        case "$(uname -m)" in
            aarch64|arm64) cfst_arch=arm64 ;;
            *) cfst_arch=amd64 ;;
        esac
        local cfst_file="cfst_linux_${cfst_arch}.tar.gz"
        local cfst_url="https://github.com/XIU2/CloudflareSpeedTest/releases/download/${CFST_PIN}/${cfst_file}"
        local tmp_dir="/tmp/cfst"
        mkdir -p "$tmp_dir"

        # 先取 pin 版；失败则告警回退 latest，避免 pin 失效后永远装不上
        if ! curl -fsSL --max-time 60 "$cfst_url" -o "$tmp_dir/cfst.tar.gz" 2>/dev/null; then
            warn "pin 版 CFST ${CFST_PIN} 下载失败，回退上游 latest"
            cfst_url="https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/${cfst_file}"
            if ! curl -fsSL --max-time 60 "$cfst_url" -o "$tmp_dir/cfst.tar.gz" 2>/dev/null; then
                rm -rf "$tmp_dir"
                error "CFST 下载失败"
                return 1
            fi
        fi

        if tar -xzf "$tmp_dir/cfst.tar.gz" -C "$tmp_dir" 2>/dev/null && [ -f "$tmp_dir/cfst" ]; then
            mv "$tmp_dir/cfst" "$CFST_BIN" 2>/dev/null
            chmod +x "$CFST_BIN" 2>/dev/null
            rm -rf "$tmp_dir"
            info "CFST 下载完成（${cfst_arch} / ${cfst_url##*/}）"
        else
            rm -rf "$tmp_dir"
            error "CFST 解包失败"
            return 1
        fi
    fi

    # 运行 CFST 优选
    # -tl: 延迟上限 (ms)
    # -sl: 速度下限 (MB/s)，100Mbps = 12.5MB/s
    # -dn: 测速数量
    # -n: 并发数
    info "运行 CFST 优选..."
    local result_file="/tmp/cfst-result.csv"
    local cfst_min_speed=12 # 100Mbps ≈ 12.5MB/s，取整 12
    "$CFST_BIN" -tl "$LATENCY_THRESHOLD" -sl "$cfst_min_speed" -dn 20 -n 100 -o "$result_file" -p 0 2>&1 || true

    if [ ! -f "$result_file" ] || [ ! -s "$result_file" ]; then
        error "CFST 优选失败，无结果"
        return 1
    fi

    # 解析结果，应用"速度优先，延迟折中"策略
    # CFST 输出格式: IP地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
    local best_file="/tmp/cfst-best.txt"

    # 跳过表头，逐行分析，结果写入临时文件（避免子 shell 变量问题）
    : >"$best_file"
    tail -n +2 "$result_file" | while IFS=',' read -r ip _sent _recv _loss latency speed colo; do
        # 跳过无效数据
        [ -z "$ip" ] && continue
        [ "$latency" = "0" ] && continue  # 延迟为 0 表示测试失败
        [ "$speed" = "0.00" ] && continue # 速度为 0 表示测试失败

        # 检查是否满足阈值
        local latency_int=${latency%%.*}
        if [ "$latency_int" -gt "$LATENCY_THRESHOLD" ]; then
            continue # 延迟超标，跳过
        fi

        # 计算分数：速度 * 1000 - 延迟（速度优先，延迟折中）
        local speed_mbps
        speed_mbps=$(echo "$speed * 8" | bc -l 2>/dev/null | awk '{printf "%.0f", $1}' || echo "0")
        local score=$((speed_mbps * 1000 - latency_int))

        # 更新最佳结果（写入临时文件）
        local current_best_score=0
        if [ -s "$best_file" ]; then
            current_best_score=$(cut -d'|' -f5 "$best_file" 2>/dev/null || echo "0")
        fi

        if [ "$score" -gt "$current_best_score" ]; then
            echo "$ip|$latency|$speed|$colo|$score" >"$best_file"
        fi
    done

    # 读取最佳结果
    local best_ip="" best_latency="" best_speed="" best_colo=""
    if [ -s "$best_file" ]; then
        best_ip=$(cut -d'|' -f1 "$best_file")
        best_latency=$(cut -d'|' -f2 "$best_file")
        best_speed=$(cut -d'|' -f3 "$best_file")
        best_colo=$(cut -d'|' -f4 "$best_file")
    fi

    # 如果没有找到合适的 IP，取第一行（CFST 已按延迟排序）
    if [ -z "$best_ip" ]; then
        best_ip=$(head -2 "$result_file" | tail -1 | cut -d',' -f1)
        best_latency=$(head -2 "$result_file" | tail -1 | cut -d',' -f5)
        best_speed=$(head -2 "$result_file" | tail -1 | cut -d',' -f6)
        best_colo=$(head -2 "$result_file" | tail -1 | cut -d',' -f7)
    fi

    if [ -z "$best_ip" ] || [ "$best_ip" = "IP 地址" ]; then
        error "CFST 结果解析失败"
        return 1
    fi

    info "优选结果: IP=$best_ip, 延迟=${best_latency}ms, 速度=${best_speed}MB/s, colo=$best_colo"

    # 写入 argo-extra.conf
    {
        echo "# vpnmax 边缘优选（$(date -Is)）：最优 colo $best_colo @ ${best_latency}ms via $best_ip"
        echo -n "--edge-ip-version 4"
        [ -n "${ARGO_REGION:-}" ] && echo -n " --region $ARGO_REGION"
        echo ""
    } >"$EXTRA_CONF" 2>/dev/null || {
        error "写入 $EXTRA_CONF 失败"
        return 1
    }

    # 更新状态
    LAST_GOOD_COLO="$best_colo"
    LAST_GOOD_IP="$best_ip"
    LAST_SPEED="$best_speed"
    LAST_TEST_TS=$(date +%s)
    FAIL_COUNT=0

    info "优选完成，配置已更新"
    return 0
}

# ── 重启隧道 ──────────────────────────────────────────────
restart_tunnel() {
    local now
    now=$(date +%s)

    # 冷却检查
    if [ $((now - LAST_RESTART_TS)) -lt "$COOLDOWN" ]; then
        info "冷却中，跳过重启 (距上次重启 $((now - LAST_RESTART_TS))s < ${COOLDOWN}s)"
        return 0
    fi

    info "重启 Argo 隧道 (通过 systemd)..."

    # 重启 systemd 服务
    if systemctl is-active --quiet cloudflared-argo.service; then
        systemctl restart cloudflared-argo.service
        info "已重启 cloudflared-argo.service"
    else
        # 如果服务不存在，回退到直接重启进程
        warn "cloudflared-argo.service 不存在，回退到直接重启进程"
        pkill -9 -f 'cloudflared.*tunnel.*--url' 2>/dev/null || true
        sleep 2

        # 解析 WS 端口
        local wsport
        wsport=$(jq -r '[.inbounds[] | select(.type=="vless" and .transport.type=="ws") | .listen_port][0] // empty' /etc/s-box/sb.json 2>/dev/null)
        [ -n "$wsport" ] && [ "$wsport" != "null" ] || wsport=$(jq -r '.inbounds[1].listen_port // empty' /etc/s-box/sb.json 2>/dev/null)

        if [ -z "$wsport" ] || [ "$wsport" = "null" ]; then
            error "WS 端口解析失败"
            return 1
        fi

        # 获取 cloudflared 路径
        local cfbin
        cfbin=$(command -v cloudflared 2>/dev/null)
        [ -x "${cfbin:-}" ] || cfbin=$(ls /etc/s-box/cloudflared /usr/local/bin/cloudflared 2>/dev/null | head -1)
        [ -x "${cfbin:-}" ] || {
            error "cloudflared 未找到"
            return 1
        }

        # 读取优选参数
        local extra_args=""
        if [ -f "$EXTRA_CONF" ]; then
            extra_args=$(grep -v '^#' "$EXTRA_CONF" 2>/dev/null | tr '\n' ' ' || true)
        fi

        # 启动新隧道
        nohup "$cfbin" tunnel --url "http://localhost:$wsport" --no-autoupdate --protocol auto \
            --edge-ip-version auto $extra_args >/etc/s-box/argo.log 2>&1 &
    fi

    sleep 5

    # 验证启动
    if pgrep -f 'cloudflared.*tunnel.*--url' >/dev/null 2>&1; then
        info "隧道重启成功"
        LAST_RESTART_TS=$(date +%s)
        return 0
    else
        error "隧道重启失败"
        return 1
    fi
}

# ── 刷新订阅 ──────────────────────────────────────────────
refresh_subscription() {
    info "刷新订阅..."
    printf '9\n1\n0\n0\n0\n' | timeout 30 bash /usr/bin/sb >/dev/null 2>&1 || true
    pkill -9 -f 'bash /usr/bin/sb' 2>/dev/null || true
}

# ── 主循环 ────────────────────────────────────────────────
main() {
    info "=== Edge Monitor 启动 ==="

    while true; do
        load_state

        # 1. 检查隧道进程
        if ! check_tunnel_alive; then
            warn "隧道进程不存在，重启..."
            restart_tunnel
            sleep 5
            continue
        fi

        # 2. 获取当前 colo
        local current_colo
        current_colo=$(get_current_colo)

        if [ -z "$current_colo" ]; then
            warn "无法获取当前 colo，跳过检查"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # 3. 检查是否在优选列表中
        if ! check_in_preferred_list "$current_colo"; then
            warn "当前 colo [$current_colo] 不在优选列表中"
            FAIL_COUNT=$((FAIL_COUNT + 1))

            if [ "$FAIL_COUNT" -ge "$MAX_FAIL_COUNT" ]; then
                warn "连续失败 $FAIL_COUNT 次，触发重新优选"
                if trigger_optimization; then
                    refresh_subscription
                    restart_tunnel
                fi
                FAIL_COUNT=0
            fi
        else
            # 4. 延迟测试
            local current_ip
            current_ip=$(get_current_edge_ip)

            if [ -n "$current_ip" ]; then
                local latency
                latency=$(test_latency "$current_ip")

                if [ "$latency" -gt "$LATENCY_THRESHOLD" ]; then
                    warn "延迟过高: ${latency}ms > ${LATENCY_THRESHOLD}ms"
                    FAIL_COUNT=$((FAIL_COUNT + 1))

                    if [ "$FAIL_COUNT" -ge "$MAX_FAIL_COUNT" ]; then
                        warn "连续失败 $FAIL_COUNT 次，触发速度测试"

                        # 5. 速度测试
                        local speed
                        speed=$(test_speed "$current_ip")

                        if [ "$(echo "$speed < $SPEED_THRESHOLD" | bc -l 2>/dev/null || echo "1")" = "1" ]; then
                            warn "速度过低: ${speed}Mbps < ${SPEED_THRESHOLD}Mbps"
                            trigger_optimization
                            refresh_subscription
                            restart_tunnel
                        else
                            info "速度正常: ${speed}Mbps"
                        fi
                        FAIL_COUNT=0
                    fi
                else
                    # 一切正常
                    info "✓ 隧道正常: colo=$current_colo, 延迟=${latency}ms"
                    FAIL_COUNT=0
                fi
            fi
        fi

        save_state
        sleep "$CHECK_INTERVAL"
    done
}

# ── 入口 ──────────────────────────────────────────────────
case "${1:-}" in
--check-once)
    # 单次检查模式
    load_state
    if check_tunnel_alive; then
        echo "✓ 隧道运行中"
        exit 0
    else
        echo "✗ 隧道未运行"
        exit 1
    fi
    ;;
--optimize)
    # 手动触发优选
    trigger_optimization
    ;;
*)
    main
    ;;
esac
