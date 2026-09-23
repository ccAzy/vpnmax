#!/usr/bin/env bats
# tests for lib/common/time/firewall

@test "lib/common.sh loads" {
  run bash -c 'source lib/common.sh; type info >/dev/null && echo ok'
  [ "$output" = "ok" ]
}

@test "lib/time.sh ensure_time_sync dry-run" {
  # lib/time.sh 依赖 lib/common.sh 的 info()/run()，必须先 source 前者
  run bash -c 'source lib/common.sh; source lib/time.sh; DRY_RUN=true ensure_time_sync'
  [[ "$output" == *"dry-run"* ]]
}

@test "lib/firewall.sh constants exist" {
  run bash -c 'source lib/firewall.sh; echo $HOP_HY_RANGE'
  [ "$output" = "40000:42000" ]
}

@test "deploy --force 强制覆盖已有 sb" {
  run bash -c 'source lib/common.sh; source lib/singbox.sh; command(){ return 0; }; FORCE=false; ! sb_needs_install; FORCE=true; sb_needs_install'
  [ "$status" -eq 0 ]
}

@test "只信任当前 sb 原版/补丁哈希，旧 marker 不再保活旧版" {
  run bash -c 'source lib/common.sh; source lib/singbox.sh; SB_SHA256=raw; SB_ARGO_PATCHED_SHA256=patched; sb_hash_trusted raw; sb_hash_trusted patched; ! sb_hash_trusted stale'
  [ "$status" -eq 0 ]
}

@test "sb 原子安装失败不会用旧非空文件冒充成功" {
  run bash -c 'source lib/common.sh; source lib/singbox.sh; d=$(mktemp -d); printf old >"$d/sb"; src=$(mktemp); printf new >"$src"; expected=$(sha256sum "$src" | awk "{print \$1}"); install_sb_atomic "$src" "$expected" "$d/sb"; test "$(cat "$d/sb")" = new; ! install_sb_atomic "$src" wrong "$d/sb"; test "$(cat "$d/sb")" = new; rm -rf "$d" "$src"'
  [ "$status" -eq 0 ]
}

@test "真实 iptables-save 的单数 --dport 跳跃段能解析" {
  run bash -c 'line="-A VPNMAX_PORTHOP -p udp -m udp --dport 40000:42000 -j DNAT --to-destination :27800"; got=$(printf "%s\\n" "$line" | grep -oE -- "--dports? [0-9]+:[0-9]+" | grep -oE "[0-9]+:[0-9]+" | head -1); test "$got" = 40000:42000'
  [ "$status" -eq 0 ]
}

@test "vendor/sb.sh 原版和 Argo 补丁哈希与入口常量一致" {
  raw_expected=$(grep 'SB_SHA256=' deploy_singbox.sh | cut -d'"' -f2)
  patched_expected=$(grep 'SB_ARGO_PATCHED_SHA256=' deploy_singbox.sh | cut -d'"' -f2)
  raw_actual=$(sha256sum vendor/sb.sh | awk '{print $1}')
  tmp=$(mktemp)
  cp vendor/sb.sh "$tmp"
  sed -i 's/--protocol http2/--protocol auto/g' "$tmp"
  patched_actual=$(sha256sum "$tmp" | awk '{print $1}')
  rm -f "$tmp"
  [ "$raw_actual" = "$raw_expected" ]
  [ "$patched_actual" = "$patched_expected" ]
}

@test "lib/verify/time.sh loads" {
  run bash -c 'source lib/verify/time.sh; type verify_time >/dev/null && echo ok'
  [ "$output" = "ok" ]
}

@test "入口脚本 --help 不执行游离命令（R6 回归）" {
  # 回归（2026-09-23 线上事故）：头部用法注释块漏写 `#` 时，
  # `  bash bootstrap.sh [选项]` 会被当真命令跑 → 报 No such file，
  # 紧接着 `bash <(curl .../bootstrap.sh)` 递归自举 → 死循环刷屏。
  # bash -n / shellcheck 都不报（语法合法），只能靠“跑一下”逮住。
  for s in bootstrap.sh deploy_optimize.sh deploy_singbox.sh cleanup.sh; do
    run timeout 20 bash "$s" --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"No such file or directory"* ]]
    [[ "$output" != *"command not found"* ]]
  done
}

