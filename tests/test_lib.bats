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
