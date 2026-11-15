#!/bin/bash
# lib/subscription.sh — 订阅管理
[ -n "${VPNMAX_SUB_LOADED:-}" ] && return 0
VPNMAX_SUB_LOADED=1

# ── 订阅安全基线（P0-6/P0-7/P0-8）──
# token 白名单：8-64 位字母数字/_/-；port：1024-65535 纯数字。命中失败即 fail-closed。
vpnmax_valid_subtoken() { printf '%s' "${1:-}" | grep -qE '^[A-Za-z0-9_-]{8,64}$'; }
vpnmax_valid_subport() {
    case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] 2>/dev/null
}
# 高熵随机 token（openssl 优先，/dev/urandom 兜底；绝不复用 UUID 当订阅密码）
vpnmax_new_subtoken() {
    local t=""
    t=$(openssl rand -hex 16 2>/dev/null || true)
    [ -n "$t" ] || t=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || true)
    printf '%s' "$t"
}
# 私钥/订阅凭证统一 0600（默认 umask 下 echo 重定向会落成 644）
ensure_sub_perms() {
    chmod 600 /etc/s-box/private.key /etc/s-box/subtoken.log /etc/s-box/subport.log 2>/dev/null || true
    chmod 644 /etc/s-box/cert.pem /etc/s-box/public.key 2>/dev/null || true
}

