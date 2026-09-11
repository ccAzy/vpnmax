#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnmax — 部署后验证脚本
# 检查 sing-box 进程、端口、独立防火墙链、Argo 隧道、订阅链接、域名分流
#
# 与旧版差异：验证独立命名链（VPNMAX_PORTHOP / VPNMAX_ANTIPROBE）是否存在，
#   不再 grep 全局 INPUT/PREROUTING 规则（旧法易误判/误删第三方规则）。
# 用法: bash verify.sh [SERVER_IP]
# ===================================================================
set -euo pipefail

# lib 加载（verify 侧仅需 time/tuic 检查，失败则用内联兜底）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in common time verify/time verify/tuic; do
    if [ -f "$SCRIPT_DIR/lib/${_lib}.sh" ]; then
        source "$SCRIPT_DIR/lib/${_lib}.sh" 2>/dev/null || true
    elif [ -f "lib/${_lib}.sh" ]; then
        source "lib/${_lib}.sh" 2>/dev/null || true
    fi
done

SERVER_IP="${SERVER_IP:-${1:-}}" # 兼容两种用法：SERVER_IP=x.x.x.x bash verify.sh 或 bash verify.sh x.x.x.x
VMESS_LOCK="${VMESS_LOCK:-off}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
N='\033[0m'
ok() { echo -e "${GREEN}[✓]${N}   $*"; }
warn() { echo -e "${YELLOW}[!]${N}   $*"; }
fail() { echo -e "${RED}[✗]${N}   $*"; }
info() { echo -e "${CYAN}[*]${N}   $*"; }

