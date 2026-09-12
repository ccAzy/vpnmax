#!/bin/bash
# shellcheck disable=SC2034 # 本文件只放"配置常量 + 编排"，常量由 lib/*.sh 在运行时消费（跨文件）
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnmax — sing-box 彻底清理脚本
# 清除 sing-box / cloudflared(argo) / busybox / crontab / iptables(仅ACVPN链) / nftables
# 保留 /opt/cloudflared 等永久隧道文件不受影响
#
# 安全设计（相对旧版 ACVPN 的关键改进）：
#   1. 只清理 vpnmax 自己创建的独立防火墙链（VPNMAX_*），
#      绝不按 'limit: above'/'#conn' 等通用文本全局删 INPUT 链规则，
#      避免误删 fail2ban / Docker / 其他程序的安全规则。
#   2. crontab 清理用 '|| true' 包裹命令替换，杜绝 set -e 静默退出。
#   3. 清理前自动备份原始 iptables/nftables 规则到 /var/backups/vpnmax/。
#   4. 清理后逐项自检，任一失败明确列出修复命令。
#
# 用法: bash cleanup.sh [--force] [--dry-run]
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

FORCE=""
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
    --force) FORCE="--force" ;;
    --dry-run) DRY_RUN=true ;;
    esac
done

# dry-run 安全的执行包装：--dry-run 只打印将执行的动作，不真正执行

echo ""
echo "========================================="
echo "  vpnmax sing-box 清理"
echo "========================================="
echo ""

if [ "$FORCE" != "--force" ]; then
    echo -e "${YELLOW}警告：将清除所有 sing-box 相关配置、进程、定时任务。${N}"
    if [ -t 0 ]; then read -r -p "确认继续？[y/N] " confirm; else confirm=n; fi
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && {
        echo "已取消"
        exit 0
    }
fi

# ———————— 0. 备份当前防火墙规则（清理前快照，可回滚） ————————

# ———————— 仅删除 vpnmax 自己的独立链（不碰第三方规则） ————————
# 关键改进：不 grep INPUT 链全局匹配删除，只处理 VPNMAX_* 命名链。

# ———————— 1-5：停止服务 / 杀进程 / 清 crontab / 删 unit / 删目录 ————————
# （与 ACVPN 相同，但 crontab 处理修复了 set -e 退出问题）
stop_services() {
    echo "--- 停止服务 ---"
    for svc in sing-box cloudflared cloudflared-update vpnmax-rss vpnmax-net-tuning; do
        if systemctl is-active "$svc" &>/dev/null; then
            run_ok systemctl stop "$svc" || true
            ok "已停止服务: $svc"
        fi
        if systemctl is-enabled "$svc" &>/dev/null; then
            run_ok systemctl disable "$svc" || true
            ok "已禁用服务: $svc"
        fi
    done
    if systemctl is-active cloudflared-update.timer &>/dev/null; then
        run_ok systemctl stop cloudflared-update.timer || true
        run_ok systemctl disable cloudflared-update.timer || true
        ok "已停止/禁用: cloudflared-update.timer"
    fi
}

kill_procs() {
    echo "--- 终止进程 ---"
    run_ok pkill -15 -f sing-box || true
    sleep 2
    # 临时 Argo 隧道统一匹配口径（与 deploy_singbox keepalive 一致：cloudflared + tunnel + --url）
    for proc in sing-box 'cloudflared.*tunnel.*--url'; do
        if pgrep -f "$proc" &>/dev/null; then
            run_ok pkill -9 -f "$proc" || true
            ok "已终止: $proc"
        fi
    done
}

# 精确停止 vpnmax 订阅端口对应的 busybox httpd，不按进程名全局杀进程。
kill_sub_httpd() {
    local port pids
    [ -f /etc/s-box/subport.log ] || return 0
    port=$(grep -oE '[0-9]{1,5}' /etc/s-box/subport.log 2>/dev/null | head -1 || true)
    [ -n "$port" ] || return 0
    pids=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | sed 's/pid=//' | sort -u || true)
    for p in $pids; do
        if tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qE 'busybox[[:space:]]+httpd.*(/root/websbox|subport.log)'; then
            run_ok kill -TERM "$p" || true
            ok "已终止 vpnmax 订阅 httpd (PID $p, 端口 $port)"
        fi
    done
}

