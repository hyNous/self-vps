# 自建 VPS 代理与监控方案

本文档整理自建 VPS 代理与监控方案，区分**原始完整目标**、**当前已部署架构**、**已完成验证**、**暂缓事项**和**后续待办**。当前生产环境使用腾讯云首尔 VPS、Xray Trojan + TLS、Nginx、BBR、Beszel、Uptime Kuma 与 Cloudflare Tunnel。
仓库按无凭据标准维护：不写入真实密码、Token、Key、私钥、订阅地址或 Push URL。

---

## 1. 原始完整目标

原始目标是把代理入口、住宅出口、订阅分发、证书续期与应用同步集中在一台 VPS 上管理，同时保证代理服务与同步服务逻辑隔离。

```text
本地设备
├─ Windows / FlClash
├─ 手机 Clash / Mihomo
└─ 其他 Clash.Meta / Mihomo 客户端
        │
        ├─ 主链路：本地直连 VPS
        │
        └─ 备用链路：机场节点前置后再连接 VPS
        ▼
腾讯云首尔 VPS
Ubuntu 24.04
        │
        ├─ Xray
        │   ├─ Trojan + TLS 443 入站
        │   ├─ 主出站：ProxyCheap RES-2
        │   └─ 备用链路最终出口仍为 RES-2
        │
        ├─ Nginx
        │   ├─ 网站
        │   ├─ Clash/Mihomo 订阅文件
        │   └─ Certbot webroot 验证
        │
        ├─ Certbot
        │   └─ TLS 证书自动续期
        │
        ├─ PocketBase
        │   └─ SparkFlow 账号与同步数据
        │
        └─ Cloudflare Tunnel
            └─ 对外暴露 SparkFlow 同步服务
```

### 1.1 目标代理链路

**主链路**

```text
本地 Clash / Mihomo
  → Trojan + TLS 443
  → node.example.com
  → 腾讯云首尔 VPS / Xray
  → ProxyCheap RES-2
  → 美国住宅 IP 出口
```

**备用机场前置链路**（本地直连 VPS 不稳定时使用；机场仅作前置，最终出口仍为 RES-2）

```text
本地 Clash / Mihomo
  → 备用机场节点
  → 腾讯云首尔 VPS / Xray
  → ProxyCheap RES-2
  → 美国住宅 IP 出口
```

### 1.2 目标服务分层

| 层级 | 组件 | 职责 |
|---|---|---|
| 代理 | Xray Trojan + TLS、住宅出站 | 认证、加密、转发、美国住宅出口 |
| 订阅 | Nginx 订阅 YAML | 多设备统一拉取配置、节点参数集中维护 |
| 证书 | Certbot + webroot | Let's Encrypt 签发与自动续期，续期后重载 Xray 证书 |
| 同步 | PocketBase + Cloudflare Tunnel | SparkFlow 账号与配置同步（与代理逻辑隔离） |

---

## 2. 当前已部署架构

当前阶段先验证域名、TLS、Xray、Nginx 与客户端连通性，使用**首尔 VPS 直出**，暂不接入 ProxyCheap RES-2，也未部署 SparkFlow 同步服务。

```text
Windows / FlClash
        │
        │ Trojan + TLS
        ▼
node.example.com:443
        │
        ▼
腾讯云首尔 VPS（Ubuntu 24.04）
        │
        ├─ Xray freedom ── 首尔 VPS 直接出站
        ├─ Linux BBR + fq_codel ── 优化高延迟 TCP 吞吐
        ├─ Nginx 80 / 127.0.0.1:8080 fallback
        ├─ Certbot 证书与自动续期
        ├─ Docker
        │   ├─ Beszel Hub + Agent
        │   └─ Uptime Kuma
        └─ Cloudflare Tunnel ── monitor.example.com / status.example.com
```

### 2.1 域名与角色

| 域名 | 用途 | 状态 |
|---|---|---|
| `node.example.com` | Xray Trojan + TLS 代理入口 | 已完成 |
| `example.com` | 测试站点 | 已完成 |
| `monitor.example.com` | Beszel VPS 性能监控 | 已完成 |
| `status.example.com` | Uptime Kuma 服务可用性监控 | 已完成 |
| `sub.example.com` | 预留订阅分发 | 未完成 |
| `sync.example.com` | 预留 SparkFlow 同步 | 未完成 |

### 2.2 本机绑定端口

| 端口 | 服务 |
|---|---|
| `22` | SSH |
| `80` | Nginx（ACME + 站点） |
| `443` | Xray Trojan + TLS |
| `127.0.0.1:8080` | Nginx fallback（非公网开放） |
| `127.0.0.1:8090` | Beszel Hub（仅本机） |
| `127.0.0.1:3001` | Uptime Kuma（仅本机） |

