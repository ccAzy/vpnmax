#!/bin/bash
# install-edge-monitor.sh — 安装 Edge Monitor 服务
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

check_dependencies() {
    local deps="curl jq bc"
    for dep in $deps; do
        if ! command -v "$dep" &>/dev/null; then
            warn "缺少 $dep，正在安装..."
            apt-get update -qq && apt-get install -y -qq "$dep" 2>/dev/null || {
                error "安装 $dep 失败"
                exit 1
            }
        fi
    done
}

# ── 安装 ──────────────────────────────────────────────────
install_scripts() {
    info "安装脚本..."

    # 复制脚本
    install -m 755 "$SCRIPT_DIR/vpnmax-edge-monitor.sh" /usr/local/sbin/vpnmax-edge-monitor.sh
    install -m 755 "$SCRIPT_DIR/vpnmax-speed-test.sh" /usr/local/sbin/vpnmax-speed-test.sh

    info "脚本安装完成"
}

install_service() {
    info "安装 systemd 服务..."

    # 复制服务文件
    install -m 644 "$SCRIPT_DIR/vpnmax-edge-monitor.service" /etc/systemd/system/vpnmax-edge-monitor.service

    # 重载 systemd
    systemctl daemon-reload

    # 启用服务
    systemctl enable vpnmax-edge-monitor.service

    info "服务安装完成"
}

# ── 配置 ──────────────────────────────────────────────────
create_state_dir() {
    info "创建状态目录..."

    mkdir -p /etc/s-box
    touch /etc/s-box/edge-monitor.state
    touch /etc/s-box/edge-monitor.log
    touch /etc/s-box/speed-test.log

    info "状态目录创建完成"
}

# ── 启动 ──────────────────────────────────────────────────
start_service() {
    info "启动 Edge Monitor 服务..."

    systemctl start vpnmax-edge-monitor.service

    # 检查状态
    if systemctl is-active --quiet vpnmax-edge-monitor.service; then
        info "服务启动成功"
    else
        error "服务启动失败"
        systemctl status vpnmax-edge-monitor.service --no-pager || true
        exit 1
    fi
}

# ── 状态 ──────────────────────────────────────────────────
show_status() {
    echo ""
    info "=== Edge Monitor 状态 ==="
    systemctl status vpnmax-edge-monitor.service --no-pager || true
    echo ""
    info "=== 最近日志 ==="
    journalctl -u vpnmax-edge-monitor.service --no-pager -n 20 || true
    echo ""
    info "=== 监控日志 ==="
    tail -20 /etc/s-box/edge-monitor.log 2>/dev/null || echo "(无日志)"
}

# ── 卸载 ──────────────────────────────────────────────────
uninstall() {
    info "卸载 Edge Monitor..."

    systemctl stop vpnmax-edge-monitor.service 2>/dev/null || true
    systemctl disable vpnmax-edge-monitor.service 2>/dev/null || true

    rm -f /etc/systemd/system/vpnmax-edge-monitor.service
    rm -f /usr/local/sbin/vpnmax-edge-monitor.sh
    rm -f /usr/local/sbin/vpnmax-speed-test.sh

    systemctl daemon-reload

    info "卸载完成"
    info "保留状态文件: /etc/s-box/edge-monitor.*"
}

# ── 主程序 ────────────────────────────────────────────────
case "${1:-}" in
install)
    check_root
    check_dependencies
    install_scripts
    install_service
    create_state_dir
    start_service
    show_status
    ;;
uninstall)
    check_root
    uninstall
    ;;
status)
    show_status
    ;;
start)
    check_root
    systemctl start vpnmax-edge-monitor.service
    ;;
stop)
    check_root
    systemctl stop vpnmax-edge-monitor.service
    ;;
restart)
    check_root
    systemctl restart vpnmax-edge-monitor.service
    ;;
*)
    echo "用法: $0 {install|uninstall|status|start|stop|restart}"
    exit 1
    ;;
esac
