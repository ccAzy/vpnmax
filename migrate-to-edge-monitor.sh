#!/bin/bash
# migrate-to-edge-monitor.sh — 从旧保活系统迁移到 Edge Monitor
set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 检查 ──────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 权限运行"
        exit 1
    fi
}

# ── 迁移 ──────────────────────────────────────────────────
remove_old_keepalive() {
    info "移除旧保活系统..."

    # 1. 停止 cron 任务
    if crontab -l 2>/dev/null | grep -q "vpnmax-argo-keepalive"; then
        info "移除 cron 任务..."
        crontab -l 2>/dev/null | grep -v "vpnmax-argo-keepalive" | crontab - 2>/dev/null || true
    fi

    # 2. 删除旧脚本
    if [ -f "/usr/local/sbin/vpnmax-argo-keepalive.sh" ]; then
        info "删除旧脚本..."
        rm -f /usr/local/sbin/vpnmax-argo-keepalive.sh
    fi

    # 3. 删除旧状态文件（保留备份）
    if [ -f "/etc/s-box/argo-keepalive.state" ]; then
        info "备份旧状态文件..."
        mv /etc/s-box/argo-keepalive.state /etc/s-box/argo-keepalive.state.bak 2>/dev/null || true
    fi

    # 4. 删除旧锁文件
    rm -f /var/lock/vpnmax-argo-keepalive.lock 2>/dev/null || true

    info "旧保活系统已移除"
}

install_new_system() {
    info "安装新 Edge Monitor 系统..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 安装脚本
    install -m 755 "$SCRIPT_DIR/vpnmax-edge-monitor.sh" /usr/local/sbin/vpnmax-edge-monitor.sh
    install -m 755 "$SCRIPT_DIR/vpnmax-speed-test.sh" /usr/local/sbin/vpnmax-speed-test.sh
    install -m 755 "$SCRIPT_DIR/cloudflared-argo-start.sh" /usr/local/sbin/cloudflared-argo-start.sh

    # 安装服务
    install -m 644 "$SCRIPT_DIR/vpnmax-edge-monitor.service" /etc/systemd/system/vpnmax-edge-monitor.service
    install -m 644 "$SCRIPT_DIR/cloudflared-argo.service" /etc/systemd/system/cloudflared-argo.service

    # 创建状态目录
    mkdir -p /etc/s-box
    touch /etc/s-box/edge-monitor.state
    touch /etc/s-box/edge-monitor.log
    touch /etc/s-box/speed-test.log

    # 重载 systemd
    systemctl daemon-reload

    # 启用服务
    systemctl enable vpnmax-edge-monitor.service
    systemctl enable cloudflared-argo.service

    info "新系统安装完成"
}

start_new_system() {
    info "启动 Edge Monitor 服务..."

    systemctl start vpnmax-edge-monitor.service

    if systemctl is-active --quiet vpnmax-edge-monitor.service; then
        info "服务启动成功"
    else
        error "服务启动失败"
        systemctl status vpnmax-edge-monitor.service --no-pager || true
        return 1
    fi
}

show_status() {
    echo ""
    info "=== 迁移完成 ==="
    echo ""
    info "旧系统状态："
    if crontab -l 2>/dev/null | grep -q "vpnmax-argo-keepalive"; then
        warn "  cron 任务仍存在"
    else
        info "  cron 任务已移除 ✓"
    fi

    if [ -f "/usr/local/sbin/vpnmax-argo-keepalive.sh" ]; then
        warn "  旧脚本仍存在"
    else
        info "  旧脚本已移除 ✓"
    fi

    echo ""
    info "新系统状态："
    systemctl status vpnmax-edge-monitor.service --no-pager || true

    echo ""
    info "=== 使用方法 ==="
    echo "  查看状态: systemctl status vpnmax-edge-monitor"
    echo "  查看日志: journalctl -u vpnmax-edge-monitor -f"
    echo "  停止服务: systemctl stop vpnmax-edge-monitor"
    echo "  重启服务: systemctl restart vpnmax-edge-monitor"
}

# ── 主程序 ────────────────────────────────────────────────
main() {
    info "=== VPNMax Edge Monitor 迁移脚本 ==="
    echo ""
    info "此脚本将："
    info "1. 移除旧的 cron 保活系统"
    info "2. 安装新的 systemd Edge Monitor 系统"
    info "3. 启动新服务"
    echo ""

    read -p "确认迁移？(y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "已取消"
        exit 0
    fi

    check_root
    remove_old_keepalive
    install_new_system
    start_new_system
    show_status

    info "=== 迁移完成 ==="
}

# ── 入口 ──────────────────────────────────────────────────
case "${1:-}" in
--help | -h)
    echo "用法: $0 [选项]"
    echo ""
    echo "选项："
    echo "  --help, -h    显示帮助"
    echo "  --status      只显示状态"
    echo ""
    echo "此脚本将旧的 cron 保活系统迁移到新的 systemd Edge Monitor 系统。"
    ;;
--status)
    show_status
    ;;
*)
    main
    ;;
esac
