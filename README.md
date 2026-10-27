# self-vps

在 Ubuntu 24.04 上部署 Xray **VLESS + TCP + Reality + XTLS Vision** 直连节点，并可选配置 VLESS/WS over Cloudflare Tunnel 作为 CDN 备用入口。Nginx 只负责 80 端口、ACME 和本机 8080/8082 回环服务；UFW、BBR 和可选的 key-only SSH 加固随核心节点配置。Beszel 与 Uptime Kuma 是独立监控模块。

> **Beta**：仓库脚本经过静态检查，但新的 Reality 安装流程仍应先在测试 VPS 上完整跑一遍，并保留云厂商快照和 SSH 控制台。

## 架构

~~~text
FlClash / Mihomo（建议开启 TUN）
      │
      ├─ VLESS + Reality 443（直连，xtls-rprx-vision）
      │     ▼
      │   Xray ──────────────→ freedom / VPS 直接出站
      │
      └─ VLESS + WS 443（Cloudflare 边缘，备用）
            ▼
        Cloudflare Tunnel → Nginx 127.0.0.1:8082 → Xray 127.0.0.1:10086

SSH：直连 22 / Cloudflare Tunnel → sshd key-only
监控：Beszel + Uptime Kuma ← Cloudflare Tunnel
~~~

核心部署：

- Ubuntu 24.04 amd64
- Xray VLESS + Reality，监听 TCP 443
- Reality `dest` 默认 `104.16.123.96:443`，`serverNames` 默认 `www.cloudflare.com`
- Nginx 监听 TCP 80，并在 `127.0.0.1:8080` 提供本机回环页面
- Certbot webroot 续期：证书不再被 Reality 使用，但保留给可选的 8443 网站入口
- UFW 仅放行 SSH、80、443；8443 等额外端口需单独放行
- BBR + 系统现有队列规则
- 默认 freedom 直出，`domainStrategy` 为 `UseIPv4`
- 可选 VLESS/WS：Xray 仅监听 `127.0.0.1:10086`，Nginx `127.0.0.1:8082` 做 WebSocket 反代和伪装页
- 可选 SSH 加固：只允许公钥，关闭密码和 root SSH
- 可选 Cloudflare Tunnel：CDN 入口、SSH、监控面板

## 重要边界：443 属于 Reality

Reality 直接占用 TCP 443。**Nginx 不再在 443 提供普通网站**，因此：

- `www.example.com`、`example.com` 的 HTTPS 不会由 Nginx 直接提供；
- 个人主页使用独立 Cloudflare Tunnel，把 `www`/apex 发布到 `http://127.0.0.1:8080`；
- QQQ 使用另一个独立 Tunnel，经过本机 HTTP 桥到 8443；
- 也可以把其他网站放到单独的端口，并用 Cloudflare Origin Rule 或直接访问；
- 不要为了恢复网站把 Reality 从 443 挪走，除非你愿意重新调整所有客户端和防火墙。

当前部署使用：

~~~text
hynous-home
  www.hynous.cc / hynous.cc -> http://127.0.0.1:8080

hynous-qqq
  qqq.hynous.cc -> http://127.0.0.1:8444
  8444 -> https://127.0.0.1:8443 -> QQQ Dashboard
~~~

不要把主页发布到 `https://127.0.0.1:443`，那里是 Reality，不是 Nginx。

## 快速开始

~~~bash
git clone https://github.com/hyNous/self-vps.git
cd self-vps
cp .env.example .env
nano .env
sudo bash scripts/install.sh
sudo bash scripts/verify.sh
~~~

`.env` 最少需要填写：

~~~dotenv
NODE_DOMAIN=node.example.com
ACME_EMAIL=admin@example.com
SSH_PORT=22
REALITY_DEST=104.16.123.96:443
REALITY_SERVER_NAME=www.cloudflare.com
~~~

可选值：

~~~dotenv
REALITY_UUID=
REALITY_SHORT_ID=
CDN_DOMAIN=
VLESS_UUID=
VLESS_WS_PATH=
ENABLE_SSH_HARDENING=0
~~~

- `REALITY_UUID`、`REALITY_SHORT_ID` 留空会自动生成并保存到 `/etc/self-vps/reality.env`；
- `CDN_DOMAIN` 留空时从 `NODE_DOMAIN` 推导 `cdn.<zone>`；
- `VLESS_UUID`、`VLESS_WS_PATH` 留空会自动生成，并保存到 `/etc/self-vps/vless-ws.env`；
- `ENABLE_SSH_HARDENING=1` 会关闭密码和 root SSH，必须在确认公钥登录可用后再启用；
- `REALITY_DEST` 必须是 `host:port`，`REALITY_SERVER_NAME` 必须是目标站点证书覆盖的域名。

管理员读取 Reality 客户端参数（不要打印私钥）：

~~~bash
sudo sed -n 's/^REALITY_PUBLIC_KEY=//p' /etc/self-vps/reality.env
sudo sed -n 's/^REALITY_SHORT_ID=//p' /etc/self-vps/reality.env
sudo sed -n 's/^REALITY_UUID=//p' /etc/self-vps/reality.env
~~~

将 [FlClash 模板](templates/flclash.yaml) 中的占位符替换为自己的域名、UUID、shortId 和公钥，再从 FlClash 的“配置”页面导入。TUN 在 FlClash 的应用设置里开启，不属于这个 YAML 文件。

## 安装内容

