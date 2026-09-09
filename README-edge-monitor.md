# VPNMax Edge Monitor

Argo 隧道质量监控 + 自动重选系统

## 功能特性

- ✅ **自动优选**：集成 CloudflareSpeedTest，自动选择最优边缘节点
- ✅ **质量监控**：定期检查隧道延迟和速度
- ✅ **自动切换**：质量不达标时自动重新优选并重启隧道
- ✅ **流量控制**：轻量检查为主，速度测试为辅，日消耗约 50KB
- ✅ **防抖动**：连续失败 N 次才触发重启，避免误判

## 架构设计

```
┌─────────────────────────────────────────────────────────┐
│                    Edge Monitor 系统                     │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────┐ │
│   │  优选模块     │ →  │  写入模块     │ →  │ 监控模块  │ │
│   │ (调用 CFST)  │    │ (argo.conf)  │    │ (保活)   │ │
│   └──────────────┘    └──────────────┘    └──────────┘ │
│          ↑                                     │        │
│          │             ┌──────────────┐        │        │
│          └──────────── │  触发模块     │ ←──────┘        │
│                        │ (不达标时)   │                  │
│                        └──────────────┘                  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## systemd 服务架构

```
重启后自动启动顺序：

1. network.target
   ↓
2. sb.service (sing-box)
   ↓
3. cloudflared-argo.service (Argo 隧道)
   ↓
4. vpnmax-edge-monitor.service (质量监控)
```

**关键点：**

- cloudflared 由 systemd 管理，重启后自动启动
- Edge Monitor 监控质量，不直接管理 cloudflared
- 质量不达标时，Edge Monitor 触发重新优选 → 写入配置 → 重启 systemd 服务

## 三步循环

1. **写入**：CFST 优选结果 → `argo-extra.conf`
2. **扫描**：定期检查隧道质量（延迟/colo/速度）
3. **循环**：不达标 → 重新调用 CFST → 写入 → 继续循环

## 安装

```bash
# 一键安装
bash install-edge-monitor.sh install

# 查看状态
bash install-edge-monitor.sh status

# 卸载
bash install-edge-monitor.sh uninstall
```

## 使用

### 服务管理

```bash
# 启动服务
systemctl start vpnmax-edge-monitor

# 停止服务
systemctl stop vpnmax-edge-monitor

# 重启服务
systemctl restart vpnmax-edge-monitor

# 查看状态
systemctl status vpnmax-edge-monitor

# 查看日志
journalctl -u vpnmax-edge-monitor -f
```

### 手动测试

```bash
# 快速检查 (<1KB)
/usr/local/sbin/vpnmax-speed-test.sh --quick

# 完整测试 (~5MB)
/usr/local/sbin/vpnmax-speed-test.sh --full

# 只测延迟
/usr/local/sbin/vpnmax-speed-test.sh --latency

# 只测速度
/usr/local/sbin/vpnmax-speed-test.sh --speed

# 获取当前 colo
/usr/local/sbin/vpnmax-speed-test.sh --colo
```

### 手动触发优选

```bash
# 手动触发优选
/usr/local/sbin/vpnmax-edge-monitor.sh --optimize
```

## 配置

### 阈值配置

编辑 `/usr/local/sbin/vpnmax-edge-monitor.sh` 中的配置：

```bash
LATENCY_THRESHOLD=500      # 延迟上限 (ms)
SPEED_THRESHOLD=100        # 速度下限 (Mbps)
CHECK_INTERVAL=180         # 检查间隔 (秒)
MAX_FAIL_COUNT=3           # 连续失败 N 次才重启
COOLDOWN=300               # 重启后冷却 (秒)
```

### 优选策略

**速度优先，延迟折中**：

1. 速度必须 >= 100Mbps
2. 延迟必须 <= 500ms
3. 在满足条件的 IP 中，优先选速度最快的
4. 速度相同时，选延迟最低的

**评分公式**：`score = speed_mbps * 1000 - latency_ms`

- 速度权重远大于延迟（1000倍）
- 速度相同时，延迟低的得分更高

### 状态文件

```bash
# /etc/s-box/edge-monitor.state
LAST_GOOD_COLO=LAX          # 上次达标的 colo
LAST_GOOD_IP=172.64.32.1    # 上次达标的 IP
LAST_TEST_TS=1695000000     # 上次测试时间戳
LAST_SPEED=85.5             # 上次速度 (Mbps)
FAIL_COUNT=0                # 连续失败次数
LAST_RESTART_TS=1695000000  # 上次重启时间
```

## 流量消耗

| 检查类型 | 频率 | 单次流量 | 日消耗 |
| ---------- | ------ | ---------- | -------- |
| 轻量检查 (ping/连接) | 每 3 分钟 | <1KB | ~50KB |
| 速度检查 | 仅触发时 | 1-5MB | 视情况 |
| **总计 (正常)** | - | - | **~50KB/天** |
| **总计 (频繁触发)** | - | - | **~50-200MB/天** |

## 日志

```bash
# 监控日志
tail -f /etc/s-box/edge-monitor.log

# 速度测试日志
tail -f /etc/s-box/speed-test.log

# Argo 隧道日志
tail -f /etc/s-box/argo.log
```

## 故障排查

### 服务无法启动

```bash
# 检查依赖
which curl jq bc

# 检查状态文件
ls -la /etc/s-box/edge-monitor.*

# 查看详细日志
journalctl -u vpnmax-edge-monitor -n 100 --no-pager
```

### 隧道频繁重启

```bash
# 检查冷却时间
grep LAST_RESTART_TS /etc/s-box/edge-monitor.state

# 临时禁用监控
systemctl stop vpnmax-edge-monitor
```

### 速度测试失败

```bash
# 手动测试
/usr/local/sbin/vpnmax-speed-test.sh --full

# 检查网络
curl -I https://speed.cloudflare.com
```

## 文件说明

| 文件 | 说明 |
| ------ | ------ |
| `vpnmax-edge-monitor.sh` | 主监控脚本 |
| `vpnmax-speed-test.sh` | 速度测试工具 |
| `vpnmax-edge-monitor.service` | systemd 服务文件 |
| `install-edge-monitor.sh` | 安装脚本 |
| `/etc/s-box/edge-monitor.state` | 状态文件 |
| `/etc/s-box/edge-monitor.log` | 监控日志 |
| `/etc/s-box/speed-test.log` | 测试日志 |
| `/etc/s-box/argo-extra.conf` | 优选配置 |
| `/usr/local/bin/cfst` | CloudflareSpeedTest 二进制 |

## 更新日志

### v1.0.0 (2026-09-09)

- ✅ 初始版本
- ✅ 自动优选 (集成 CFST)
- ✅ 质量监控 (延迟/速度/colo)
- ✅ 自动切换 (不达标时重启)
- ✅ 流量控制 (轻量检查为主)
- ✅ 防抖动 (连续失败才重启)
- ✅ 冷却机制 (避免频繁重启)