setup_subscription() {
    info "配置本地订阅链接..."
    sleep 1
    # RESET_SUB=1 / --reset-sub：暴露后一键轮转（删旧 token/端口，强制全新）
    if [ "${RESET_SUB:-0}" = "1" ] || [ "${RESET_SUB:-}" = "true" ]; then
        if $DRY_RUN; then
            info "[dry-run] RESET_SUB=1 将删除旧订阅并生成全新 token/端口"
        else
            info "RESET_SUB=1 检测到，清理旧订阅（旧链接将失效）..."
            rm -f /etc/s-box/subport.log /etc/s-box/subtoken.log 2>/dev/null || true
            rm -rf /root/websbox/* 2>/dev/null || true
            # 同步清理旧 sb 生成的聚合文件，避免残留
            rm -f /etc/s-box/jhsub.txt /etc/s-box/jhdy.txt 2>/dev/null || true
            ok "旧订阅已清理，下一步将生成全新 token/端口"
        fi
    fi
    # 端口稳定性：重跑时复用已有订阅端口，避免每次随机导致客户端订阅地址作废
    local KEEP_PORT=""
    if [ -f /etc/s-box/subport.log ]; then
        local _p
        _p=$(grep -oE '[0-9]{1,5}' /etc/s-box/subport.log 2>/dev/null | head -1 || true)
        # 仅复用合法端口段（与 sb 随机范围一致），异常值则放弃复用走随机
        if [ -n "$_p" ] && [ "$_p" -ge 1024 ] && [ "$_p" -le 65535 ] 2>/dev/null; then
            KEEP_PORT="$_p"
        fi
    fi
    if [ -n "$KEEP_PORT" ]; then
        info "检测到已有订阅端口 $KEEP_PORT，重跑将复用（客户端订阅地址保持有效）"
    fi
    if ! $DRY_RUN; then
        # 投喂序列对齐当前 sb 菜单（v26.x）：
        #   main changeserv(配置变更) → 8(设置本地IP订阅) → 1(重置安装) →
        #   \n(路径密码=当前UUID) → <端口行：已有端口则原样输入保持稳定，否则\n随机> → 尾部补足 0 逐层返回/退出
        # 即便中间 sleep 3 递归拉起新 sb 面板，sb_feed 的 timeout+pkill 也会兜底清理，绝不卡死。
        sb_feed 150 <<-EOSUB || true
3
8
1

${KEEP_PORT}

0
0
0
0
0
EOSUB
        sleep 3
    else
        info "[dry-run] sb 菜单 3-8-1 配置订阅${KEEP_PORT:+（复用端口 $KEEP_PORT）}"
    fi
    if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
        ensure_sub_perms
        ok "订阅配置成功"
        return 0
    fi
    warn "订阅配置产物未生成（sb 菜单结构可能已变更）"
    info "手动: sb → 3 → 8 → 1"
    return 1
}

get_sub_port() {
    local port=""
    if [ -f /etc/s-box/subport.log ]; then
        port=$(grep -oE '[0-9]{1,5}' /etc/s-box/subport.log 2>/dev/null | head -1 || true)
        if vpnmax_valid_subport "$port"; then
            echo "$port"
            return 0
        fi
        port=""
    fi
    port=$(ss -tlnp 2>/dev/null | grep -iE 'busybox|httpd|lighttpd|nginx' | awk '{print $4}' | grep -oE '[0-9]+$' | head -1 || true)
    vpnmax_valid_subport "$port" || return 1
    echo "$port"
}

wait_subscription() {
    info "等待订阅服务启动..."
    local SUB_PORT=""
    for _ in $(seq 1 30); do
        sleep 2
        SUB_PORT=$(get_sub_port)
        [ -n "$SUB_PORT" ] && break
    done
    if [ -n "$SUB_PORT" ]; then
        ok "订阅端口: $SUB_PORT"
        # 这里只确认「端口已监听」。不在这里判 HTTP 是否 200：sbshare 生成
        # clmi.yaml 比监听端口晚得多（实测 >10s），此时查必然 404——而部署末尾
        # 就绪状态本来就要再查一次，同类检查做两遍只会多出一个假警告。
        info "订阅内容仍在生成，就绪状态在部署末尾统一确认"
    else
        warn "订阅服务超时未启动（已等 60s）"
    fi
}

ensure_sub_httpd() {
    local port
    port=$(get_sub_port 2>/dev/null)
    if ! vpnmax_valid_subport "$port"; then
        warn "订阅端口非法（${port:-空}），跳过订阅服务保障（防 crontab 注入）"
        return 1
    fi
    command -v busybox >/dev/null 2>&1 || {
        warn "busybox 不可用，跳过订阅服务保障"
        return 1
    }
    if ! $DRY_RUN; then
        # 回环绑定：订阅 HTTP 只听 127.0.0.1（busybox -p 支持 [IP:]PORT 写法），扫段拖链直接断
        {
            crontab -l 2>/dev/null | grep -vE 'busybox httpd.*(/root/websbox|subport.log)'
            echo "@reboot sleep 10 && /bin/bash -c \"busybox httpd -f -p 127.0.0.1:${port} -h /root/websbox > /dev/null 2>&1 &\""
        } | crontab - 2>/dev/null || true
    else
        info "[dry-run] 写入 @reboot 订阅服务自启"
    fi
    if ss -tln 2>/dev/null | grep -q ":$port"; then
        ok "订阅 HTTP 服务运行中 (端口 $port)"
    else
        if $DRY_RUN; then
            info "[dry-run] 启动 busybox httpd (端口 $port)"
        else
            # 精确清理：只停监听该端口的 busybox（不 pkill -x busybox 杀全局）
            local pids
            pids=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | sed 's/pid=//' | sort -u || true)
            [ -n "$pids" ] && {
                for p in $pids; do kill "$p" 2>/dev/null || true; done
                sleep 1
            }
            mkdir -p /root/websbox
            nohup busybox httpd -f -p "127.0.0.1:${port}" -h /root/websbox >/dev/null 2>&1 &
            sleep 2
        fi
        if ss -tln 2>/dev/null | grep -q ":$port"; then
            ok "订阅 HTTP 服务已启动"
        else
            warn "订阅 HTTP 服务启动失败，请手动检查"
        fi
    fi
}

# 节点一览：上游 sb 每次调用都刷一遍的节点摘要已被 sbfeed 过滤器折叠，
# 这里用自己的数据（sb.json）重新打一张紧凑表，端口/sni 一目了然。
show_nodes() {
    [ -f /etc/s-box/sb.json ] || return 0
    local rows
    rows=$(jq -r '.inbounds[]?
        | select(.type=="vless" or .type=="vmess" or .type=="hysteria2" or .type=="tuic" or .type=="anytls")
        | [.type, (.listen_port // .port // 0 | tostring), (.tls.server_name // "-")] | @tsv' \
        /etc/s-box/sb.json 2>/dev/null) || true
    [ -n "$rows" ] || return 0
    echo ""
    info "━━━ 节点 ━━━"
    printf '%s\n' "$rows" | awk -F'\t' '
        { name = $1; if (name == "hysteria2") name = "hy2"; if (name == "vmess") name = "vmess-ws"
          printf "  %-12s %-7s %s\n", name, $2, ($3 == "-" ? "" : "sni=" $3) }'
}

# 订阅里实际写入的 server 字段——链接与告警的唯一真相源。
# 为什么不能各取各的：clmi.yaml 的 server 由 sbshare 生成，而出口 IP 是现查的，
# 两者可能不同步（sbshare 超时/没跑完）——就会出现「告警说还是 IPv6、
# 下面链接却全是 IPv4」这种自相矛盾，用户会当成故障。
sub_server_ip() {
    local v=""
    v=$(grep -m1 -E '^[[:space:]]*server:[[:space:]]*' /etc/s-box/clmi.yaml 2>/dev/null \
        | sed 's/^[[:space:]]*server:[[:space:]]*//' | tr -d '"[:space:]' || true)
    if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
    curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null ||
        curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null ||
        echo "你的服务器IP"
}