| 路径 | 用途 |
|---|---|
| `/usr/local/etc/xray/config.json` | Xray Reality + 可选 VLESS/WS 配置 |
| `/etc/self-vps/reality.env` | Reality UUID、公钥、私钥、shortId、目标，root-only |
| `/etc/self-vps/vless-ws.env` | VLESS UUID、WS path、CDN 域名，root-only |
| `/etc/nginx/sites-available/self-vps` | ACME、HTTP 页面和 8080 回环页面 |
| `/etc/nginx/sites-available/vless-cdn` | VLESS/WS 反代和 CDN 伪装页 |
| `/etc/letsencrypt/renewal-hooks/` | 可选的证书续期钩子 |
| `/etc/modules-load.d/bbr.conf` | 开机加载 BBR |
| `/etc/sysctl.d/99-tcp-tune.conf` | BBR、队列和 SYN 参数 |
| `/etc/ssh/sshd_config.d/00-hynous-hardening.conf` | 可选的 key-only SSH 加固 |
| `/usr/local/sbin/self-vps-docker-watchdog.sh` | Docker 监控链/端口自动恢复 |
| `/etc/systemd/system/self-vps-docker-watchdog.{service,timer}` | 每 2 分钟运行 watchdog |

Xray 由 [XTLS 官方安装器](https://github.com/XTLS/Xray-install)安装。仓库固定安装器提交，避免上游脚本在无人知情时变化。

## 验证

~~~bash
sudo bash scripts/verify.sh
~~~

验证脚本检查 SSH、Nginx、Xray、Certbot timer、80/443/8080 监听、Reality inbound、BBR、HTTP 页面；如果存在 `vless-ws.env`，还会检查 10086/8082 监听、WebSocket 101、无 Upgrade 的 404 和 CDN 伪装页。存在 Uptime Kuma/Beszel 容器时，会额外检查 3001/8090 和 Docker `DOCKER` 链。

它不会从服务端证明“客户端到 VPS”的 Reality 端到端可用，也不会测试 TUN；这两项需要客户端或外部探针验证。

客户端导入后可检查出口：

~~~powershell
curl.exe -x http://127.0.0.1:7890 https://api.ipify.org
~~~

## 可选监控

[监控模块](optional/monitoring/README.md)提供：

- Beszel Hub + 本机 Agent
- Uptime Kuma
- 仅绑定 `127.0.0.1:8090` 和 `127.0.0.1:3001`
- 可选 Cloudflare Tunnel 访问

当前实际部署可能分别使用 `/opt/uptime-kuma` 和 `/opt/beszel`；`backup.sh` 会自动识别这两个目录，也兼容旧的 `/opt/self-vps-monitoring`。

建议把 Uptime Kuma 当成“可用性面板”，把 Beszel 当成“资源面板”：

- `status.hynous.cc` 是统一状态页，根路径会跳到 `/status/hynous`；
- `monitor.hynous.cc` 是 Beszel 资源面板；
- Reality 的 TCP 443 只能说明端口开放，不能说明协议可用；端到端探测应通过客户端或独立的 Xray/sing-box 探针完成；
- 仓库的 `scripts/client-probe.ps1` 是 Windows 客户端探针，通过 FlClash 的 7890 端口验证真实出口并上报 Uptime Kuma；
- 具体颜色含义和红灯处理顺序见[监控与状态页说明](docs/monitoring.md)。

## 运维与迁移

- [日常运维、升级与回滚](docs/operations.md)
- [监控与状态页说明](docs/monitoring.md)
- [VPS 或域名迁移](docs/migration.md)
- [常见故障排查](docs/troubleshooting.md)

常用操作：

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
sudo bash scripts/restore.sh --check /path/to/self-vps-TIMESTAMP.tar.gz
sudo bash scripts/restore.sh --confirm /path/to/self-vps-TIMESTAMP.tar.gz
sudo bash scripts/verify.sh
~~~

备份包含 Reality 私钥、证书私钥、Cloudflare Tunnel token、Nginx 配置、`/var/www` 和监控数据库，权限设为 600，仍应存放到加密介质，绝不能提交 Git。额外的非仓库服务可以通过 `/etc/self-vps/backup-extra-paths` 添加，每行一个绝对路径。

## 安全边界

- 不提交真实域名、服务器地址、密码、Token、私钥、订阅地址或监控数据库。
- `ssh.example.com` 如果使用 Cloudflare Tunnel，建议加 Cloudflare Access；当前直连 22 的暴露程度由云安全组和 UFW 决定。
- `ubuntu` 的 NOPASSWD sudo 会让任何被授权的 key 等价于 root；给 agent 使用独立用户和独立 key。
- `cdn.example.com` 不要加 Cloudflare Access，否则 VLESS 会被登录页挡住。
- 不要把 Reality 443 挂到 HTTP 型 Cloudflare Public Hostname。
- 不要把 Reality 私钥、`reality.env`、`vless-ws.env` 或 Cloudflare token 粘贴到聊天/Issue/日志。
- 公开仓库中的域名、IP、密码和 Token 全部是示例或占位符。

## 已知限制

- 仅支持 Ubuntu 24.04 amd64。
- 尚未在一台全新 VPS 上完成端到端 Beta 验证。
- 443 归 Reality，普通网站 HTTPS 需要额外设计。
- Reality `dest` 是固定目标；目标 IP、SNI 或证书不匹配时会出现握手 EOF，需要调整 `REALITY_DEST`/`REALITY_SERVER_NAME`。
- Cloudflare 免费线路在中国大陆的带宽和稳定性有限，不能保证跑满 VPS 套餐带宽。
- Uptime Kuma 监控项和 Beszel 首次配对仍需通过 Web UI 完成。
- 自动恢复仅覆盖备份脚本收录的路径，不是整机灾难恢复。
- TUN、规则分流和 FlClash 的本地设置不在服务端脚本内。

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
