# self-vps

在 Ubuntu 24.04 上快速部署 Xray Trojan + TLS 自建代理节点，默认由 VPS freedom 直接出站；Nginx、Let's Encrypt、UFW 和 BBR 随核心节点配置。可选 VLESS+WS over Cloudflare Tunnel 作为直连被阻断时的备用入口；Beszel、Uptime Kuma 与 Cloudflare Tunnel 为监控模块。SSH 支持 key-only 加固。

> **Beta**：模板和脚本经过静态检查，但尚未在一台全新 VPS 上完成端到端安装验证。请先使用测试服务器，并保留云厂商快照和 SSH 控制台。

## 架构

~~~text
FlClash / Mihomo
      │
      ├─ Trojan + TLS 443（直连，可能被路径阻断）
      │     ▼
      │   Xray ──────────────→ freedom / VPS 直接出站
      │     │ fallback
      │     ▼
      │   Nginx 127.0.0.1:8080
      │
      └─ VLESS + WS 443（Cloudflare 边缘）
            ▼
        Cloudflare Tunnel → Nginx 127.0.0.1:8082 → Xray 127.0.0.1:10086

SSH：cloudflared access ssh → ssh.example.com → sshd key-only
监控：Beszel + Uptime Kuma ← Cloudflare Tunnel
~~~

核心部署与当前项目保持一致：

- Ubuntu 24.04 amd64
- Xray Trojan + TLS，监听 TCP 443
- Nginx 监听 TCP 80，并在 127.0.0.1:8080 提供 Xray fallback
- Certbot webroot 续期，部署钩子复制证书并重启 Xray
- UFW 仅放行 SSH、80、443
- BBR + 系统现有队列规则
- 默认 freedom 直出，不包含住宅代理或机场前置
- 可选 VLESS + WS：Xray 仅监听 127.0.0.1:10086，Nginx 127.0.0.1:8082 做 WebSocket 反代和伪装页
- 可选 SSH 加固：只允许公钥，关闭密码和 root SSH
- 可选 Cloudflare Tunnel：暴露 CDN 入口和 SSH，监控面板仍只绑定回环

## 可选：Cloudflare Tunnel + VLESS/WS

当中国大陆到 VPS 公网 IP 的直连 TCP 回程被丢弃时，Trojan 443 和 SSH 22 都可能超时。此时可以让 VPS 主动向 Cloudflare 建立 Tunnel，客户端只连 Cloudflare 边缘：

- `cdn.example.com` → `http://localhost:8082` → Nginx → `127.0.0.1:10086` Xray VLESS/WS
- `ssh.example.com` → `tcp://localhost:22`，必须加 Cloudflare Access
- 监控继续使用 `monitor.example.com` / `status.example.com`

Cloudflare 侧注意：

- `cdn` 的 Service 必须是 `HTTP`，不能填 `https`；8082 是纯 HTTP。
- 不要给 `cdn` 加 Cloudflare Access，否则 VLESS 会被登录页挡住。
- `ssh` 必须加 Access；未加 Access 的公开 TCP SSH 入口风险很高。
- Trojan 443 不要挂到 HTTP 型 Public Hostname；Cloudflare 终止 TLS 后 Xray 会认为不是 Trojan。
- WebSocket 手工测试必须用 HTTP/1.1；HTTP/2 没有 Upgrade 语义，会返回 404。
- Cloudflare 免费线路的速度和 ToS 都有上限，适合作为备用/过渡入口。

## SSH 登录

服务端默认支持 key-only 登录。Cloudflare Tunnel 可用时，本机 `~/.ssh/config`：

~~~sshconfig
Host hynous
    HostName ssh.example.com
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ProxyCommand "C:/Program Files (x86)/cloudflared/cloudflared.exe" access ssh --hostname %h
    ServerAliveInterval 30
    ServerAliveCountMax 3
~~~

然后直接：

~~~bash
ssh hynous
sudo -i   # 需要 root 操作时
~~~

密码登录和 root SSH 默认关闭；`ubuntu` 通过 NOPASSWD sudo 提权。OrcaTerm / 腾讯云 VNC 作为 break-glass。若给 `ssh.example.com` 加了 Cloudflare Access，`cloudflared access ssh` 会要求 OTP 或 Service Token。

