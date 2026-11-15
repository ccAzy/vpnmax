# Changelog

## 2026-09-23 — P0 修复：订阅全空（`sed 's://.*::g'` 会砍掉含 `//` 的 JSON 值）

**真机虚拟机实测发现**：`sb.json` 完全正常，但 `clmi.yaml` 的 `port:`/`uuid:` 全空、
`jhsub.txt` 的链接是 `vless://@1.2.3.4:?` —— 订阅能打开，导入客户端却连不上。
而部署脚本打印"全部部署完成"，没有任何报错。

### 根因（实测定位到具体字节）

上游 `sb.sh` 有 **94 处**这样的管道：

```bash
uuid=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '...')
```

那个 sed 看起来像"去掉 `://` 后面的东西"，但因为分隔符用了 `:`，实际语义是
**`s` + 分隔符`:` + 模式`//.*` + 分隔符`:` + 空替换 + `g`** —— 即
**「从 `//` 删到行尾」**。

平时 sb.json 里没有 `//`，这行什么也不做，所以一直没暴露。
但 WARP 的 `private_key` 是 base64，**随机出现 `//` 的概率约 1%**：

```json
"private_key": "mBqPJvenCnL4/lPGyAPLQY4wg1qUjNmiyo//fRcu218=",
```

被砍成 `"private_key": "mBqPJvenCnL4/lPGyAPLQY4wg1qUjNmiyo` → JSON 断裂 →
`jq` 报 `Invalid string: control characters` → 所有取值为空 →
订阅生成出来全是空的。**整条链路静默失败。**

### 修复

`vendor/sb.sh` 94 处 `sed 's://.*::g' <file> | jq` → `cat <file> | jq`。
语义等价（原本就是"把文件喂给 jq"），但不再破坏内容。

配套：`SB_SHA256` / `SB_ARGO_PATCHED_SHA256` 重算，`VPNMAX_LIB_REV` → `2026-09-23.10`，
`BOOT_SHA256` 重算（改 vendor 必须 bump，否则服务器缓存的旧 vendor 会让哈希校验失败）。

### 实测验证（VirtualBox + Debian 12.15）

| 项 | 修复前 | 修复后 |
| --- | --- | --- |
| `clmi.yaml` 的 port/uuid | 空（8 处） | `port: 48698` / `uuid: aa1e3633-...` |
| `jhsub.txt` 链接 | `vless://@85.121.51.211:?` | `vless://aa1e3633-...@85.121.51.211:48698?...` |
| `verify.sh` | 通过 29 / 失败 2 | **通过 33 / 失败 1**（仅 Argo，环境无 cloudflared） |

### 顺带修掉 verify.sh 三处自身缺陷

1. **假红灯**：订阅服务返回 200 却报「未响应（HTTP `502000`）」——token 为空时 URL 拼成
   `//clmi.yaml`；且 `curl ... || echo "000"` 会把 502 和 000 粘成 `502000`。
2. **假绿灯**：只查"能不能打开"，不查"内容对不对"——上面那个 P0 完全发现不了。
   新增内容完整性检查（clmi 空 port/uuid、jhsub 残缺链接数）。
3. **整数比较报错**：`grep -c ... || echo 0` 在无匹配时会输出两行 `0`（grep 自己已经打印了 0），
   导致 `[: 0
0: integer expression expected`。改为 `|| true` 再补默认值。

## 2026-09-23 — 继续收口上游风险：补丁覆盖前置检查 + 拒绝「回退 latest」

接上一轮巡检的三条建议，把「能拦住复发」的部分补上。

### ① CI：缺内核补丁时 30 秒内失败，而不是 1.5 小时后

`preflight` 原本没有 checkout，看不到 `patches/`。现在加了 `actions/checkout` +
「检查 BBRv3 补丁是否覆盖目标内核系列」一步：

```
kernel.org 最新稳定版 = 7.3.4  →  series = 7.3
patches/bbrv3-linux-7.3.patch 不存在 → ::error 并 exit 1
```

**为什么必须前置失败**：`apply-bbrv3-port.sh` 在没有对应补丁时会「取最新可用的旧补丁 +
`patch --fuzz=3`」。旧补丁往新内核上打，可能偏移应用、可能失败、也可能打偏了却编译通过 ——
那是运气不是正确性。在这里失败，比构建一小时后才炸好得多。

### ② `vendor/sb.sh`：删除「pin 拉取失败 → 回退 latest」

上一轮只在部署侧加了 `assert_singbox_core_compat` 守卫（装完再查）。但更好的位置是**根本别装**：

```diff
- red "pin 版拉取失败，回退上游 latest"
- sbcore=$(curl ... releases/latest ...)      # 会装出 1.14 内核 + 1.13 配置
+ red "已拒绝自动回退 latest：1.14+ 内核不接受本脚本生成的 DNS 配置格式"
+ exit 1
```

`cloudflared` / `cfst` 的「pin 失败回退 latest」**保留**——它们是活水二进制，命令行为向后兼容、
也不生成配置，回退的代价远小于装不上。差别来自「失效的代价是否对称」，已写进 `vendor/README.md`。

### ③ `verify.sh`：手动升级内核的机器也能被查出来

`assert_singbox_core_compat` 只在部署流程里跑。如果有人用 `sb` 菜单（`1`）单独升级了内核，
部署侧看不到。现在 `verify.sh` 在确定 `SB_BIN` 之后也做一次配对校验，> 1.13 直接判失败。

### ④ 连带修正：改 `vendor/` 必须 bump `VPNMAX_LIB_REV`

`vpnmax_refresh_if_stale` 的版本戳本来**同时覆盖 lib 与 vendor 缓存**，但文档只写了「改 lib 必 bump」。
如果只改 `SB_SHA256` 而不 bump rev，服务器上缓存的旧 `vendor/sb.sh` 不会被刷新，
结果是「哈希校验失败 → 拒绝安装」的死循环。已在 `lib/boot.sh` 注释与 `vendor/README.md` 写明。

**本轮版本联动**：`VPNMAX_LIB_REV` → `2026-09-23.9`；`BOOT_SHA256` 重算；
`SB_SHA256` / `SB_ARGO_PATCHED_SHA256` 按新 `vendor/sb.sh` 重算并复核一致。

**验证**

| 项 | 结果 |
| --- | --- |
| `bash -n`（含 vendor/sb.sh） | 全通过 |
| shellcheck（CI 同款） | clean |
| R1–R7 门禁 | 全绿 |
| vendor/sb.sh 改动前后 shellcheck 数量 | 32 → 32（未引入新问题） |
| workflow YAML | 可解析；preflight 3 步 |
| verify.sh 实跑（WSL） | 走完 51 行并给出汇总；新段落无 sing-box 时优雅跳过 |
| 双哈希复核 | `SB_SHA256` / `SB_ARGO_PATCHED_SHA256` 与现文件一致 |

## 2026-09-23 — 上游巡检：补 7.3 内核补丁 + 修「内核/配置错配」隐患

对全部上游做了一次巡检（`git ls-remote` + GitHub API + 逐条 URL 可达性），结论如下。

### 巡检结果总览

| 上游 | 我们的 pin | 上游当前 | 影响 |
| --- | --- | --- | --- |
| `yonggekkk/sing-box-yg`（sb.sh） | `5001e76` | `b13f943` | **菜单结构未变**（81 个输入提示序列逐条比对完全一致），改动集中在配置模板 |
| `yonggekkk/acme-yg` | `e3299a70` | 同 | 无变化 |
| `yonggekkk/warp-yg` | `f2f634ba` | 同 | 无变化 |
| `sbwpph_amd64/arm64` | `9e8b710c` | — | 仍可达（200） |
| `SagerNet/sing-box` | `1.13.19` | `1.14.4` | **有破坏性变更**，见下 |
| `cloudflare/cloudflared` | `2026.8.3` | `2026.11.0` | 未发现我们依赖的 flag 变更；老资产仍可下载（302） |
| `byJoey/Actions-bbr-v3` | — | 新增 `bbrv3-linux-7.3.patch` | **我们缺这份补丁**，见下 |

全部 pin 的 URL 实测仍可达（acme/CFwarp/sbwpph 200，sing-box 1.13.19 / cloudflared 2026.8.3 均 302），
**冻结层没有腐烂**。

### ① P0：sing-box 1.14 删除了旧 DNS server 格式 → 我们的「pin 回退 latest」是个雷

查 sing-box 官方 deprecated 列表：

> **Legacy DNS server formats** — *Old formats were removed in sing-box 1.14.0.*

而我们 pin 的 `sb.sh@5001e76` 生成的正是旧格式（`"type":"https"` + `server` + `path`）。
当前配对是正确的：**旧格式配置 + 1.13.19 内核**。

问题在于 `vendor/sb.sh` 里有一条「pin 拉取失败（含 404）→ 回退上游 latest」的路径。
一旦 1.13.19 的发布资产失效，就会装出 **1.14.4 内核 + 1.13 格式配置** 的组合 ——
配置解析失败、sing-box 起不来，而脚本只会打印一句「回退上游 latest」就继续往下走。