PASS=0
FAIL=0
CHAIN_PORTHOP="VPNMAX_PORTHOP"
CHAIN_ANTIPROBE="VPNMAX_ANTIPROBE"
check() {
    local desc="$1"
    shift
    if "$@" 2>/dev/null; then
        ok "$desc"
        PASS=$((PASS + 1))
        return 0
    else
        fail "$desc"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

echo ""
echo "========================================="
echo "  vpnmax 部署验证"
echo "========================================="
echo ""

# 1. 基础
echo "--- 基础状态 ---"
check "sb 命令存在" command -v sb
SB_BIN=""
for _b in /usr/bin/sing-box /usr/local/bin/sing-box /etc/s-box/sing-box; do [ -x "$_b" ] && {
    SB_BIN="$_b"
    break
}; done
check "sing-box 二进制" [ -n "$SB_BIN" ]
check "/etc/s-box 目录" [ -d /etc/s-box ]

if command -v modinfo >/dev/null 2>&1; then
    if modinfo tcp_bbr 2>/dev/null | grep -qi 'bbr3\|bbr v3'; then
        ok "BBRv3 内核模块已就位"
        PASS=$((PASS + 1))
    else
        warn "tcp_bbr 为主线 BBRv1（未启用 BBRv3 内核，先执行 deploy_optimize.sh）"
    fi
else
    warn "modinfo 不可用，跳过 BBRv3 检测"
fi

IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
if [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
    if ethtool -k "$IFACE" 2>/dev/null | grep -q 'tx-udp-segmentation: on'; then
        ok "UDP 分段卸载已开启（Hy2/Tuic）"
        PASS=$((PASS + 1))
    else
        warn "UDP 分段卸载未开启或驱动不支持"
    fi
fi
if [ -n "$IFACE" ] && command -v tc >/dev/null 2>&1; then
    if tc qdisc show dev "$IFACE" 2>/dev/null | grep -qE '(^| )fq([ _]|$)'; then
        ok "默认网卡 fq 队列调度已启用"
        PASS=$((PASS + 1))
    else
        warn "默认网卡未检测到 fq 队列调度"
    fi
fi
if systemctl is-active --quiet vpnmax-net-tuning.service 2>/dev/null; then
    ok "持久化网络调优服务运行中"
    PASS=$((PASS + 1))
    systemctl is-enabled --quiet vpnmax-net-tuning.service 2>/dev/null && ok "网络调优服务已启用(开机自启)" || warn "网络调优服务未 enable"
else
    warn "持久化网络调优服务未运行（可能尚未执行 deploy_optimize.sh）"
fi

# 防火墙持久化恢复单元（#2026-08-25：防重启后 VPNMAX_* 链丢失）
if [ -f /etc/systemd/system/vpnmax-netfilter-restore.service ]; then
    ok "vpnmax-netfilter-restore.service 存在"
    PASS=$((PASS + 1))
    systemctl is-enabled --quiet vpnmax-netfilter-restore.service 2>/dev/null && ok "防火墙恢复单元已启用" || warn "防火墙恢复单元未 enable"
else
    warn "未检测到 vpnmax-netfilter-restore.service（重启后端口跳跃/防探测规则可能不自动恢复）"
fi
# 日志轮转配置
if [ -f /etc/logrotate.d/vpnmax ]; then
    ok "日志轮转配置存在"
    PASS=$((PASS + 1))
else warn "未检测到 logrotate 配置"; fi

# 1a. sing-box 1.12+ legacy 环境变量（2026-08-27 JP/HK 崩溃根因）
echo "--- sing-box 兼容 ---"
if grep -q "ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS" /etc/systemd/system/sing-box.service.d/99-vpnmax.conf 2>/dev/null; then
    ok "sing-box legacy env 已注入"
    PASS=$((PASS + 1))
else warn "sing-box legacy env 缺失（1.12+ 会 FATAL 崩溃，需 ensure_singbox_legacy_env）"; fi
if grep -q "^precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null && [ "$(grep -c "^precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null)" -eq 1 ]; then
    ok "gai.conf IPv4 优先单行"
    PASS=$((PASS + 1))
else warn "gai.conf 重复或缺失 precedence ::ffff:0:0/96 100（去重后应为单行）"; fi
# IPv4 锁定校验（G2 vpnmax：目标 prefer_ipv4，与 7 台调优最佳状态对齐）
if [ -f /etc/s-box/sb.json ]; then
    _ipv4_bad=""
    _ipv4_bad+=$(jq -r '.route.rules[]? | select(.strategy != null and .strategy != "prefer_ipv4") | .strategy' /etc/s-box/sb.json 2>/dev/null | head -1 || true)
    _ipv4_bad+=$(jq -r '.outbounds[]? | select(.type=="direct" or .type=="socks") | select(.domain_strategy != "prefer_ipv4") | .type+":"+(.domain_strategy//"null")' /etc/s-box/sb.json 2>/dev/null | head -1 || true)
    _ipv4_bad+=$(jq -r '.dns.strategy? // empty | select(. != "prefer_ipv4")' /etc/s-box/sb.json 2>/dev/null | head -1 || true)
    if [ -z "$_ipv4_bad" ]; then
        ok "IPv4 锁定 prefer_ipv4 已生效（route/outbounds/dns）"
        PASS=$((PASS + 1))
    else warn "IPv4 未锁定: $_ipv4_bad 仍非 prefer_ipv4，重跑 deploy 即自动对齐"; fi
else warn "sb.json 不存在，跳过 IPv4 锁定校验"; fi
# 入口IP（订阅 server:）校验：server_ip.log 应为 IPv4，否则订阅入口仍是 v6，verify 会漏报
if [ -f /etc/s-box/server_ip.log ]; then
    _srv=$(cat /etc/s-box/server_ip.log 2>/dev/null | tr -d '[]' | tr -d '\r\n')
    if echo "$_srv" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        ok "订阅入口IP已切 IPv4 ($_srv)"
        PASS=$((PASS + 1))
    else warn "订阅入口仍非 IPv4 ($_srv)，建议 sb→15→1 或 bash deploy_singbox.sh --force"; fi
else warn "server_ip.log 不存在，跳过入口IP校验"; fi

# 1c. 调优缺口回归（vpnmax G1/G3/G5/G6/G7：7 台实测缺口，只读告警）
echo "--- 调优缺口回归 ---"
# G1：SSH 加固（判定时必须用运行中的 /usr/sbin/sshd，裸 sshd 可能是 /usr/local 自编译版）
_SSHD_BIN="/usr/sbin/sshd"
[ -x "$_SSHD_BIN" ] || _SSHD_BIN="sshd"
if "$_SSHD_BIN" -T -f /etc/ssh/sshd_config 2>/dev/null | grep -qi '^passwordauthentication yes'; then
    warn "G1: SSH 密码登录仍开着（应为 no）"
else
    ok "G1: SSH 密码登录已关"
    PASS=$((PASS + 1))
fi
if "$_SSHD_BIN" -T -f /etc/ssh/sshd_config 2>/dev/null | grep -qi '^permitrootlogin yes'; then
    warn "G1: PermitRootLogin 非 prohibit-password"
else
    ok "G1: root 仅密钥登录"
    PASS=$((PASS + 1))
fi
# G3：旧 ACVPN 残留
_G3_LEFTOVER=""
for _lf in /etc/sysctl.d/99-acvpn.conf /etc/sysctl.d/99-ACVPN-security.conf /etc/sysctl.d/99-ACVPN-brutal.conf /etc/systemd/system/sing-box.service.d/99-acvpn.conf; do
    [ -f "$_lf" ] && _G3_LEFTOVER="$_G3_LEFTOVER $_lf"
done
if [ -n "$_G3_LEFTOVER" ]; then warn "G3: 旧 ACVPN 残留未清:$_G3_LEFTOVER（重跑 deploy_optimize.sh 自动清）"; else
    ok "G3: 无旧 ACVPN 残留"
    PASS=$((PASS + 1))
fi
# G5：内核版本一致性（BBRv3-max 小版本漂移告警）
_KVER=$(uname -r 2>/dev/null || true)
if echo "$_KVER" | grep -q 'bbrv3'; then
    ok "G5: BBRv3 内核 $_KVER"
    PASS=$((PASS + 1))
else warn "G5: 当前内核非 bbrv3 ($_KVER)，需跑 deploy_optimize.sh"; fi
# G6：cloudflared 版本（pin 2026.8.3， drift 告警不强更）
_CF_BIN=""
for _cb in /etc/s-box/cloudflared /usr/local/bin/cloudflared; do [ -x "$_cb" ] && {
    _CF_BIN="$_cb"
    break
}; done
if [ -n "$_CF_BIN" ]; then
    _CF_VER=$("$_CF_BIN" --version 2>/dev/null | grep -oE '20[0-9.]+' | head -1 || true)
    if [ "$_CF_VER" = "2026.8.3" ]; then
        ok "G6: cloudflared $_CF_VER（已 pin）"
        PASS=$((PASS + 1))
    else warn "G6: cloudflared $_CF_VER 非 pin 版 2026.8.3（手动升级指引见 README）"; fi
else warn "G6: cloudflared 二进制缺失"; fi
# G7：订阅-隧道一致性（运行域名必须出现在 Argo 订阅产物里）
_RUN_DOM=$(grep -ao 'https://[a-z0-9.-]*\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null | tail -1 | sed 's|https://||' || true)
if [ -n "$_RUN_DOM" ]; then
    _G7_OK=true
    for _sf in /etc/s-box/jhsub.txt /etc/s-box/jhdy.txt /etc/s-box/clmi.yaml /etc/s-box/sbox.json /etc/s-box/vm_ws_argols.txt; do
        if [ -f "$_sf" ] && grep -q 'trycloudflare' "$_sf" 2>/dev/null && ! grep -q "$_RUN_DOM" "$_sf" 2>/dev/null; then
            warn "G7: $_sf 仍是旧域名（运行域 $_RUN_DOM），keepalive 下轮补同步"
            _G7_OK=false
        fi
    done
    $_G7_OK && {
        ok "G7: 订阅与运行隧道域名一致 ($_RUN_DOM)"
        PASS=$((PASS + 1))
    }
else warn "G7: argo.log 无运行域名，隧道可能未启动"; fi
# 品牌切割回归：旧 vpnplus/ACVPN 资产应已被迁移，无残留
_MIG_OK=true
for _mf in /etc/systemd/system/vpnplus-net-tuning.service /etc/systemd/system/vpnplus-netfilter-restore.service /usr/local/sbin/vpnplus-argo-keepalive.sh /etc/logrotate.d/vpnplus /etc/systemd/system/sing-box.service.d/99-vpnplus.conf /etc/.vpnplus-optimized /etc/.vpnplus-singbox; do
    if [ -e "$_mf" ]; then
        warn "迁移残留: $_mf 仍存在（重跑 deploy 即接管清理）"
        _MIG_OK=false
    fi
done
for _mc in ACVPN_PORTHOP ACVPN_ANTIPROBE ACVPN_RSS; do
    if iptables -L "$_mc" -n >/dev/null 2>&1 || iptables -t nat -L "$_mc" -n >/dev/null 2>&1; then
        warn "迁移残留: 旧链 $_mc 仍存在（重跑 deploy 即拆除）"
        _MIG_OK=false
    fi
done
$_MIG_OK && {
    ok "品牌切割无残留（旧 units/链/marker 已接管）"
    PASS=$((PASS + 1))
}

# 1b. 时间同步（P0：Reality/VMess 握手对时，漂移>90s 全不通，但端口照常通）
if declare -F verify_time >/dev/null 2>&1; then verify_time; else
    echo "--- 时间同步 ---"
    if command -v chronyc >/dev/null 2>&1; then
        if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then
            ok "chrony 已同步（Leap Normal）"
            PASS=$((PASS + 1))
        else warn "chrony 未 Normal（$(chronyc tracking 2>/dev/null | grep 'Leap status' | head -1)）"; fi
        if chronyc sources -v 2>/dev/null | grep -q '\^'; then
            ok "chrony 源可达"
            PASS=$((PASS + 1))
        else warn "chrony 源不可达或未配置国内源"; fi
    else
        warn "chrony 未安装（时间漂移会导致 bad timestamp 全不通，建议 apt install chrony）"
    fi
    if timedatectl 2>/dev/null | grep -q 'System clock synchronized: yes'; then
        ok "System clock synchronized: yes"
        PASS=$((PASS + 1))
    else warn "System clock synchronized: no（timedatectl）"; fi
    _off=$(timeout 5 ntpdate -q ntp.aliyun.com 2>&1 | grep -oE 'offset .* sec' | head -1 || true)
    [ -n "$_off" ] && info "NTP 偏移: $_off"
fi

# 2. 进程
echo "--- 进程检查 ---"
if pgrep -f sing-box >/dev/null; then
    ok "sing-box 进程运行中"
    PASS=$((PASS + 1))
    pgrep -af sing-box 2>/dev/null | while read -r line; do info "$line"; done || true
else
    fail "sing-box 进程未运行"
    FAIL=$((FAIL + 1))
fi

# 3. 端口 + 独立防火墙链
echo "--- 端口与防火墙 ---"
PORTS=$(ss -tlnp 2>/dev/null | grep sing-box | awk '{print $4}' | grep -oE '[0-9]+$' | sort -n | tr '\n' ' ' || true)
if [ -n "$PORTS" ]; then
    ok "监听端口: $PORTS"
    PASS=$((PASS + 1))
else
    fail "未检测到 sing-box 监听端口"
    FAIL=$((FAIL + 1))
fi
if ss -ulnp 2>/dev/null | grep -q sing-box; then
    ok "UDP 端口监听正常（Hysteria2）"
    PASS=$((PASS + 1))
else warn "未检测到 UDP 端口"; fi

# 独立命名链存在性（vpnmax 防火墙设计核心）
if iptables -t nat -L "$CHAIN_PORTHOP" -n >/dev/null 2>&1; then
    ok "端口跳跃链 ${CHAIN_PORTHOP:-VPNMAX_PORTHOP} 存在"
    PASS=$((PASS + 1))
else warn "端口跳跃链不存在（可能未配置端口跳跃）"; fi
# PREROUTING 是否残留指向过期端口的孤立跳跃段规则（会导致 hy2/tuic 端口跳跃握手无响应）
# 注意：40000:42000 / 43000:45000 与 deploy_singbox.sh 顶部的 HOP_HY_RANGE / HOP_TU_RANGE 保持同步
HOP_LEAK=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E "DNAT|REDIRECT" | grep -E "40000:42000|43000:45000" | grep -v "VPNMAX_PORTHOP" | head -1 || true)
if [ -n "$HOP_LEAK" ]; then warn "检测到 PREROUTING 残留过期端口跳跃规则: $HOP_LEAK（重跑 deploy_singbox.sh 会自动清理）"; else
    ok "PREROUTING 无残留端口跳跃段"
    PASS=$((PASS + 1))
fi
if iptables -L "$CHAIN_ANTIPROBE" -n >/dev/null 2>&1; then
    ok "防探测链 ${CHAIN_ANTIPROBE:-VPNMAX_ANTIPROBE} 存在"
    PASS=$((PASS + 1))
else warn "防探测链不存在"; fi

# 3b. TUIC 端口可用性（P0：40254 为已知易被墙端口）
if declare -F verify_tuic >/dev/null 2>&1; then verify_tuic; else
    TU_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)
    if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; then
        if [ "$TU_PORT" = "40254" ]; then warn "TUIC 仍为 40254（已知易被运营商限速，建议切 54321 并重建跳跃 DNAT）"; else
            ok "TUIC 端口 $TU_PORT 非已知污染端口"
            PASS=$((PASS + 1))
        fi
        if iptables -t nat -L "$CHAIN_PORTHOP" -n 2>/dev/null | grep -q "to::${TU_PORT}"; then
            ok "端口跳跃 DNAT 指向 TUIC $TU_PORT"
            PASS=$((PASS + 1))
        else warn "端口跳跃 DNAT 未指向 TUIC $TU_PORT（43000:45000 应 DNAT 到 :$TU_PORT）"; fi
    fi
    if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ] && command -v /etc/s-box/sing-box >/dev/null 2>&1; then
        _tuic_uuid=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid' /etc/s-box/sb.json 2>/dev/null || true)
        if [ -n "$_tuic_uuid" ] && [ "$_tuic_uuid" != "null" ]; then
            _vport=$(shuf -i 18080-19090 -n1 2>/dev/null || echo 18081)
            cat >/tmp/vpnmax-verify-tuic.json <<JSON_TMP
{"log":{"level":"error"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":$_vport}],"outbounds":[{"type":"tuic","server":"127.0.0.1","server_port":$TU_PORT,"uuid":"$_tuic_uuid","password":"$_tuic_uuid","congestion_control":"bbr","tls":{"enabled":true,"server_name":"www.bing.com","insecure":true,"alpn":["h3"]}}]}
JSON_TMP
            timeout 4 /etc/s-box/sing-box run -c /tmp/vpnmax-verify-tuic.json >/tmp/vpnmax-verify-tuic.log 2>&1 &
            _vpid=$!
            sleep 2
            if curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:"$_vport" --connect-timeout 4 --max-time 6 https://www.google.com/generate_204 2>/dev/null | grep -q '204'; then
                ok "TUIC 本地回环自检通（127.0.0.1:$TU_PORT → google 204）"
                PASS=$((PASS + 1))
            else warn "TUIC 本地回环不通（本机 sing-box 或证书异常，非外网墙）"; fi
            kill -9 $_vpid 2>/dev/null || true
            rm -f /tmp/vpnmax-verify-tuic.json /tmp/vpnmax-verify-tuic.log 2>/dev/null || true
        fi
    fi
fi

if [ "$VMESS_LOCK" = "on" ]; then
    if iptables-save 2>/dev/null | grep -q '! -i lo'; then
        ok "VMess 明文端口公网封锁中"
        PASS=$((PASS + 1))
    else
        warn "未检测到 VMess 明文端口回环锁定规则"
    fi
else
    info "VMESS_LOCK=off：跳过明文 VMess 公网封锁检查"
fi

# 3c. 三处对齐（sb.json vs clmi.yaml vs iptables）— 捕获 rn1 40254/54321 岔裂
# 自动化比对：sb.json 的每个 inbound 端口 是否等于 clmi.yaml 同名 proxy 的 port，且跳跃 DNAT 是否指向它
if [ -f /etc/s-box/sb.json ] && [ -f /etc/s-box/clmi.yaml ]; then
    echo "--- 三处对齐 ---"
    _align_ok=true
    while IFS='|' read -r _sb_port _sb_type; do
        [ -z "$_sb_port" ] || [ "$_sb_port" = "null" ] && continue
        # 跳过 vmess-argo 等 clmi 中 server 为 cloudflare 的项，只比直连
        _clmi_port=$(grep -A2 "type: $_sb_type" /etc/s-box/clmi.yaml 2>/dev/null | grep -oE 'port: [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
        # 若 sb.json 某类型在 clmi 找不到（比如 argo），跳过
        [ -z "$_clmi_port" ] && continue
        if [ "$_sb_port" != "$_clmi_port" ]; then
            warn "三处岔裂: sb.json $_sb_type $_sb_port ≠ clmi.yaml $_clmi_port（订阅与监听不一致，客户端按订阅连会不通）"
            _align_ok=false
        fi
    done < <(jq -r '.inbounds[] | "\(.listen_port)|\(.type)"' /etc/s-box/sb.json 2>/dev/null || true)
    $_align_ok && {
        ok "sb.json 与 clmi.yaml 端口一致"
        PASS=$((PASS + 1))
    }
    # 额外：若 sb.json TUIC 已是 54321 但 iptables 仍指 40254，也算岔裂（上次 rn1 就是）
    _tu_now=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)
    if [ -n "$_tu_now" ] && [ "$_tu_now" != "null" ] && ! iptables -t nat -L "$CHAIN_PORTHOP" -n 2>/dev/null | grep -q "to::${_tu_now}"; then
        warn "三处岔裂: iptables 跳跃未指向当前 TUIC $_tu_now（$CHAIN_PORTHOP 需 DNAT 43000:45000→:$_tu_now）"
    fi
fi

# 4. Argo
echo "--- Argo 隧道 ---"
if [ -f /etc/s-box/argo.log ]; then
    ARGO_URL=$(grep -ao 'https://[a-z0-9.-]*\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null | head -1)
    if [ -n "$ARGO_URL" ]; then
        ok "Argo 隧道: $ARGO_URL"
        PASS=$((PASS + 1))
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$ARGO_URL" 2>/dev/null || echo "000")
        # 隧道代理的是 sing-box WS 服务：根路径 404/4xx 属正常响应（能拿到状态码=Cloudflare 边缘→隧道→本地链路通）
        # 只有 000（连不上边缘/超时）才算不可达
        if [ "$HTTP_CODE" != "000" ]; then
            ok "Argo 端点可达 (HTTP $HTTP_CODE，根路径无内容属正常)"
            PASS=$((PASS + 1))
        else warn "Argo 端点不可达"; fi
    else
        fail "argo.log 中未找到 trycloudflare.com URL"
        FAIL=$((FAIL + 1))
    fi
else
    fail "/etc/s-box/argo.log 不存在"
    FAIL=$((FAIL + 1))
fi

# Argo 自愈保活（v3）：脚本存在 + cron 每 3 分钟 + flock 依赖可用
if [ -x /usr/local/sbin/vpnmax-argo-keepalive.sh ]; then
    ok "Argo 保活脚本存在"
    PASS=$((PASS + 1))
    if crontab -l 2>/dev/null | grep -q 'vpnmax-argo-keepalive'; then
        ok "保活 cron 已注册(每3分钟)"
        PASS=$((PASS + 1))
    else warn "保活 cron 未注册"; fi
    command -v flock >/dev/null 2>&1 && ok "flock 可用(保活互斥)" || warn "flock 缺失(util-linux)"
else
    warn "Argo 保活脚本不存在（重跑 deploy_singbox.sh 可重建）"
fi

# 5. 订阅链接
echo "--- 订阅链接 ---"
if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
    SUBPORT=$(cat /etc/s-box/subport.log)
    SUBTOKEN=$(cat /etc/s-box/subtoken.log)
    ok "订阅端口: $SUBPORT"
    if [ -n "$SERVER_IP" ]; then
        for fmt in clmi.yaml sbox.json jhsub.txt; do
            HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/${fmt}" 2>/dev/null || echo "000")
            if [ "$HTTP_CODE" = "200" ]; then
                ok "$fmt 可访问 (HTTP 200)"
                PASS=$((PASS + 1))
            else
                fail "$fmt 不可访问 (HTTP $HTTP_CODE)"
                FAIL=$((FAIL + 1))
            fi
        done
    else
        LOCAL_HTTP=000
        for fmt in clmi.yaml sbox.json jhsub.txt; do
            LOCAL_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "http://127.0.0.1:${SUBPORT}/${SUBTOKEN}/${fmt}" 2>/dev/null || echo "000")
            [ "$LOCAL_HTTP" = "200" ] && {
                ok "$fmt 本机可访问 (HTTP 200)"
                break
            }
        done
        if [ "$LOCAL_HTTP" = "200" ]; then PASS=$((PASS + 1)); else
            fail "订阅服务未响应（本机 HTTP $LOCAL_HTTP）— 检查 busybox httpd"
            FAIL=$((FAIL + 1))
        fi
    fi
else
    fail "订阅配置文件缺失 (subport.log / subtoken.log)"
    FAIL=$((FAIL + 1))
fi

# 6. 域名分流
# 旧实现检查 /etc/s-box/sbwpph.json，但该文件在所有 sb.sh 版本里都不存在（属永久误报，一直 warn）。
# 改为检真实的部署配置 /etc/s-box/sb.json 里含 domain 的 route 规则数。
echo "--- 域名分流 ---"
_DY_CONF="/etc/s-box/sb.json"
if [ -f "$_DY_CONF" ] && command -v jq >/dev/null 2>&1; then
    DOMAIN_COUNT=$(jq '[.route.rules[]? | select(.domain != null)] | length' "$_DY_CONF" 2>/dev/null || echo "?")
    if [ "$DOMAIN_COUNT" != "0" ] && [ "$DOMAIN_COUNT" != "?" ]; then
        ok "域名分流已配置（sb.json 中含 domain 的 route 规则：${DOMAIN_COUNT} 条）"
        PASS=$((PASS + 1))
    else
        warn "未检测到域名分流规则（sb.json 中 domain 规则数=${DOMAIN_COUNT}）"
    fi
else
    warn "无法检测域名分流（/etc/s-box/sb.json 缺失或缺少 jq）"
fi

echo ""
echo "========================================="
echo -e "  通过: ${GREEN}${PASS}${N} / 失败: ${RED}${FAIL}${N}"
echo "========================================="
[ $FAIL -eq 0 ] && echo -e "${GREEN}部署验证全部通过。${N}" || {
    echo -e "${RED}存在失败项，请按上方提示排查。${N}"
    exit 1
}