`monitor.example.com` 与 `status.example.com` 经 Cloudflare Tunnel 访问本机服务，**无需**在 UFW 或云防火墙开放 `8090` / `3001`。

### 2.3 监控与客户端职责

| 组件 | 职责 |
|---|---|
| **Beszel** | VPS CPU、内存、硬盘、网络、容器等性能与资源数据（`monitor.example.com` → `127.0.0.1:8090`） |
| **Uptime Kuma** | Xray、Nginx、域名、HTTPS 与证书可用性监控及到期提醒（`status.example.com` → `127.0.0.1:3001`） |
| **FlClash** | Windows 端节点选择、实时延迟与手动测速（当前不依赖计划任务探测） |
| **Cloudflare Tunnel** | 将本机 Beszel / Uptime Kuma 安全暴露为监控域名，连接器 `vps-monitor` 状态 Healthy |

Beszel 可以查看 VPS 网卡的实时与历史流量，但统计包含 Xray、Cloudflare Tunnel 和其他服务，不能作为 Xray 节点的按用户流量审计。当前未启用 Xray API/Stats，因此不能按客户端追溯代理用量或访问目标。

### 2.4 与原始方案的差异

| 项目 | 原始方案 | 当前实际 |
|---|---|---|
| VPS | 腾讯云首尔 Ubuntu 24.04 | 相同 |
| 入口 | `node.example.com` Trojan + TLS 443 | 相同 |
| 最终出口 | ProxyCheap RES-2 | 首尔 VPS 直出 |
| 备用机场前置 | 计划保留 | 未完成 |
| 订阅分发 | Nginx | 未完成 |
| PocketBase / SparkFlow | 计划部署 | 未部署（Beszel 内部 PocketBase 不计） |
| Cloudflare Tunnel | 计划用于同步服务 | 监控连接器与两监控域名已完成；同步未完成 |
| 性能监控 | 原方案未单列 | Beszel 已完成 |
| 可用性监控 | 原方案未单列 | Uptime Kuma 已完成 |
| TCP 拥塞控制 | 原方案未单列 | BBR 已永久启用，保留 `fq_codel` |

---

## 3. 已完成验证

快照日期：2026-07-22。

### 3.1 基础设施与代理

- [x] 腾讯云首尔 Ubuntu 24.04 VPS（约 2 核 / 2 GiB / 50 GiB）
- [x] 域名 `example.com`、`node.example.com`；DNS 指向示例地址 `203.0.113.10`
- [x] Nginx、Certbot、Xray、UFW
- [x] Nginx `80` 与 `127.0.0.1:8080` fallback
- [x] `node.example.com` TLS 证书；复制至 Xray 目录并修复私钥权限
- [x] Xray Trojan + TLS 443、`alpn: http/1.1`、`freedom` 首尔直出
- [x] 普通 HTTPS 请求 fallback 到 Nginx
- [x] Xray 监听 443；Nginx 监听 80 与 `127.0.0.1:8080`
- [x] Certbot 自动续期部署钩子；`certbot renew --dry-run --run-deploy-hooks` 通过
- [x] VPS 重启后 SSH、Nginx、Xray、Certbot 自动恢复
- [x] 腾讯云公网峰值带宽确认为 30 Mbps
- [x] BBR A/B 测试完成并永久启用；重启后自动恢复
- [x] KVM VPS 禁用无实际用途且版本不匹配的 `fwupd-refresh.timer`

### 3.2 客户端

- [x] FlClash 通过 `Seoul-Trojan` 连接 VPS
- [x] 混合端口与系统代理可用
- [x] 出口 IP 验证为示例地址 `203.0.113.10`（首尔直出）

### 3.3 监控栈

- [x] Docker Engine 与 Docker Compose
- [x] Beszel Hub + 本机 Agent；实时性能数据正常
- [x] Uptime Kuma（含 Xray 443、Nginx 80、`node.example.com` HTTPS 与证书到期提醒）
- [x] Cloudflare Tunnel 连接器 Healthy，systemd 已启用
- [x] `monitor.example.com` / `status.example.com` 可访问
- [x] Beszel 与 Uptime Kuma 仅绑定本机回环地址
- [x] VPS 重启后 Beszel、Beszel Agent、Uptime Kuma 和 Cloudflare Tunnel 自动恢复

### 3.4 运行状态快照

