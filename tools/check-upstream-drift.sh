#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# tools/check-upstream-drift.sh — 上游漂移巡检（信息性，不阻断）
#
# 用途：把「依赖悄悄落后」这件事从隐性变显性。
# 本项目对第三方脚本采取「pin commit + SHA256」冻结策略，代价是**不会自动跟随上游**：
# 上游修了 bug、改了配置模板，我们都不会知道，直到某天撞上。
# 这个脚本把「我们落后多少」直接打出来，再决定要不要 re-vendor。
#
# 退出码恒为 0（这是巡检，不是门禁）。要阻断请用 tools/check-lib-integrity.py。
#
# 用法：
#   bash tools/check-upstream-drift.sh          # 只查 commit 是否落后
#   DEEP=1 bash tools/check-upstream-drift.sh    # 额外比对上游文件是否与我们的 vendor 一致

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 0

SB_COMMIT=$(grep -m1 '^SB_COMMIT=' deploy_singbox.sh | cut -d'"' -f2)
SB_SHA256=$(grep -m1 '^SB_SHA256=' deploy_singbox.sh | cut -d'"' -f2)

# 名称 | 仓库 URL | 我们 pin 的 commit | 判断依据来源变量
pins() {
    printf '%s\t%s\t%s\n' \
        "sing-box-yg(sb.sh)" "https://github.com/yonggekkk/sing-box-yg" "$SB_COMMIT"
}

hr() { printf '%s\n' "------------------------------------------------------------------"; }

echo "vpnmax 上游漂移巡检  $(date -Is)"
hr
printf '%-22s %-12s %-12s %s\n' "依赖" "我们 pin" "上游 HEAD" "状态"

drift=0
while IFS=$'\t' read -r name url pin; do
    [ -n "$name" ] || continue
    head=$(timeout 25 git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1}')
    if [ -z "$head" ]; then
        printf '%-22s %-12s %-12s %s\n' "$name" "${pin:0:12}" "(取不到)" "网络不可达，跳过"
        continue
    fi
    if [ "$head" = "$pin" ]; then
        printf '%-22s %-12s %-12s %s\n' "$name" "${pin:0:12}" "${head:0:12}" "与上游一致"
    else
        printf '%-22s %-12s %-12s %s\n' "$name" "${pin:0:12}" "${head:0:12}" "**落后**"
        drift=$((drift + 1))
    fi
done < <(pins)
hr

if [ "${DEEP:-0}" = "1" ] && [ -n "${SB_COMMIT:-}" ]; then
    echo "深度比对：上游文件 vs 本地 vendor/sb.sh"
    tmp=$(mktemp /tmp/sb-upstream.XXXXXX.sh 2>/dev/null) || exit 0
    if curl -fsSL --connect-timeout 15 --max-time 120 \
        -o "$tmp" "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/$SB_COMMIT/sb.sh" 2>/dev/null; then
        if [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$SB_SHA256" ]; then
            echo "  vendor/sb.sh 与该 commit 的上游文件字节一致（无本地补丁层）"
        else
            echo "  vendor/sb.sh 与该 commit 的上游文件不同：本地有补丁层（这是预期的）"
            echo "  补丁规模：$(grep -c 'vpnmax\|VPNMAX' vendor/sb.sh 2>/dev/null || echo '?') 处 vpnmax 标记"
        fi
        echo "  上游那份里的已知缺陷：sed 's://.*::g' 命中 $(grep -c "sed 's://.*::g'" "$tmp" 2>/dev/null || echo 0) 处"
        echo "  （>0 表示：直接换上游文件会重新引入「订阅全空」P0，必须把本地补丁层重新应用）"
    else
        echo "  拉取上游文件失败（网络），跳过"
    fi
    rm -f "$tmp" 2>/dev/null || true
    hr
fi

if [ "$drift" -gt 0 ]; then
    cat <<'EOF'
结论：有依赖落后于上游。

**这不是「必须马上升级」**。本项目的冻结策略本来就不跟随上游，
当前版本与最新内核的兼容性由 `sing-box check` 在部署后实测判定。

判断要不要 re-vendor 的触发条件（满足任一条再做，且必须整层移植、不能只换文件）：
  1. 部署时 `sing-box check` 开始失败（说明内核真的删了 legacy 逃生口）；
  2. 上游修复了我们本地补丁层里的某个缺陷，而我们没有独立修；
  3. 需要上游的新协议/新特性。

re-vendor 的做法：上游文件 + 重新应用本地补丁层（见 vendor/README.md），
而不是把上游文件直接覆盖 vendor/sb.sh —— 上游版仍有 93 处
`sed 's://.*::g'`，直接覆盖会重新引入「订阅全空」。
EOF
else
    echo "结论：全部与上游一致。"
fi
exit 0
