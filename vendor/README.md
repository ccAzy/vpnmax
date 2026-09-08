# vendor/ — vpnmax 融合依赖（零上游调用）

| 文件 | 来源 | 版本 pin | SHA256 |
|---|---|---|---|
| `sb.sh` | `ccAzy/sing-box-yg` commit `5001e76e`（与 `yonggekkk/sing-box-yg` 同 commit 字节一致，已实测） | 见 `SB_COMMIT` | `65113dd4…f36b`（见 `SB_SHA256`） |

规则：

1. 部署优先使用本目录 `sb.sh`，安装时仍做 SHA256 校验（纵深防御）。
2. 本目录缺失时（如 curl 裸装单文件模式）回退到**自家** `ccAzy/vpnmax` raw，
   绝不调上游 `yonggekkk`。同样 SHA256 校验。
3. 升级 sb 时：更新本文件 + 同步 `SB_COMMIT`/`SB_SHA256` 两个常量，
   否则校验失败拒绝安装（有意设计）。
4. 该 fork 已原生支持 `/etc/s-box/argo-extra.conf`
  （Argo 附加参数，如 `--region`），与 `lib/edgeprefer.sh` 对接。
