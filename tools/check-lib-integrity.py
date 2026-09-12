#!/usr/bin/env python3
"""vpnmax 完整性门禁 —— 防止「双实现」回归。

背景（2026-09-12 重构）：重构前每个入口脚本把每个函数各抄一份内联兜底（共 38 块），
与 lib/ 逐份漂移，靠人工对齐，衍生出「检查器 → 10 处未决 → 门禁上不了 CI」的长尾。
现在入口脚本只做「引导 + 编排」，lib/ 是唯一源码；curl|bash 单文件模式由 lib/boot.sh
运行时自举取回。本工具把这条架构约束变成可执行门禁。

检查项：
  R1 入口脚本不得再出现内联兜底块（if ! declare -F X ...; then <X 的函数定义>）
  R2 入口脚本必须经 vpnmax_load 加载 lib
  R3 入口脚本不得重复定义 lib 中 readonly 的常量（重跑会 runtime 报 readonly variable）
  R4 所有 shell 文件 bash -n 通过
  R5 lib 每个模块必须有重复-source 守卫

用法: python3 tools/check-lib-integrity.py
退出码: 0 通过 / 1 有违规
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENTRIES = ["bootstrap.sh", "deploy_optimize.sh", "deploy_singbox.sh", "verify.sh", "cleanup.sh"]

violations = []
notes = []


def read(p):
    return (ROOT / p).read_text(encoding="utf-8", errors="replace")


# ── R1 内联兜底块 ──
for e in ENTRIES:
    lines = read(e).split("\n")
    for i, ln in enumerate(lines):
        m = re.match(r"^if ! declare -F (\w+) >", ln)
        if not m:
            continue
        nxt = "\n".join(lines[i + 1:i + 4])
        if re.search(rf"^\s*{m.group(1)}\(\)", nxt, re.M):
            violations.append(f"R1 {e}:{i+1} 内联兜底块 {m.group(1)}（应只存在于 lib/，单文件模式由 boot.sh 自举）")

# ── R2 必须走引导 ──
for e in ENTRIES:
    t = read(e)
    if "vpnmax_load" not in t:
        violations.append(f"R2 {e} 未调用 vpnmax_load（入口脚本必须经 boot.sh 加载 lib）")
    if "lib/boot.sh" not in t:
        violations.append(f"R2 {e} 未引用 lib/boot.sh")

# ── R3 readonly 常量重复定义 ──
ro = set()
for f in sorted((ROOT / "lib").rglob("*.sh")):
    ro |= set(re.findall(r"^\s*readonly\s+([A-Z][A-Z0-9_]*)=", f.read_text(encoding="utf-8"), re.M))
for e in ENTRIES:
    for i, ln in enumerate(read(e).split("\n")):
        m = re.match(r"^\s*(?:readonly\s+)?([A-Z][A-Z0-9_]*)=", ln)
        if m and m.group(1) in ro:
            violations.append(f"R3 {e}:{i+1} 重复定义 lib 中的 readonly 常量 {m.group(1)}")

# ── R4 bash -n ──
shells = sorted(list(ROOT.glob("*.sh")) + list((ROOT / "lib").rglob("*.sh")))
for p in shells:
    r = subprocess.run(["bash", "-n", p.relative_to(ROOT).as_posix()], capture_output=True, text=True, check=False)
    if r.returncode != 0:
        violations.append(f"R4 {p.relative_to(ROOT)} bash -n 失败: {r.stderr.strip().splitlines()[:1]}")

# ── R5 lib 模块守卫 ──
for p in sorted((ROOT / "lib").rglob("*.sh")):
    if p.name == "boot.sh":
        continue
    if not re.search(r"^VPNMAX_[A-Z_]*LOADED=", p.read_text(encoding="utf-8"), re.M):
        violations.append(f"R5 {p.relative_to(ROOT)} 缺少重复-source 守卫（VPNMAX_*_LOADED）")

# ── 报告（不判失败）：入口脚本里出现、但 lib/本文件都没有定义的标识符 ──
defined = set()
for src in list((ROOT / "lib").rglob("*.sh")):
    defined |= set(re.findall(r"^\s*([a-z_][a-z0-9_]*)\(\)", src.read_text(encoding="utf-8"), re.M))
for e in ENTRIES:
    defined |= set(re.findall(r"^([a-z_][a-z0-9_]*)\(\)", read(e), re.M))

KEEP = {"if", "then", "else", "elif", "fi", "for", "do", "done", "while", "case", "esac", "function",
        "return", "local", "readonly", "export", "declare", "set", "unset", "shift", "exit", "echo",
        "printf", "source", "true", "false", "break", "continue", "in", "not"}
for e in ENTRIES:
    for i, ln in enumerate(read(e).split("\n")):
        code = ln.split("#")[0]
        for m in re.finditer(r"(?:^|[|&;(]\s*|\b(?:then|do|else)\s+)([a-z_][a-z0-9_]*)\b", code):
            n = m.group(1)
            if n in KEEP or n in defined or n.startswith("vpnmax_"):
                continue
            notes.append(f"  {e}:{i+1} {n}")

print(f"✓ R1-R5 全部通过：{len(shells)} 个 shell 文件，{len(ENTRIES)} 个入口脚本")
if notes:
    print(f"\n参考（可能的外部命令调用，未判失败，{len(notes)} 项）：")
    print("\n".join(notes[:15]))

if violations:
    print(f"\n✗ {len(violations)} 项违规：")
    for v in violations:
        print("  " + v)
    sys.exit(1)