@test "乱序 inbounds 按 type 查询各归其位（HY2/TUIC 回归）" {
  # 回归：vendor/sb.sh 曾用 .inbounds[N] 硬下标，sb.json 增删 inbounds 后全错位。
  # 现按 type 查询（与 lib/argo.sh:105 同范式）；此处静态断言 idiom，语义用 jq/python 双通道验证。
  run bash -c 'grep -c "inbounds\[[0-9]" vendor/sb.sh || true'
  [ "$output" = "0" ]
  run bash -c 'grep -c "select(.type==" vendor/sb.sh'
  [ "$output" -ge 60 ]
  d=$(mktemp -d)
  cat >"$d/sb.json" <<'JSON'
{
  "inbounds": [
    { "type": "tuic", "listen_port": 44001 },
    { "type": "hysteria2", "listen_port": 41001 },
    { "type": "vmess", "listen_port": 21001 },
    { "type": "anytls", "listen_port": 51001 },
    { "type": "vless", "listen_port": 11001 }
  ]
}
JSON
  if command -v jq >/dev/null 2>&1; then
    # 与 vendor/sb.sh 实装同一过滤器（含 // 注释预处理）
    printf '// scrambled fixture\n' >>"$d/sb.json"
    [ "$(sed 's://.*::g' "$d/sb.json" | jq -r '[.inbounds[]|select(.type=="vless")][0].listen_port')" = "11001" ]
    [ "$(sed 's://.*::g' "$d/sb.json" | jq -r '[.inbounds[]|select(.type=="vmess")][0].listen_port')" = "21001" ]
    [ "$(sed 's://.*::g' "$d/sb.json" | jq -r '[.inbounds[]|select(.type=="hysteria2")][0].listen_port')" = "41001" ]
    [ "$(sed 's://.*::g' "$d/sb.json" | jq -r '[.inbounds[]|select(.type=="tuic")][0].listen_port')" = "44001" ]
    [ "$(sed 's://.*::g' "$d/sb.json" | jq -r '[.inbounds[]|select(.type=="anytls")][0].listen_port')" = "51001" ]
  elif command -v python3 >/dev/null 2>&1; then
    run python3 - "$d/sb.json" <<'PY'
import json, sys
inb = json.load(open(sys.argv[1]))["inbounds"]
q = lambda t: [i for i in inb if i.get("type") == t][0]["listen_port"]
assert (q("vless"), q("vmess"), q("hysteria2"), q("tuic"), q("anytls")) == (11001, 21001, 41001, 44001, 51001), "乱序归位失败"
print("order-ok")
PY
    [ "$output" = "order-ok" ]
  else
    skip "jq/python3 均缺失"
  fi
  rm -rf "$d"
}

@test "双 DNAT 规则取最新跳跃段（tail -1 回归）" {
  # 回归：PREROUTING 堆积新旧两条 DNAT 时 head -1 取旧段 → 跳跃指向已废弃端口。
  # 与 vendor/sb.sh:1134/1164/2821-2822 同一管道（输入换为 fixture）。
  save=$(mktemp)
  cat >"$save" <<'EOF'
-A PREROUTING -p udp -m udp --dport 40000:42000 -j DNAT --to-destination :27800
-A PREROUTING -p udp -m udp --dport 43000:45000 -j DNAT --to-destination :27800
EOF
  hy2_port=27800
  got=$(grep -- "--to-destination :$hy2_port$" "$save" | grep -oE -- "--dports? [0-9]+:[0-9]+" | grep -oE '[0-9]+:[0-9]+' | tail -1 || true)
  [ "$got" = "43000:45000" ]
  old=$(grep -- "--to-destination :$hy2_port$" "$save" | grep -oE -- "--dports? [0-9]+:[0-9]+" | grep -oE '[0-9]+:[0-9]+' | head -1 || true)
  [ "$old" = "40000:42000" ]
  grep -q "tail -1" vendor/sb.sh
  rm -f "$save"
}

@test "防火墙 v6 对称清理 + vendor 不再整机拆防火墙" {
  run bash -c 'grep -c "ip6tables" lib/firewall.sh'
  [ "$output" -ge 40 ]
  # PORTHOP 链清理 v4/v6 对称（D/F/X 成套）
  grep -q 'ip6tables -t nat -D PREROUTING -j "$CHAIN_PORTHOP"' lib/firewall.sh
  grep -q 'ip6tables -t nat -F "$CHAIN_PORTHOP"' lib/firewall.sh
  grep -q 'ip6tables -t nat -X "$CHAIN_PORTHOP"' lib/firewall.sh
  # 跳跃残留 v6 镜像循环
  grep -q 'rnum6=$(ip6tables -t nat -L PREROUTING' lib/firewall.sh
  # vendor close() 只删自家 DNAT（v4/v6 对称），不再 ufw disable / 整机 -F/-X/-P（跳过注释行）
  run bash -c 'grep -v "^[[:space:]]*#" vendor/sb.sh | grep -c "ufw disable" || true'
  [ "$output" = "0" ]
  run bash -c 'grep -v "^[[:space:]]*#" vendor/sb.sh | grep -cE "iptables -(F|X|P)[[:space:]]" || true'
  [ "$output" = "0" ]
  grep -q 'ip6tables -t nat -D PREROUTING -p udp --dport' vendor/sb.sh
}

