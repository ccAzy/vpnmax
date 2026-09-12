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

# 取一个远端文件；失败返回 1。超时刻意取小：这是首次运行的前置步骤，
# 一旦不可达宁可 5 秒内明确报错，也不要让用户对着空白终端等一分钟。
vpnmax_fetch() { # <远端相对路径> <落到本地路径> <max-time>
    local url="$VPNMAX_RAW/$1" out="$2" tmp
    tmp="$out.$$"
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
    return 0
}

# 加载模块；失败返回 1（调用方必须 fail-loud 退出，绝不带着缺函数的脚本继续跑）
vpnmax_load() {
    local want="${1:-$VPNMAX_MODULES_ALL}" src m f
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
