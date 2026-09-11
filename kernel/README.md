# kernel/ — BBRv3 内核构建工作目录

**这个目录不是补丁/配置的存放处，只是流水线的工作目录。**

## 权威位置（要改就改这里）

| 内容 | 路径 |
| --- | --- |
| BBRv3 补丁（冻结层，pin） | 仓库根 `patches/bbrv3-linux-<ver>.patch` |
| 内核配置基线 | 仓库根 `x86-64.config`、`arm64.config` |
| 构建脚本（打补丁 / max 配置 / 准备 .config / 构建） | 仓库根 `scripts/` |
| 工作流 | 仓库根 `.github/workflows/build-bbrv3.yml` |

> ⚠️ 2026-09-12 之前本目录下曾存在 `patches/`、`scripts/`、`x86-64.config`、`arm64.config`
> 的同名副本。它们是早期"工作流放在 `kernel/` 下"时留下的**死副本**（脚本的 `repo_root`
> 指向仓库根，构建读的也是仓库根那份），两份已经漂移（`CONFIG_RUSTC_VERSION` 109800 vs 109801），
> 且容易让人改错地方。这些副本连同上游 byJoey 的 `install.sh`／`cve_2026_31431_detector.py`
> 副本一并删除。

## 这个目录里会出现什么

工作流在此处 clone 内核源码并编译，以下均为**构建产物，不入仓**（见 `.gitignore`）：

```text
kernel/linux/              # git clone 的 gregkh/linux
kernel/*.deb               # 编译出的 deb 包（只进 GitHub Release）
kernel/build-configs/      # 生成的 .config
kernel/publish-markers/    # 发布标记
kernel/generated-configs/  # 回写基线用的中转目录
kernel/SHA256SUMS
```

## 构建策略

```text
BBRv3 补丁固定（仓库根 patches/），内核自动跟随 kernel.org 最新 stable。
```

`linux-7.x.y` 系列内的小版本更新复用同一个 patch（如 `7.0.11 -> 7.0.12`）。
内核跳到新主线系列而仓库没有对应 patch 时，会回退到最近的旧 patch 并告警，
而不是让整条流水线停摆。

产物发布为 Release，tag 形如 `x86_64-<ver>` / `arm64-<ver>-max`，
部署侧 `deploy_optimize.sh` 默认从本仓 Release 拉取并校验。

上游参考：[byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)（本流水线的移植来源，致谢）。
