#!/usr/bin/env python3
"""check-fallback-sync.py — 防止 lib/ 与顶层脚本的内联兜底再次漂移。

问题背景
--------
顶层脚本（deploy_optimize / deploy_singbox / verify / bootstrap / cleanup）同时支持两种跑法：

  · 仓库模式：`source lib/*.sh`，用模块化实现
  · 单文件模式（`curl ... | bash`）：没有 lib/，用脚本里的 `if ! declare -F f; then f() {...}; fi` 兜底

于是同一个函数有两份实现。**两份不一致时，同一台机器换个装法行为就不同**，而且完全静默。
2026-09-12 实测：8 个函数的兜底块与 lib 已经漂移（lib 是较新的那份，含 G3/G7 等修复），
其中 `clean_stale_acvpn_sysctl` 的旧版绕过了 `run` 包装 → 单文件模式下 `--dry-run` 会真的删文件。

本脚本做的事
------------
只比较"同名函数的第一处定义"：
  · 顶层脚本里找 NAME 的**第一处**定义（对带兜底的函数，那就是兜底块）
  · lib/ 里找 NAME 的定义
  · 归一化（去空行/行首尾空白）后比对摘要

这样不需要解析 guard 边界，也不依赖 if/fi 计数，因此对 heredoc 不敏感——
这是它比"按块解析"更可靠的原因（后者会被 heredoc 里的内容带偏）。

用法
----
  python3 tools/check-fallback-sync.py            # 报告
  python3 tools/check-fallback-sync.py --check    # 门禁：不一致则退出 1（CI 用）

注意
----
只报"不一致"为错误；"顶层没有该函数"只作提示（可能是刻意的"有则调用"，
例如 `if declare -F migrate_legacy_units; then ... fi`），需人工判断。
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TOP_FILES = ["deploy_optimize.sh", "deploy_singbox.sh", "verify.sh",
             "bootstrap.sh", "cleanup.sh"]

FUNC_HEAD = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\(\)\s*(.*)$")


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").split("\n")


def normalize(body: str) -> str:
    """去空行、去行首行尾空白——只比语义，忽略缩进/排版。"""
    return "\n".join(line.strip() for line in body.split("\n") if line.strip())


def digest(body: str) -> str:
    return hashlib.sha256(normalize(body).encode()).hexdigest()[:12]


def first_definitions(lines: list[str]) -> dict[str, str]:
    """{函数名: 第一处定义的正文}。

    花括号配对定界；整行注释不参与计数（避免注释里的括号带偏）。
    """
    out: dict[str, str] = {}
    i, n = 0, len(lines)
    while i < n:
        m = FUNC_HEAD.match(lines[i])
        if not m:
            i += 1
            continue
        name, rest = m.group(1), re.sub(r"#.*$", "", m.group(2)).strip()
        if rest == "":
            if i + 1 < n and lines[i + 1].strip() == "{":
                open_at = i + 1
            else:
                i += 1
                continue
        elif rest.startswith("{"):
            if rest.endswith("}"):
                out.setdefault(name, lines[i])
                i += 1
                continue
            open_at = i
        else:
            i += 1
            continue

        depth, j = 0, open_at
        while j < n:
            code = "" if lines[j].lstrip().startswith("#") else lines[j]
            depth += code.count("{") - code.count("}")
            if j > open_at and depth <= 0:
                break
            if j == open_at and depth <= 0:
                break
            j += 1
        out.setdefault(name, "\n".join(lines[i:j + 1]))
        i = j + 1
    return out


def collect_lib() -> dict[str, tuple[str, str]]:
    libdir = ROOT / "lib"
    out: dict[str, tuple[str, str]] = {}
    for path in sorted(libdir.glob("*.sh")) + sorted((libdir / "verify").glob("*.sh")):
        for name, body in first_definitions(read_lines(path)).items():
            out.setdefault(name, (str(path.relative_to(ROOT)), body))
    return out


def main() -> int:
    check = "--check" in sys.argv
    lib = collect_lib()
    drift, missing = [], []

    for top in TOP_FILES:
        path = ROOT / top
        if not path.exists():
            continue
        topdefs = first_definitions(read_lines(path))
        for name, (libfile, libbody) in sorted(lib.items()):
            if name not in topdefs:
                missing.append((top, name, libfile))
            elif digest(topdefs[name]) != digest(libbody):
                drift.append((top, name, libfile))

    print(f"lib/ 定义 {len(lib)} 个函数；顶层脚本中有同名定义但实现不同的：{len({n for _, n, _ in drift})} 个（去重）\n")

    if drift:
        print("❌ 同一函数在顶层脚本与 lib/ 中实现不同（两份实现已分叉）：")
        for top, name, libfile in sorted(set(drift)):
            print(f"   {top:<22} {name:<30} 应等于 {libfile}")
        print("\n   修法：以 lib/ 为准，把顶层脚本里该函数替换为 lib/ 的实现；")
        print("   若差异是刻意的（如 run 的错误处理语义），需先把 lib/ 改成正确的那份，再对齐。")
    else:
        print("✅ 所有内联兜底与 lib/ 一致")

    if missing:
        uniq = {n for _, n, _ in missing}
        print(f"\n✅ 顶层脚本里没有同名定义的 lib 函数（多为刻意的『有则调用』，需人工确认）共 {len(uniq)} 个：")
        for name in sorted(uniq):
            print(f"   {name}")

    if check and drift:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
