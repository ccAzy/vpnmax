#!/bin/bash
# shellcheck disable=SC2034 # 本文件只放"配置常量 + 编排"，常量由 lib/*.sh 在运行时消费（跨文件）
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnmax — 服务器暴力优化脚本（BBRv3 + 网络极限压榨）
# 幂等设计：已优化过的服务器再次运行会自动跳过，不会重复重启
#
# 相对旧版 ACVPN 的关键改进：
#   1. 内核 SHA256 校验改为【强制】：SHA256SUMS 获取失败或找不到目标包 → 直接中止，
#      不再降级为"仅警告后照装"。内核是最高权限组件，不允许无声降级。
#   2. 内核下载地址锁定到明确的 release tag（可配置 VERSION_PIN），
#      不做"API 动态取最新"的不确定性拼接；未锁定版本则强制校验。
#   3. 所有命令替换统一 || true 防 set -e 静默退出。
#   4. 全程写部署清单 /var/log/vpnmax-optimize-manifest.log（来源/版本/校验值）。
#   5. 支持 --dry-run 预览 + --no-reboot。
#
# 用法: bash deploy_optimize.sh [--no-reboot] [--dry-run] [VERSION_PIN=x.y.z]
# 强制重跑: rm -f /etc/.vpnmax-optimized && bash deploy_optimize.sh
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

# ── 参数解析 ──
NO_REBOOT=false
DRY_RUN=false
FORCE=false
VERSION_PIN="" # 可选：锁定 BBRv3 版本 (如 7.3.2)
for arg in "$@"; do
    case "$arg" in
    --no-reboot) NO_REBOOT=true ;;
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    VERSION_PIN=*) VERSION_PIN="${arg#VERSION_PIN=}" ;;
    --help | -h)
        cat <<'HELP'
vpnmax deploy_optimize.sh — 服务器暴力优化（BBRv3 + 网络极限压榨）
用法: bash deploy_optimize.sh [--no-reboot] [--dry-run] [--force] [VERSION_PIN=x.y.z]
  --no-reboot            完成优化后不自动重启（手动 reboot 生效）
  --dry-run              只打印将执行的动作，不实际修改系统
  --force                已优化也重跑（覆盖安装，`bash <(curl ...) --force` 一键重跑）
  VERSION_PIN=x.y.z      锁定 BBRv3 内核版本；缺省时取 release 最新并强制校验
HELP
        exit 0
        ;;
    esac
done

MANIFEST="/var/log/vpnmax-optimize-manifest.log"
MARK="/etc/.vpnmax-optimized"

# ── 日志落盘 ──
if [ -w /var/log ] && [ -d /var/log ]; then
    LOG_FILE="/var/log/vpnmax-optimize.log"
    : >"$LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1 || true
fi

# 写部署清单（来源/版本/校验值，供审计）

cleanup() { rm -f /tmp/bbrv3.deb /tmp/bbrv3.sha256 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

UA="User-Agent: vpnmax-deploy"

if [ -n "$VERSION_PIN" ] && [[ ! "$VERSION_PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "VERSION_PIN 格式无效：$VERSION_PIN（应为 x.y.z，例如 7.3.2）"
    exit 2
fi

# dry-run 包装：--dry-run 时不执行副作用命令

step() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${YELLOW}║  [$1] $2"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${N}"
}

# ── 环境预检 ──
check_env() {
    local fail_flag=0
    if ! command -v apt-get &>/dev/null; then
        fail "非 Debian/Ubuntu 系统，脚本仅支持 apt 系发行版"
        fail_flag=1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        fail "需要 root 权限运行"
        fail_flag=1
    fi
    local mem_kb mem_mb
    mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    mem_mb=$((mem_kb / 1024))
    info "内存: ${mem_mb}MB"
    if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 768 ]; then
        warn "内存不足 768MB（当前 ${mem_mb}MB），BBRv3 内核安装可能失败"
    fi
    case "$(uname -m)" in x86_64 | aarch64) ;; *)
        fail "不支持的架构: $(uname -m)"
        fail_flag=1
        ;;
    esac
    if [ "$fail_flag" -eq 1 ]; then exit 1; fi
}

ARCH=$(uname -m)
HOSTNAME=$(hostname)
case "$ARCH" in x86_64) DEB_ARCH="amd64" ;; aarch64) DEB_ARCH="arm64" ;; *) DEB_ARCH="$ARCH" ;; esac