show_subscription() {
    local sub_port token public_ip
    sub_port=$(get_sub_port 2>/dev/null || true)
    if [ -z "$sub_port" ] || [ ! -f /etc/s-box/subtoken.log ]; then
        warn "订阅链接未生成：缺少订阅端口或 token"
        return 1
    fi
    token=$(tr -cd 'a-zA-Z0-9_-' </etc/s-box/subtoken.log 2>/dev/null || true)
    if ! vpnmax_valid_subport "$sub_port" || ! vpnmax_valid_subtoken "$token"; then
        warn "订阅端口/token 未通过白名单校验（port=[0-9]/1024-65535，token=8-64位字母数字/_/-），拒绝拼链接"
        return 1
    fi
    public_ip=$(sub_server_ip 2>/dev/null || true)
    [ -n "$public_ip" ] || public_ip="你的服务器IP"
        # 末尾就绪确认：链接印出去之前先真打一次，200 就说 200，
        # 不是 200 就如实告警（此时已过完全部步骤，再不到就是真问题）。
        local _code="000" _i
        for _i in $(seq 1 5); do
            # --noproxy：用户机器上常残留 http_proxy，连 127.0.0.1 也会被送去代理
            # （实测本机自检返回 502），本机检查必须绕开代理
            _code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 \
                "http://127.0.0.1:${sub_port}/${token}/clmi.yaml" 2>/dev/null || echo 000)
            [ "$_code" = "200" ] && break
            sleep 1
        done
        if [ "$_code" = "200" ]; then ok "订阅服务就绪（本机 HTTP 200）"
        else warn "订阅端口 ${sub_port} 返回 HTTP ${_code}，客户端可能导入失败：检查 ss -tlnp | grep ${sub_port}"; fi
        echo ""
        info "━━━ 订阅链接 ━━━"
    echo ""
    echo "Clash / Mihomo:"
    echo "http://${public_ip}:${sub_port}/${token}/clmi.yaml"
    echo ""
    echo "Sing-box:"
    echo "http://${public_ip}:${sub_port}/${token}/sbox.json"
    echo ""
    echo "通用聚合:"
    echo "http://${public_ip}:${sub_port}/${token}/jhsub.txt"
    echo ""
    # 这是一条长期提示而非本次部署的问题，不该出现在「需要注意」里
    hint "订阅走 HTTP + IP:端口；移动网络可能拦截高端口，必要时改用 Argo/HTTPS 入口。"
    return 0
}
