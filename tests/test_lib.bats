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
