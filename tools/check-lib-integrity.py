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
  R6 头部注释区不得夹带未注释行（漏写 # 会把用法文本当命令执行）
  R7 版本/哈希联动（2026-09-23 更新链断点复盘）：
      R7a 改 vendor/sb.sh 必重算 deploy_singbox.sh 双哈希
             （SB_SHA256=原版，SB_ARGO_PATCHED_SHA256=http2→auto 补丁版）
      R7b VPNMAX_LIB_REV 格式门（改 lib/ 必 bump）+ BOOT_SHA256 非空且等于
             归一化自哈希（sed 值置空后 sha256；改 boot.sh 必重算）

用法: python3 tools/check-lib-integrity.py
退出码: 0 通过 / 1 有违规
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENTRIES = [
    "bootstrap.sh",
    "deploy_optimize.sh",
    "deploy_singbox.sh",
    "verify.sh",
    "cleanup.sh",
]

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
        nxt = "\n".join(lines[i + 1 : i + 4])
        if re.search(rf"^\s*{m.group(1)}\(\)", nxt, re.M):
            violations.append(
                f"R1 {e}:{i + 1} 内联兜底块 {m.group(1)}（应只存在于 lib/，单文件模式由 boot.sh 自举）"
            )

# ── R2 必须走引导 ──
for e in ENTRIES:
    t = read(e)
    if "vpnmax_load" not in t:
        violations.append(
            f"R2 {e} 未调用 vpnmax_load（入口脚本必须经 boot.sh 加载 lib）"
        )
    if "lib/boot.sh" not in t:
        violations.append(f"R2 {e} 未引用 lib/boot.sh")

# ── R3 readonly 常量重复定义 ──
ro = set()
for f in sorted((ROOT / "lib").rglob("*.sh")):
    ro |= set(
        re.findall(
            r"^\s*readonly\s+([A-Z][A-Z0-9_]*)=", f.read_text(encoding="utf-8", errors="replace"), re.M
        )
    )
for e in ENTRIES:
    for i, ln in enumerate(read(e).split("\n")):
        m = re.match(r"^\s*(?:readonly\s+)?([A-Z][A-Z0-9_]*)=", ln)
        if m and m.group(1) in ro:
            violations.append(
                f"R3 {e}:{i + 1} 重复定义 lib 中的 readonly 常量 {m.group(1)}"
            )

# ── R4 bash -n ──
shells = sorted(list(ROOT.glob("*.sh")) + list((ROOT / "lib").rglob("*.sh")))
for p in shells:
    r = subprocess.run(
        ["bash", "-n", p.relative_to(ROOT).as_posix()],
        capture_output=True,
        text=True,
        errors="replace",
        check=False,
    )
    if r.returncode != 0:
        violations.append(
            f"R4 {p.relative_to(ROOT)} bash -n 失败: {r.stderr.strip().splitlines()[:1]}"
        )

# ── R5 lib 模块守卫 ──
for p in sorted((ROOT / "lib").rglob("*.sh")):
    if p.name == "boot.sh":
        continue
    if not re.search(r"^VPNMAX_[A-Z_]*LOADED=", p.read_text(encoding="utf-8", errors="replace"), re.M):
        violations.append(
            f"R5 {p.relative_to(ROOT)} 缺少重复-source 守卫（VPNMAX_*_LOADED）"
        )

# ── R6 头部注释区不得夹带未注释行 ──
# 背景（2026-09-23 线上事故）：bootstrap.sh / deploy_optimize.sh 的头部用法注释块里
# 「  bash bootstrap.sh [选项]」三行漏写 `#`，bash -n 与 shellcheck 都不报错（语法完全合法），
# 但运行时会被当真命令执行：先报 `bash: bootstrap.sh: No such file or directory`，
# 再因第二行 `bash <(curl .../bootstrap.sh)` 递归自举 → 无限循环刷屏。
# 规则：从第 2 行起，遇到第一个「明确的语句行」之前，非空行必须都是注释。
STMT = re.compile(
    r"^\s*(?:"
    r"set\s|set$|\.\s|source\s|umask\b|export\s|declare\s|readonly\s|local\s|trap\s|"
    r"[A-Za-z_][A-Za-z0-9_]*=|"
    r"\[\[?\s|\(|"
    r"if\s|for\s|while\s|until\s|case\s|function\s|"
    r"[a-z_][a-z0-9_]*\s*\(\)"
    r")"
)
for p in shells:
    rel = p.relative_to(ROOT)
    for i, ln in enumerate(read(rel).split("\n")[1:60], start=2):
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        if STMT.match(ln):
            break
        violations.append(
            f"R6 {rel}:{i} 头部注释区出现未注释行（会被当作命令执行，补 `# `）: {ln.strip()[:70]}"
        )

