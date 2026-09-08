# vendor/ — vpnmax 融合依赖（零上游调用）

| 文件 | 来源 | 版本 pin | SHA256 |
|---|---|---|---|
| `sb.sh` | `ccAzy/sing-box-yg` commit `5001e76e`（与 `yonggekkk/sing-box-yg` 同 commit 字节一致，已实测）+ vpnmax 本地 patch（禁自更新/vendor 隔离） | 见 `SB_COMMIT` | `46faf59b…03c77`（见 `SB_SHA256`） |

规则：

1. 部署优先使用本目录 `sb.sh`，安装时仍做 SHA256 校验（纵深防御）。
2. 本目录缺失时（如 curl 裸装单文件模式）回退到**自家** `ccAzy/vpnmax` raw，
  绝不调上游 `yonggekkk`。同样 SHA256 校验。
3. 升级 sb 时：更新本文件 + 同步 `SB_COMMIT`/`SB_SHA256` 两个常量，
  否则校验失败拒绝安装（有意设计）。
4. 该 fork 已原生支持 `/etc/s-box/argo-extra.conf`
  （Argo 附加参数，如 `--region`），与 `lib/edgeprefer.sh` 对接。
5. **已 patch（禁上游污染）**：
  - `lnsb()` / `upsbyg()` → 空操作，禁止 sb.sh 从上游自更新覆盖 vendor 版本
  - `inssbwpph()` → 优先 `vendor/sbwpph_*`，缺失才回退上游
  - `acme()` / L313 acme 调用 → 优先 `vendor/acme.sh`，缺失才回退上游
  - `cfwarp()` → 优先 `vendor/CFwarp.sh`，缺失才回退上游
  - `bbr()` → 优先 `vendor/bbr.sh`，缺失才回退上游

## 待补充 vendor 文件（按需下载 pin 版）

| 文件 | 来源 | 用途 |
|---|---|---|
| `acme.sh` | `yonggekkk/acme-yg` | ACME 证书申请 |
| `CFwarp.sh` | `yonggekkk/warp-yg` | WARP 安装 |
| `bbr.sh` | `teddysun/across` | BBR 开启（vpnmax 已自建，此为备用） |
| `sbwpph_amd64` / `sbwpph_arm64` | `yonggekkk/sing-box-yg` | WARP-socks5 代理二进制 |
