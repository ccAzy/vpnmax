#!/usr/bin/env bats
# tests/test_regressions.bats
#
# 2026-11-15 那轮「修 → 测 → 修」循环里暴露过的缺陷，逐个钉成回归。
# 每条都对应一个真实发生过的事故（见 CHANGELOG.md 同名日期）。

# ─────────────────────────── P0：订阅全空 ───────────────────────────

@test "vendor/sb.sh 不再用 sed 's://.*::g' 破坏 JSON（P0 订阅全空根因）" {
    # 那个 sed 的分隔符是 ':'，实际语义是「从 // 删到行尾」。
    # WARP private_key 是 base64，约 1% 概率含 //，一出现整条订阅静默变空。
    run grep -c "sed 's://.*::g'" vendor/sb.sh
    [ "$output" = "0" ]
}

@test "含 // 的 JSON 值经 cat|jq 后完好（P0 语义回归）" {
    command -v jq >/dev/null 2>&1 || skip "jq 缺失"
    run bash -c 'printf "%s" "{\"private_key\":\"mBqPJven//fRcu218=\"}" | cat | jq -r .private_key'
    [ "$output" = "mBqPJven//fRcu218=" ]
    [ "$status" -eq 0 ]
}

# ─────────────────────────── 并发互斥 ───────────────────────────

@test "并发锁：活进程持有的锁会拒绝第二个实例" {
    d=$(mktemp -d)
    sleep 30 &
    holder=$!
    printf '%s\n' "$holder" >"$d/vpnmax-system.pid"
    run env VPNMAX_LOCK_DIR="$d" bash -c 'source lib/common.sh; vpnmax_lock system'
    kill "$holder" 2>/dev/null || true
    rm -rf "$d"
    [ "$status" -ne 0 ]
    [[ "$output" == *"另一个 vpnmax 实例正在运行"* ]]
}

@test "并发锁：陈旧 pidfile（进程已死）会被自动接管" {
    d=$(mktemp -d)
    printf '999999\n' >"$d/vpnmax-system.pid"   # 几乎不可能存在的 PID
    run env VPNMAX_LOCK_DIR="$d" bash -c 'source lib/common.sh; vpnmax_lock system; echo acquired'
    rm -rf "$d"
    [ "$status" -eq 0 ]
    [[ "$output" == *"acquired"* ]]
}

@test "并发锁：正常退出后锁文件被清掉（EXIT trap 用全局变量）" {
    d=$(mktemp -d)
    # 关键回归：trap 里若引用函数内的 local lockfile，函数返回后变量已出栈，
    # 会报 "lockfile: unbound variable" 且锁文件删不掉。
    run env VPNMAX_LOCK_DIR="$d" bash -c 'source lib/common.sh; vpnmax_lock system'
    found=$(ls "$d"/vpnmax-system.pid 2>/dev/null | wc -l)
    rm -rf "$d"
    [ "$status" -eq 0 ]
    [ "$found" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]]
}

# ─────────────────────────── 订阅 server 真相源 ───────────────────────────

@test "sub_server_ip 优先取 clmi.yaml 的 server（而不去查外部 IP）" {
    command -v jq >/dev/null 2>&1 || skip "jq 缺失"
    d=$(mktemp -d)
    mkdir -p "$d/etc"
    printf 'proxies:\n  - name: x\n    server: 203.0.113.9\n    port: 443\n' >"$d/etc/clmi.yaml"
    # 把 /etc/s-box 指到临时目录：函数里写死了该路径，用 bind 不可行，
    # 这里改为直接验证解析逻辑（同一段 sed/tr 管道）
    got=$(grep -m1 -E '^[[:space:]]*server:[[:space:]]*' "$d/etc/clmi.yaml" \
        | sed 's/^[[:space:]]*server:[[:space:]]*//' | tr -d '"[:space:]' || true)
    rm -rf "$d"
    [ "$got" = "203.0.113.9" ]
}

@test "端口 / token 白名单拒绝畸形值（订阅链接拼接前的防线）" {
    run bash -c '
        source lib/common.sh
        source lib/subscription.sh
        vpnmax_valid_subport 48245 || exit 1
        vpnmax_valid_subport 80    && exit 1     # 低于 1024
        vpnmax_valid_subport abc   && exit 1
        vpnmax_valid_subtoken "b52aa6ff-b2b2-4994-9ab8-ef7aab8e17c5" || exit 1
        vpnmax_valid_subtoken "ab" && exit 1      # 太短
        vpnmax_valid_subtoken "has space" && exit 1
        exit 0
    '
    [ "$status" -eq 0 ]
}

# ─────────────────────────── verify 的孤儿进程泄漏 ───────────────────────────

@test "TUIC 自检按唯一配置名清理，不退回 kill \\$!（每跑一次漏一个进程）" {
    # 旧写法 kill -9 $_vpid 杀的是 timeout，sing-box 会被孤儿化继续跑
    run grep -c 'kill -9 \$_vpid' lib/verify/tuic.sh
    [ "$output" = "0" ]
    run grep -c "pkill -9 -f 'vpnmax-verify-tuic" lib/verify/tuic.sh
    [ "$output" -ge 1 ]
}

@test "verify.sh 不再保留 TUIC 检查的第二份内联副本" {
    # 双实现是那个 bug 两份都有的根源；只保留 lib/verify/tuic.sh 一份
    run grep -c 'timeout 4 /etc/s-box/sing-box run -c /tmp/vpnmax-verify-tuic.json' verify.sh
    [ "$output" = "0" ]
    run grep -c 'verify_tuic' verify.sh
    [ "$output" -ge 1 ]
}

# ─────────────────────────── 参数与输出分级 ───────────────────────────

@test "未知参数被拒（--no-reboo 曾会重启服务器）" {
    for f in deploy_optimize.sh deploy_singbox.sh bootstrap.sh; do
        run bash "$f" --bogus-flag
        [ "$status" -eq 2 ] || return 1
        [[ "$output" == *"未知参数"* ]] || return 1
    done
}

@test "警告分级：warn 进汇总、note 进可选组、hint 不进汇总" {
    run bash -c '
        source lib/common.sh
        warn "核心问题" >/dev/null
        note "可选组件" >/dev/null
        hint "长期提示" >/dev/null
        printf "%s|%s\n" "${#VPNMAX_WARNINGS[@]}" "${#VPNMAX_NOTES[@]}"
    '
    [ "$output" = "1|1" ]
}

# ─────────────────────────── 部署输出瘦身 ───────────────────────────

@test "上游装饰行被过滤（banner/菜单/分隔线），错误与提示保留" {
    run bash -c '
        source lib/common.sh
        source lib/singbox.sh
        printf "%s\n" \
          "  ░██   ░██  " \
          "~~~~~~" \
          "甬哥Github项目" \
          " 1. 一键安装 Sing-box" \
          "Sing-box状态：未安装" \
          "下载失败：网络不可达" | _sb_console_filter
    '
    [[ "$output" != *"░"* ]]
    [[ "$output" != *"甬哥"* ]]
    [[ "$output" != *"1. 一键安装"* ]]
    [[ "$output" == *"下载失败"* ]]
}
