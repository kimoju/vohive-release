# VoHive Release

VoHive 官方公开分发与运维仓库：提供多架构预编译二进制资产（附带 `SHA256SUMS` 校验清单）、一键安装/升级/卸载脚本以及 `systemd` / OpenWrt `procd` 服务编排文档。

## 项目源码与生态

- 主项目仓库：[https://github.com/kimoju/vohive](https://github.com/kimoju/vohive)
- 相关组件：[`vowifi-go`](https://github.com/kimoju/vowifi-go) · [`quectel-qmi-go`](https://github.com/kimoju/quectel-qmi-go) · [`netlink`](https://github.com/kimoju/netlink) · [`qqbot`](https://github.com/kimoju/qqbot)

## 免责声明

> [!WARNING]
> **重要提示：本软件（VoHive）仅供个人学习、通信技术研究与内部功能测试使用，严禁任何形式的商业使用，严禁将本软件用于任何非法或违规场景。**
>
> 使用者因违反所在地法律法规、电信运营商服务条款或违规使用本软件造成的一切法律责任及后果，均由使用者自行承担，软件作者及贡献者不承担任何责任。下载或使用本软件即表示您已阅读并同意本免责声明。

---

## 功能概览

VoHive 是面向高通 4G/5G 蜂窝模组与智能卡读卡器的一体化管理与测试平台，核心能力包括：

- **多形态硬件统一纳管**：支持 **QMI**、**MBIM**、**AT 串口** 模组及 **PC/SC 智能卡读卡器**（纯静态二进制亦内置原生 `pcscd` 客户端支持）
- **双栈多实例代理**：内置按模组网卡严格绑定（`SO_BINDTODEVICE`）的 `SOCKS5` / `HTTP` 代理服务与实时流量监控
- **网页与机器人收发短信**：支持长短信编解码、多卡会话归档、蜂窝与 IMS USSD 交互
- **实体 eSIM / eUICC (SGP.22 LPA) 管理**：支持通过 AT / QMI / MBIM / PC/SC 通道下载激活、切卡、改名与删卡
- **全渠道推送与双向控制**：支持 **Telegram Bot**、**飞书机器人**、**QQ 官方机器人**、**Webhook**、**Bark**、**Email**、**PushPlus**
- **3GPP VoWiFi / IMS 测试**：在运营商与网络条件满足时建立 SWu/ePDG IPsec 隧道与 IMS 注册，支持短信收发、本地 SIP 软电话桥接及 `/vocall` 模拟外呼测试

---

## 一、适用环境

### 推荐硬件

- **4G / 5G 模组**：移远（Quectel）EC20 / EC25 / EC21 / EG25 / EM20 / RM500Q 等高通芯片方案 USB / M.2 模组（搭配带 SIM 卡槽的 USB 转接底板），或高通 MSM8916（随身 WiFi 刷 Debian / OpenWrt）等设备
- **智能卡读卡器（可选）**：兼容 `pcscd`（CCID）的 USB PC/SC 智能卡读卡器（仅使用读卡器配合实体 SIM/eSIM 进行 eSIM 管理或 VoWiFi 测试时无需蜂窝模组）

### 操作系统与架构

- **系统**：Debian / Ubuntu / Armbian / Raspberry Pi OS（`systemd`）及 OpenWrt（`procd`）
- **架构**：`linux/amd64` (`x86_64`)、`linux/arm64` (`aarch64`)、`linux/armv7` (`armhf`)

---

## 二、ModemManager 与 `pcscd` 说明

- **QMI 模式共存**：VoHive 在 QMI 模式下支持启用 `qmi-proxy` 打开控制口，可与宿主机 `ModemManager` 共用 QMI 通道（注意：同时运行时请勿让双方同时接管同一模组的拨号或 APN 配置）。
- **AT 串口模式**：若使用传统 AT 串口模式，建议在宿主机停用 `ModemManager` 以避免串口抢占。
- **PC/SC 读卡器模式**：宿主机需安装并启动 `pcscd` 服务（如 Debian/Ubuntu 下执行 `sudo apt install -y pcscd && sudo systemctl enable --now pcscd`）。

---

## 三、可选：切换模组 USBNET 工作模式

若模组当前 USB 网络模式不符合预期，可通过串口发送 AT 指令切换（以切回常见 QMI 模式为例）：

```bash
sudo apt update && sudo apt install -y socat
echo 'AT+QCFG="usbnet",0;+CFUN=1,1' | sudo socat - /dev/ttyUSB2,crnl
```

- `AT+QCFG="usbnet",0`：切换为 QMI / RMNET 模式（`2` 为 MBIM 模式）
- `AT+CFUN=1,1`：保存并重启模组生效
- `/dev/ttyUSB2` 仅为示例，请按实际设备的 AT 端口调整

---

## 四、部署方式一：一键脚本安装（推荐）

支持 Linux (`systemd`) 与 OpenWrt (`procd`)，安装器默认会在提权落盘前强制校验发布版本的 `SHA256SUMS` 哈希签名，并采用原子替换避免运行中覆盖报错（`ETXTBSY`）：

```sh
wget -O - https://raw.githubusercontent.com/kimoju/vohive-release/master/install.sh | sh
```

> 同样兼容 `curl -fsSL https://raw.githubusercontent.com/kimoju/vohive-release/master/install.sh | bash`。

### 常用安装与维护选项

```sh
# 安装或升级/回退至指定版本
wget -O - https://raw.githubusercontent.com/kimoju/vohive-release/master/install.sh | sh -s -- --version v1.5.3

# 仅预演打印操作步骤，不修改任何系统文件
wget -O - https://raw.githubusercontent.com/kimoju/vohive-release/master/install.sh | sh -s -- --dry-run

# 仅安装二进制，跳过 systemd / procd 服务注册
wget -O - https://raw.githubusercontent.com/kimoju/vohive-release/master/install.sh | sh -s -- --no-systemd
```

### 卸载

```sh
# 默认安全卸载：停止并移除系统服务与二进制，保留配置 (/opt/vohive/config) 与数据库 (/opt/vohive/data)
wget -O - https://raw.githubusercontent.com/kimoju/vohive-release/master/uninstall.sh | sh

# 彻底卸载并清理数据与日志（如需保留配置可额外加 --keep-config）
wget -O - https://raw.githubusercontent.com/kimoju/vohive-release/master/uninstall.sh | sh -s -- --purge
```

更多运维细节可参阅：
- [快速上手指南 (`docs/quickstart.md`)](docs/quickstart.md)
- [版本升级说明 (`docs/upgrade.md`)](docs/upgrade.md)
- [版本回滚与灾难恢复 (`docs/rollback.md`)](docs/rollback.md)

### 默认安装目录结构（`/opt/vohive`）

- 二进制程序：`/opt/vohive/bin/vohive`（升级自动备份旧版至 `vohive.bak`）
- 配置文件：`/opt/vohive/config/config.yaml`（默认权限 `0600`）
- 数据目录：`/opt/vohive/data`（SQLite 数据库 `vohive.db` 等）
- 日志目录：`/opt/vohive/logs`

---

## 五、部署方式二：Docker / Docker Compose

### 1. 创建目录与配置文件

```bash
mkdir -p vohive/{config,data,logs}
cd vohive

cat > config/config.yaml << 'EOF'
server:
  port: 7575
  debug: false

web:
  username: admin
  password: admin123
EOF
```

### 2. 创建 `docker-compose.yml`

```yaml
services:
  vohive:
    image: kimoju/vohive:latest
    container_name: vohive
    restart: unless-stopped
    network_mode: host
    privileged: true
    volumes:
      - ./config:/app/config
      - ./data:/app/data
      - ./logs:/app/logs
      - /run/pcscd:/run/pcscd
    environment:
      - TZ=Asia/Shanghai
      - CONFIG_PATH=/app/config/config.yaml
    devices:
      - /dev:/dev
```

### 3. 启动并访问后台

```bash
docker compose up -d
```

浏览器访问 `http://你的服务器IP:7575`（首次登录后请及时修改默认密码）。

---

## 六、机器人常用命令（Telegram / 飞书 / QQ）

- `/list`：查看全部已接入设备列表与状态
- `/status [设备ID]`：查看全局或指定设备的详细运行与注册状态
- `/sms <设备ID>`：查看指定设备最近收到的短信
- `/send <设备ID> <号码> <内容>`：发送短信（自动优先复用已激活的 VoWiFi 通道）
- `/rotate <设备ID>`：触发模组重拨切换公网 IP
- `/esim <设备ID>`：查看设备 eSIM Profile 列表
- `/switch <设备ID> <序号或ICCID>`：切换启用指定 eSIM Profile
- `/vocall <设备ID> <号码>`：发起 VoWiFi 无头模拟外呼测试

---

## 七、补充说明

- VoWiFi 可用性取决于运营商策略、SIM/ISIM 卡开通状态以及到运营商 ePDG 的网络连通性（支持在 Web 后台配置按国家分流的上游 SOCKS5 代理）。
- 本程序内置已禁止中国大陆运营商卡发起 VoWiFi，请严格遵纪守法使用。

### 界面预览

![image](https://cdn.nodeimage.com/i/rnGhjMfPlMatrdxQMPogawI3d5OGc1Fu.png)

![image](https://cdn.nodeimage.com/i/GGAj5ua1dK4vZihroXV0pUmT7COonPnQ.png)

![image](https://cdn.nodeimage.com/i/hX90MLQqjmgkaPkZt4Pz4uCM1lHmDBx4.png)

![image](https://cdn.nodeimage.com/i/jbbwBuP1Zu9iPpfZrSsXzftGo0et5i4F.png)

![image](https://cdn.nodeimage.com/i/P7BpZu8fF98622Q3VCZlafg4aBHVM8Qu.png)

![image](https://cdn.nodeimage.com/i/X5Ps5w9AHo1Qas6DDsnxYnbrfYcVhAfV.png)

### 发布频道

https://t.me/vohive_channel

### 交流群

https://t.me/vohive
