#!/bin/bash
# lib/verify/tuic.sh — TUIC 端口污染与回环自检
[ -n "${VPNMAX_VERIFY_TUIC_LOADED:-}" ] && return 0
VPNMAX_VERIFY_TUIC_LOADED=1

verify_tuic() {
    # 有 verify.sh 提供的计数助手就用它，独立加载时退回 ok/warn
    local _p=ok _q=warn
    declare -F check_pass >/dev/null 2>&1 && _p=check_pass
    declare -F check_fail >/dev/null 2>&1 && _q=check_fail
    local TU_PORT
    TU_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)
    [ -z "$TU_PORT" ] || [ "$TU_PORT" = "null" ] && return 0
    if [ "$TU_PORT" = "40254" ]; then warn "TUIC 仍为 40254（已知易被运营商限速，建议切 54321 并重建跳跃 DNAT）"; else $_p "TUIC 端口 $TU_PORT 非已知污染端口"; fi
    if iptables -t nat -L "$CHAIN_PORTHOP" -n 2>/dev/null | grep -q "to::${TU_PORT}"; then $_p "端口跳跃 DNAT 指向 TUIC $TU_PORT"; else $_q "端口跳跃 DNAT 未指向 TUIC $TU_PORT（43000:45000 应 DNAT 到 :$TU_PORT）"; fi
    if [ -n "$TU_PORT" ] && command -v /etc/s-box/sing-box >/dev/null 2>&1; then
        local _tuic_uuid
        _tuic_uuid=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid' /etc/s-box/sb.json 2>/dev/null || true)
        if [ -n "$_tuic_uuid" ] && [ "$_tuic_uuid" != "null" ]; then
            local _port
            _port=$(shuf -i 18080-19090 -n1 2>/dev/null || echo 18081)
            cat >/tmp/vpnmax-verify-tuic.json <<JSON_TMP
{"log":{"level":"error"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":$_port}],"outbounds":[{"type":"tuic","server":"127.0.0.1","server_port":$TU_PORT,"uuid":"$_tuic_uuid","password":"$_tuic_uuid","congestion_control":"bbr","tls":{"enabled":true,"server_name":"www.bing.com","insecure":true,"alpn":["h3"]}}]}
JSON_TMP
            # timeout 只是兵底，且它的 PID ≠ sing-box 的 PID——kill $! 只杀掉 timeout，
            # sing-box 会被孤儿化并一直跑下去（实测每次 verify 漏一个，累积占内存）。
            # 同时 timeout 必须大于 curl 的 --max-time，否则会在测试中途砍掉后端。
            timeout 20 /etc/s-box/sing-box run -c /tmp/vpnmax-verify-tuic.json >/tmp/vpnmax-verify-tuic.log 2>&1 &
            local _vpid=$!
            # disown：pkill 杀掉后台任务时 bash 的作业控制会打印一行 "Killed"，
            # 混在验证结果里像报错（它只是清理动作的副产物）
            disown "$_vpid" 2>/dev/null || true
            sleep 2
            if curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:"$_port" --connect-timeout 4 --max-time 6 https://www.google.com/generate_204 2>/dev/null | grep -q '204'; then $_p "TUIC 本地回环自检通（127.0.0.1:$TU_PORT → google 204）"; else warn "TUIC 本地回环不通（本机 sing-box 或证书异常，非外网墙；不计失败）"; fi
            # 按唯一配置路径精确清理（比 PID 可靠，顺带收掉历史遗留的孤儿）
            pkill -9 -f 'vpnmax-verify-tuic\.json' 2>/dev/null || true
            wait "$_vpid" 2>/dev/null || true
            rm -f /tmp/vpnmax-verify-tuic.json /tmp/vpnmax-verify-tuic.log 2>/dev/null || true
        fi
    fi
    return 0
}