| 项目 | 状态 | 说明 |
|---|---|---|
| VPS / SSH | 正常 | 首尔 Ubuntu 24.04；TCP 22，UFW 已放行 |
| Nginx | 正常 | 80 + `127.0.0.1:8080` |
| Xray | 正常 | Trojan + TLS 443，首尔直出 |
| TLS | 正常 | Certbot 定时器与 Xray 部署钩子已验证 |
| FlClash | 正常 | `Seoul-Trojan`，出口示例地址 `203.0.113.10` |
| Docker | 正常 | Engine 29.6.1，Compose 5.3.1 |
| Beszel | 正常 | Hub + Agent |
| Uptime Kuma | 正常 | 2.4.0，SQLite |
| Cloudflare Tunnel | 正常 | `vps-monitor` Healthy |
| TCP 拥塞控制 | 正常 | BBR；`fq_codel`；重启后已验证 |
| fwupd 刷新 | 已禁用 | KVM VPS 无需访客系统刷新物理固件；避免版本不匹配反复报错 |
| Cloudflare Access | **暂缓** | 见第 4 节 |
| Windows VPN 探测脚本 | **暂缓** | 见第 4 节 |

### 3.5 网络性能优化验证

首尔到本地的链路平均延迟约 124 ms，测试期间最高达到 285 ms。VPS 本机网络与 Nginx 读取正常，但 CUBIC 在慢速时段的单连接吞吐明显不足。保持同一目标、文件大小和测试时段进行 A/B 对照后，BBR 的改善可重复：

| 测试 | 下载速度 | 说明 |
|---|---:|---|
| CUBIC 复测 | 约 3.46 Mbps | 高延迟回程下吞吐不足 |
| 临时 BBR | 约 14.14 Mbps | 运行时切换测试 |
| 持久 BBR | 约 14.08 Mbps | 写入配置后的最终测试 |

BBR 相比 CUBIC 提升约 4.1 倍，但不能突破腾讯云 30 Mbps 峰值带宽，也不能消除运营商路由和晚高峰拥塞。生产配置保持 `fq_codel`，未额外调整 TCP 缓冲区或 Xray 协议。

---

## 4. 暂缓事项

以下事项**明确暂缓**，不是遗漏：

| 事项 | 原因 / 当前替代 |
|---|---|
| **Windows 定时 VPN 探测脚本** | 当前个人使用；FlClash 仪表盘可手动测速与测延迟。若后续需要历史记录、远程查看或自动故障通知，再考虑 Uptime Kuma Push 等方案。 |
| **Cloudflare Access 邮箱验证码** | 监控站目前依赖应用自身账号保护；Access 邮箱验证码保护保留为后续待办。 |

---

## 5. 后续待办

### 5.1 当前阶段剩余

- [ ] 解决 Windows DNS 超时
- [ ] 配置 / 评估 FlClash DoH

### 5.2 完整方案剩余

- [ ] 接入 ProxyCheap RES-2（SOCKS5 或 HTTP 出站），确认美国住宅出口 IP
- [ ] 配置备用机场前置与 Clash/Mihomo 链式代理（最终出口仍为 RES-2）
- [ ] Nginx 订阅文件与订阅自动更新
- [ ] 部署 PocketBase（数据目录与备份）及 SparkFlow 独立同步域名与接口
- [ ] 验证代理服务与同步服务隔离
- [ ] 为 `monitor.example.com`、`status.example.com` 配置 Cloudflare Access 邮箱验证码保护
- [ ] 日志轮转与自动备份
- [ ] 后续评估 Trojan → VLESS + Flow / Seed

### 5.3 建议推进顺序

1. 观察 Beszel、Uptime Kuma 与 Cloudflare Tunnel 稳定性
2. 需要时为监控域名增加 Cloudflare Access
3. 修复或绕过 Windows DNS 超时，评估 FlClash DoH
4. 准备 ProxyCheap RES-2 参数并测试住宅出站
5. 备用机场前置链路
6. 订阅分发
7. PocketBase + SparkFlow 同步
8. 自动备份

---

## 6. 部署参考（当前阶段）

以下内容仅作运维参考；**密码与 Token 均为占位符**，不得填入真实值后提交。

### 仓库获取与部署边界

```powershell
git clone https://github.com/hyNous/self-vps.git
cd self-vps
```

克隆得到的是无凭据运维文档和忽略规则，不是可从零安装生产环境的一键部署包。仓库不包含 Xray、Nginx、Docker Compose、systemd 或 Cloudflare Tunnel 的真实生产配置，也故意不提供 `.env.example`；不存在 `cp .env.example .env` 配置步骤。本文中的配置均为占位示意，当前生产环境依赖已经在 VPS 上完成的人工部署。全新服务器安装、数据恢复和无停机迁移尚未形成可验证的自动化流程。

首次访问 Beszel 和 Uptime Kuma 时使用应用内已经创建的账号；初始账号、密码和修改密码流程不写入仓库。若账号交给新维护者，应在应用界面完成凭据轮换，并确认 Cloudflare Tunnel 与应用自身登录保护正常。

