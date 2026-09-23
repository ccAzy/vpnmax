#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# lib/boot.sh — vpnmax 唯一引导层
#
# 目标：入口脚本无论以「仓库模式」「已安装模式」「curl|bash 单文件模式」运行，
#       都加载同一份 lib/。lib/ 是唯一源码，不再有内联副本。
#
# 入口脚本只写：
#   VPNMAX_SCRIPT_DIR="${VPNMAX_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)}"
#   . "$VPNMAX_SCRIPT_DIR/lib/boot.sh" 2>/dev/null || . "${VPNMAX_LIB_HOME:-/usr/local/lib/vpnmax}/boot.sh" 2>/dev/null || { <自举下载 boot.sh>; }
#   vpnmax_load "common time firewall singbox subscription argo warp" || exit 1
#
# 查找顺序：$VPNMAX_SCRIPT_DIR/lib → ./lib → $VPNMAX_LIB_HOME
#           全无 → 从 $VPNMAX_RAW/lib 自举下载到 $VPNMAX_LIB_HOME
#
# 为什么要有这一层：历史上每个入口脚本把每个函数各抄一份内联兜底（共 38 块），
# 与 lib/ 逐份漂移，靠检查器人工对齐。那是「为支持单文件部署而把一份代码拆两份」
# 的代价。现在单文件模式改为运行时自举取回 lib/，源码只有一份。
# ===================================================================

VPNMAX_LIB_HOME="${VPNMAX_LIB_HOME:-/usr/local/lib/vpnmax}"
VPNMAX_RAW="${VPNMAX_RAW:-https://raw.githubusercontent.com/ccAzy/vpnmax/main}"

# 全部模块（含 verify 子目录）；顺序即依赖顺序
VPNMAX_MODULES_ALL="common time hardening firewall singbox subscription argo warp optimize"
VPNMAX_MODULES_VERIFY="verify/time verify/tuic"
# vendor/ 里随部署落盘的冻结件（单文件模式下也能命中"vendor 优先、零上游"）
VPNMAX_VENDOR_FILES="sb.sh"

# lib 版本戳：**每次改动 lib/ 就把它改掉**。服务器靠它判断要不要重拉已缓存的模块——
# 旧逻辑只补缺失文件，缓存一旦落地就冻结，lib 的修复永远到不了线上（2026-09-23 连踩两次）。
# 联动门禁见 tools/check-lib-integrity.py R7b（格式 + BOOT 自哈希 + 双哈希一致性）。
VPNMAX_LIB_REV="2026-09-23.6"

# boot.sh 自哈希（归一化自哈希：把下一行的值置空后对本文件取 sha256）。
# **每次改动 lib/boot.sh 都必须重算本常量**，否则 R7b 门禁失败拒绝安装。
# 重算：sed 's/^BOOT_SHA256=".*"/BOOT_SHA256=""/' lib/boot.sh | sha256sum
BOOT_SHA256="b69303901c79b4032014c0a9493cd2d42487576be9f8dc92fcdf4debdc1c3b99"

# 远端源 allowlist（供应链 RCE 防线：VPNMAX_RAW 只能是自家源）。
# vpnmax_fetch / 各入口自举下载前必经 vpnmax_raw_allowed()，命中失败即 fail-closed 中止。
VPNMAX_RAW_ALLOW="raw.githubusercontent.com/ccAzy/vpnmax cdn.jsdelivr.net/gh/ccAzy/vpnmax"

# 打印可用的 lib 源目录（以 common.sh 为存在标志）
vpnmax_lib_src() {
    local d
    for d in "${VPNMAX_SCRIPT_DIR:-}/lib" "./lib" "$VPNMAX_LIB_HOME"; do
        [ -n "$d" ] && [ -r "$d/common.sh" ] && {
            printf '%s\n' "$d"
            return 0
        }
    done
    return 1
}

# VPNMAX_RAW 必须命中自家 allowlist，否则拒绝下载（防 VPNMAX_RAW=https://evil/ 投毒）。
# fail-closed：未知 host 直接返回 1，调用方必须中止，绝不带着可疑源继续跑。
vpnmax_raw_allowed() {
    local raw="${VPNMAX_RAW:-}" allow
    for allow in $VPNMAX_RAW_ALLOW; do
        # 前缀匹配：锁死 host + 仓库路径（如 evil 换自家 raw 下的别的仓库也过不去）
        case "$raw" in "https://$allow"*|"http://$allow"*) return 0 ;; esac
    done
    printf '[x] VPNMAX_RAW 源不在白名单（%s），拒绝下载\n' "${VPNMAX_RAW:-}" >&2
    return 1
}

# 校验一份 boot.sh 文本是否与 BOOT_SHA256 相符（归一化：值字段置空后取哈希）。
# 用法: vpnmax_verify_boot <文件>；入口自举下载后必调，失败即 fail-closed。
vpnmax_verify_boot() {
    local f="$1" got
    [ -s "$f" ] || return 1
    [ -n "${BOOT_SHA256:-}" ] || {
        printf '[x] BOOT_SHA256 为空（boot.sh 未重算自哈希），拒绝信任\n' >&2
        return 1
    }
    got=$(sed 's/^BOOT_SHA256=".*"/BOOT_SHA256=""/' "$f" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}' || true)
    if [ "$got" != "$BOOT_SHA256" ]; then
        printf '[x] boot.sh 自哈希校验失败（期望 %s 实得 %s），拒绝加载\n' "${BOOT_SHA256:0:12}" "${got:-空}" >&2
        return 1
    fi
    return 0
}