clean_crontab() {
    echo "--- 清理 crontab（仅 vpnmax 自己的条目和明确的旧 ACVPN 兼容条目） ---"
    if crontab -l &>/dev/null; then
        BEFORE=$(crontab -l 2>/dev/null | wc -l)
        # 修复 set -e 问题：grep 无匹配时返回 1，必须 || true 防静默退出
        NEW_CRON=$(crontab -l 2>/dev/null | grep -vE 'vpnmax-argo-keepalive|vpnplus-argo-keepalive|acvpn-argo-keepalive|acvn-argo-keepalive|/usr/bin/sb|busybox httpd.*(/root/websbox|subport.log)' || true)
        if $DRY_RUN; then
            info "[dry-run] 过滤 crontab（移除 ${BEFORE} 行中的 sb 相关条目）"
        elif [ -z "$NEW_CRON" ]; then
            crontab -r 2>/dev/null || true
            ok "crontab 已整体清空"
        else
            printf '%s\n' "$NEW_CRON" | crontab - 2>/dev/null || warn "crontab 写入失败，请手动检查 crontab -e"
        fi
        AFTER=$(crontab -l 2>/dev/null | wc -l)
        REMOVED=$((BEFORE - AFTER))
        [ $REMOVED -gt 0 ] && ok "crontab: 移除 ${REMOVED} 条 sb 相关条目" || info "crontab 无 sb 条目需清理"
    else
        info "crontab 为空"
    fi
}

rm_units() {
    echo "--- 清理 systemd units ---"
    local COUNT=0 unit
    for unit in /etc/systemd/system/sing-box.service \
        /etc/systemd/system/sing-box.service.d \
        /etc/systemd/system/sb.service \
        /etc/systemd/system/sb.service.d \
        /etc/systemd/system/xr.service \
        /etc/systemd/system/xr.service.d \
        /etc/systemd/system/cloudflared.service \
        /etc/systemd/system/cloudflared-update.service \
        /etc/systemd/system/cloudflared-update.timer \
        /etc/systemd/system/vpnmax-rss.service \
        /etc/systemd/system/vpnplus-rss.service \
        /etc/systemd/system/vpnmax-net-tuning.service \
        /etc/systemd/system/vpnplus-net-tuning.service \
        /etc/systemd/system/vpnmax-netfilter-restore.service \
        /etc/systemd/system/vpnplus-netfilter-restore.service; do
        if [ -e "$unit" ]; then
            # 只删除明确属于 vpnmax/旧 ACVPN 的 unit；不因同名而删除其他 cloudflared 服务。
            if [ "$(basename "$unit")" = "vpnmax-rss.service" ] || [ "$(basename "$unit")" = "vpnplus-rss.service" ] || [ "$(basename "$unit")" = "sb.service" ] || [ "$(basename "$unit")" = "xr.service" ] || [ -d "$unit" ] || grep -qE '/etc/s-box|/root/websbox|vpnmax|ACVPN|ENABLE_DEPRECATED' "$unit" 2>/dev/null; then
                run_ok rm -rf "$unit"
                COUNT=$((COUNT + 1))
            else
                warn "保留未确认归属的 unit: $unit"
            fi
        fi
    done
    run_ok systemctl daemon-reload || true
    [ $COUNT -gt 0 ] && ok "已删除 ${COUNT} 个 vpnmax/sb systemd unit 文件" || info "无 vpnmax unit 文件需清理"
}

