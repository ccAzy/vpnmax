#!/bin/bash
# shellcheck disable=SC2034 # 本文件只放"配置常量 + 编排"，常量由 lib/*.sh 在运行时消费（跨文件）
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnmax — sing-box VPN 一键部署（需先执行 deploy_optimize.sh）
# 用法: curl -fsSL .../deploy_singbox.sh | bash
#
# 相对旧版 ACVPN 的关键加固：
#   1. 外部 sb.sh 固定到 commit 5001e76 + 强制 SHA256 校验（失败即中止）
#   2. 防火墙改独立命名链（VPNMAX_ANTIPROBE / VPNMAX_PORTHOP），
#      重跑/卸载绝不按 'limit: above'/'#conn' 全局删 INPUT，保护第三方规则
#   3. 核心/可选失败语义分离：核心失败 → 不写成功标记；可选失败 → 告警继续
#   4. 进程清理精确化：busybox 用端口查找，绝不 pkill -x busybox 杀全局
#   5. 安全参数网络感知：IPv6 若无地址才关 RA，rp_filter 可覆盖
# ===================================================================
set -euo pipefail

# ── lib 加载：唯一源码在仓库 lib/；curl|bash 单文件模式自动自举取回，不再有内联副本 ──
VPNMAX_SCRIPT_DIR="${VPNMAX_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)}"
# shellcheck disable=SC2034 # lib/*.sh 经 SCRIPT_DIR 定位仓库内 vendor/
SCRIPT_DIR="$VPNMAX_SCRIPT_DIR"
. "$VPNMAX_SCRIPT_DIR/lib/boot.sh" 2>/dev/null || . "${VPNMAX_LIB_HOME:-/usr/local/lib/vpnmax}/boot.sh" 2>/dev/null || {
    VPNMAX_LIB_HOME="${VPNMAX_LIB_HOME:-/usr/local/lib/vpnmax}"
    mkdir -p "$VPNMAX_LIB_HOME" || true
    curl -fsSL "${VPNMAX_RAW:-https://raw.githubusercontent.com/ccAzy/vpnmax/main}/lib/boot.sh" -o "$VPNMAX_LIB_HOME/boot.sh" || {
        printf '[✗] vpnmax: 无法获取引导脚本（检查网络，或改用 git clone 后运行）\n' >&2
        exit 1
    }
    . "$VPNMAX_LIB_HOME/boot.sh"
}
vpnmax_load "$VPNMAX_MODULES_ALL" || {
    printf '[✗] vpnmax: 无法加载 lib（网络或仓库不可达）\n' >&2
    exit 1
}

# ── sb 菜单安全投喂：一次性喂完按键，timeout 限定，结束后强杀残留 sb 交互防孤儿 ──
# 背景：sb（sing-box-yg）部分子菜单（如订阅 ipsub）完成操作后会 `sleep 3 && sb`
#       递归拉起新 sb 面板。若是固定管道喂键，stdin 一旦耗尽，递归的 sb 会永远挂起等待，
#       而 timeout 只杀最外层 → 留下孤儿 sb 进程，脚本被卡死等同"中断"。
# 解决：包装所有 sb 菜单调用，末尾补多组 0（逐层返回/退出），超时后清理本次会话遗留的 sb。
#       pkill 只针对"本次 sb_feed 期间新出现"的 sb 进程（用前后 PID 差集），不误伤同机手动开的 sb 面板。
DRY_RUN=false
VMESS_LOCK="${VMESS_LOCK:-off}" # 用户明确不需要防火墙：vmess 明文端口公网直连（不再锁回环）
RESET_SUB="${RESET_SUB:-0}"     # RESET_SUB=1 强制轮转订阅 token/端口（暴露后一键换链）
FORCE=false
for arg in "$@"; do
    case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --reset-sub) RESET_SUB=1 ;;
    --force) FORCE=true ;;
    --help | -h)
        cat <<'HELP'
vpnmax deploy_singbox.sh — sing-box 一键部署
用法: bash deploy_singbox.sh [--dry-run] [--reset-sub] [--force]
  --dry-run  只打印将执行的动作，不实际修改系统
  --reset-sub 强制轮转订阅（删除旧 subport/subtoken，生成全新 token/端口）
             等价 RESET_SUB=1 bash deploy_singbox.sh，暴露后一键换链
  --force    强制重跑全流程（忽略 /etc/.vpnmax-singbox 已部署标记，强制对齐 sb.json/iptables/订阅三处）
  VMESS_LOCK=on|off  明文 VMess 端口是否封锁公网（默认 off：直连，仅密钥登录无防火墙场景）
  RESET_SUB=1        同 --reset-sub
HELP
        exit 0
        ;;
    esac
done