**修法**：新增 `lib/singbox.sh: assert_singbox_core_compat`，安装后读回内核版本，
> 1.13 时明确失败并给出二选一（调回 pin / 两者同批升级），且**不写部署成功标记**——
避免「装完了但其实起不来」。

同时在 `vendor/README.md` 新增「sb.sh 与内核版本是成对的」章节，把这条耦合写死进文档。

### ② P1：内核补丁缺 7.3，CI 会拿 7.2 的补丁去打 7.3 的树

- kernel.org 最新稳定版已是 **7.3.4**
- 我们 `patches/` 只有 7.0 / 7.1 / 7.2
- CI 会按 `KERNEL_VERSION` 推导 `patches/bbrv3-linux-7.3.patch` → 不存在
- `apply-bbrv3-port.sh` 的兜底是「取最新可用的补丁 + `patch --fuzz=3`」

实测 7.2 与 7.3 补丁的代码改动**完全一致**，只是 hunk 行号差 1 行 —— 所以 fuzz 大概率能应用，
但那是「能过就过了」的运气，不是正确性。

**修法**：从上游取 `bbrv3-linux-7.3.patch` 入仓（确认是 LF 进索引：`i/lf`）。

### ③ 结论：菜单投喂没受影响

上游 sb.sh 虽然改了很多，但 **81 个 `readp` 输入提示序列与我们 pin 版逐条一致**，
说明 `sb_feed` 依赖的菜单序号（`3-3-1-1` / `3-8-1` / `14-1` / `5-3-1` / `15-1` / `9-1`）仍然有效。
上游本轮改的是**配置模板**（向 1.14 迁移），不是菜单。

### 验证

| 项 | 结果 |
| --- | --- |
| `bash -n` | 全通过 |
| shellcheck（CI 同款） | clean |
| R1–R7 门禁 | 全绿 |
| 自哈希复核 | 一致（`VPNMAX_LIB_REV` → `2026-09-23.8`） |
| 版本配对逻辑单测 | 6/6（1.13.19/1.13.0/1.12.9 通过；1.14.0/1.14.4/2.0.0 拦截） |
| 7.3 补丁索引行尾 | `i/lf` |
| 全部 pin URL 可达性 | 7/7 可达 |

## 2026-09-23 — 内核调优收口：关掉忙轮询、补 MTU 探测、参数落地可验证

来源：对比 `a6216abcd/newsuoha.sh` 的调优段后反查本项目，发现三类问题（其中一类是自家的真缺陷）。

**① 忙轮询是个反优化（P1，自家缺陷）**

`net.core.busy_read = 50` / `busy_poll = 50` 来自早期抄来的调优模板。查内核语义：
`busy_read` 是 **SO_BUSY_POLL 的系统级默认值**，内核在 `sock_init_data()` 里直接赋给每个新 socket
（`sk->sk_ll_usec = sysctl_net_busy_read`）。写成 50 意味着**所有 socket** 在数据未就绪时
都会空转 50µs 再睡。代理场景的瓶颈是广域网 RTT（几十毫秒），这 50µs 换不到可感知收益，
却会在 1~2 vCPU 的小机器上白烧 CPU（按 CPU 积分计费的云厂商尤其明显）。
→ 改为 `0`（关闭），并在配置里写明理由。

**② 缺 `tcp_mtu_probing`（P2）**

路径 MTU 黑洞是「能连上、传小包正常、传大包就卡」的经典成因。Reality/AnyTLS 走 TCP、
Hy2/TUIC 走 QUIC，两者都会受影响。→ 补 `net.ipv4.tcp_mtu_probing = 1`。
顺带补 `net.ipv4.tcp_tw_reuse = 1`（代理服务器大量出站短连接，安全且有用）。

**③ 参数「写了不等于生效」，但没有统一校验（P1）**

原来只回读校验了 `nf_conntrack_max` 一个键。`sysctl --system` 对「键不存在 / 模块未加载 /
被后序文件覆盖」都是静默跳过 —— 打完一堆参数、实际只有一半生效，是这个层面最常见的坑。

- 新增 `lib/common.sh: sysctl_expect`（读回 + 空白归一化比较，区分「不一致」与「读不到」）
- `apply_sysctl` 末尾扩到 **10 个关键键**逐项回读，失败时列出「配置=… 实际=…」
- `verify.sh` 新增「调优落地」段：**遍历整个 `99-vpnmax-brutal.conf`**，逐行与内核实际比对，
  不通过就点名到具体键（比手挑几个键更彻底：配置里以后加了新键也自动被覆盖）

**④ 顺带修掉两处 verify.sh 自身缺陷（P0，验证工具跑不完）**

- `check()` 在失败时 `return 1`，而脚本是 `set -e` → **verify 在第一个失败项当场退出**，
  后面的检查一项都跑不到。验证工具的价值恰恰是把问题一次全列出来。→ 恒返回 0，结果靠计数器。
- `verify_time()` 以 `[ -n "$_off" ] && info ...` 收尾，取不到 NTP 偏移时函数返回 1，
  被裸调用同样触发 `set -e` → 在「时间同步」这段整段退出。→ 显式 `return 0`。
  `verify_tuic()` 同样加保险。

实测：修复前 verify.sh 在 WSL 上只输出 **30 行就中断**；修复后走完全流程 **51 行并给出汇总**。

**⑤ 配置可读性**

30+ 个魔法参数平铺，改成 8 个分组（拥塞/缓冲/队列/时延/UDP/conntrack/忙轮询），
文件头写明「本次生成的 RMEM/TCPMEM/conntrack 值」和「别手改，重跑会整份重写」。

**版本联动**：改 `lib/` → `VPNMAX_LIB_REV` bump 到 `2026-09-23.7`，
并按 R7 门禁重算 `BOOT_SHA256`（自哈希已复核一致）。

**验证**：`bash -n` 全通过；shellcheck（CI 同款命令）clean；R1–R7 门禁全绿；
`sysctl_expect` 与配置解析写了 8 条单元断言（含制表符多值、行尾注释、读不到键），8/8 通过。

## 2026-09-23 — P0 修复：真实 iptables-save 输出是 `--dport`，mport 仍为空

**QQ/QQ2 真机强制重跑证据**：新版 `sb.sh` 已上线（哈希 `b7a0d829…`、lib rev `2026-09-23.4`），但订阅仍是空的 `ports:`，HY2/TUIC 链接仍没有 `mport`。

**根因**：离线测试误用了 `iptables-save` 的多端口输出 `--dports`；服务器真实规则来自 `--dport 40000:42000`（单数），所以 `grep -- "--dports"` 匹配不到。

**修复**：

- 4 处提取正则改为 `--dports?`，同时兼容单数 `--dport` 和复数 `--dports`。
- 新增真实输出回归测试：`--dport 40000:42000` → `40000:42000`。
- 修正端口跳跃日志把 `40000:42000` 打成 `4000042000` 的显示错误。
- 同步重算原版/Argo 补丁版哈希，bump `VPNMAX_LIB_REV=2026-09-23.5`。

## 2026-09-23 — P0 修复：--force 实际没覆盖旧 sb.sh（用户重跑后 HY2/TUIC 仍不通）

**用户实测**：GitHub 修复已推送，服务器执行 `deploy_singbox.sh --force` 并更新订阅后，HY2/TUIC 仍不通。

**服务器证据**：

- QQ/QQ2 的 `/usr/bin/sb` 哈希均为旧 Argo 补丁版 `dee59d47…`，补丁 marker 也等于该旧哈希。
- QQ 虽已拉取 `VPNMAX_LIB_REV=2026-09-23.3`，但 sb 仍是旧版，说明 lib 更新了、冻结 vendor 没更新。
- 实际订阅：HY2 有 `mport=40000-42000`，TUIC 没有 mport；恰好对应旧版“新 HY2 解析、缺 TUIC 补丁”的半更新状态。
- iptables `VPNMAX_PORTHOP` 两条 DNAT 规则正确，sing-box 服务 active；不是防火墙或服务没起。

**根因**：`lib/singbox.sh::install_singbox_yg()` 的 `--force` 只打印“强制重装”，随后仍进入“现有文件哈希复查”分支；旧 `/etc/s-box/.sb-argo-patched.sha256` 无条件信任历史补丁哈希，于是旧 sb 永远保留，新 vendor/sb.sh 根本没上线。

**修复**：

- 新增 `sb_needs_install()`：已有 sb 且 `FORCE=true` 时也必须进入安装分支。
- 新增 `sb_hash_trusted()`：只信任当前 `SB_SHA256` 和当前 Argo 补丁版 `SB_ARGO_PATCHED_SHA256`；历史 marker 不再保活旧版。
- 安装改为同目录暂存→校验→原子替换；安装失败时旧 sb 保持不变且明确失败，不再被“目标文件非空”冒充成功。
- 增加 force、白名单、安装失败和原版/补丁版双哈希回归测试，防止以后改 vendor 忘记同步常量。
- bump `VPNMAX_LIB_REV=2026-09-23.4`，强制线上重拉本轮 lib/vendor。