CUR_KERNEL=$(uname -r)

# ── 幂等检测（提前执行，无需联网/装依赖） ──
# 品牌切割：先接管旧 vpnplus 资产，再做新旧标记判断
if declare -F migrate_legacy_units >/dev/null 2>&1; then migrate_legacy_units || true; fi
if $FORCE; then
    info "--force 已启用，强制重跑全流程"
    rm -f "$MARK" 2>/dev/null || true
fi
if [ -f "$MARK" ]; then
    if echo "$CUR_KERNEL" | grep -q "bbrv3"; then
        if $FORCE; then
            info "--force 已启用，忽略已生效标记，继续重跑"
        else
            logo=$(
                cat <<'EOF'
  ██╗   ██╗██████╗ ███╗   ██╗██╗   ██╗██████╗ ██╗     ██╗   ██╗███████╗
  ██║   ██║██╔══██╗████╗  ██║██║   ██║██╔══██╗██║     ██║   ██║██╔════╝
  ██║   ██║██████╔╝██╔██╗ ██║██║   ██║██████╔╝██║     ██║   ██║███████╗
  ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║██║   ██║██╔═══╝ ██║     ██║   ██║╚════██║
   ╚═╝ ╚═╝ ╚═╝     ╚═╝ ╚═╝╚═╝   ╚═╝╚══════╝ ╚██████╔╝███████╗███████║
                                            ╚═════╝ ╚══════╝╚══════╝╚══════╝
EOF
            )
            echo "$logo"
            echo -e "  ${WHITE}服务器: ${CYAN}$HOSTNAME${N}"
            echo -e "  ${WHITE}当前内核: ${GREEN}$CUR_KERNEL${N}"
            echo ""
            ok "BBRv3 已生效，无需再次执行"
            info "如需强制重新优化：bash deploy_optimize.sh --force"
            echo ""
            exit 0
        fi
    else
        warn "标记文件存在但内核未使用 BBRv3（可能已更新），重新执行优化"
        if $DRY_RUN; then
            info "[dry-run] 删除失效优化标记: $MARK"
        else
            rm -f "$MARK"
        fi
    fi
fi

# ── 依赖（bootstrap 的内置兜底；远程直接运行也能准备环境） ──
# curl 是下载本脚本前的引导依赖；进入脚本后同时补齐 jq、iproute2、iptables、
# procps、cron、ethtool 等第二阶段会用到的工具。缺包安装失败时明确中止，
# 不再“apt 失败后继续运行再静默报错”。
install_dependencies() {
    # netfilter-persistent 提供服务 iptables-persistent；logrotate 提供日志轮转；flock 属 util-linux
    local packages=(ca-certificates curl jq git xz-utils tmux iproute2 iptables iptables-persistent procps psmisc util-linux cron ethtool kmod logrotate chrony)
    local missing=() pkg
    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done
    [ "${#missing[@]}" -eq 0 ] && {
        ok "基础依赖已齐全"
        return 0
    }
    info "缺少依赖: ${missing[*]}"
    $DRY_RUN && {
        info "[dry-run] apt-get update && apt-get install -y ${missing[*]}"
        return 0
    }
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
        fail "apt-get update 失败，检查软件源/网络"
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || {
        fail "依赖安装失败: ${missing[*]}"
        return 1
    }
    ok "基础依赖安装完成"
}

# 先预检再访问 apt，避免非 Debian 系统在检查前就执行 apt-get。
check_env
if $DRY_RUN; then
    install_dependencies
    info "[dry-run] 环境预检完成；跳过内核下载、系统写入和重启"
    exit 0
fi
install_dependencies || exit 1
ensure_time_sync
# ── IPv4 优先（防 raw.githubusercontent 等 v6 黑洞导致 curl 卡 75s）── 幂等去重单行
if grep -q '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null && [ "$(grep -c '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null)" -eq 1 ]; then
    ok "gai.conf 已设 IPv4 优先"
else
    if $DRY_RUN; then
        info "[dry-run] 将写入 /etc/gai.conf：precedence ::ffff:0:0/96 100（IPv4 优先，去重单行）"
    else
        ensure_gai_ipv4 && ok "已设 IPv4 优先（/etc/gai.conf，去重单行）" || warn "写入 /etc/gai.conf 失败"
    fi
