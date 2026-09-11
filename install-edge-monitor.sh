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

# ── 迁移：移除旧的 cron 保活 ───────────────────────────────
# 旧保活（/usr/local/sbin/vpnmax-argo-keepalive.sh + 每 3 分钟 cron）与新 Edge Monitor
# 职责重叠，两者并存会出现两个实例抢着重启 cloudflared（历史上表现为 rn1 双进程）。
# 因此安装新系统前必须先移除旧系统，不能让用户“只装不改”。
remove_legacy_keepalive() {
    info "检查并移除旧的 cron 保活系统..."

    local found=0

    if crontab -l 2>/dev/null | grep -q "vpnmax-argo-keepalive"; then
        found=1
        info "移除旧 cron 任务..."
        crontab -l 2>/dev/null | grep -v "vpnmax-argo-keepalive" | crontab - 2>/dev/null || true
    fi

    if [ -f "/usr/local/sbin/vpnmax-argo-keepalive.sh" ]; then
        found=1
        info "删除旧保活脚本..."
        rm -f /usr/local/sbin/vpnmax-argo-keepalive.sh
    fi

    if [ -f "/etc/s-box/argo-keepalive.state" ]; then
        info "备份旧状态文件..."
        mv /etc/s-box/argo-keepalive.state /etc/s-box/argo-keepalive.state.bak 2>/dev/null || true
    fi

    rm -f /var/lock/vpnmax-argo-keepalive.lock 2>/dev/null || true

    if [ "$found" -eq 0 ]; then
        info "未发现旧保活系统，跳过"
    else
        info "旧保活系统已移除"
    fi
}

# ── 安装 ──────────────────────────────────────────────────
install_scripts() {
    info "安装脚本..."

    # Monitor 本体
    install -m 755 "$SCRIPT_DIR/vpnmax-edge-monitor.sh" /usr/local/sbin/vpnmax-edge-monitor.sh
    install -m 755 "$SCRIPT_DIR/vpnmax-speed-test.sh" /usr/local/sbin/vpnmax-speed-test.sh
    # Argo 隧道启动脚本：cloudflared-argo.service 的 ExecStart 指向它，
    # 不装就会出现“服务起不来 / 监控守一个不存在的脚本”。
    install -m 755 "$SCRIPT_DIR/cloudflared-argo-start.sh" /usr/local/sbin/cloudflared-argo-start.sh

    info "脚本安装完成"
}

install_service() {
    info "安装 systemd 服务..."

    # 复制服务文件（edge-monitor + 它要监控的 cloudflared-argo）
    install -m 644 "$SCRIPT_DIR/vpnmax-edge-monitor.service" /etc/systemd/system/vpnmax-edge-monitor.service
    install -m 644 "$SCRIPT_DIR/cloudflared-argo.service" /etc/systemd/system/cloudflared-argo.service

    # 重载 systemd
    systemctl daemon-reload

    # 启用服务
    systemctl enable vpnmax-edge-monitor.service
    systemctl enable cloudflared-argo.service

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

    # cloudflared-argo 是本套服务的一部分（ExecStart 依赖 cloudflared-argo-start.sh），
    # 一起清掉，避免留下指向已删脚本的孤儿 unit。
    systemctl stop cloudflared-argo.service 2>/dev/null || true
    systemctl disable cloudflared-argo.service 2>/dev/null || true
    rm -f /etc/systemd/system/cloudflared-argo.service
    rm -f /usr/local/sbin/cloudflared-argo-start.sh

    systemctl daemon-reload

    info "卸载完成"
    info "保留状态文件: /etc/s-box/edge-monitor.*"
}

# ── 主程序 ────────────────────────────────────────────────
case "${1:-}" in
install)
    check_root
    check_dependencies
    remove_legacy_keepalive
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