@test "sshd 解析：多 Port + Include 展开 + Match 块排除" {
  d=$(mktemp -d)
  mkdir -p "$d/sshd_config.d"
  cat >"$d/sshd_config" <<'EOF'
Port 2222
Port 6688
Include sshd_config.d/*.conf
Match User blocked
    Port 9999
EOF
  cat >"$d/sshd_config.d/extra.conf" <<'EOF'
Port 7777
Match Address 10.0.0.0/8
    Port 8888
EOF
  # 与 lib/firewall.sh 回退分支同一 awk：主文件 Match 块内 Port 排除
  main=$(awk 'BEGIN{inmatch=0} /^[[:space:]]*Match[[:space:]]/ {inmatch=1; next} inmatch==0 && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+/ {print $2}' "$d/sshd_config" | sort -nu | tr '\n' ' ')
  [[ "$main" == *"2222"* ]]
  [[ "$main" == *"6688"* ]]
  [[ "$main" != *"9999"* ]]
  # Include 文件同样跳 Match 块
  inc=$(awk 'BEGIN{inmatch=0} /^[[:space:]]*Match[[:space:]]/ {inmatch=1; next} inmatch==0 && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+/ {print $2}' "$d/sshd_config.d/extra.conf" | sort -nu | tr '\n' ' ')
  [[ "$inc" == *"7777"* ]]
  [[ "$inc" != *"8888"* ]]
  # lib 实装三要素：sshd -T 全量 + Include 展开 + Match 排除
  grep -q "sshd -T" lib/firewall.sh
  grep -q "Include" lib/firewall.sh
  grep -q "inmatch" lib/firewall.sh
  rm -rf "$d"
}

@test "chrony 双路径 + sourcedir 保留 + 关 timesyncd" {
  grep -q "/etc/chrony/chrony.conf" lib/time.sh
  grep -q "/etc/chrony.conf" lib/time.sh
  grep -q "sourcedir" lib/time.sh
  grep -q "systemd-timesyncd" lib/time.sh
  grep -q 'mask systemd-timesyncd' lib/time.sh
  grep -q 'bak\.' lib/time.sh
  run bash -c 'source lib/common.sh; source lib/time.sh; DRY_RUN=true ensure_time_sync'
  [[ "$output" == *"dry-run"* ]]
}

@test "GRUB 回退 + sysctl 全原子写 + RP 覆盖（回归静态门）" {
  grep -q "TIMEOUT_STYLE=menu" lib/optimize.sh
  grep -q "grub-mkconfig" lib/optimize.sh
  grep -q "vpnmax_sysctl_set" lib/optimize.sh
  grep -q "vpnmax_grub_backup" lib/optimize.sh
  grep -q "VPNMAX_RP_FILTER" lib/hardening.sh
  run bash -c 'source lib/common.sh; source lib/optimize.sh; type vpnmax_sysctl_set >/dev/null && echo ok'
  [ "$output" = "ok" ]
}

@test "R7b 联动门禁：REV 格式 + BOOT 自哈希干净" {
  # R7a（vendor 双哈希）由既有用例“原版和 Argo 补丁哈希与入口常量一致”覆盖；
  # vendor 定稿前允许漂移（leader 重算后转绿），此处只 gate R7b。
  run python3 tools/check-lib-integrity.py
  [[ "$output" != *"R7b"* ]]
  run bash -c 'grep -qE "^VPNMAX_LIB_REV=\"20[0-9]{2}-[0-9]{2}-[0-9]{2}\.[0-9]+\"" lib/boot.sh && echo ok'
  [ "$output" = "ok" ]
}

@test "完整性门禁 GBK 字节不崩溃（errors=replace 回归）" {
  # 回归：checker 三处裸 read_text(encoding="utf-8") 遇到 GBK 存盘的 .sh 即 UnicodeDecodeError 全崩。
  d=$(mktemp -d)
  printf '#!/bin/bash\n# \xd6\xd0\xce\xc4\xd7\xa2\xca\xcd\nreadonly GBK_T=1\n' >"$d/gbk.sh"
  run python3 -c 'import sys; from pathlib import Path; t = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace"); assert "GBK_T" in t; print("gbk-ok")' "$d/gbk.sh"
  [ "$output" = "gbk-ok" ]
  # 门禁源码不得残留裸 read_text(encoding="utf-8")（无 errors 即崩溃向量）
  run bash -c 'grep -c "errors=\"replace\"" tools/check-lib-integrity.py'
  [ "$output" -ge 4 ]
  ! grep -q 'read_text(encoding="utf-8")' tools/check-lib-integrity.py
  rm -rf "$d"
}