rm_files() {
    echo "--- 清理文件和目录 ---"
    local COUNT=0
    for path in /etc/s-box /usr/bin/sb /root/websbox \
        /usr/local/sbin/vpnmax-argo-keepalive.sh \
        /usr/local/sbin/vpnplus-argo-keepalive.sh \
        /usr/local/sbin/vpnmax-net-tuning.sh \
        /usr/local/sbin/vpnplus-net-tuning.sh \
        /var/lock/vpnmax-argo-keepalive.lock \
        /var/lock/vpnplus-argo-keepalive.lock \
        /etc/iptables/rules.v4 /etc/iptables/rules.v6 \
        /etc/logrotate.d/vpnmax \
        /etc/logrotate.d/vpnplus \
        /var/log/vpnmax-optimize.log \
        /var/log/vpnplus-optimize.log \
        /var/log/vpnmax-optimize-manifest.log \
        /var/log/vpnplus-optimize-manifest.log \
        /var/log/vpnmax-singbox-manifest.log \
        /var/log/vpnplus-singbox-manifest.log \
        /var/log/vpnmax-sbfeed.log \
        /var/log/vpnplus-sbfeed.log; do
        if [ -e "$path" ]; then
            run_ok rm -rf "$path"
            COUNT=$((COUNT + 1))
            ok "已删除: $path"
        fi
    done
    for mark in /etc/.ACVPN-optimized /etc/.ACVPN-singbox /etc/.vpnmax-optimized /etc/.vpnmax-singbox; do
        # 注意：[ -f ] && {...} 独立成句时，文件不存在=整句 rc=1，set -e 会杀脚本（2026-08-27 HK 实测），必须 || true
        if [ -f "$mark" ]; then
            run_ok rm -f "$mark"
            ok "已删除标记: $mark"
        fi
    done
    if [ $COUNT -eq 0 ]; then info "无 sb 文件需清理"; fi
}

# ———————— 6-7：sysctl / nftables 遗留清理 ————————
clean_sysctl() {
    echo "--- 清理系统已应用参数（不改动第三方配置） ---"
    # 我们只移除脚本文档明确自己写入的 sysctl.d 文件（若仍存在）
    for f in /etc/sysctl.d/99-ACVPN-security.conf /etc/sysctl.d/99-ACVPN-brutal.conf \
        /etc/sysctl.d/99-acvpn.conf /etc/sysctl.d/99-ACVPN.conf \
        /etc/sysctl.d/99-vpnmax-security.conf /etc/sysctl.d/99-vpnmax-brutal.conf \
        /etc/sysctl.d/99-vpnmax-bbr.conf; do
        # 同上：if 形式防 set -e 在文件不存在时杀脚本
        if [ -f "$f" ]; then
            run_ok rm -f "$f"
            ok "已删除 sysctl 文件: $f"
        fi
    done
    /etc/init.d/procps restart >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
}

clean_nft() {
    echo "--- 清理 nftables（仅 vpnmax 表） ---"
    if command -v nft >/dev/null 2>&1; then
        # 只有检测到 vpnmax/旧 ACVPN 的部署痕迹时才删除通用 sing-box 表，
        # 避免清理另一套独立 sing-box 实例。
        if [ -f /etc/.vpnmax-singbox ] || [ -f /etc/.ACVPN-singbox ] || [ -d /etc/s-box ]; then
            run_ok nft delete table inet sing-box 2>/dev/null
            run_ok nft delete table inet vpnmax 2>/dev/null
        else
            info "未确认 nftables sing-box 表归属，保留不动"
        fi
    fi
}

