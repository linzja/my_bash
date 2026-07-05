# `xldj.sh` 脚本分析

脚本文件：[`xldj.sh`](/Users/lzj/code/my_bash/xldj.sh)

## 一句话结论

这是一个面向 Linux 服务器的代理管理脚本，主线是 `sing-box`，同时内置了 `Xray` 的安装与节点管理入口。它不仅会下载二进制，还会修改服务文件、初始化配置、创建节点、生成链接、做 Argo Tunnel、定时重启和自愈修复。

## 它具体做了什么

### 1. 启动前自举

- 先检查当前是不是 `bash` 环境。
- 如果在 Alpine 上且没有 `bash`，会先尝试切换软件源，再安装 `bash`、`curl`、`wget`、`ca-certificates`、`coreutils`、`openrc`。
- 只支持 Linux，且明确限定 Debian、Ubuntu、Alpine。
- 要求 root 权限。

对应代码：

- Alpine 自举与安装依赖：[`xldj.sh`:1-79](/Users/lzj/code/my_bash/xldj.sh#L1)
- 系统与发行版检查：[`xldj.sh`:173-220](/Users/lzj/code/my_bash/xldj.sh#L173)

### 2. 安装和更新 `sing-box`

- 从 GitHub Releases 获取最新版。
- 自动区分架构和 libc 类型，Alpine 这类 musl 系统会下载 musl 包。
- 解压后把二进制放到 `/usr/local/bin/sing-box`。
- 初始化 `/usr/local/etc/sing-box/` 下的配置文件。
- 创建并重载 `systemd` 或 `OpenRC` 服务。

对应代码：

- `sing-box` 安装：[`xldj.sh`:1348-1416](/Users/lzj/code/my_bash/xldj.sh#L1348)
- `sing-box` 更新与服务恢复：[`xldj.sh`:5032-5066](/Users/lzj/code/my_bash/xldj.sh#L5032)
- 主入口的修复逻辑：[`xldj.sh`:6118-6208](/Users/lzj/code/my_bash/xldj.sh#L6118)

### 3. 安装和更新 `Xray`

- 同样从 GitHub Releases 拉取最新版。
- 安装到 `/usr/local/bin/xray`。
- 初始化 `/usr/local/etc/xray/config.json` 和 `metadata.json`。
- 生成 `systemd` 或 `OpenRC` 服务文件。
- 会压低日志等级，减少低内存机器的压力。

对应代码：

- `Xray` 安装与更新：[`xldj.sh`:5068-5159](/Users/lzj/code/my_bash/xldj.sh#L5068)
- `Xray` 服务文件生成：[`xldj.sh`:5180-5246](/Users/lzj/code/my_bash/xldj.sh#L5180)

### 4. 节点与服务管理

主菜单提供的核心功能包括：

- 添加节点
- 查看节点链接
- 删除节点
- 修改端口
- 重启 / 停止 / 查看状态 / 看日志
- 定时重启
- 检查配置
- 更新脚本
- 卸载脚本

它对 `sing-box` 的节点创建主要是：

- `VLESS (Vision + REALITY)`
- `AnyTLS`
- `Hysteria2`

批量创建也只保留了这几个方向。说明这个脚本对 `sing-box` 的定位是“主代理核心”，不是只做一个启动器。

对应代码：

- 主菜单：[`xldj.sh`:5529-5708](/Users/lzj/code/my_bash/xldj.sh#L5529)
- 添加节点菜单：[`xldj.sh`:5942-6114](/Users/lzj/code/my_bash/xldj.sh#L5942)

### 5. Argo / Cloudflared 隧道

- 会安装 `cloudflared`。
- 支持固定 token 隧道和临时 URL 隧道。
- 为了省资源和避免自动更新挂起，强制使用 `http2`。
- 还带了 watchdog，崩了会尝试恢复。

对应代码：

- `cloudflared` 安装：[`xldj.sh`:1419-1447](/Users/lzj/code/my_bash/xldj.sh#L1419)
- Argo Tunnel 逻辑：[`xldj.sh`:1451-1515](/Users/lzj/code/my_bash/xldj.sh#L1451)

### 6. 自动修复和自愈

脚本不是“装完就完事”，它还会：

- 清理旧版残留配置
- 补 DNS 相关配置
- 修修旧服务文件
- 生成缺失的 `relay.json`
- 刷新动态资源限制

对应代码：

- 初始化和自愈入口：[`xldj.sh`:6142-6208](/Users/lzj/code/my_bash/xldj.sh#L6142)

## 这个脚本的风险点

这类脚本的风险不在“有没有恶意代码”这一层，而在“它对系统的控制面很大”：

- 会写 `/usr/local/bin/`、`/usr/local/etc/`、`/etc/systemd/system/`、`/etc/init.d/`
- 会下载并执行远程脚本和远程二进制
- 会开代理节点、开隧道、改路由、改 DNS、改服务状态
- 如果在生产机上跑，等于把代理栈的生命周期交给这个脚本管理

静态看下来，没有看到明显的账户窃取或数据外传逻辑，但它本身就是高权限运维脚本，不能按普通“安装脚本”看待。

## 问题 1: 为什么叫 `sing-box` 管理脚本，里面还可以 `Xray`，区别是什么

因为它的主设计中心就是 `sing-box`：

- 主菜单标题直接写的是 `sing-box 管理脚本`
- 大部分节点管理、服务管理、自愈逻辑都围绕 `sing-box`
- `Xray` 是后面加进去的附加能力，属于兼容和迁移入口，不是主线
- 甚至在 `Xray` 管理里，还对可创建协议做了限制，只保留少数项

所以名字叫 `sing-box` 管理脚本是合理的，`Xray` 更像是“同一套脚本里的第二核心”。

从脚本实现看：

- `sing-box` 是默认主服务
- `Xray` 只是在菜单里额外提供安装、更新、节点管理
- `Xray` 子菜单还会被脚本二次改写，防止用户创建过多协议

对应代码：

- 主菜单标题：[`xldj.sh`:5542-5546](/Users/lzj/code/my_bash/xldj.sh#L5542)
- `Xray` 入口：[`xldj.sh`:5492-5527](/Users/lzj/code/my_bash/xldj.sh#L5492)
- 限制 `Xray` 创建协议：[`xldj.sh`:5286-5489](/Users/lzj/code/my_bash/xldj.sh#L5286)

## 问题 2: `sing-box` 和 `Xray` 对比

### 简表

| 维度 | sing-box | Xray |
| --- | --- | --- |
| 产品定位 | 通用代理平台 | Project X / Xray-core |
| 设计风格 | 一体化、统一配置、协议面更广 | 更偏 XTLS / REALITY / VLESS 生态 |
| 协议覆盖 | 官方文档首页列出了很多 inbound / outbound / transport 选项 | 官方文档强调 VLESS、XTLS Vision、REALITY，以及与 v2ray 体系的演进关系 |
| 运维体验 | 适合做“一个核心管很多协议” | 适合做兼容性强、生态成熟的传统方案 |
| 这个脚本里的角色 | 主核心 | 辅助核心 |

### 怎么理解差异

- `sing-box` 更像“现代化的统一代理框架”，协议和传输选项很全，适合把多种协议收进同一个管理面。
- `Xray` 更像“Project X 系列的成熟核心”，重点是 VLESS、XTLS Vision、REALITY 这些能力，以及和既有 v2ray / Xray 生态的兼容使用习惯。
- 如果你的目标是多协议统一管理，`sing-box` 更顺手。
- 如果你的目标是传统 Xray 生态、Reality/Vision 方案、既有客户端兼容，`Xray` 仍然很常见。

### 结合这个脚本看

这个脚本显然把 `sing-box` 放在第一位，因为它需要：

- 多协议节点管理
- 自动修复配置
- 更灵活的服务与路由控制

`Xray` 在这里更像“补充兼容层”，而不是主业务核心。

## 参考

- `sing-box` 官方文档首页：<https://sing-box.sagernet.org/>
- `Xray-core` 官方文档首页：<https://xtls.github.io/>
