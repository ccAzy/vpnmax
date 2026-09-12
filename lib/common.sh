#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# lib/common.sh — 统一日志/运行/清单，供所有部署脚本 source
# 保持幂等：重复 source 不重复定义
# shellcheck disable=SC2034 # 颜色常量是给入口脚本用的（如 deploy_optimize.sh 的 banner），跨文件 shellcheck 看不到
[ -n "${VPNMAX_COMMON_LOADED:-}" ] && return 0
VPNMAX_COMMON_LOADED=1

# 颜色与日志（若已定义则不覆盖）
# 颜色只在交互终端启用：被管道/重定向/写日志时不吐转义码（否则日志里全是 ^[[0;36m）
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'[0;31m' GREEN=$'[0;32m' YELLOW=$'[1;33m'
    CYAN=$'[0;36m' WHITE=$'[1;37m' N=$'[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' WHITE='' N=''
fi

# 统一日志函数（唯一来源；入口脚本不再各抄一份，故不加 declare -F 守卫——
# 守卫会让残留的旧副本悄悄胜出，制造「改 lib 不生效」）
# 状态前缀一律 3 列 ASCII：✓ / ✗ 是宽字符，渲染宽度随终端字体而变（1~2 列），
# 会让整段输出参差；ASCII 在任何字体下都严格对齐。
info() { printf '%s[*]%s   %s
' "$CYAN" "$N" "$*"; }
ok() { printf '%s[+]%s   %s
' "$GREEN" "$N" "$*"; }
warn() { printf '%s[!]%s   %s
' "$YELLOW" "$N" "$*"; }
fail() { printf '%s[x]%s   %s
' "$RED" "$N" "$*"; }

# 脏数据/清理场景需要「报错并终止」的变体
die() {
    printf '%s[x]%s   %s
' "$RED" "$N" "$*"
    exit 1
}

# 部署清单（若外层已定义 MANIFEST 则复用）
MANIFEST=${MANIFEST:-"/var/log/vpnmax-manifest.log"}
manifest() { echo "[$(date -Is)] $*" >>"$MANIFEST" 2>/dev/null || true; }

# DRY_RUN 感知的执行包装——两种语义，按调用方需要选，别混用：
#   run    — 失败即失败（set -e 下中止），保留 stderr，可观测。用于「必须成功」的部署动作。
#   run_ok — 吞掉失败与 stderr。用于「尽力而为」的清理/探测动作。
# 历史遗留：入口脚本各自定义 run（deploy_* 传播、cleanup 吞错），而 `if ! declare -F run`
# 守卫让顶层那份胜出 → 改 lib 静默失效。已收敛到本文件，故不再加守卫。
run() {
    if ${DRY_RUN:-false}; then
        info "[dry-run] $*"
        return 0
    fi
    "$@"
}

run_ok() {
    if ${DRY_RUN:-false}; then
        info "[dry-run] $*"
        return 0
    fi
    "$@" 2>/dev/null || true
}

# 原子写入：先写同目录临时文件，内容非空才 mv 覆盖。
# 为什么需要：sb.json / iptables rules.v4 / systemd drop-in 这类文件写到一半被中断
# 就是「配置残缺」——轻则服务起不来，重则节点失联。同文件系统内 mv 是原子的。
# 用法:  cmd | atomic_write /etc/x.conf [备份后缀]
#        atomic_place /tmp/gen.json /etc/x.json [备份后缀]
atomic_write() {
    local target="$1" bak="${2:-}" tmp
    if ${DRY_RUN:-false}; then
        info "[dry-run] 原子写 $target"
        cat >/dev/null 2>&1 || true
        return 0
    fi
    mkdir -p "$(dirname "$target")" 2>/dev/null || true
    tmp="$(mktemp "${target}.vpnmax.XXXXXX" 2>/dev/null)" || {
        warn "原子写失败：无法在 $(dirname "$target") 建临时文件"
        cat >/dev/null 2>&1 || true
        return 1
    }
    if ! cat >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
        rm -f "$tmp" 2>/dev/null || true
        warn "原子写失败：内容为空或写入出错（$target 保持原样）"
        return 1
    fi
    atomic_place "$tmp" "$target" "$bak"
}

# 把已生成的 <src> 原子落位到 <target>（同文件系统内 mv）
atomic_place() {
    local src="$1" target="$2" bak="${3:-}"
    [ -s "$src" ] || {
        rm -f "$src" 2>/dev/null || true
        return 1
    }
    if [ -n "$bak" ] && [ -e "$target" ]; then
        cp -a "$target" "${target}.${bak}" 2>/dev/null || true
    fi
    chmod --reference="$target" "$src" 2>/dev/null || true
    chown --reference="$target" "$src" 2>/dev/null || true
    mv -f "$src" "$target"
}

# IPv4 优先（gai.conf）幂等单行。bootstrap 与 deploy_optimize 共用，故收在 common。
# 用 mktemp 而非固定 /tmp 名：脚本以 root 运行，固定名可被本地用户预置符号链接利用。
ensure_gai_ipv4() {
    if grep -q '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null &&
        [ "$(grep -c '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null)" -eq 1 ]; then
        return 0
    fi
    {
        grep -v '^precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null || true
        echo 'precedence ::ffff:0:0/96 100'
    } | atomic_write /etc/gai.conf "bak"
}

# 基础依赖（两阶段共用，含 chrony 时间同步）
# shellcheck disable=SC2034 # used by callers after source
BASE_PACKAGES=(ca-certificates curl jq git xz-utils tmux iproute2 iptables iptables-persistent procps psmisc util-linux cron ethtool kmod logrotate chrony)

# vpnmax品牌切割迁移：认旧（vpnplus时代）资产并接管，幂等，只做一次有效。
# 覆盖：旧 systemd units、旧 keepalive 脚本+锁+crontab、旧 logrotate、旧 drop-in、旧 marker。
# 新资产由正常安装路径重建；调用方须在安装新资产之前调用本函数（先剥旧后立新，防双跑）。
migrate_legacy_units() {
    if ${DRY_RUN:-false}; then
        info "[dry-run] 将迁移旧 vpnplus 资产（units/keepalive/cron/logrotate/drop-in/marker）"
        return 0
    fi
    local _changed=false _u _f _old _new _pair
    for _u in vpnplus-net-tuning.service vpnplus-netfilter-restore.service; do
        if [ -e "/etc/systemd/system/$_u" ]; then
            run systemctl stop "$_u" 2>/dev/null || true
            run systemctl disable "$_u" 2>/dev/null || true
            run rm -f "/etc/systemd/system/$_u" 2>/dev/null || true
            _changed=true
        fi
    done
    for _f in /usr/local/sbin/vpnplus-argo-keepalive.sh /usr/local/sbin/vpnplus-net-tuning.sh /var/lock/vpnplus-argo-keepalive.lock /etc/logrotate.d/vpnplus; do
        if [ -e "$_f" ]; then
            run rm -rf "$_f" 2>/dev/null || true
            _changed=true
        fi
    done
    if crontab -l 2>/dev/null | grep -qE 'vpnplus-argo-keepalive|acvpn-argo-keepalive' 2>/dev/null; then
        (crontab -l 2>/dev/null | grep -vE 'vpnplus-argo-keepalive|acvpn-argo-keepalive|acvn-argo-keepalive' || true) | crontab - 2>/dev/null || true
        _changed=true
    fi
    if [ -f /etc/systemd/system/sing-box.service.d/99-vpnplus.conf ] && [ ! -f /etc/systemd/system/sing-box.service.d/99-vpnmax.conf ]; then
        run mv /etc/systemd/system/sing-box.service.d/99-vpnplus.conf /etc/systemd/system/sing-box.service.d/99-vpnmax.conf 2>/dev/null || true
        _changed=true
    fi
    for _pair in "/etc/.vpnplus-optimized:/etc/.vpnmax-optimized" "/etc/.vpnplus-singbox:/etc/.vpnmax-singbox"; do
        _old="${_pair%%:*}"
        _new="${_pair##*:}"
        if [ -f "$_old" ] && [ ! -f "$_new" ]; then
            run touch "$_new" 2>/dev/null || true
            _changed=true
        fi
    done
    if $_changed; then
        run systemctl daemon-reload 2>/dev/null || true
        ok "旧 vpnplus 资产已迁移接管"
    fi
}

# 日志落盘（若 /var/log 可写）
if [ -w /var/log ] && [ -d /var/log ] && [ -z "${VPNMAX_COMMON_LOGGED:-}" ]; then
    LOG_FILE="/var/log/vpnmax-common.log"
    : >"$LOG_FILE" 2>/dev/null || true
    VPNMAX_COMMON_LOGGED=1
fi