# ———————— 验证 ————————
verify_clean() {
    if $DRY_RUN; then
        info "[dry-run] 跳过清理结果验证（未执行实际删除）"
        return 0
    fi
    echo ""
    echo "========================================="
    echo "  验证清理结果"
    echo "========================================="
    local PASS=0 FAIL=0
    if ! systemctl is-active sing-box &>/dev/null && [ ! -f /etc/systemd/system/sing-box.service ]; then
        ok "sing-box 服务已清除"
        PASS=$((PASS + 1))
    else
        warn "sing-box 服务仍存在"
        FAIL=$((FAIL + 1))
    fi
    if [ ! -d /etc/systemd/system/sing-box.service.d ] && [ ! -f /etc/systemd/system/sing-box.service.d/99-vpnmax.conf ]; then
        ok "sing-box drop-in 已清除（无 legacy env 残留）"
        PASS=$((PASS + 1))
    else
        warn "sing-box.service.d drop-in 残留"
        FAIL=$((FAIL + 1))
    fi
    [ ! -d /etc/s-box ] && {
        ok "/etc/s-box 已删除"
        PASS=$((PASS + 1))
    } || {
        warn "/etc/s-box 仍存在"
        FAIL=$((FAIL + 1))
    }
    if ! ls /var/log/vpnmax-*.log >/dev/null 2>&1; then
        ok "vpnmax 日志已清除（无 IP/token 残留）"
        PASS=$((PASS + 1))
    else
        warn "vpnmax 日志仍存在"
        FAIL=$((FAIL + 1))
    fi
    if [ ! -f /etc/systemd/system/sb.service ] && [ ! -f /etc/systemd/system/xr.service ]; then
        ok "sb/xr 兼容服务已清除"
        PASS=$((PASS + 1))
    else
        warn "sb.service/xr.service 残留"
        FAIL=$((FAIL + 1))
    fi
    [ ! -f /etc/systemd/system/vpnmax-netfilter-restore.service ] && [ ! -f /etc/systemd/system/vpnplus-netfilter-restore.service ] && {
        ok "vpnmax-netfilter-restore.service 已删除"
        PASS=$((PASS + 1))
    } || {
        warn "vpnmax-netfilter-restore.service 仍存在"
        FAIL=$((FAIL + 1))
    }
    [ ! -f /usr/local/sbin/vpnmax-argo-keepalive.sh ] && [ ! -f /usr/local/sbin/vpnplus-argo-keepalive.sh ] && {
        ok "Argo 保活脚本已删除"
        PASS=$((PASS + 1))
    } || {
        warn "vpnmax-argo-keepalive.sh 仍存在"
        FAIL=$((FAIL + 1))
    }
    if iptables -L "$CHAIN_ANTIPROBE" -n >/dev/null 2>&1 || iptables -t nat -L "$CHAIN_PORTHOP" -n >/dev/null 2>&1; then
        warn "vpnmax 独立防火墙链仍存在"
        FAIL=$((FAIL + 1))
    else
        ok "vpnmax 独立防火墙链已清除"
        PASS=$((PASS + 1))
    fi
    if crontab -l 2>/dev/null | grep -qE 'vpnmax-argo-keepalive|vpnplus-argo-keepalive|acvpn-argo-keepalive|/usr/bin/sb|busybox httpd.*(/root/websbox|subport.log)' 2>/dev/null; then
        warn "crontab 残留 sb 条目"
        FAIL=$((FAIL + 1))
    else
        ok "crontab 无 sb 条目"
        PASS=$((PASS + 1))
    fi
    # 注意：pgrep -c 会把自己的 shell 也算进 /bin/bash 匹配，用 -f + 精确进程名排除干扰
    remaining=$(pgrep -f 'sing-box|cloudflared.*tunnel.*--url' 2>/dev/null | wc -l)
    if [ "$remaining" -eq 0 ]; then
        ok "进程已清理"
        PASS=$((PASS + 1))
    else
        warn "仍有 ${remaining} 个进程"
        FAIL=$((FAIL + 1))
    fi

    echo ""
    echo "========================================="
    echo -e "  通过: ${GREEN}${PASS}${N} / 失败: ${RED}${FAIL}${N}"
    echo "========================================="
    [ $FAIL -eq 0 ] || die "部分清理失败，请手动检查（--dry-run 为预览，未做实际清理）"
    echo -e "${GREEN}清理完成。可以开始部署。${N}"
}

bak_firewall
clean_chains
stop_services
kill_procs
kill_sub_httpd
clean_crontab
rm_units
rm_files
clean_sysctl
clean_nft
verify_clean