**诚实说明**：上一提交 b820b3d 虽修正了 mport 解析，但因更新链没修，修复未真正进入 QQ/QQ2；不能据代码已 push 就声称用户侧已修好。

## 2026-09-23 — 修复：HY2/TUIC 订阅 mport 恒空，端口跳跃段不通

**症状**：一键部署后订阅能生成、大部分节点（TCP 协议）能连，但 **Hysteria2 和 Tuic（UDP 协议）节点不通**。

**根因（两层）**：

1. `vendor/sb.sh` 生成订阅时读跳跃段用的是 `iptables -t nat -nL`，该命令**只列内置链**
   （PREROUTING/INPUT/OUTPUT/POSTROUTING），读不到 vpnmax 独立链 `VPNMAX_PORTHOP` 里的
   跳跃段 DNAT 规则 → `hy2_ports` 恒空 → 订阅里 **mport 参数缺失** → 客户端只连主端口，
   主端口被运营商 QoS/限速（如已知 40254 精准限速）→ 不通。
2. **Tuic 完全没有 mport 处理逻辑**：Clash YAML 的 tuic 节点无 `ports` 字段，`tuic://` 链接无 `&mport=`，
   客户端根本不知道有 43000:45000 跳跃段可用。

**修法**（`vendor/sb.sh`）：

- 跳跃段读取改用 `iptables-save -t nat`（**覆盖所有链**，含 `VPNMAX_PORTHOP`），按
  `--to-destination :主端口` 精确定位指向该协议主端口的 UDP DNAT 规则，再提取 `--dports X:Y`。
- HY2 主订阅区 + `allports()` 同步改成上述逻辑；读到才拼 `mport`/`ports`，读不到保持空（不误报）。
- TUIC 主订阅区 + `allports()` 新增同样的跳跃段读取；`restu5` 的 `tuic://` 链接加 `&mport=`；
  Clash YAML 的 tuic 节点补 `ports:` 字段（与 hy2 对称）。
- 同步重算 `deploy_singbox.sh` 顶部 `SB_SHA256`（vendor/sb.sh 变更后必须同步，否则安装时 SHA 校验失败拒绝安装）。

**验证**（模拟 `iptables-save` 输出离线验证）：HY2 主端口 33775 → 提取 `40000:42000`；
Tuic 主端口 54321 → 提取 `43000:45000`；主端口为 `null`（无该 inbound）→ 空、不误匹配。3/3 通过。

**边界**：若客户端（v2rayN/Karing）对应协议**不支持 mport 参数**，加了也无效，需客户端升级或改走 Argo 隧道。

## 2026-09-23 — 修复：lib 自举缓存冻结（lib 的修复到不了线上）

**问题**：`vpnmax_bootstrap` 只补**缺失**的文件（`[ -s "$VPNMAX_LIB_HOME/$m.sh" ] && continue`），
入口脚本每次从 raw 取最新，但真正执行的 `install_bbrv3` 等来自 `/usr/local/lib/vpnmax/` 的**旧缓存**
→ **lib 的修复永远到不了线上**。当天连踩两次：改了三轮下载逻辑，服务器上跑的还是 13:37 那份
（`grep -c -- '-C -'` = 0，`max-time 120` = 1）。

**修法**

- `lib/boot.sh` 加 `VPNMAX_LIB_REV` 版本戳 + `vpnmax_refresh_if_stale()`：戳不一致就丢掉缓存的
  lib/vendor 并整体重拉；`vpnmax_bootstrap` 成功后写戳（`$VPNMAX_LIB_HOME/.lib-rev`）。
- 5 个入口脚本（bootstrap / deploy_optimize / deploy_singbox / verify / cleanup）：单文件模式下
  **每次都取最新 `boot.sh`**（只有几 KB），再由它按戳决定要不要重拉模块。
- 仓库模式（有本地 `lib/`）完全不碰缓存、不校验戳。

**验证**（用 `file://` 指向本地仓库模拟服务器缓存）：旧戳 → 检测到版本变化、重拉 12 个文件、
戳更新为 `2026-09-23.1`；戳一致 → 静默跳过；手动把戳改旧 → 再次重拉（证明戳是判据）。

> ⚠️ **以后每次改 `lib/` 必须同步改 `VPNMAX_LIB_REV`**，否则线上不会更新。
> vpnplus 无此问题（它只读 `/usr/local/lib/vpnplus`、从不写入，用的是内联副本）。

## 2026-09-23 — 一键脚本端到端实测发现的 3 个问题（GRUB 索引 / conntrack 失效 / 重跑白下）

在 QQ/QQ2 两台新刷的 Ubuntu 22.04 上跑真·一键脚本（`curl … | bash`，不带参数）发现的：

**P1 `ensure_grub_boot` 的 GRUB 索引算错（侬幸进对了，但会失效）**

- 原实现用 `grep -oP "menuentry '\K[^']+"` 数菜单项 —— **只数 `menuentry`，不数 `submenu`**，
  于是把 Advanced 子菜单里的条目当成顶层项来数，算出 `target=1`。
- 真实 grub.cfg：`[0] menuentry 'Ubuntu'`、`[1] submenu 'Advanced options for Ubuntu'`，
  BBRv3 实际在**子菜单第 0 项**。`GRUB_DEFAULT=1` 选中子菜单 → 子菜单默认项正好是 BBRv3 → 侬幸进对。
- **失效场景**：以后装了更新的内核，子菜单第 0 项变成新内核 → 引导到错内核，BBRv3 白装。
- 改为用 **「子菜单>条目」完整路径**（GRUB 手册语法）定位，不受索引漂移影响：
  `GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.2.7-joeyblog-bbrv3-max"`

**P2 conntrack 调优重启后失效，脚本却报「已应用」**

- `apply_sysctl` 里 `modprobe nf_conntrack` 只在**当次运行**生效；没写 `/etc/modules-load.d/`，
  重启后模块不加载 → `/proc/sys/net/netfilter/nf_conntrack_max` 不存在 → sysctl 那行开机静默失败，
  上限回落到内核默认。而脚本无条件打印 `[+] …并应用（conntrack=130000）`。
- 修：写 `/etc/modules-load.d/vpnmax-conntrack.conf`（systemd-sysctl 排在 modules-load 之后，
  开机顺序是对的）+ **回读校验**，对不上就 warn 而不是报成功。

**P3 重跑白下 141MB**

- `install_bbrv3` 只判「**运行中**的内核」有没有 bbrv3，不判「包已装好、只差重启」→ 重跑会重下 141MB（实测约 3 分钟）。
- 修：`/boot/vmlinuz-*bbrv3*` 已存在 → 直接提示「已安装，只差重启」并 `return 0`。
- 顺带修掉误导提示：`标记文件存在但内核未使用 BBRv3（可能已更新）` → 说明真实原因是「已装好未重启」。

**未改（已记录）**：ethtool 对不支持的参数会打 `netlink error`（功能有兜底，但看着像失败）。

## 2026-09-23 — 修复：慢速链路下内核下载必然失败（固定 --max-time + 无断点续传）

**症状**：`deploy_optimize.sh` 卡在内核下载，反复报

```text
curl: (28) Operation timed out after 120001 milliseconds with 105431013 out of 141161094 bytes received
Warning: Problem : timeout. Will retry in 2 seconds. 3 retries left.
Throwing away 105431013 bytes
```

**根因（算术题，不是网络抖动）**：内核 deb **141,161,094 B（134MB）**，实测下行 **0.84 MB/s** →
下完需要 **161 秒**，而脚本给的是 `--max-time 120` → **每次尝试必然在第 120 秒被砍**；
更糟的是 `--retry 3` **不带 `-C -`**，curl 每次重试都把已下载字节丢弃重下
（日志里的 `Throwing away N bytes` 就是它）→ 4 次尝试全白跑。

**触发条件**：服务器下行低于约 1.18 MB/s（141MB ÷ 120s）就永远装不上内核。

**修复**：`lib/common.sh` 新增 `vpnmax_download`，`lib/optimize.sh` 改用它：

- `-C -` **断点续传**：进度跨重试累积，不再丢弃
- `--speed-limit 10240 --speed-time 60` 做**停滞判定**：只在下行持续低于 10KB/s 达 60s 时才放弃，
  **不再按总时长砍**（慢但一直在走就不打断）
- 用 `Content-Length` **校验完整性**，尺寸对不上就明确失败，不留半个包

**验证**（离线 stub harness，11/11 通过）：两段续传后完成 / 文件已完整（服务端 416）/ 永远下不完应失败；
每次都确认带 `-C -`。

**影响面**：`lib/singbox.sh` 里 sb.sh 的 `--max-time 120` 保留——那个文件只有 155KB，不存在这个风险。

## 2026-09-23 — 内核校验和降级为「尽力而为」：不再阻断安装

**起因**：用户反馈 `bash <(curl .../deploy_optimize.sh)` 装不上 BBRv3 内核。

