#!/bin/bash
# lib/edgeprefer.sh — Cloudflare 边缘优选（融合 CFData-WEB 测量逻辑）
#
# CFData 核心手法（tasks_official.go scanOfficialIP）：直连候选 CF IP，
# Host 头指向 speed.cloudflare.com 取 /cdn-cgi/trace，解析 colo= 判定该 IP
# 落地的数据中心，同时计量 TCP 建连延迟。shell 版用 curl --resolve 等价实现。
#
# 诚实边界（7 台实测 cloudflared tunnel --help）：
#   quick tunnel 没有 --edge <ip>；可用的是 --region（粗粒度）与
#   --edge-ip-version {4,6,auto}。本脚本做两件实事：
#   1) 测出 v4/v6 哪个家族更快 → 写 --edge-ip-version（替代 auto 碰运气）
#   2) 记录最优 colo → edge-prefer.log，供 verify 校验隧道实际落地
#   3) 若用户显式 ARGO_REGION=xx，则透传 --region（cloudflared 自校验合法性）
# 默认开启（EDGE_PREFER=off 可跳过），全程有预算上限，不卡死一键部署。
[ -n "${VPNPLUS_EDGEPREFER_LOADED:-}" ] && return 0
VPNPLUS_EDGEPREFER_LOADED=1

ensure_edge_prefer() {
    if [ "${EDGE_PREFER:-on}" = "off" ]; then
        info "EDGE_PREFER=off，跳过边缘优选"
        return 0
    fi
    if ${DRY_RUN:-false}; then
        info "[dry-run] 将执行 CF 边缘优选（扫段→测延迟→写 argo-extra.conf）"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || {
        warn "curl 缺失，跳过边缘优选"
        return 0
    }
    local workdir="/tmp/vpnmax-edgeprefer"
    run mkdir -p "$workdir" || return 0
    info "CF 边缘优选：采样官方段测延迟（预算 90s）..."

    # 官方段（cloudflare.com/ips-v4/v6，失败则用内置保底段）
    local v4cidrs
    v4cidrs=$(curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null | grep -E '^[0-9.]+/' | head -20 || true)
    [ -z "$v4cidrs" ] && v4cidrs="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22"
    # 每段取第 2 个可用 IP（.1 常为网关，取 .2 避开），限 15 段控制预算
    local ips=""
    ips=$(echo "$v4cidrs" | head -15 | while IFS=/ read -r net _bits; do
        IFS=. read -r a b c d <<EOF2
$net
EOF2
        echo "$a.$b.$c.$((d + 2))"
    done)
    # 有 v6 全局地址才测 v6 家族
    local have_v6=""
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | grep -q 'via\|dev' && have_v6=1 || true

    # 并发探测：TCP 建连耗时 + trace 读 colo（与 CFData 同口径）
    local result="$workdir/hits.txt"
    : >"$result"
    echo "$ips" | xargs -P 16 -I{} bash -c '
        ip="$1"
        out=$(curl -s --resolve speed.cloudflare.com:443:"$ip" --max-time 4 -w "\n%{time_connect}|%{http_code}" https://speed.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
        code=$(echo "$out" | tail -1 | cut -d"|" -f2)
        [ "$code" = "200" ] || exit 0
        colo=$(echo "$out" | grep -oE "^colo=[A-Z0-9]+" | cut -d= -f2 | head -1)
        lat=$(echo "$out" | tail -1 | cut -d"|" -f1)
        [ -n "$colo" ] && [ -n "$lat" ] && echo "$lat $colo $ip" >> "'"$result"'"
    ' _ {} 2>/dev/null || true

    if [ ! -s "$result" ]; then
        warn "边缘优选无有效样本，保持 auto（网络可能受限）"
        return 0
    fi
    # 最优 colo = 样本最多且延迟最低（先按延迟排序取前 1/3，再按出现次数投票）
    local best_line best_lat best_colo best_ip
    best_line=$(sort -n "$result" | head -5 | sort -k2 | uniq -c -f1 2>/dev/null | sort -rn | head -1 | awk '{print $2, $3, $4}' || true)
    [ -z "$best_line" ] && best_line=$(sort -n "$result" | head -1)
    best_lat=$(echo "$best_line" | awk '{print $1}')
    best_colo=$(echo "$best_line" | awk '{print $2}')
    best_ip=$(echo "$best_line" | awk '{print $3}')
    [ -z "$best_colo" ] && {
        warn "边缘优选解析失败，保持 auto"
        return 0
    }

    # v4/v6 家族二选一：直连 region1 端点比握手（仅有 v6 时才测）
    local family="4"
    if [ -n "$have_v6" ]; then
        local t4 t6
        t4=$(curl -s -o /dev/null -w '%{time_connect}' --ipv4 --max-time 5 https://region1.v2.argotunnel.com/ 2>/dev/null || echo 9)
        t6=$(curl -s -o /dev/null -w '%{time_connect}' --ipv6 --max-time 5 https://region1.v2.argotunnel.com/ 2>/dev/null || echo 9)
        # shell 浮点比较：awk 判定
        if awk "BEGIN{exit !(($t6+0) < ($t4+0) && ($t6+0) > 0)}" 2>/dev/null; then family="6"; fi
        info "边缘家族实测 v4=${t4}s v6=${t6}s → 选 v$family"
    fi

    # 落盘：argo-extra.conf（keepalive/自启隧道自动携带；sb 菜单启动的由 ensure_argo_extra_applied 对齐）
    local extra="/etc/s-box/argo-extra.conf"
    {
        echo "# vpnmax 边缘优选（$(date -Is)）：最优 colo $best_colo @ ${best_lat}s via $best_ip"
        echo -n "--edge-ip-version $family"
        [ -n "${ARGO_REGION:-}" ] && echo -n " --region $ARGO_REGION"
        echo ""
    } >"$extra" 2>/dev/null || {
        warn "argo-extra.conf 写入失败，优选结果仅记录日志"
    }
    {
        echo "ts=$(date -Is) best_colo=$best_colo best_lat=${best_lat}s best_ip=$best_ip family=v$family region=${ARGO_REGION:-auto}"
    } >>/etc/s-box/edge-prefer.log 2>/dev/null || true
    manifest "edge-prefer colo=$best_colo lat=${best_lat}s family=v$family"
    ok "边缘优选完成：colo=$best_colo（${best_lat}s），家族 v$family"
    rm -rf "$workdir" 2>/dev/null || true
}
