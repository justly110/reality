<div align="center">

# ⚡ Xray VLESS-Reality 极速一键部署脚本

轻量 · 高性能 · 深度网络调优 · 极简交互

[![Xray-core](https://img.shields.io/badge/Xray--core-v26.10.21-blue.svg?logo=github)](https://github.com/XTLS/Xray-core)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20Alpine-orange.svg)](#-系统要求)
[![Arch](https://img.shields.io/badge/Arch-x86__64%20%7C%20arm64-lightgrey.svg)](#-系统要求)

</div>

---

## 📖 项目简介

专为 Linux VPS（Debian / Ubuntu / Alpine）打造的 **Xray VLESS-Reality (Vision)** 极速搭建与运维脚本。  
精简优化，纯粹高效。不仅支持快速部署与交互式管理，还内置了**长肥管道网络优化**、**SNI 域名健康体检**、**低内存防 OOM 自动保护**以及**双独立在线升级**等实用特性。

---

## ✨ 核心特性

- 🚀 **深度内核网络调优**：
  - 自动启用 **BBR + FQ** 拥塞控制算法。
  - 深度注入 **32MB TCP 动态缓冲区** 及长肥管道参数，显著提升高延迟、跨洲跨洋线路的吞吐速度。
  - 开启 **TCP Fast Open** 与 **15s TCP KeepAlive**，禁用无用服务端嗅探，降低握手延迟与资源开销。
- 🛡️ **纯粹原生安全**：
  - 基于最新官方规范：`VLESS` + `Reality` + `xtls-rprx-vision`。
  - 默认伪装站点选用 `addons.mozilla.org`，避开被官方封禁告警的敏感域名。
  - 支持**修改 SNI 自动握手体检**：自动验证目标站点是否支持 TLS 1.3 以及证书体积是否安全（防超 8KB 缓冲区）。
- 🖥️ **全终端命令行后台**：
  - 部署完成后直接在终端输入 `xray` 即可呼出多功能交互式管理菜单。
  - 支持随时查看节点链接、修改端口/SNI/密钥/UUID、查看日志与服务管理。
- 📉 **极低资源自适应（小鸡友好）**：
  - 识别物理内存 $\le 256\text{MB}$ 环境，自动注入 Go 运行时内存防 OOM 调优参数，杜绝因瞬时握手导致的内存溢出杀进程。
- 🔄 **双独立在线平滑升级**：
  - 内核（`xray-core`）与管理脚本（`xray.sh`）支持在线独立一键检测与平滑升级，无需重复配置。
- 🌐 **双系统全环境支持**：
  - 完美适配基于 **Systemd** 的发行版（Debian 10+ / Ubuntu 20.04+）。
  - 原生适配基于 **OpenRC** 的超轻量发行版（Alpine Linux）。

---

## 💻 一键安装与使用

### 1. 一键快速安装

在服务器终端中以 `root` 权限运行以下指令即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/justly110/reality/main/xray.sh)
```

> **备用命令（通过 wget）：**
> ```bash
> wget -O xray.sh https://raw.githubusercontent.com/justly110/reality/main/xray.sh && bash xray.sh
> ```

---

### 2. 随时呼出管理面板

安装成功后，脚本已自动注册系统全局命令，在终端任意路径直接输入：

```bash
xray
```

即可进入管理后台：

```text
==========================================
      Xray-Reality 直连节点管理后台       
==========================================
程序版本: 脚本 v0.0.15 | 内核 v26.10.21
服务状态: ● 正在运行 (Running)
------------------------------------------
 1. 重启 Xray
 2. 启动 Xray
 3. 停止 Xray
 4. 查看全部节点链接及详细配置
 5. 修改主节点配置 (端口/SNI/UUID/密钥)
 6. TCP BBR 加速与网络调优
 7. 检查与升级 (Xray内核 / 管理脚本)
 8. 查看运行日志
 9. 彻底卸载 Xray
 0. 退出菜单
==========================================
```

---

## 📁 核心文件与路径说明

| 文件路径 | 说明 |
| :--- | :--- |
| `/usr/local/bin/xray-core` | Xray 核心执行二进制程序 |
| `/usr/local/bin/xray` | 面板快捷管理脚本（终端命令 `xray`） |
| `/usr/local/etc/xray/config.json` | Xray 核心服务端运行配置文件 |
| `/usr/local/etc/xray/params.env` | 当前节点的核心参数持久化环境变量 |
| `/usr/local/etc/xray/link.txt` | 节点直连链接与参数明细备份 |
| `/usr/local/etc/xray/extra_nodes.env`| 多端口/多用户扩展节点记录文件 |

---

## ⚙️ 系统要求

- **操作系统**：
  - Debian 10+
  - Ubuntu 20.04+
  - Alpine Linux 3.16+
- **CPU 架构**：
  - `x86_64` / `amd64`
  - `aarch64` / `arm64`
- **基础依赖**：脚本会自动检查并安装 `curl`、`openssl`、`unzip` 等基础工具。

---

## 📱 客户端兼容性指南

生成的节点链接协议格式为：
```text
vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#节点名称
```

- **v2rayN / v2rayNG / Sing-box / Shadowrocket**：直接导入上方生成的链接即可使用。
- **FlClash / Clash Verge Rev (Mihomo 内核)**：
  - 由于新版 Xray-core（v26.9.8+）强化了对 Chrome 指纹的后量子协商检测，Mihomo 内核需在 `reality-opts` 中包含 `support-x25519mlkem768: true`。
  - 建议搭配配套的订阅转换工具使用以获得最佳兼容性。

---

## ⚠️ 免责声明

- 本项目仅供网络技术学习、科研与管理自身 VPS 使用。
- 请遵守服务器所在地区以及相关法律法规，请勿用于非法用途。
