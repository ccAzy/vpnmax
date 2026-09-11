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
