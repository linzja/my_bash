# my_bash

## nextTrace
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linzja/my_bash/main/nexttrace.sh) 1.1.1.1
```

## remove komari
```bash
sudo bash <(curl -s https://raw.githubusercontent.com/linzja/my_bash/main/remve_komari.sh)

sudo bash <(wget -qO- https://raw.githubusercontent.com/linzja/my_bash/main/remve_komari.sh)
```

## Swap 与端口流量监控

`server-tool.sh` 提供：

- 仅管理 `/swapfile` 的 Swap 创建、调整、删除和推荐容量
- 使用 nftables 按单端口、端口范围或端口组统计 TCP/UDP 入站与出站流量
- 在 DNAT 前和反向 NAT 后计数，兼容普通转发与 Docker 端口映射
- systemd 或 Alpine OpenRC 下每 5 分钟保存计数，重启后恢复
- 原子更新规则、严格校验快照，并拒绝互相重叠的端口配置
- 在 Debian/Ubuntu amd64 上安装 XanMod BBR v3 内核并启用 `fq`
- 安装 UFW，启用前自动放行当前 SSH 端口与 TCP 22
- 安装 Fail2ban 保护 SSH 22，并统计近期失败登录的 IP 来源和次数
- 下载并运行 singbox-lite 的 `sb` 管理脚本
- 一键安装 Docker Engine、Compose 插件并启用系统服务

```bash
sudo bash server-tool.sh
```

执行后会进入中文交互式菜单，可直接选择 Swap 管理或端口流量监控，无需记忆命令。也可以使用下面的命令行方式：

```bash
sudo bash server-tool.sh swap status
sudo bash server-tool.sh swap set 2048

sudo bash server-tool.sh traffic add 443 HTTPS
sudo bash server-tool.sh traffic add 8000-8100 转发端口
sudo bash server-tool.sh traffic add 80,443,8443 Web端口组
sudo bash server-tool.sh traffic list

sudo bash server-tool.sh bbr install
# 重启并进入新内核后：
sudo bash server-tool.sh bbr enable
sudo bash server-tool.sh bbr status

sudo bash server-tool.sh firewall install
sudo bash server-tool.sh firewall allow 443/tcp

sudo bash server-tool.sh fail2ban install
sudo bash server-tool.sh fail2ban status
sudo bash server-tool.sh fail2ban attempts 20
sudo bash server-tool.sh fail2ban whitelist add 203.0.113.10
sudo bash server-tool.sh fail2ban whitelist add 2001:db8::/32
sudo bash server-tool.sh fail2ban whitelist list
sudo bash server-tool.sh fail2ban whitelist del 203.0.113.10

sudo bash server-tool.sh sb install
# 以后再次进入 sb：
sb

sudo bash server-tool.sh docker install
sudo bash server-tool.sh docker status
```

脚本支持 Debian、Ubuntu 和常规 OpenRC Alpine。流量监控只负责统计，不包含计费、限速、配额封锁或到期管理。

### Alpine Linux

脚本必须以 root 身份通过 Bash 运行，不能使用 Alpine 默认的 `/bin/sh`：

```bash
apk add bash nftables util-linux coreutils
bash server-tool.sh
```

在 Alpine 上，脚本会：

- 使用 `apk add --no-progress nftables` 安装缺失的 nftables
- 创建 `/etc/local.d/swap.start`，确保开机启用 `/swapfile`
- 通过 OpenRC 创建并启用 `/etc/init.d/port-traffic-monitor`
- 在 `/etc/crontabs/root` 添加每 5 分钟保存流量快照的任务，并尝试启动 `crond`

脚本会使用 `free`、`flock`、`readlink -f` 和 `stat -c` 等命令，因此建议安装 `util-linux` 和 `coreutils`。精简容器若没有 OpenRC 或完整的内核 nftables 支持，流量监控和开机持久化可能无法正常工作。

BBR v3 的自动内核安装仅支持 Debian/Ubuntu amd64；Alpine 没有对应的通用预编译内核路径，脚本不会把主线内核自带的 BBR v1 错报为 v3。UFW 和 Fail2ban 支持 apt/apk，但容器必须具备防火墙能力和 systemd/OpenRC 服务管理。

Fail2ban 使用 UFW 作为 `banaction`，因此自动封禁与手工防火墙规则可统一通过 UFW 管理。白名单支持单个 IPv4、IPv6 以及 CIDR 网段，持久化保存在 `/etc/port-traffic-monitor/fail2ban-whitelist.conf`，并写入 Fail2ban 的 `ignoreip`。

`sb install` 会从 [0xdabiaoge/singbox-lite](https://github.com/0xdabiaoge/singbox-lite) 下载脚本到 `/usr/local/bin/sb`，优先使用 curl，curl 缺失或下载失败时回退到 wget；安装成功后会立即启动 `sb`。

Docker 在 Debian/Ubuntu 等受支持发行版上使用 Docker 官方便利脚本安装，在 Alpine 上使用 `apk` 安装并通过 OpenRC 启动。Docker 发布的容器端口可能绕过 UFW 入站规则，部署容器前应单独检查 Docker 防火墙策略。