fi
for dep in curl jq git xz tmux ip iptables ss tc systemctl; do
    command -v "$dep" >/dev/null 2>&1 || {
        fail "关键命令缺失: $dep，请先执行 bootstrap.sh"
        exit 1
    }
done

PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null) ||
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null) ||
    PUBLIC_IP="unknown"
[ "$PUBLIC_IP" = "unknown" ] && warn "无法获取公网 IP，网络可能受限"

# ── BBRv3 内核安装 ──
# 关键安全点：SHA256 校验【强制】。下载地址优先：
#   1) 若 VERSION_PIN 指定 → 精确拼接该 tag 的下载 URL（无 API 不确定性）
#   2) 否则 → API 取最新 max tag，并同样强制 SHA256 校验
# ── 网络优化（保持 ACVPN 的三级内存分级 + ethtool 尽力降级） ──
# ── GRUB 默认内核校验（防重启后进旧内核） ──
# ══════════ 主流程 ══════════
if $DRY_RUN; then echo -e "${YELLOW}═══ DRY-RUN 模式：仅预览，不修改系统 ═══${N}"; fi
logo() { :; }

# check_env/install_dependencies 已在依赖阶段完成，这里不重复执行。

step "1" "清理旧安装"
if [ -f /etc/.vpnmax-singbox ]; then
    info "检测到 sing-box 已部署，跳过旧安装清理（保留 /etc/s-box）"
elif [ -f "$MARK" ]; then
    warn "检测到优化标记，跳过清理"
else
    run systemctl stop sb xr 2>/dev/null || true
    run systemctl disable sb xr 2>/dev/null || true
    run pkill -15 -f sing-box 2>/dev/null || true
    run pkill -15 -f xray 2>/dev/null || true
    sleep 2
    run pkill -9 -f sing-box 2>/dev/null || true
    run pkill -9 -f xray 2>/dev/null || true
    run rm -rf /etc/s-box /root/agsbx /usr/local/etc/argosbx \
        /etc/systemd/system/sb.service /etc/systemd/system/xr.service \
        /etc/systemd/system/cloudflared-argo.service 2>/dev/null || true
    run systemctl daemon-reload || true
    ok "清理完成"
fi

step "2" "BBRv3 内核安装"
BBR_OK=false
if install_bbrv3; then BBR_OK=true; else
    fail "BBRv3 安装失败（网络优化仍会继续，但不会写成功标记/重启）"
fi

step "3" "网络暴力优化"
apply_sysctl
apply_ethtool || warn "ethtool 优化已跳过（可选步骤，不影响后续步骤）"
apply_qdisc || true
boost_limits
apply_rss

# ── 智能带宽/亚太调优（移植自 byJoey，非交互化） ──
# 环境变量控制: VPNMAX_BUFFER_MODE=apac|smart|default（默认 smart）
_buffer_mode="${VPNMAX_BUFFER_MODE:-smart}"
case "$_buffer_mode" in
apac) apply_apac_tuning ;;
smart) apply_smart_bandwidth_tuning ;;
default) info "跳过智能带宽调优（VPNMAX_BUFFER_MODE=default）" ;;
*) apply_smart_bandwidth_tuning ;;
esac

if $BBR_OK; then
    ensure_grub_boot || warn "GRUB 默认引导项未确认；若重启后进入旧内核请手动处理"
    run touch "$MARK"
    manifest "optimize mark written; kernel=$CUR_KERNEL"
    step "4" "重启生效"
    echo ""
    if $NO_REBOOT || $DRY_RUN; then
        info "已跳过自动重启 (--no-reboot/--dry-run)"
        info "请稍后手动执行: reboot"
        info "重启后执行第 2 步: curl -fsSL .../deploy_singbox.sh | bash"
        exit 0
    fi
    for i in $(seq 10 -1 1); do
        echo -ne "  即将重启... ${i} 秒 \r"
        sleep 1
    done
    echo ""
    sync
    reboot
else
    echo ""
    warn "BBRv3 内核未安装成功，未写优化标记、未重启"
    info "网络优化已应用（重启后仍生效，但 BBRv3 需要内核安装成功）"
    info "修复后重新执行: bash deploy_optimize.sh"
    exit 1
fi
