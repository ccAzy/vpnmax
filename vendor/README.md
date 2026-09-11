# vendor/ — vpnmax 融合依赖

> **一句话现状**：本目录**目前只有 `sb.sh`**。下表中标 ❌ 的依赖都还没入仓，
> 相关功能触发时会**实时从上游拉取**。"零上游调用"是**目标**，不是当前事实。

## 已入仓

| 文件 | 来源 | 版本 pin | SHA256 |
|---|---|---|---|
| `sb.sh` | `ccAzy/sing-box-yg` commit `5001e76e`（与 `yonggekkk/sing-box-yg` 同 commit 字节一致，已实测）+ vpnmax 本地 patch | 见 `SB_COMMIT` | `46faf59b…03c77`（见 `SB_SHA256`） |

规则：

1. 部署优先使用本目录 `sb.sh`，安装时仍做 SHA256 校验（纵深防御）。
2. 本目录缺失时（如 curl 裸装单文件模式）回退到**自家** `ccAzy/vpnmax` raw，
   绝不调上游 `yonggekkk`。同样 SHA256 校验。
3. 升级 sb 时：更新本文件 + 同步 `SB_COMMIT`/`SB_SHA256` 两个常量，
   否则校验失败拒绝安装（有意设计）。
4. 该 fork 已原生支持 `/etc/s-box/argo-extra.conf`
  （Argo 附加参数，如 `--region`），与 `lib/edgeprefer.sh` 对接。

## 未入仓清单（⚠️ 当前恒走上游，等于没有冻结）

| 文件 | 代码里的回退目标 | 现状 |
|---|---|---|
| `acme.sh` | `yonggekkk/acme-yg` main | ❌ 未入仓 → 每次签证书都实时拉上游 |
| `CFwarp.sh` | `yonggekkk/warp-yg` main | ❌ 未入仓 → WARP 安装实时拉上游 |
| `bbr.sh` | `teddysun/across` master | ❌ 未入仓（vpnmax 已自建，此为备用） |
| `sbwpph_amd64` / `sbwpph_arm64` | `yonggekkk/sing-box-yg` main | ❌ 未入仓 → WARP-socks5 二进制实时拉上游 |

`sb.sh` 里对应的"优先用 vendor 本地文件"分支**已经 patch 好了**，但因为上表文件都没有，
**这些分支永远不生效**——实际执行的始终是回退分支。所以：

- `acme()` / `cfwarp()` / `bbr()` / `inssbwpph()` 目前**没有**兑现"禁上游污染"。
- `inssbwpph()` 的上游回退**原先还带 `--insecure`**（关闭 TLS 校验后把二进制
  `chmod +x` 并以 root 执行）。该 `--insecure` 已移除，现在强制 https + TLS1.2+，
  失败即中止该组件。

### 第二个坑：vendor/ 相对路径在单文件部署下解析不到

这些分支用 `dirname "$(readlink -f "${BASH_SOURCE[0]}")"/vendor/...` 定位本地文件。
但一键部署是把 `sb.sh` **当单文件下载执行**（见 `deploy_singbox.sh` 的 `SB_URL`），
运行时 `vendor/` 不在脚本旁边 → 即使把文件补进仓库，也**依然解析不到**。
要让这个机制真正生效，必须让部署流程把 `vendor/` 一起分发（或把路径改成绝对可配）。

## 待办（需要决策，不是纯代码问题）

1. 决定这几个第三方脚本/二进制**是否入仓**：二进制入仓会撑大仓库体积，
   不入仓则"冻结层"在这几项上名不副实——二选一，别维持"声称已冻结但实际没冻"的状态。
2. 若入仓：`vendor/` 必须随部署一起落地，否则相对路径失效（见上）。
3. 无论哪种选择，都应给回退下载**加校验**（pin commit + SHA256），
   而不是"从上游 main 拉最新然后 root 执行"。