实测根因：脚本把 `SHA256SUMS` 设为**强制**，而整条链（`byJoey/Actions-bbr-v3` → `ccAzy` fork → 本仓 release）
**都不产出这个文件**（`x86_64-7.2.5/6/7-max`、`arm64-7.2.7-max` 全部 404；上游构建工作流里也没有任何
`sha256sum` 步骤）→ 校验必然失败 → `install_bbrv3` 必然中止 → **内核永远装不上**。

**决定（用户拍板）：默认信任上游，不为其维护哈希资产。**

我原先提的两种做法都被否决，理由成立：

- 「在仓库里固化哈希」→ 上游一重建哈希就变，又要人工重算，是永动的维护债；
- 「让 CI 生成并随 release 发布」→ 技术可行，但没必要为此增加流水线动作。

最终采用：**校验降级为「有就比对、没有或对不上只告警」，绝不阻断**；哈希仍写入部署清单留痕。

**改动**

- `lib/optimize.sh` `install_bbrv3`：校验段由「强制 → `return 1`」改为「尽力而为」，删掉 3 处中止分支。
- `deploy_optimize.sh`：头部改进说明、内核段落注释、`--help` 文案同步。
- `SKILL.md`：核心安全设计 #3、文件总览、第 1 步说明同步。
- `kernel/README.md`：标注 `kernel/SHA256SUMS` 从未实现。

**验证**（临时 harness 对照修复前后，跑完已删）：同一条件下（模拟上游 404）——
修复前 `return=1` 并报「SHA256SUMS 无法获取…中止安装」；修复后 `return=0`，输出
「上游未提供 SHA256SUMS（已知情况）—— 跳过校验，继续安装」→「BBRv3 已安装」。

**边界（写明以免以后又纠结）**：不校验等于放弃「来源真实性」保证，只剩 HTTPS 传输完整性。
用户明确接受此权衡。**后续不要以「安全」为由把这道门禁加回来。**

## 2026-09-23 — P0 修复：一键安装脚本头部注释漏写 `#`（线上无限刷屏事故）

**症状**：在 VPS 上粘贴
`bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnmax/main/bootstrap.sh)`
后，终端**不停刷** `bash: bootstrap.sh: No such file or directory`，且不会自己停。

**根因**：`bootstrap.sh` / `deploy_optimize.sh` 的头部「用法」注释块里有 3 行漏写了 `#`：

```
# 用法:
  bash bootstrap.sh [选项]        # 仓库模式 / 已下载        ← 漏 #
  bash <(curl -fsSL .../bootstrap.sh) [选项]   # 一键          ← 漏 #

参数: bash bootstrap.sh [--dry-run] [--check-only]            ← 漏 #
```

于是 bash 把它们当真命令执行：

1. `bash bootstrap.sh [选项]` → 当前目录没有该文件 → 报
   `bash: bootstrap.sh: No such file or directory`（用户看到的第一行）；
2. `bash <(curl .../bootstrap.sh) [选项]` → **把脚本自己下载下来再跑一遍** → 递归，
   每层都重演 1、2 → 无限刷屏；
3. `参数: bash ...` → `command not found`。

因为第 2 行是同步调用，父进程永远卡在这一行，**后面的代码一行都没执行** ——
所以只有刷屏，没有对系统做任何修改（root 检查、apt、gai.conf 全在更后面）。

**为什么 CI 没拦住**：这几行语法完全合法，`bash -n` 通过，shellcheck 也不报。
纯静态检查看不出「这行本来是注释」。引入于 a7d3f08（UX/--help 补齐那笔，重写头部时丢了 `#`）。

**修复**

- 给 `bootstrap.sh`（3 行）、`deploy_optimize.sh`（3 行）补回 `#`。
- 门禁新增 **R6**：shell 文件「头部注释区」内出现未注释行即失败
  （`tools/check-lib-integrity.py`，已接进 CI test job）。
- 回归测试：`tests/test_lib.bats` 新增「入口脚本 --help 不执行游离命令」——
  用 `timeout 20 bash <entry> --help` 断言 exit 0 且输出无 `No such file` / `command not found`。
  带超时，正好能逮住这类死循环：**静态检查逮不住的，跑一下就能逮住**。

**影响面**：`bootstrap.sh`、`deploy_optimize.sh` 两个入口的一键安装路径 100% 不可用；
`deploy_singbox.sh` / `cleanup.sh` 的同类用法文本在 `<<'HELP'` heredoc 内，不受影响（已确认）。

## 2026-09-12 — 砍掉「测速优选」方向（保留部署 / 保活 / 验证）

**决定依据（用户的判断，我原本方向错了）**：完整链路是

```
本机 ──①运营商/国际出口──> CF 边缘 ──②──> cloudflared ──> VPS ──> 目标网站
```

服务器侧「经隧道测速」测的是 **②**，而 **② 是整条链上最不容易出问题的一段**（VPS 在国外机房，
到 Cloudflare 是干净的机房互联）。真正决定体感的是 **①**：家宽、晚高峰国际出口、QoS、UDP 封锁。
**在 VPS 上测，大概率测出「很快」，然后误导人** —— 等于答错了题。

客户端优选（本地解析到指定 CF IP、SNI 仍用域名）技术上可行，但收益必须由用户在自己网络上反复实测；
而用户 2026-09-12 已明确「不要自动测速、手动选节点够用」。故**整个方向不做**。

**删除（合计 1624 行）**

| 文件 | 行数 | 原因 |
| --- | --- | --- |
| `vpnmax-speed-test.sh` | 210 | 纯测速，且位置在服务器侧 |
| `vpnmax-edge-monitor.sh` | 467 | 测速优选宿主（其保活职责已由 `install_argo_keepalive` 覆盖） |
| `vpnmax-edge-monitor.service` | 20 | 同上 |
| `install-edge-monitor.sh` | 204 | 同上安装器 |
| `migrate-to-edge-monitor.sh` | 167 | 迁移到该系统的脚本 |
| `cloudflared-argo-start.sh` / `cloudflared-argo.service` | 59 + 21 | 该系统的启动单元（与 cron 保活的 `nohup cloudflared` 重复） |
| `README-edge-monitor.md` | 256 | 其文档 |
| `lib/edgeprefer.sh` | 121 | CF 段扫描 + colo 优选引擎 |
| `docs/reference/cfdata-scanOfficialIP.go.txt` | 99 | 仅为 edgeprefer 保留的参考 |

**保留（以及为什么）**

- `lib/argo.sh` 的 `install_argo_keepalive` —— 现役保活（flock 互斥 + 进程/HTTP 双检 + 僵死重连 +
  翻动冷却 + 订阅同步）。它跟「测不测速」无关，是可用性刚需。
- `ensure_argo_extra_applied` + `/etc/s-box/argo-extra.conf` —— 从「自动优选的输出端」降级为
  **手工 pin 口子**（例如 `--edge-ip-version 4`），不再由任何脚本自动写入。
- `deploy_optimize.sh` 的智能带宽调优 —— 它测的是 **VPS 出口带宽**，用途是**算 TCP buffer 大小**，
  属于配置计算而非质量评估，与本次砍的方向不是一回事。
- `verify.sh` 的隧道存活检查。

**给已装过 Edge Monitor 的机器（卸载指引）**

```bash
systemctl disable --now vpnmax-edge-monitor cloudflared-argo 2>/dev/null
rm -f /usr/local/sbin/vpnmax-edge-monitor.sh /usr/local/sbin/cloudflared-argo-start.sh       /etc/systemd/system/vpnmax-edge-monitor.service /etc/systemd/system/cloudflared-argo.service
systemctl daemon-reload
# cron 保活（install_argo_keepalive 装的 /usr/local/sbin/vpnmax-argo-keepalive.sh）保留即可
```

**验证**：`bash -n` 全通过；shellcheck 自有代码 0 告警；完整性门禁 R1–R5 全绿；
WSL 实机跑通仓库模式加载（模块清单已去 edgeprefer、`ensure_edge_prefer` 确认移除）与
单文件自举（rc=0，落 10 个 lib + 2 个 verify + `vendor/sb.sh`）；全仓无残留引用。

## 2026-09-12 — 消除「双实现」：lib/ 成为唯一源码，单文件改为运行时自举

**背景（为什么不是继续修漂移）**：上一轮修完 11 处漂移后，检查器仍报 10 处同名不同实现未决，
且 `run` 是语义级冲突（顶层 `"$@"` 传播错误 vs lib `"$@" 2>/dev/null || true` 吞错误+stderr）。
根因不是「对齐不勤」，而是**架构把一份代码拆成了两份**：入口脚本为了让 `curl | bash` 能跑，
各自抄一份内联兜底（共 38 块、约 1200 行），于是每加一个能力都要写两遍。继续逐个修 = 无限长尾。

**做法（最短路径）**：不再「让两份保持一致」，而是**让源码只有一份**。

- 新增 `lib/boot.sh` 引导层：定位 lib 来源（`$SCRIPT_DIR/lib` → `./lib` → `/usr/local/lib/vpnmax`），
  全无则自举下载到 `/usr/local/lib/vpnmax/`，**连同 `vendor/`**。入口脚本只留 3 行加载。