# 取一个远端文件；失败返回 1。超时刻意取小：这是首次运行的前置步骤，
# 一旦不可达宁可 5 秒内明确报错，也不要让用户对着空白终端等一分钟。
vpnmax_fetch() { # <远端相对路径> <落到本地路径> <max-time>
    local url="$VPNMAX_RAW/$1" out="$2" tmp
    vpnmax_raw_allowed || return 1
    tmp=$(mktemp "${out}.vpnmax.XXXXXX" 2>/dev/null) || return 1
    if curl -fsSL --connect-timeout 5 --max-time "${3:-30}" "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$out" && return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# 自举：把 lib/（与 vendor/）落到 $VPNMAX_LIB_HOME（幂等；任一文件失败即整体失败，不留半套）
vpnmax_bootstrap() {
    local m v total=0 i=0
    for m in $VPNMAX_MODULES_ALL $VPNMAX_MODULES_VERIFY $VPNMAX_VENDOR_FILES; do
        case "$m" in sb.sh) [ -s "$VPNMAX_LIB_HOME/vendor/$m" ] || total=$((total + 1)) ;; esac
    done
    for m in $VPNMAX_MODULES_ALL $VPNMAX_MODULES_VERIFY; do
        [ -s "$VPNMAX_LIB_HOME/$m.sh" ] || total=$((total + 1))
    done
    printf '[*] 首次运行：正在取回 lib/ 与 vendor/（共 %d 个文件）...
' "$total" >&2
    mkdir -p "$VPNMAX_LIB_HOME/verify" "$VPNMAX_LIB_HOME/vendor" 2>/dev/null || return 1
    for m in $VPNMAX_MODULES_ALL $VPNMAX_MODULES_VERIFY; do
        [ -s "$VPNMAX_LIB_HOME/$m.sh" ] && continue
        i=$((i + 1))
        printf '    [%d/%d] lib/%s.sh
' "$i" "$total" "$m" >&2
        vpnmax_fetch "lib/$m.sh" "$VPNMAX_LIB_HOME/$m.sh" 30 || {
            printf '[x] 取回 lib/%s.sh 失败（网络不可达）
' "$m" >&2
            return 1
        }
    done
    for v in $VPNMAX_VENDOR_FILES; do
        [ -s "$VPNMAX_LIB_HOME/vendor/$v" ] && continue
        i=$((i + 1))
        printf '    [%d/%d] vendor/%s
' "$i" "$total" "$v" >&2
        vpnmax_fetch "vendor/$v" "$VPNMAX_LIB_HOME/vendor/$v" 120 || {
            printf '[x] 取回 vendor/%s 失败（网络不可达）
' "$v" >&2
            return 1
        }
    done
    printf '    [%d/%d] 已就绪
' "$total" "$total" >&2
    printf '%s\n' "${VPNMAX_LIB_REV:-}" >"$VPNMAX_LIB_HOME/.lib-rev" 2>/dev/null || true
    return 0
}

# 版本戳不一致 → 丢弃缓存的 lib/vendor 并整体重拉。
# 只在用缓存（$VPNMAX_LIB_HOME）时才有意义；仓库模式（有本地 lib/）由 vpnmax_load 跳过。
# --force 语义：强制重跑全流程时同样丢弃缓存重拉，保证 --force 真覆盖（2026-09-23 事故复盘）。
vpnmax_refresh_if_stale() {
    local rev_file="$VPNMAX_LIB_HOME/.lib-rev" m v
    [ -n "${VPNMAX_LIB_REV:-}" ] || return 0
    if [ "${FORCE:-false}" != "true" ] && [ -s "$rev_file" ] && [ "$(cat "$rev_file" 2>/dev/null || true)" = "$VPNMAX_LIB_REV" ]; then
        return 0
    fi
    printf '[*] lib 版本变化（%s → %s）：重新取回 lib/ 与 vendor/\n' \
        "$(cat "$rev_file" 2>/dev/null || echo 无)" "$VPNMAX_LIB_REV" >&2
    for m in $VPNMAX_MODULES_ALL $VPNMAX_MODULES_VERIFY; do rm -f "$VPNMAX_LIB_HOME/$m.sh" 2>/dev/null || true; done
    for v in $VPNMAX_VENDOR_FILES; do rm -f "$VPNMAX_LIB_HOME/vendor/$v" 2>/dev/null || true; done
    vpnmax_bootstrap || return 1
    return 0
}

# 加载模块；失败返回 1（调用方必须 fail-loud 退出，绝不带着缺函数的脚本继续跑）
vpnmax_load() {
    local want="${1:-$VPNMAX_MODULES_ALL}" src m f
    # 仓库模式（有本地 lib/common.sh）直接用，不碰缓存也不校验版本戳
    if [ ! -r "${VPNMAX_SCRIPT_DIR:-}/lib/common.sh" ] && [ ! -r "./lib/common.sh" ]; then
        vpnmax_refresh_if_stale || return 1
    fi
    if ! src="$(vpnmax_lib_src)"; then
        vpnmax_bootstrap || return 1
        src="$VPNMAX_LIB_HOME"
    fi
    for m in $want; do
        # shellcheck disable=SC1090
        . "$src/$m.sh" || return 1
    done
    # 冒烟：核心函数必须已定义，否则早失败好过在执行到一半时 command not found
    for f in info ok warn fail run run_ok manifest; do
        declare -F "$f" >/dev/null 2>&1 || return 1
    done
    return 0
}