# ── R7 版本/哈希联动门禁 ──
# 背景（2026-09-23 连踩两次）：vendor 更新但 SB_SHA256 未重算 → 安装校验失败；
# lib 修复但 VPNMAX_LIB_REV 未 bump → 服务器缓存冻结、修复永远到不了线上。
import hashlib

# R7a：双哈希一致性
_sb = ROOT / "vendor" / "sb.sh"
_deploy = read("deploy_singbox.sh")
if _sb.is_file():
    raw = _sb.read_bytes()
    m = re.search(r'^SB_SHA256="([0-9a-f]{64})"', _deploy, re.M)
    if not m:
        violations.append("R7a deploy_singbox.sh 缺少 SB_SHA256 常量")
    elif m.group(1) != hashlib.sha256(raw).hexdigest():
        violations.append(
            "R7a SB_SHA256 与 vendor/sb.sh 实哈希不一致（改 vendor 必重算双哈希）"
        )
    m2 = re.search(r'^SB_ARGO_PATCHED_SHA256="([0-9a-f]{64})"', _deploy, re.M)
    patched = _sb.read_text(encoding="utf-8", errors="replace").replace(
        "--protocol http2", "--protocol auto"
    )
    if not m2:
        violations.append("R7a deploy_singbox.sh 缺少 SB_ARGO_PATCHED_SHA256 常量")
    elif m2.group(1) != hashlib.sha256(patched.encode("utf-8")).hexdigest():
        violations.append(
            "R7a SB_ARGO_PATCHED_SHA256 与补丁版实哈希不一致（改 vendor 必重算双哈希）"
        )
else:
    violations.append("R7a vendor/sb.sh 缺失，无法校验双哈希")

# R7b：REV 格式 + BOOT 自哈希
_boot = read("lib/boot.sh")
mb = re.search(r'^VPNMAX_LIB_REV="([^"]+)"', _boot, re.M)
if not mb or not re.fullmatch(r"20\d{2}-\d{2}-\d{2}\.\d+", mb.group(1)):
    violations.append(
        f"R7b VPNMAX_LIB_REV 格式非法（{mb.group(1) if mb else '缺失'}；改 lib/ 必 bump 为 YYYY-MM-DD.N）"
    )
mh = re.search(r'^BOOT_SHA256="([^"]*)"', _boot, re.M)
if not mh or not mh.group(1):
    violations.append("R7b BOOT_SHA256 为空（改 boot.sh 必重算自哈希，见 lib/boot.sh 注释）")
else:
    normalized = re.sub(
        r'^BOOT_SHA256=".*"', 'BOOT_SHA256=""', _boot, count=1, flags=re.M
    )
    if hashlib.sha256(normalized.encode("utf-8")).hexdigest() != mh.group(1):
        violations.append("R7b BOOT_SHA256 与归一化自哈希不一致（改 boot.sh 必重算）")

# ── 报告（不判失败）：入口脚本里出现、但 lib/本文件都没有定义的标识符 ──
defined = set()
for src in list((ROOT / "lib").rglob("*.sh")):
    defined |= set(
        re.findall(r"^\s*([a-z_][a-z0-9_]*)\(\)", src.read_text(encoding="utf-8", errors="replace"), re.M)
    )
for e in ENTRIES:
    defined |= set(re.findall(r"^([a-z_][a-z0-9_]*)\(\)", read(e), re.M))

KEEP = {
    "if",
    "then",
    "else",
    "elif",
    "fi",
    "for",
    "do",
    "done",
    "while",
    "case",
    "esac",
    "function",
    "return",
    "local",
    "readonly",
    "export",
    "declare",
    "set",
    "unset",
    "shift",
    "exit",
    "echo",
    "printf",
    "source",
    "true",
    "false",
    "break",
    "continue",
    "in",
    "not",
}
for e in ENTRIES:
    for i, ln in enumerate(read(e).split("\n")):
        code = ln.split("#")[0]
        for m in re.finditer(
            r"(?:^|[|&;(]\s*|\b(?:then|do|else)\s+)([a-z_][a-z0-9_]*)\b", code
        ):
            n = m.group(1)
            if n in KEEP or n in defined or n.startswith("vpnmax_"):
                continue
            notes.append(f"  {e}:{i + 1} {n}")

print(f"[OK] R1-R7 全部通过：{len(shells)} 个 shell 文件，{len(ENTRIES)} 个入口脚本")
if notes:
    print(f"\n参考（可能的外部命令调用，未判失败，{len(notes)} 项）：")
    print("\n".join(notes[:15]))

if violations:
    print(f"\n[X] {len(violations)} 项违规：")
    for v in violations:
        print("  " + v)
    sys.exit(1)