常用 systemd 运维命令如下；将变量改为 `xray`、`nginx`、`docker` 或 `cloudflared` 后按需单独操作：

```bash
SERVICE=xray
sudo systemctl start "$SERVICE"
sudo systemctl stop "$SERVICE"
sudo systemctl restart "$SERVICE"
sudo systemctl status "$SERVICE" --no-pager
sudo journalctl -u "$SERVICE" -n 100 --no-pager
```

容器状态与日志：

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
CONTAINER=uptime-kuma
sudo docker logs --tail 100 "$CONTAINER"
```

升级前必须先确认服务健康、记录当前版本，并备份配置、证书引用和应用数据；自动备份与经过演练的恢复流程仍是待办。升级后应复查端口、服务、容器、域名和代理出口。发生故障时优先回滚单项配置或镜像版本；涉及系统级变更时使用升级前的腾讯云快照恢复。仓库当前不提供数据库或整机恢复命令，因此不能宣称具备自动回滚能力。

### 6.1 登录

```powershell
ssh ubuntu@203.0.113.10
```

```bash
sudo -i
```

### 6.2 端口检查

```bash
ss -lntp | grep -E ':(22|80|443|3001|8080|8090)\b'
```

### 6.3 Nginx（示意）

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name example.com www.example.com node.example.com sub.example.com sync.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
    }

    location / {
        root /var/www/hynous;
        index index.html;
        try_files $uri $uri/ =404;
    }
}

server {
    listen 127.0.0.1:8080;

    server_name node.example.com;

    root /var/www/hynous;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

### 6.4 Xray（示意，密码为占位符）

```json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "REPLACE_WITH_YOUR_TROJAN_PASSWORD",
            "email": "hyn-main"
          }
        ],
        "fallbacks": [
          {
            "dest": "127.0.0.1:8080",
            "xver": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "node.example.com",
          "alpn": [
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "/usr/local/etc/xray/cert/fullchain.pem",
              "keyFile": "/usr/local/etc/xray/cert/privkey.pem"
            }
          ],
          "minVersion": "1.2"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
```

### 6.5 FlClash 客户端（示意，密码为占位符）

```yaml
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false

proxies:
  - name: Seoul-Trojan
    type: trojan
    server: 203.0.113.10
    port: 443
    password: "REPLACE_WITH_YOUR_TROJAN_PASSWORD"
    sni: node.example.com
    skip-cert-verify: false
    udp: true

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - Seoul-Trojan
      - DIRECT

rules:
  - MATCH,PROXY
```

导入：FlClash → 配置 → 从文件导入 → 选择 YAML → 选 `PROXY` / `Seoul-Trojan` → 开启系统代理。

```powershell
curl.exe -x http://127.0.0.1:7890 https://api.ipify.org
```

已验证选择 `Seoul-Trojan` 时返回示例地址 `203.0.113.10`（Windows → FlClash → Xray → 首尔直出）。

### 6.6 BBR 状态、持久化与回滚

持久配置：

```text
/etc/modules-load.d/bbr.conf
/etc/sysctl.d/99-bbr.conf
```

状态检查：

```bash
sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc
lsmod | grep '^tcp_bbr'
```

当前预期值为 `bbr`、可用算法包含 `bbr`、默认队列为 `fq_codel`。回滚时删除两个专用配置文件并恢复 CUBIC：

```bash
sudo rm -f /etc/modules-load.d/bbr.conf /etc/sysctl.d/99-bbr.conf
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
```

`fwupd-refresh.timer` 已在 KVM VPS 上禁用。它不影响常规 APT 安全更新；如未来迁移到需要访客系统管理物理固件的机器，应重新评估并修复 `fwupd` 软件包版本后再启用。

---

## 7. 安全与发布约定

**禁止提交或写入仓库：**

```text
Trojan 密码
ProxyCheap 用户名和密码
机场订阅地址
SSH 私钥
TLS 私钥
PocketBase 管理员账号
Cloudflare Tunnel Token
Beszel Token 和 Key
Uptime Kuma 管理员账号
Uptime Kuma Push URL
本地客户端完整配置（如 local-client.yaml）
Beszel 本地凭据文件（如 beszel.txt）
```

**公开或仓库内配置统一使用占位符：**

```text
REPLACE_WITH_YOUR_TROJAN_PASSWORD
PROXYCHEAP_HOST
PROXYCHEAP_USERNAME
PROXYCHEAP_PASSWORD
CLOUDFLARE_TUNNEL_TOKEN
```

本地敏感文件应由 `.gitignore` 排除，即使目标为私有仓库也不得放宽无凭据标准。

---

## 8. License

本仓库当前为私有运维资料，尚未指定开源许可证。除非仓库所有者另行授权，不授予复制、再分发或商用许可。