- **删除全部 38 个内联兜底块**（deploy_singbox 26 / deploy_optimize 10 / cleanup 2）：
  deploy_singbox 1562→~300 行，deploy_optimize 746→319 行。
- `apply_hardening` 归位到新 `lib/hardening.sh`；`ensure_gai_ipv4` 从两个脚本的重复定义收进
  `lib/common.sh`（顺手把固定 `/tmp/gai.clean` 改为 `mktemp`，消掉一个固定名的符号链接面）。
- `run` 语义拆分：`run` = 传播失败（部署动作，保留 stderr 可观测）；`run_ok` = 吞失败（清理/探测）。
  cleanup.sh 的 34 处调用改用 `run_ok`，行为不变但语义不再含糊。
- 常量单一来源：`HOP_*` / `RATE_*` / `CONN_ABOVE` / `SSH_RATE_*` / `CHAIN_*` / `BAK_DIR` 收进
  `lib/firewall.sh`，`SB_PATCH_MARKER` 收进 `lib/singbox.sh`。**此前顶层重复定义这些 `readonly`
  常量，会在 lib 先加载后运行时报 `readonly variable` 并退出** —— 这是 `bash -n` 查不出的运行时缺陷。
- 删 `build.sh`（"校验 lib→单文件漂移"的前提已不存在）。
- `tools/check-fallback-sync.py` → `tools/check-lib-integrity.py`：门禁改为防回归
  （R1 禁内联兜底 / R2 必须走 boot 引导 / R3 禁重复定义 lib 的 readonly 常量 / R4 全量 `bash -n` / R5 lib 模块守卫）。
- `vendor/README.md` 第六节的"待决策"结案：自举把 vendor 落到 `/usr/local/lib/vpnmax/vendor/`，
  而 `fetch_sb_sh()` 的查找链本就含该绝对路径 → **"vendor 优先"在单文件部署下真正生效**。

**验证**

| 项 | 结果 |
| --- | --- |
| `bash -n` | 23/23 通过 |
| shellcheck（忽略已知良性 SC1090/1091/2015） | 0 告警 |
| `tools/check-lib-integrity.py` | R1–R5 全绿 |
| 剩余内联兜底块 | **0** |
| WSL 实机：仓库模式加载 lib | 23 个关键函数全部定义；`run` 吞 stderr 0 次，`run_ok` 1 次 |
| WSL 实机：单文件自举（无 lib 目录，HTTP 取回） | 退出码 0；自动落 11 个 lib + 2 个 verify 子模块 + vendor/sb.sh |
| 入口脚本 `--help` | bootstrap / deploy_optimize / deploy_singbox / cleanup 全部 rc=0 |

**过程中的教训**

- 批量删块时，**行首 `fi` 不是可靠边界**：heredoc（`<<'KEEP'`，内容 0 缩进，内含 `fi`）与
  跨行双引号字符串（`run bash -c "cat >x <<'TUNE' ... TUNE"`，其内容不是 bash 语法）都会骗过正则。
  中途两版删除器分别删出了「51 行」（删过头）和「main() 头被吃掉」。最终改用 **ast-grep 的 AST
  节点 range** 定位边界，一次成功。
- 静态检查必须配**运行时冒烟**：`readonly` 常量重复定义、`run` 语义、自举路径，`bash -n` 全都查不出来，
  是 WSL 里 `--help` 跑一遍才暴露的。

## 2026-09-12 — lib/ 与内联兜底的一致性修复（+ 漂移检测工具）

**背景**：顶层脚本同时支持两种跑法 —— 仓库模式 `source lib/*.sh`；单文件模式（`curl ... | bash`）
靠脚本内的 `if ! declare -F f; then f() {...}; fi` 兜底。于是同一个函数有两份实现。

**本次实测出的问题**

- **8 个函数的兜底块已与 lib/ 分叉**。lib 是较新的那份（含 G3 修复、`run` 包装），兜底是旧版
  → 同一台机器换个装法行为就不同，**且完全静默**。
- 其中最严重的是 `clean_stale_acvpn_sysctl`：旧版用裸 `mkdir`/`cp`/`rm`（绕过了 `run` 包装）
  → **单文件模式下 `--dry-run` 会真的删文件**，dry-run 契约被破坏。
- **3 处是“内联无条件覆盖 lib”**：`manifest`（deploy_optimize / deploy_singbox）与 `fetch_sb_sh`
  在顶层无条件重新定义 → 内联永远胜出，lib 里那份成了死代码 → **改 lib 不生效**。

**修复**

- 8 处兜底块按 lib/ 实现刷新：`ensure_time_sync`×2、`install_bbrv3`、`apply_sysctl`、
  `clean_stale_acvpn_sysctl`、`install_singbox_yg`、`wait_subscription`、`config_port_hopping`。
- 3 处无条件定义改为 `declare -F` 守卫，让 lib 优先：`manifest`×2、`fetch_sb_sh`。
- 新增 `tools/check-fallback-sync.py`：比对“顶层脚本中该函数的第一处定义”与 lib/，
  不一致即退出 1。**刻意不按 guard 块解析**（按块解析会被 heredoc 带偏，实测会误报），
  改为只比“同名函数的第一处定义”，因此对 heredoc 不敏感。
- 该工具已自测：注入一处漂移后确实报错退出 1。

**验证**：`bash -n` 27/27 通过；上述 11 处与 lib/ 归一化摘要一致；脚本行尾保持 LF（CR=0）。

**尚未解决（明确记录，不假装已完成）**

- 检查器另发现 **10 处同名不同实现**：`clean_chains`、`ensure_argo_extra_applied`、
  `ensure_edge_prefer`、`ensure_singbox_legacy_env`、`ensure_sub_httpd`、`install_argo_keepalive`、
  `migrate_legacy_chains`、`setup_logrotate`、`start_argo`、`run`×3。
- 其中 **`run` 是语义级冲突，不是笔误**：
  顶层版 `"$@"`（错误向上传递）；lib 版 `"$@" 2>/dev/null || true`（吞掉错误与 stderr）。
  顶层版是无条件定义 → lib 版从不生效。保留哪一份会影响全项目的失败语义，**需决策后再对齐**。
- 因此 `check-fallback-sync.py` **暂不接入 CI**（在上述 10 处处理完之前接入就是红的）。

## 2026-09-12 — 冻结层落地（外部依赖全部 pin + 校验）

承接同日审计的结论“冻结层只冻了配方没冻原料”，本轮把外部依赖的版本决定权收回本地。

### 原则

| 依赖类型 | 处理 |
| --- | --- |
| 上游有专业团队维护（sing-box / cloudflared / 内核源码） | 只 pin 版本号，不抄代码（活水） |
| 上游个人维护 + 以 root 执行（acme.sh / CFwarp.sh / sbwpph） | pin commit + SHA256 校验（冻结） |
| 数据文件（geoip/geosite） | 有意保持 latest（理由见 `vendor/README.md`） |

### 新增冻结（pin commit + SHA256，校验失败即中止，不回落 main）

- `acme.sh` ← `yonggekkk/acme-yg@e3299a70`
- `CFwarp.sh` ← `yonggekkk/warp-yg@f2f634ba`
- `sbwpph_amd64/arm64` ← `yonggekkk/sing-box-yg@9e8b710c`（逐架构 SHA256；~24MB × 2 不入仓）
- 统一入口 `vpnmax_fetch_pinned()`：强制 https + TLS1.2，`sha256sum -c` 校验，校验失败丢弃并中止

### 新增版本 pin（pin 优先，拉取失败才告警回退 latest）

- sing-box `1.13.19`（本项目已验证过的版本）
- cloudflared `2026.8.3`（与 `verify.sh` 的 G6 断言对齐；此前安装脚本拉 latest 而 verify 断言 2026.8.3，两者本就矛盾）
- cfst `v2.3.5`（顺带修掉硬编码 `amd64`——arm64 机器原先会装错架构的二进制）

### 移除的引用

- `bbr()` 不再拉 `teddysun/across/bbr.sh`，改为本地最小实现（只设 fq + bbr → `/etc/sysctl.d/99-vpnmax-bbr.conf`）。
  理由：那份外部脚本会覆盖 `lib/optimize.sh` 算出的 TCP buffer（两套系统写同一批 sysctl 键）。`cleanup.sh` 已同步纳入该文件。
- 卸载完成后的提示原为“欢迎继续使用 Sing-box-yg 脚本：bash <(curl .../yonggekkk/sing-box-yg/main/sb.sh)”——
  这条提示等于引导用户覆盖自己的冻结层，改为指向本仓 `deploy_singbox.sh`。

### 配套

- `SB_SHA256` 同步为 `99b8a4e5…`（改 `vendor/sb.sh` 必须同步，否则安装时校验失败拒绝安装）
- `vendor/README.md` 重写：分“已入仓 / 不入仓但已 pin / 只 pin 版本 / 已移除 / 有意不 pin / 未解决”六类