CHECKPOINT="/etc/.vpnmax-singbox"
MANIFEST="/var/log/vpnmax-singbox-manifest.log"
# 锁定的 sb.sh（vpnmax 融合：仓库自带 vendor/sb.sh，与 ccAzy/sing-box-yg acvpn 分支
# 2026-08-05 提交字节一致；SB_URL 仅为 vendor 缺失时的自家回退，绝不指向上游）
SB_COMMIT="5001e76efc9e15eac1f8ff33a0b389172e331e1d"
# SB_SHA256 对应的是“上游 commit + vpnmax 本地 patch”之后的文件。
# 每次改 vendor/sb.sh 都必须同步重算本常量，否则安装时校验失败拒绝安装。
# 2026-09-12 本地 patch（冻结层）：
#   ① acme.sh / CFwarp.sh / sbwpph 改为 pin commit + SHA256 校验（不再裸拉上游 main 后 root 执行）
#   ② 版本 pin：sing-box 1.13.19 / cloudflared 2026.8.3 / cfst v2.3.5（pin 拉不到才告警回退 latest）
#   ③ bbr() 改本地最小实现（不再拉 teddysun/across，避免覆盖本项目的 TCP buffer 调优）
SB_SHA256="99b8a4e5b06c64ac0f2ed190e5207cc42932acdaa8c683716d687b8e31d5ec08"
SB_URL="https://raw.githubusercontent.com/ccAzy/vpnmax/main/vendor/sb.sh"

