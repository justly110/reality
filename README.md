# Xray-Reality 极简部署与管理指南

本项目使用 Xray内核 部署Reality 一键管理脚本，支持一键安装、修改配置及查看节点，支持Debian/Ubuntu以及Alpine。
---

## 1. 一键部署安装

在 VPS 终端（Root 用户）中直接执行以下命令进行安装(v4 v6端口均为443)：

```bash
bash <(wget -qO- -o- https://github.com/justly110/reality/raw/main/xray.sh)
```

低内存机器使用下面命令安装(内存小于512M NAT专用 v4端口30333 v6端口30334)：

```bash
bash <(wget -qO- -o- https://github.com/justly110/reality/raw/main/xray-low.sh)
```

> **注意**：如果系统提示缺少 `wget`，可先执行 `apt update && apt install -y wget`（Debian/Ubuntu）或
`apk update && apk add wget`（Alpine）。

---

## 2. 打开后台管理面板

部署完成后，在终端随时输入以下命令即可呼出管理菜单：

```bash
xray
```

管理菜单主界面预览：
```text
==========================================
       Xray-Reality 极简后台管理          
==========================================
服务状态: ● 正在运行 (Running)
------------------------------------------
 1. 重启 Xray
 2. 启动 Xray
 3. 停止 Xray
 4. 查看节点链接及配置 (IPv4 + IPv6)
 5. 修改节点配置 (端口/SNI/UUID/密钥)
 6. 查看运行日志
 7. 彻底卸载 Xray
 0. 退出菜单
==========================================
```

---

## 3. 常用操作速查

* **查看节点链接**：在管理菜单输入 `4`，复制生成的 `vless://` 链接直接导入客户端（v2rayN、Sing-box、Clash 等）。
* **修改伪装与端口**：在管理菜单输入 `5`。
* **查看运行日志**：在管理菜单输入 `6`（排查连接异常与探测）。

---

## 4. 最佳配置建议（防封与防断连）

| 配置项 | 推荐值 | 说明 |
| :--- | :--- | :--- |
| **监听端口 (Port)** | `443` | HTTPS 标准默认端口，与 SNI 伪装最契合，抗封锁效果最好 |
| **伪装域名 (SNI)** | `addons.mozilla.org` | 火狐插件官方站，具备大厂白名单属性，支持 TLS 1.3 + H2 |
| **目标地址 (dest)** | `addons.mozilla.org:443` | 证书体积极小（约 4.4KB），杜绝 Xray 8KB 缓冲区崩溃问题 |