### 验证

- 全部 pin 的资源均实测可达（HTTP 200，含 arm64 变体）
- `bash -n` 全通过；项目内已无“裸拉上游 main/latest 后直接 root 执行”的路径

## 2026-09-12 — 全面审计修复（供应链 / 权限 / 死副本 / 文档一致性）

对公开仓库做一次只读全面审计（CI 权限、路径映射、脱敏、文档一致性、脚本语法与 lint），本轮修掉以下项：

- **P0 供应链**：`build-bbrv3.yml` 的第三方 action `Mattraks/delete-workflow-runs` 由浮动分支 `@main` 改为固定 commit（`0cf693b`）；其余 4 个 action（checkout / upload-artifact / download-artifact / action-gh-release）同样钉到 commit SHA。
- **P0 权限最小化**：工作流原为全局 `contents: write + actions: write`，第三方 action 因此能拿到仓库写权限。改为顶层 `contents: read`，各 job 按需覆盖：`cleanup` 只需 `actions: write`，`build` / `update-config-baseline` 才给 `contents: write`。
- **P0 运行历史可追溯**：`cleanup` 原为 `retain_days: 0` + `keep_minimum_runs: 0`，会把失败历史全部删掉（实测 API 只剩 1 条记录，失败后无法回溯）。改为保留 14 天 / 至少 5 条。
- **P1 删死副本（同一类路径坑的根因）**：删除 `kernel/patches/`、`kernel/scripts/`、`kernel/x86-64.config`、`kernel/arm64.config` —— 它们是“工作流曾在 kernel/ 下”时期的副本，而脚本 `repo_root` 与工作流实际读的都是仓库根那份，两份 config 已经漂移（`CONFIG_RUSTC_VERSION` 109800 vs 109801）。`kernel/README.md` 改写为“权威路径在仓库根”的说明。
- **P1 删上游死代码**：删除 `kernel/install.sh`（上游 byJoey 原版安装器，全仓零引用，且下载的是上游 release 而非本仓）与 `kernel/cve_2026_31431_detector.py`。
- **P1 文档指错源**：README “鱼缸论”段落原写“BBRv3 补丁 pin 在 `kernel/patches/`”，按此修改不会生效；改为仓库根 `patches/`，并补上内核配置基线的真实位置。
- **P1 Edge Monitor 安装入口不完备**：README 推荐的 `install-edge-monitor.sh` 原先不装 `cloudflared-argo.service` / `cloudflared-argo-start.sh`（service 的 ExecStart 指向后者，缺它服务起不来），也不移除旧的 `vpnmax-argo-keepalive` cron → 新旧保活并存会让 G4 双进程问题复活。现补齐：安装 cloudflared-argo 一套、安装前先移除旧保活、卸载时一并清理。
- **P1 测试从未被执行且本身是坏的**：新增独立 `test` job（bats，不参与构建链路故不阻塞 release）；修复 `tests/test_lib.bats` 中 `time.sh` 用例（没 source `lib/common.sh`，`info: command not found`，该用例实际一直失败）。
- **P2 清理清单漏项**：`cleanup.sh` 旧 sysctl 清理清单补上小写 `99-acvpn.conf` / `99-ACVPN.conf`（Linux 文件名区分大小写，实测存在过小写版本）。
- **P2 vendor 现状诚实化**：`vendor/README.md` 原称“零上游调用 / 已 patch 禁上游污染”，但 `acme.sh` / `CFwarp.sh` / `bbr.sh` / `sbwpph_*` 均未入仓，对应“优先用 vendor”分支恒不生效 → 文档改写为“未入仓清单 + 当前恒走上游”，并指出单文件部署下 vendor 相对路径本身也解析不到。
- **P2 去掉 `--insecure`**：`vendor/sb.sh` 的 `inssbwpph()` 回退下载原带 `--insecure`（关闭 TLS 校验后把二进制 `chmod +x` 以 root 执行），改为强制 https + TLS1.2、失败即中止该组件；同步更新 `SB_SHA256`（`46faf59b…` → `9b5f4b91…`）。
- **P2 `.gitattributes` 规则失效**：`*.example text eol=lf` 与 `.gitignore text eol=lf` 因缺换行粘成一行，导致 `.gitignore` 规则从未生效；重写并补 `.shellcheckrc` / `.yamllint` / `.editorconfig`（这三个文件此前无规则，在 Windows 检出下变 CRLF，使本地 shellcheck 报大量 SC1017 噪声）。
- **P2 SKILL.md 陈旧**：文档里承诺的 Telegram 推送订阅与 `sbwpph.json` 在代码中均不存在，改为与实现一致的描述。
- **P2 日志一致性**：`vendor/README.md` 标题由“零上游调用”改为现状描述，避免把目标当成事实。

**验证**：32 个 shell 文件 `bash -n` 全通过；自有代码 shellcheck 仅剩 SC1090（动态 source，已知良性）；工作流 YAML 解析通过；`git ls-files --eol` 确认索引行尾全 LF（53/53）。

## 2026-09-08 — vpnmax 二次优化（7 台调优缺口 + 融合怪第一步）

- **G2 出口目标 prefer_ipv4**：与 7 台调优最佳状态对齐（ipv4_only 在有 v6 机器上掐回退）；force_ipv4_lock 改常态幂等，不再仅 --force。
- **G4/G7 Argo**：restart 单实例收敛（防 cron/keepalive 竞态双进程）；L3 改遍历全部订阅产物并复验，失败明示手动。
- **sb 零上游**：`vendor/sb.sh` 入仓（与 pin SHA 一致），本地优先、自家 raw 兜底，全程 SHA 校验。
- **边缘优选**：新增 `lib/edgeprefer.sh`（CFData trace+colo 测量逻辑的 shell 版），输出家族选择与最优 colo；quick tunnel 无 `--edge`（已实测 help），用 `--edge-ip-version` + 可选 `--region` 经 argo-extra.conf 注入。
- **verify 新增 1c 回归**：SSH（用运行中 sshd 判定）、旧 ACVPN 残留、内核/BBR、cloudflared pin 版、订阅-隧道一致性。
- **G3**：部署路径自动清旧 ACVPN sysctl（带备份）。
- **杂项**：清两个死变量（patched_ok/need_restart，后者改为 drop-in 变化才重启）。

## 2026-08-27 — IPv4 全链路强制锁定（JP/HK 订阅回退根因，e3dc9c5）

- **P0 IPv4 全链路 `ipv4_only`**：`sb-yg` 每次 `3-8-1 设置本地IP订阅 / 14-1 WARP / 5-3-1 域名分流` 重建 `sb.json` 会重置 `yg_kkk: prefer_ipv6`，导致 JP/HK `sb.json` 订阅更新后回退 v6、移动端仍 `2a06`。`lib/singbox.sh:force_ipv4_lock` 改原子单次 `jq` 锁 `route.rules[].strategy + dns.strategy/dns.servers[].strategy + outbounds direct/socks.domain_strategy = ipv4_only`，幂等（`cmp` 无变化不重启）、`gai.conf` 去重单行、`legacy env` 前置防 `FATAL`，`verify.sh` 同 `jq` 校验 `IPv4 锁定已生效`，`README/SKILL` 同步。双机热补验证 `inject prefer_ipv6 → jq ok → active → ipv4_only` 通过。
- **P1 `lib/warp.sh` `mktemp` 模板**：`fix_mport_dup` `mktemp → mktemp /tmp/vpnmax-mport.XXXXXX` 防 `/tmp` 竞争。
- **热补纪律**：热补仅测试阶段，线上回归一键 `deploy_singbox.sh --force` 单一入口，`cron/sub-argo` 热补已清，`busybox httpd -p` 常驻。

## 2026-08-27 — SSH 仅密钥 + sing-box 1.12+ 崩溃修复 + 全脚本审查（7台实测）

- **P0 sing-box 1.12+ `legacy domain_strategy` FATAL 崩溃**：`sing-box 1.13.19` 对 `domain_strategy`/`strategy: prefer_ipv4/ipv4_only` 报 `legacy domain strategy options is deprecated ... FATAL ... ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true`，导致 JP/HK 在 `force_ipv4_lock` 后 `activating/auto-restart 155次`、端口全失。新增 `lib/singbox.sh:ensure_singbox_legacy_env()`，在 `force_ipv4_lock()` 前注入 `Environment=ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true` 到 `/etc/systemd/system/sing-box.service.d/99-vpnmax.conf`（兼容 sb/xr），`daemon-reload` 后自动重启，`verify.sh` 新增 `sing-box legacy env 已注入` 与 `gai.conf 单行` 校验。
- **P0 线上 SSH 已手工加固为仅密钥**（不入脚本，脚本仅负责协议节点部署）：7台线上节点已手工执行 `PasswordAuthentication no / PermitRootLogin prohibit-password` 并验证 `sshd -T`，此加固逻辑已从部署脚本中移除，保持脚本职责单一。
- **P1 gai.conf 幂等去重**：`bootstrap.sh`/`deploy_optimize.sh` 原 `echo 'precedence ...' >> /etc/gai.conf` 会累积重复（实测 2行），现改为 `grep -v '^precedence ::ffff:0:0/96' > /tmp/gai.clean; echo 'precedence ::ffff:0:0/96 100' >>` 单行幂等，`verify.sh` 校验 `grep -c ==1`。
- **P1 mktemp 安全**：`deploy_singbox.sh:fix_mport_dup` 的 `tmp=$(mktemp)` 改为 `mktemp /tmp/vpnmax-mport.XXXXXX`，防 `/tmp` 竞争。
- **P2 cleanup.sh `read -r`**：`read -p` 改为 `read -r -p`，防反斜杠转义。
- **全面 shellcheck 审查**：`shellcheck 0.11.0` 全量扫描 5脚本+lib，剩余仅 SC1090（动态 source）与 SC2015（`A && ok || warn`  intentional 三元）已确认不改，SC2034/2162 已修复。
- **影响面**：JP/HK 已从 crash loop 恢复 `active (running)`，订阅 `http://IP:PORT/token/clmi.yaml` 实测 200，`verify.sh` 新增 legacy/gai 两项均通过。

