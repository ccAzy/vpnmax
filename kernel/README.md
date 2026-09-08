# kernel/ — BBRv3 内核自供流水线（vpnmax 融合）

本目录 = `ccAzy/Actions-bbr-v3` 构建系统的移植（BBR 补丁本身仍 pin 在
`patches/`，与老仓一致）。`.github/workflows/build.yml` 每日定时检查
kernel.org 最新稳定版，缺失即构建（x86_64/arm64 × 标准/max）并发 release。

| 文件 | 说明 |
| --- | --- |
| `.github/workflows/build.yml` | 定时构建流水线（路径已适配本仓 `kernel/` 下） |
| `scripts/` | 补丁应用/配置准备/构建脚本 |
| `patches/bbrv3-linux-7.{0,1}.patch` | BBRv3 补丁（pin，不跟官方走）。精确匹配失败时自动回退到最近版本（BBRv3 是独立 TCP 模块，跨版本兼容性好） |
| `arm64.config` / `x86-64.config` | 配置基线（流水线回写更新） |

部署侧（`lib/optimize.sh` / `deploy_optimize.sh`）默认从
`ccAzy/vpnmax` releases 拉 deb；在 vpnmax 首个构建落地前，
`bbr_api_get` 自动桥接回退老仓（warn 标明过渡期），SHA256 强制校验不变。