# ── 环境预检 + 第二阶段依赖兜底 ──
check_env() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "需要 root 权限"
        return 1
    fi
    if ! command -v apt-get &>/dev/null; then
        fail "非 Debian/Ubuntu 系统，脚本仅支持 apt 系发行版"
        return 1
    fi

    # deploy_singbox 也可独立运行：补齐第一阶段可能未执行的工具。
    local packages=(ca-certificates curl jq git xz-utils tmux iproute2 iptables iptables-persistent procps psmisc util-linux cron ethtool kmod logrotate chrony)
    local missing=() pkg
    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        info "缺少第二阶段依赖: ${missing[*]}"
        if $DRY_RUN; then
            info "[dry-run] apt-get update && apt-get install -y ${missing[*]}"
        else
            DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
                fail "apt-get update 失败，检查软件源/网络"
                return 1
            }
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || {
                fail "依赖安装失败: ${missing[*]}"
                return 1
            }
            ok "第二阶段基础依赖安装完成"
        fi
    fi
    for cmd in curl jq git xz tmux ip ss iptables systemctl crontab pgrep pkill timeout sha256sum sysctl; do
        command -v "$cmd" >/dev/null 2>&1 || {
            fail "关键命令缺失: $cmd，请先执行 bootstrap.sh"
            return 1
        }
    done
    if ! command -v systemctl &>/dev/null; then
        fail "无 systemd，sing-box 需要 systemd"
        return 1
    fi
    local mem_kb mem_mb
    mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    mem_mb=$((mem_kb / 1024))
    info "内存: ${mem_mb}MB"
    if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 512 ]; then warn "低内存 VPS（<512MB）"; fi
    return 0
}
# ── 订阅配置 ──
# ── 获取订阅端口（多源探测） ──
# ── Hysteria2 + Tuic 端口跳跃（独立命名链，绝不触碰第三方 NAT 规则） ──
# ── WARP-plus-Socks5 ──
# ── 域名分流（AI + 流媒体 + 搜索引擎走 WARP） ──
# ── Argo 隧道 ──
# ── 安全加固（网络感知：IPv6 无地址才关 RA；rp_filter 可覆盖） ──
# ── Argo 传输协议优化补丁（http2 → auto，QUIC 优先抗丢包） ──
# ── Argo 临时隧道保活（掉线自动拉起 + 刷新订阅） ──
# ── iptables 持久化（三层兜底 + 自建恢复 unit，防重启后端口跳跃/防探测规则丢失） ──
# 背景（2026-08-25 审计）：旧实现第三层 iptables-save 只写文件、无开机加载，重启后 VPNMAX_* 链丢失。
# 现做两层保障：
#   1) 优先用 netfilter-persistent 存储（Debian iptables-persistent，开机由 network-pre.target 自动恢复）
#   2) 否则写 /etc/iptables/rules.v4|v6 并注册 vpnmax-netfilter-restore.service（network-pre.target 前恢复）
# ── 日志轮转（防 vpnmax 长期运行日志无限膨胀） ──
# ── 订阅 HTTP 服务保障（busybox httpd；精确按端口定位，绝不杀全局 busybox） ──
# ── 订阅后处理：修复 sb 生成的 mport 重复（双 DNAT 导致 40000-42000,40000-42000） ──
# ── 最终显示订阅链接 ──
# ── 防主动探测（独立命名链；重跑/卸载只动 VPNMAX_ANTIPROBE，绝不 delete 全局 INPUT 规则） ──
# ══════════ 主流程 ══════════
main() {
    logo() { :; }
    if $DRY_RUN; then echo -e "${YELLOW}═══ DRY-RUN 模式：仅预览，不修改系统 ═══${N}"; fi
    # 品牌切割：先接管旧 vpnplus 资产（units/keepalive/cron/marker），再走新流程
    if declare -F migrate_legacy_units >/dev/null 2>&1; then migrate_legacy_units || true; fi

    # 失败 trap：半成品状态下明确给出恢复指引，而不是带着半配置退出
    trap_interrupt() {
        local rc=$?
        # 正常完成/主动 skip（rc 0）不算中断，避免 "退出码 0" 误报
        [ "$rc" -eq 0 ] && return 0
        echo ""
        fail "部署中断（最后退出码 $rc），可能残留半成品状态。"
        info "修复与恢复："
        info "  1) 先安全预览: bash cleanup.sh --force --dry-run —— 看会清哪些东西"
        info "  2) 若只是刚才某步失败，可直接: bash deploy_singbox.sh 重跑（幂等）"
        info "  3) 想彻底重建: bash cleanup.sh --force && bash deploy_singbox.sh"
        info "  sb_feed 详细日志在 /var/log/vpnmax-sbfeed.log（本次 sb 交互输出，便于回溯卡点）"
        return $rc
    }
    trap 'trap_interrupt' EXIT

    # 跳过条件：sb.json 存在 + 服务运行中即跳过（checkpoint 仅为"部署完全成功"辅标记；
    # 若强依赖 checkpoint，上次中断/被打断后丢失，已部署机器会被误判全流程重跑）
    # 例外：RESET_SUB=1（显式轮转订阅）与 VMESS_LOCK=on（显式改防火墙策略）不跳过，
    # 否则 README 教的 "RESET_SUB=1 bash deploy_singbox.sh" 在已部署机器上永远执行不到
    if [ "$FORCE" != "true" ] && [ "${RESET_SUB:-0}" != "1" ] && [ "${VMESS_LOCK:-off}" != "on" ] &&
        [ -f /etc/s-box/sb.json ] && { systemctl is-active sb >/dev/null 2>&1 || systemctl is-active sing-box >/dev/null 2>&1 || systemctl is-active xr >/dev/null 2>&1; }; then
        # 已部署跳过≠失败，撤销 EXIT trap 避免误报“部署中断（退出码 0）”
        trap - EXIT
        ok "sing-box 已部署运行中，跳过安装。"
        info "如需强制重跑并对齐 sb.json/iptables/订阅三处："
        info "  本地已有脚本: bash deploy_singbox.sh --force"
        info "  一键裸装: bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnmax/main/deploy_singbox.sh) --force"
        return 0
    fi
    if [ "$FORCE" = "true" ]; then
        info "--force 已启用，将强制重跑全流程并对齐三处配置"
        rm -f "$CHECKPOINT" 2>/dev/null || true
    fi

    check_env || return 1
    # sb 菜单结构指纹：先抓一次 sb 主菜单横幅，确认菜单结构与脚本投喂序列预期一致
    # 若 sb 已存在的版本与锁定的 SB_COMMIT 不符（比如用户手动升级过），菜单序号可能漂移，
    # 静默继续会让安装"产物缺失才报错"很难排查。这里先探测，命中预期则继续，未命中则明确警告。
    if [ -f /etc/.vpnmax-singbox ]; then :; else assert_sb_menu; fi

    # 时间校准必须在安装前完成（否则 Reality/VMess 握手 bad timestamp）
    ensure_time_sync

    if $DRY_RUN; then
        echo -e "${YELLOW}═══ DRY-RUN 模式：仅预览，不修改系统 ═══${N}"
        info "[dry-run] 将执行：安装 sb.sh、生成订阅、配置端口跳跃、Argo、独立防火墙链、WARP"
        info "[dry-run] 已跳过实际文件、服务、防火墙和进程检查"
        return 0
    fi
    local DEPLOY_OK=true

    step "1" "安装 sing-box"
    install_singbox_yg || DEPLOY_OK=false
    apply_argo_patch

    step "2" "配置订阅链接"
    setup_subscription || DEPLOY_OK=false
    wait_subscription
    ensure_sub_httpd

    step "3" "端口跳跃（Hy2 + Tuic）独立链"
    config_port_hopping || true

    step "4" "Argo 临时隧道"
    start_argo || DEPLOY_OK=false
    install_argo_keepalive
    if declare -F ensure_argo_extra_applied >/dev/null 2>&1; then ensure_argo_extra_applied || true; fi

    step "5" "安全加固 + 防主动探测（独立链）"
    apply_hardening
    apply_antiprobe || true
    # sing-box 1.12+ 兼容环境变量（2026-08-27 JP/HK 崩溃根因：legacy domain_strategy 需注入）
    if declare -F ensure_singbox_legacy_env >/dev/null 2>&1; then ensure_singbox_legacy_env || true; fi

    step "6" "WARP + 域名分流（可选）"
    setup_warp
    setup_domain_routing
    force_ipv4_lock || true
    fix_mport_dup || true
    show_subscription || true

    step "7" "日志轮转 + 基线体检（可选）"
    setup_logrotate

    # 仅核心成功才写成功标记
    if $DEPLOY_OK; then
        run touch "$CHECKPOINT"
        manifest "deploy core OK; vmess_lock=${VMESS_LOCK}"
        ok "全部部署完成！"
        info "管理命令: sb"
    else
        warn "核心步骤未完全成功，未写成功标记"
        info "修复后重试: bash deploy_singbox.sh"
        return 1
    fi
}

step() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${YELLOW}║  [$1] $2"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${N}"
}

main "$@"
