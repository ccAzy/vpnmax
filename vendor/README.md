# vendor/ — vpnmax 融合依赖与外部依赖的版本控制

> **一句话现状（2026-09-12 起）**：仓库里只有 `sb.sh`；其余上游依赖**不入仓，但全部 pin + 校验**。
> 项目里已经**不存在"裸拉上游 main/latest 后直接 root 执行"的路径**。

## 一、已入仓

| 文件 | 来源 | 版本 pin | SHA256 |
|---|---|---|---|
| `sb.sh` | `ccAzy/sing-box-yg` commit `5001e76e`（与 `yonggekkk/sing-box-yg` 同 commit 字节一致，已实测）+ vpnmax 本地 patch | 见 `SB_COMMIT` | `99b8a4e5…5ec08`（见 `SB_SHA256`） |

规则：

1. 部署优先使用本目录 `sb.sh`，安装时仍做 SHA256 校验（纵深防御）。
2. 本目录缺失时（如 curl 裸装单文件模式）回退到**自家** `ccAzy/vpnmax` raw，
   绝不调上游 `yonggekkk`。同样 SHA256 校验。
3. 升级 sb 时：更新本文件 + 同步 `SB_COMMIT`/`SB_SHA256` 两个常量，
   否则校验失败拒绝安装（有意设计）。
4. 该 fork 已原生支持 `/etc/s-box/argo-extra.conf`（Argo 附加参数，如 `--edge-ip-version 4`）。
   本项目**不做自动优选**；需要固定时由人手写该文件（`lib/argo.sh` 的 `ensure_argo_extra_applied` 会把它对齐到运行中的隧道）。

## 二、不入仓，但已 pin + 校验（在 `sb.sh` 顶部常量区）

| 依赖 | pin 方式 | 常量 |
|---|---|---|
| `acme.sh` | commit + SHA256 | `VPNMAX_ACME_COMMIT` / `VPNMAX_ACME_SHA256` |
| `CFwarp.sh` | commit + SHA256 | `VPNMAX_CFWARP_COMMIT` / `VPNMAX_CFWARP_SHA256` |
| `sbwpph_amd64` / `sbwpph_arm64`（各 ~24MB） | commit + 逐架构 SHA256 | `VPNMAX_SBWPPH_COMMIT` / `VPNMAX_SBWPPH_SHA_AMD64` / `_ARM64` |

统一由 `vpnmax_fetch_pinned()` 下载并校验：**校验不通过就丢弃并中止，不回落上游 main**。

**为什么不入仓**：`sbwpph` 两个架构合计约 48MB，入仓会显著撑大仓库；
而 pin + SHA256 已经拿到"内容不可变、可校验、可回滚"的全部收益。
（顺带避开这几份第三方文件的再分发/许可证问题。）

## 三、只 pin 版本号（活水层）

| 依赖 | 现值 | 说明 |
|---|---|---|
| sing-box 内核 | `1.13.19` | `VPNMAX_SINGBOX_PIN`；这是本项目已验证过的版本 |
| cloudflared | `2026.8.3` | `VPNMAX_CLOUDFLARED_PIN`；与 `verify.sh` 的 G6 断言一致 |
| cfst（CloudflareSpeedTest） | `v2.3.5` | `CFST_PIN`（在 `vendor/sb.sh` 内部使用） |

三者的取法都是 **pin 优先 → 拉取失败时告警并回退 latest**（避免 pin 失效导致整个安装或优选卡死）。
升级 = 改常量，是一次有意识的动作。

## 四、已移除的上游引用

| 依赖 | 原用途 | 现状 |
|---|---|---|
| `bbr.sh`（`teddysun/across`） | sb 菜单里的"一键开 BBR" | **改为本地最小实现**：只设 `fq` + `bbr`，写入 `/etc/sysctl.d/99-vpnmax-bbr.conf`。原因：原脚本会覆盖本项目 `lib/optimize.sh` 算出来的 TCP buffer 参数（两套系统写同一批 sysctl 键） |
| 上游 `sb.sh` 自更新 | `lnsb()` / `upsbyg()` | 已 patch 为空操作（原有的冻结做法） |
| 欢迎语里"去跑上游 sb.sh"的提示 | 卸载完成后的提示 | 已改为指向本仓 `deploy_singbox.sh`（原提示等于引导用户覆盖自己的冻结层） |

## 五、有意不 pin 的（说明，不是遗漏）

| 项 | 原因 |
|---|---|
| `geoip.db` / `geosite.db`（MetaCubeX/meta-rules-dat，`latest`） | 这是**数据文件**不是可执行代码，且必须跟随上游持续更新（新增域名/线路）。冻结它会让分流规则过期。风险等级远低于可执行脚本 |
| 版本横幅读取（`yonggekkk/sing-box-yg/main/version`） | 仅用于显示文字，不参与任何执行 |

## 六、`vendor/` 路径解析（2026-09-12 已解决）

`lib/boot.sh` 自举时会把 `vendor/` 一并落到 `/usr/local/lib/vpnmax/vendor/`，
而 `fetch_sb_sh()` 的查找链本就把该绝对路径列在最后一个候选：

```
${SCRIPT_DIR}/vendor → ./vendor → $(dirname $BASH_SOURCE)/../vendor → /usr/local/lib/vpnmax/vendor
```

所以"优先用本地件"在单文件部署下**已真正生效**；只有文件缺失时才回退到自家 raw
（`SB_URL`，指向本仓 `vendor/sb.sh`，非上游），两条路都必须过 SHA256 校验。
