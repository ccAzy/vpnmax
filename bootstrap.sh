#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnmax — 环境准备与依赖检查
# 用法:
  bash bootstrap.sh [选项]        # 仓库模式 / 已下载
  bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnmax/main/bootstrap.sh) [选项]   # 一键

参数: bash bootstrap.sh [--dry-run] [--check-only]
#
# 只负责准备 Debian/Ubuntu VPS 的基础工具，不安装内核、不部署 sing-box、
# 不修改防火墙、不重启机器。
# ===================================================================
set -euo pipefail

# shellcheck disable=SC2034 # 本文件只放"配置常量 + 编排"，常量由 lib/*.sh 在运行时消费（跨文件）

# ── lib 加载：唯一源码在仓库 lib/；curl|bash 单文件模式自动自举取回，不再有内联副本 ──
VPNMAX_SCRIPT_DIR="${VPNMAX_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)}"
# shellcheck disable=SC2034 # lib/*.sh 经 SCRIPT_DIR 定位仓库内 vendor/
SCRIPT_DIR="$VPNMAX_SCRIPT_DIR"
. "$VPNMAX_SCRIPT_DIR/lib/boot.sh" 2>/dev/null || . "${VPNMAX_LIB_HOME:-/usr/local/lib/vpnmax}/boot.sh" 2>/dev/null || {
    VPNMAX_LIB_HOME="${VPNMAX_LIB_HOME:-/usr/local/lib/vpnmax}"
    mkdir -p "$VPNMAX_LIB_HOME" || true
    curl -fsSL "${VPNMAX_RAW:-https://raw.githubusercontent.com/ccAzy/vpnmax/main}/lib/boot.sh" -o "$VPNMAX_LIB_HOME/boot.sh" || {
        printf '[x] vpnmax: 无法获取引导脚本（检查网络，或改用 git clone 后运行）\n' >&2
        exit 1
    }
    . "$VPNMAX_LIB_HOME/boot.sh"
}
vpnmax_load "$VPNMAX_MODULES_ALL" || {
    printf '[✗] vpnmax: 无法加载 lib（网络或仓库不可达）\n' >&2
    exit 1
}

DRY_RUN=false
CHECK_ONLY=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --check-only) CHECK_ONLY=true ;;
    --force) FORCE=true ;;
    --help | -h)
        cat <<'HELP'
vpnmax bootstrap.sh — 环境准备与依赖检查
用法: bash bootstrap.sh [--dry-run] [--check-only] [--force]
  --dry-run    只显示将安装的包，不修改系统
  --check-only 只检查，不执行 apt update/install
  --force      已安装也重装（覆盖安装，`bash <(curl ...) --force` 一键重跑）
HELP
        exit 0
        ;;
    esac
done


if [ "$(id -u)" -ne 0 ]; then
    fail "需要 root 权限。请先 sudo -i 切到 root，或在本条命令最前面加 sudo，然后重跑。"
    exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
    fail "仅支持 Debian/Ubuntu（未找到 apt-get）"
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    fail "未找到 systemd/systemctl，不能部署 sing-box"
    exit 1
fi

. /etc/os-release 2>/dev/null || true
case "${ID:-}" in
debian | ubuntu | linuxmint | pop) info "发行版: ${PRETTY_NAME:-$ID}" ;;
*) warn "未识别的 apt 发行版: ${PRETTY_NAME:-unknown}（继续前请确认兼容性）" ;;
esac

ARCH=$(uname -m)
case "$ARCH" in x86_64 | aarch64) ok "架构支持: $ARCH" ;; *)
    fail "不支持的架构: $ARCH"
    exit 1
    ;;
esac

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
[ "$MEM_MB" -gt 0 ] && {
    info "内存: ${MEM_MB}MB"
    [ "$MEM_MB" -lt 512 ] && warn "内存低于 512MB，BBRv3/Argo/WARP 可能不稳定"
}
BOOT_MB=$(df -Pm /boot 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "${BOOT_MB:-}" ] && [ "$BOOT_MB" -lt 200 ] && warn "/boot 可用空间低于 200MB（当前 ${BOOT_MB}MB）"

# 命令 -> Debian 包映射；这些包覆盖 vpnmax 两个部署阶段与 Hermes CLI 的基础环境。
PACKAGES=(
    ca-certificates curl jq git xz-utils tmux
    bash coreutils grep sed gawk
    iproute2 iptables iptables-persistent procps psmisc util-linux
    cron ethtool kmod logrotate chrony
)

missing=()
for pkg in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
done

if $FORCE && [ "${#missing[@]}" -eq 0 ]; then
    info "--force 已启用，重装基础依赖"
    missing=("${PACKAGES[@]}")
fi
if [ "${#missing[@]}" -eq 0 ]; then
    ok "基础依赖已齐全"
elif $CHECK_ONLY; then
    warn "缺少软件包: ${missing[*]}"
    info "以上仅为检查（--check-only，未安装任何东西）。去掉该参数即安装；加 --dry-run 可先预览。"
    exit 2
elif $DRY_RUN; then
    info "[dry-run] 将安装: ${missing[*]}"
else
    info "缺少软件包: ${missing[*]}"
    info "刷新软件源索引..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
        fail "apt-get update 失败，检查软件源/网络"
        exit 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || {
        fail "依赖安装失败: ${missing[*]}"
        exit 1
    }
    ok "基础依赖安装完成"
fi

# 非安装性检查：提前告诉用户第二阶段会用到的工具是否仍缺失。
commands=(curl jq git xz tmux bash ip ss iptables iptables-save iptables-restore ip6tables-restore systemctl crontab pgrep pkill timeout sha256sum sysctl flock logrotate)
missing_cmd=()
for cmd in "${commands[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing_cmd+=("$cmd"); done
if [ "${#missing_cmd[@]}" -gt 0 ]; then
    warn "仍缺少命令: ${missing_cmd[*]}（可能由 VPS 镜像裁剪或包名差异造成）"
    $CHECK_ONLY && exit 2
else
    ok "部署所需基础命令已可用"
fi

# ── IPv4 优先（防 raw.githubusercontent 等 v6 黑洞导致 curl 卡 75s）──
# 幂等去重：移除所有旧 precedence ::ffff:0:0/96 行，仅保留一行
if $CHECK_ONLY; then
    grep -q '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null && ok "gai.conf 已设 IPv4 优先" || warn "gai.conf 未设 IPv4 优先（建议：precedence ::ffff:0:0/96 100）"
elif $DRY_RUN; then
    grep -q '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null && info "[dry-run] gai.conf 已是 IPv4 优先，跳过" || info "[dry-run] 将写入 /etc/gai.conf：precedence ::ffff:0:0/96 100（IPv4 优先，去重后单行）"
else
    if grep -q '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null && [ "$(grep -c '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null)" -eq 1 ]; then
        ok "gai.conf 已设 IPv4 优先"
    else
        ensure_gai_ipv4 && ok "已设 IPv4 优先（/etc/gai.conf，去重单行）" || warn "写入 /etc/gai.conf 失败（IPv4 优先未生效）"
    fi
fi

info "bootstrap 只准备环境；下一步执行 deploy_optimize.sh"