## 准备条件

- 一台全新的 Ubuntu 24.04 amd64 VPS，建议至少 1 vCPU / 1 GiB 内存
- 一个已经解析到该 VPS 的域名
- 云防火墙允许 SSH、TCP 80 和 TCP 443
- 可用的 sudo/root 权限
- 安装期间 TCP 80 和 443 没有被其他服务占用

脚本不会配置云厂商防火墙，也不会自动修改 DNS。若发现现有 Xray 或本项目 Nginx 配置不属于本仓库管理，安装会停止，避免覆盖生产配置。

## 快速开始

~~~bash
git clone https://github.com/hyNous/self-vps.git
cd self-vps
cp .env.example .env
nano .env
sudo bash scripts/install.sh
sudo bash scripts/verify.sh
~~~

.env 最少需要填写：

~~~dotenv
NODE_DOMAIN=node.example.com
ACME_EMAIL=admin@example.com
SSH_PORT=22
TROJAN_PASSWORD=
CDN_DOMAIN=
VLESS_UUID=
VLESS_WS_PATH=
ENABLE_SSH_HARDENING=0
~~~

`CDN_DOMAIN`、`VLESS_UUID`、`VLESS_WS_PATH` 只在需要 VLESS+WS 备用入口时填写；留空会自动生成，并保存到 VPS 的 `/etc/self-vps/vless-ws.env`。`ENABLE_SSH_HARDENING=1` 会关闭密码和 root SSH，必须在确认公钥登录可用后再启用。

密码留空时，安装脚本会生成随机密码并保存在 VPS 的 /etc/self-vps/node.env，文件权限为 600。仓库不会打印或提交该密码。管理员可在自己的终端读取它并填写客户端配置：

~~~bash
sudo awk -F= '$1 == "TROJAN_PASSWORD" {print $2}' /etc/self-vps/node.env
~~~

将 [FlClash 模板](templates/flclash.yaml) 中的占位符替换为自己的域名和密码，再从 FlClash 的“配置”页面导入。

## 首次使用与密码轮换

首次成功动作是在 FlClash 导入配置、选择 `Seoul-CDN`（VLESS/WS）或 `Seoul-Trojan`，并通过代理请求出口地址。若需要轮换 Trojan 密码，在本地 .env 设置新的 TROJAN_PASSWORD，重新运行安装和验证，再更新所有客户端：

~~~bash
sudo bash scripts/backup.sh
sudo bash scripts/install.sh
sudo bash scripts/verify.sh
~~~

旧密码会立即失效。不要在聊天、Issue、日志或截图中粘贴新密码。可选监控的首次账号创建和凭据轮换见[监控模块说明](optional/monitoring/README.md)。

## 安装内容

| 路径 | 用途 |
|---|---|
| /usr/local/etc/xray/config.json | Xray Trojan + TLS + 可选 VLESS/WS 配置 |
| /usr/local/etc/xray/cert/ | Xray 可读取的证书副本 |
| /etc/nginx/sites-available/self-vps | ACME、测试页和 fallback |
| /etc/nginx/sites-available/vless-cdn | VLESS/WS 反代和 CDN 伪装页 |
| /etc/letsencrypt/renewal-hooks/deploy/xray-cert.sh | 续期部署钩子 |
| /etc/modules-load.d/bbr.conf | 开机加载 BBR |
| /etc/sysctl.d/99-tcp-tune.conf | BBR、队列和 SYN 参数 |
| /etc/ssh/sshd_config.d/00-hynous-hardening.conf | 可选的 key-only SSH 加固 |
| /etc/self-vps/node.env | root-only 本机参数和 Trojan 密码 |
| /etc/self-vps/vless-ws.env | root-only VLESS UUID、WS path 和 CDN 域名 |