## 2026-08-27 — 时钟与 TUIC 单点故障修复（rn1 实测）

- **P0 时钟漂移（`bad timestamp` 全不通）**：`deploy_optimize.sh`/`deploy_singbox.sh` 的 `install_dependencies` 新增 `chrony`，新增 `ensure_time_sync()`（国内源 `ntp.aliyun/ntp1.aliyun/cn.pool/pool.ntp` + `makestep 1 3` + `rtcsync`，`systemctl enable --now chrony` 并 `chronyc makestep` 即时拨正），`verify.sh` 新增 `chrony Leap Normal` / `System clock synchronized` / `ntpdate -q` 偏移检查。rn1 实测 `System clock synchronized: no` / `chronyc: command not found`，修复后 `Stratum 2 Normal`。
- **P0 TUIC 单点端口污染**：rn1 `40254` 直连在外网被精准限速（本机回环 204 通、外网 Hy2 通、TUIC 40254 超时8s、TUIC 44000跳跃/54321 新端口秒通 204），`verify.sh` 新增 `TUIC 端口污染` 与 `端口跳跃 DNAT 指向` 检查 + 本地回环 `127.0.0.1:$TU_PORT → google 204` 自检，区分“本机坏”与“外网墙”。rn1 已切 `40254→54321` 并 `iptables -t nat DNAT 43000:45000→54321` + `VPNMAX_ANTIPROBE 54321`，`clmi.yaml/tuic5.txt/jhsub` 同步 54321，重跑 `netfilter-persistent save`。
- **P0 订阅轮转（暴露后一键换链）**：`deploy_singbox.sh` 新增 `RESET_SUB=1` / `--reset-sub`（`KEEP_PORT` 逻辑前置清理 `subport.log/subtoken.log/websbox/*`），默认仍复用旧订阅保持客户端有效，暴露后 `RESET_SUB=1 bash deploy_singbox.sh` 即生成全新 token/端口，旧链接立即 404。
- **影响面**：其余 6 台（hk/jp/cc/vn/rn2/qq）已验证同依赖缺口，建议批量重跑 `deploy_optimize.sh` 补 chrony。

## 2026-08-25 — 全面审计修复（11 项，含 1 真实 Bug）

针对公开仓库做全面审计（5 脚本 + 文档），修正全部发现项：

- **`deploy_singbox.sh` iptables 持久化修复（高优）**：旧实现第三层 `iptables-save` 只写文件、无开机加载，重启后 `VPNMAX_PORTHOP`/`VPNMAX_ANTIPROBE` 独立链规则全部丢失。新增 `persist_firewall()`：优先 netfilter-persistent，并**额外写 `/etc/iptables/rules.v4|v6` + 自建 `vpnmax-netfilter-restore.service`（network-pre.target 前恢复）双保险**。两处调用点（端口跳跃/防探测）统一收敛。bootstrap/deploy 依赖新增 `iptables-persistent`。
- **`cleanup.sh` 漏删 Argo 保活脚本（真实 Bug）**：`rm_files` 只删旧名 `vpnmax-argo-keepalive.sh`，**未删新版 `vpnmax-argo-keepalive.sh`**，清理后留孤儿。现已补删，并连带清理 `vpnmax-netfilter-restore.service`、iptables 快照、lock 文件、logrotate 配置；`verify_clean` 新增对应断言。
- **`deploy_singbox.sh` 保活脚本 v3**：`install_argo_keepalive` 改为**纯单引号 heredoc 直写**（彻底消除旧版 bash -c 双层转义出错风险），并升级逻辑：
  - **flock 互斥**：禁止两个保活实例并发 pkill/重启互踩
  - **进程识别统一**：临时隧道口径改为 `cloudflared+tunnel+--url`，与 `start_argo`/`cleanup` 一致（不再只认 localhost）
  - **cloudflared 路径自动探测**：不再硬编码 `/etc/s-box/cloudflared`
  - **WS 端口健壮化**：优先按 type==vless + transport==ws 取，退化 inbounds[1]
  - **翻动检测**：30 分钟内连续重连 ≥5 次 → 触发 1 小时冷却并写 `argo-flapping.marker`（防域名无限漂移折腾客户端）
- **`deploy_singbox.sh` sb.sh 哈希复查**：重跑时即使 sb 已存在也校验哈希（原版 或 Argo 补丁白名单 `SB_PATCH_MARKER`），不在可信集合则重新下载覆盖，避免"首次校验后 /usr/bin/sb 被篡改/被 sed 补丁失去 pin 意义"。补丁版哈希由 `apply_argo_patch` 实时记录。
- **`deploy_singbox.sh` sb_feed 精确清理 + 日志**：只杀"本次调用期间新出现"的 sb 进程（PID 差集），不再 `pkill -f 'bash /usr/bin/sb'` 误杀同机手动开的 sb 面板；sb 交互输出去色后追加到 `/var/log/vpnmax-sbfeed.log` 供失败回溯。
- **`deploy_singbox.sh` sb 菜单版本指纹**：首次部署前抓 sb 横幅识别版本，非预期 v2x 系列则告警（防菜单序号漂移导致安装"产物缺失才报错"难排查）。
- **`deploy_singbox.sh` 失败 trap**：中断时明确给出恢复指引（cleanup 预览/重跑/彻底重建 + sbfeed 日志位置），不再带着半配置无提示退出。
- **`deploy_singbox.sh` 可调常量收敛**：端口跳跃段（40000:42000/43000:45000）与限速/连接数阈值集中到顶部 `readonly` 常量，清除散落各处的魔法数，杜绝 2026-08-21 那类单点改漏。
- **`deploy_singbox.sh` 日志轮转**：新增 `setup_logrotate`（step 7），对 vpnmax 各类日志 + `argo.log` 周轮+保留 4 份+压缩（`copytruncate` 防 tee/重定向句柄丢失）。
- **`verify.sh` 增强**：新增校验 netfilter-restore unit 存在/启用、logrotate 配置、保活脚本 + cron + flock、网络调优服务 enable 状态。
- **`cleanup.sh` 进程口径统一**：`kill_procs`/`verify_clean` 改用 `cloudflared.*tunnel.*--url`，与保活脚本一致；`pgrep -fc` 改用 `pgrep -f | wc -l` 防自匹配误计。
- **审计方法论沉淀**：全面审计读完全部 5 脚本+CHANGELOG+SKILL，逐项标注优先级与诚实边界（需真机确认项以#3/#5 类锚点标出，余皆代码直接判定）。

## 2026-08-24 — 稳定性修复（所有改动已在 HK 服务器 HK 实测验证）

## 2026-08-24 — 稳定性修复（所有改动已在 HK 节点实测验证）

- **`deploy_singbox.sh` Argo 临时隧道保活升级 v2（三级自愈）**：原保活只查进程是否存在，进程僵死（连接边缘断开）时不处理、重连后也不同步新域名。v2 改为：
  - **L1** 进程缺失 → 重启
  - **L2** 进程在但当前域名 HTTP 探测为 000（无任何状态码，二次确认防瞬时抖动）→ 判僵死 → 重启换新域名
  - **L3** 重连后域名变化 → 自动刷新订阅（jhsub/clmi/sbox 全部指向新域名），并兜底补同步不一致
  - HK 真机实测：杀进程→keepalive 自动重启（域名 cant-building→baptist-fourth-permit-geological）→ 订阅同步 → 客户端经新 Argo 域名端到端 HTTP 204。
