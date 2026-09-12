#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# lib/hardening.sh — 系统安全加固（网络感知 sysctl + systemd LimitNOFILE）
# 依赖 lib/common.sh 的 info/ok/warn/run

[ -n "${VPNMAX_HARDENING_LOADED:-}" ] && return 0
VPNMAX_HARDENING_LOADED=1

apply_hardening() {
    local conf="/etc/sysctl.d/99-vpnmax-security.conf"
    local v6_ra_lines
    # 检测本机是否有 IPv6 地址（无 v6 才关 RA，避免破坏依赖 RA 获址的 VPS）
    if ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        v6_ra_lines=$'net.ipv6.conf.all.accept_ra = 0\nnet.ipv6.conf.default.accept_ra = 0'
    else
        v6_ra_lines='# 检测到 IPv6 地址，保留 RA 以防破坏 v6 网络配置'
    fi
    run bash -c "cat > '$conf' <<'SEC'
# vpnmax 安全加固（网络感知生成）
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
$v6_ra_lines
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
SEC"
    sysctl --system >/dev/null 2>&1 || true
    ok "安全 sysctl 已持久化 ($conf)"

    local applied=false svc
    for svc in sing-box sb xr; do
        if [ -f "/etc/systemd/system/${svc}.service" ]; then
            mkdir -p "/etc/systemd/system/${svc}.service.d" 2>/dev/null || continue
            run bash -c "cat > '/etc/systemd/system/${svc}.service.d/99-vpnmax.conf' <<'LIMIT'
[Service]
LimitNOFILE=1048576
LIMIT"
            applied=true
        fi
    done
    if $applied; then
        run systemctl daemon-reload || true
        for svc in sing-box sb xr; do
            systemctl is-active "$svc" >/dev/null 2>&1 && run systemctl try-restart "$svc" || true
        done
        ok "systemd LimitNOFILE=1048576 已生效 (sing-box/sb/xr)"
    fi
}