Xray 由 [XTLS 官方安装器](https://github.com/XTLS/Xray-install)安装。仓库固定安装器提交，避免上游脚本在无人知情时变化。

## 验证

~~~bash
sudo bash scripts/verify.sh
~~~

验证脚本检查 SSH、Nginx、Xray、Certbot timer、80/443/8080 监听、配置语法、BBR、HTTP 页面和 TLS fallback；如果存在 vless-ws.env，还会检查 10086/8082 监听、WebSocket 101、无 Upgrade 的 404 和 CDN 伪装页。它不会测试用户本地到 VPS 的跨境线路质量。

客户端导入后可检查出口：

~~~powershell
curl.exe -x http://127.0.0.1:7890 https://api.ipify.org
~~~

## 可选监控

[监控模块](optional/monitoring/README.md)提供：

- Beszel Hub + 本机 Agent
- Uptime Kuma
- 仅绑定 127.0.0.1:8090 和 127.0.0.1:3001
- 可选 Cloudflare Tunnel 访问

监控不是核心代理的依赖。Beszel 能记录 VPS 网卡和容器流量，但不能单独定位“客户端到 VPS”的低速链路，也不提供 Xray 按用户流量审计。

## 运维与迁移

- [日常运维、升级与回滚](docs/operations.md)
- [VPS 或域名迁移](docs/migration.md)
- [常见故障排查](docs/troubleshooting.md)

核心服务的常用操作：

~~~bash
sudo systemctl start xray nginx
sudo systemctl stop xray nginx
sudo systemctl restart xray nginx
sudo systemctl status xray nginx --no-pager
sudo journalctl -u xray -u nginx -n 100 --no-pager
~~~

创建备份：

~~~bash
sudo bash scripts/backup.sh
~~~

恢复属于覆盖性操作，必须显式确认：

~~~bash
sudo bash scripts/restore.sh --confirm /path/to/self-vps-TIMESTAMP.tar.gz
sudo bash scripts/verify.sh
~~~

备份包含证书、密码和可能的监控数据库，权限设为 600，仍应存放到加密介质，绝不能提交 Git。

## 安全边界

- 不提交真实域名、服务器地址、密码、Token、私钥、订阅地址或监控数据库。
- 不通过 Cloudflare 代理 Xray 的 Trojan TCP 入口；代理域名应使用符合协议要求的 DNS 设置。
- Cloudflare Tunnel 只用于可选的 HTTP 监控界面、VLESS/WS CDN 入口和 SSH；不要把 Trojan 443 挂到 HTTP 型 Public Hostname。
- `ssh.example.com` 必须加 Cloudflare Access（Service Token 或邮箱 OTP）；`cdn.example.com` 不要加 Access，否则 VLESS 会被登录页挡住。
- 安装脚本会启用 UFW；它会保留配置的 SSH 端口以及 sshd 检测到的端口。
- 默认 SSH 加固后只允许公钥，密码和 root SSH 关闭；启用前先确认公钥登录可用。
- 首次进入 Beszel 和 Uptime Kuma 后应立即创建强密码，并按需启用应用自身的 2FA 或 Cloudflare Access。
- 公开仓库中的域名、IP、密码和 Token 全部是示例或占位符。
- Cloudflare 的 ToS/AUP 对把 CDN/Tunnel 当公共代理出口有保留，存在限速、质询或封号风险；不要把它作为唯一长期入口。

## 已知限制

- 仅支持 Ubuntu 24.04 amd64。
- 尚未在全新 VPS 上完成端到端 Beta 验证。
- 核心默认 Trojan；VLESS+WS 是可选的 CDN 入口，不替代 Trojan；不包含 Reality/XTLS Vision。
- Cloudflare 免费线路在中国大陆的带宽和稳定性有限，不能保证跑满 VPS 套餐带宽。
- Uptime Kuma 监控项和 Beszel 首次配对仍需通过 Web UI 完成。
- 自动恢复仅覆盖本仓库生成的备份，不是整机灾难恢复。

## 上游项目

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)（MPL-2.0）
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install)（GPL-3.0；本项目仅调用，不复制）
- [Nginx](https://nginx.org/)
- [Certbot](https://certbot.eff.org/)
- [Beszel](https://github.com/henrygd/beszel)（MIT）
- [Uptime Kuma](https://github.com/louislam/uptime-kuma)（MIT）
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)

## License

[MIT](LICENSE)