- **`deploy_singbox.sh` VMESS_LOCK 默认 `on→off`**：默认不启用防主动探测防火墙锁端口，明文 VMess 公网直连。适合仅密钥登录+关闭密码登录+改 SSH 端口、无多余暴露面、希望节点全通的场景（HK 实测 2082 明文端口由"不通"变通）。需要额外防探测时设 `VMESS_LOCK=on`。
- **`deploy_singbox.sh` 新增 `sb_feed` 包装函数**：统一所有 sb(sing-box-yg) 菜单投喂（安装/订阅/WARP/域名分流/Argo），解决上游 sb 子菜单"完成操作后 `sleep 3 && sb` 递归拉起新面板、管道喂完存 stdin 耗尽导致脚本卡死/残留孤儿 sb 进程"的问题。末尾补多组 0 逐层退出 + timeout 限时 + 结束强杀残留，根治 `rm -f /etc/.vpnmax-singbox && bash deploy_singbox.sh` 强制重跑卡死。
- **`deploy_singbox.sh` 配置端口跳跃前清理 PREROUTING 过期跳跃段残留**：重跑会累积指向已废弃端口的孤立 UDP DNAT/REDIRECT（40000:42000/43000:45000/40000:41000），排在 `VPNMAX_PORTHOP` 前把 hy2/tuic 跳跃段流量引入不存在的端口 → 握手无响应（Karing/V2rayN 实测不通）。现按行号幂等清除（真机验证），不碰 VPNMAX_PORTHOP 链内规则及其他 NAT。
- **`deploy_singbox.sh` 订阅端口稳定性**：`setup_subscription` 重跑时探测并复用已有 `/etc/s-box/subport.log` 端口（1024-65535 合法段），不再每次随机 → 客户端订阅地址重跑后保持有效；无旧端口才随机。
- **`verify.sh` Argo 可达判定修正**：trycloudflare 隧道代理 WS 服务，根路径 404/4xx 是正常响应（能拿到状态码=边缘→隧道→本地链路通），仅 HTTP 000（连不上/超时）才算不可达，消除误报。
- **`verify.sh` 新增"PREROUTING 无残留端口跳跃段"检查**：部署后能发现过期跳跃段残留（提醒重跑 deploy 自动清理）。
- **`cleanup.sh` 兜底清理扩展匹配 REDIRECT 型残留**：除 DNAT 外，同时清理旧配置遗留的 REDIRECT 40000:41000 型重复跳跃规则。

## 2026-08-21 — 逻辑审查修复（三处）

- 修复 `deploy_singbox.sh` 端口跳跃启用条件：`&&`/`||` 同优先级左结合导致只装 Hysteria2（无 Tuic）时整条 `VPNMAX_PORTHOP` 链被静默跳过；改为显式分组 `{ ...; } || { ...; }`，单协议/双协议/双缺失四象限实测验证。
- 修复 `deploy_optimize.sh` 两处 `set -e` 中断路径：`apply_ethtool`、`ensure_grub_boot` 存在 `return 1` 分支却被裸调用，一旦触发会中止整个脚本（跳过资源限制、多队列持久化、成功标记与重启）；改为 `|| warn` 降级继续。
- 修复 `verify.sh` 与文档不一致：README/SKILL 教的 `SERVER_IP=x.x.x.x bash verify.sh` 环境变量用法此前不生效（脚本只读 `$1`）；现在两种传参方式均支持。

## 2026-08-20 — 全项目流程与逻辑审查修复

- README/SKILL 改为“部署前置 + 第一/二/三步”，不再把环境准备写成“第零步”。
- 修复 `deploy_optimize.sh` 与 `deploy_singbox.sh` 的 dry-run：预览模式不再继续检查不存在的真实产物，也不执行系统写入/服务/防火墙/重启。
- 修复 `bootstrap.sh`：`git`、`xz-utils`、`tmux` 现在同时进入包状态检查和命令可用性检查，不再出现“列在清单但漏检”。
- 修复 `deploy_singbox.sh` 重写时遗漏的最终订阅链接输出（Clash/Mihomo、Sing-box、通用聚合）。
- 收紧 cleanup：不再全局杀 busybox；cron 只过滤 vpnmax/旧 ACVPN 自己的路径；未确认归属的 cloudflared systemd unit 和 nftables sing-box 表保留不动。
- cleanup 增加独立防火墙链清理结果验证。
- 增加 HTTP 高端口订阅链接的移动网络拦截提示。
- 增加已知限制：Private 仓库的匿名 raw 安装命令会返回 404；完整链路仍需真实 VPS 端到端验证。

## 2026-08-20 — 环境准备优化

- 新增 `bootstrap.sh`：统一检查/安装 Debian/Ubuntu 基础依赖，不装内核、不改防火墙、不重启。
- 两个部署脚本增加依赖兜底：即使跳过 bootstrap，也会明确安装缺失工具；apt 更新/安装失败直接中止，不再静默继续。
- 依赖清单覆盖 `curl`、`jq`、`git`、`xz-utils`、`tmux`、`iproute2`、`iptables`、`procps`、`psmisc`、`util-linux`、`cron`、`ethtool`、`kmod`、`ca-certificates`，兼顾 vpnmax 与 Hermes CLI 的基础环境。
- `git`/`xz-utils` 供 Hermes 安装器使用，`tmux` 用于 SSH 断开后保持 Agent 会话；`build-essential` 仍不默认安装。
- 修复 `deploy_optimize.sh` 在环境预检前就调用 apt 的顺序问题；非 Debian/Ubuntu 环境现在先明确退出。
- README/SKILL 改为第 0 步环境准备 + 第 1/2/3 步部署、验证。

## 2026-08-20 — vpnmax 初版（ACVPN 加固迁移）

本仓库由 [ccAzy/ACVPN](https://github.com/ccAzy/ACVPN) 迁移并加固而来。ACVPN 保持不动，此处为安全收敛版。

### 🛡️ 安全加固（相对 ACVPN 的核心差异）

- **独立防火墙命名链** — 关键修复
  - `VPNMAX_ANTIPROBE`（filter INPUT）：防主动探测全部规则
  - `VPNMAX_PORTHOP`（nat PREROUTING）：Hy2/Tuic 端口跳跃
  - `VPNMAX_RSS`（filter INPUT）：RSS 相关（若有）
  - 主链仅一条跳转（`-I INPUT 1 -j VPNMAX_ANTIPROBE`），重跑/卸载只 `-F/-X` 自己的链
  - **废除** 旧版 `grep 'limit: above'/'#conn'` 全局匹配删 INPUT 的写法 —— 该写法可能误删 fail2ban / Docker / 其他程序的安全规则
- **外部 sb.sh 锁定 + 强制校验**
  - 固定 commit `5001e76efc9e15eac1f8ff33a0b389172e331e1d`
  - SHA256 `65113dd45eba3bb377e71e89f01d77d84537757771802898acc6e60f36bf06be`
  - 下载后强制校验，失败即中止，不静默降级 → 防供应链篡改
- **内核 SHA256 强制校验**
  - SHA256SUMS 无法获取 / 找不到目标包 / 校验不匹配 → 一律中止安装
  - 不再"仅警告后照装"（内核为最高权限组件，不容无声降级）
  - 支持 `VERSION_PIN=x.y.z` 锁定版本
- **核心/可选失败语义分离**
  - 核心步骤（安装 sing-box / 生成订阅 / Argo）失败 → `DEPLOY_OK=false`，不写成功标记
  - 可选步骤（WARP / ethtool 不支持项 / IPv6 规则）失败 → 告警继续
- **精确进程清理**
  - busybox 按监听端口定位 PID 停止，废除 `pkill -x busybox` 杀全局
- **安全默认收紧**
  - `VMESS_LOCK` 默认 `on`（明文 VMess 端口公网 DROP，仅 Argo 回环可达），旧版默认 off
- **网络感知 sysctl**
  - `accept_ra` 仅在检测到无 IPv6 全局地址时才关闭，避免破坏依赖 RA 获址的 VPS
- **set -e 边界修复**
  - crontab/grep 命令替换统一 `|| true`，杜绝静默提前退出

### 🧰 可运维性

- **dry-run 模式** — deploy_optimize.sh / deploy_singbox.sh / cleanup.sh 均支持 `--dry-run` 预览
- **防火墙备份** — cleanup 前自动备份 iptables/ip6tables/nftables 规则到 `/var/backups/vpnmax/`
- **部署清单** — 内核来源/版本/SHA256 与 sb.sh commit/SHA256 写入 `/var/log/vpnmax-*-manifest.log`
- **verify.sh 对齐** — 改验独立命名链存在性，不再 grep 全局规则
- **`--force --dry-run`** — cleanup 支持非交互 + 预览组合

### 📄 文档

- README/SKILL 全面改写，新增"相对 ACVPN 的安全加固清单"
- 标记路径改为 `/etc/.vpnmax-optimized` / `/etc/.vpnmax-singbox`
- 服务/脚本改 vpnmax 命名（`vpnmax-argo-keepalive.sh`、`vpnmax-rss.service` 沿用兼容旧清理）

## 兼容性说明

- 独立链名沿用 `VPNMAX_*` 前缀，是为了兼容清理旧 ACVPN 安装部署的规则，属有意保留
- 升级外部 sb.sh 时**必须同时更新 `SB_COMMIT` 与 `SB_SHA256`**，否则校验失败拒绝安装
- 本仓库未继承 ACVPN 的 git 历史（新仓库独立起点）
