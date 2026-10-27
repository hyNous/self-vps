# 日常运维

## SSH 入口

当前推荐同时保留两条路径：

~~~sshconfig
Host hynous
    HostName node.example.com
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3

Host hynous-cf
    HostName ssh.example.com
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ProxyCommand cloudflared access ssh --hostname %h
    ServerAliveInterval 30
    ServerAliveCountMax 3
~~~

直连 `ssh hynous`；直连不可用时使用 `ssh hynous-cf`。OrcaTerm / 腾讯云 VNC 作为 break-glass。

不要依赖密码登录；`PermitRootLogin` 和 `PasswordAuthentication` 已经关闭。给其他 agent 使用独立的非 root 用户和独立 key，不要把 `ubuntu` 私钥分发出去。

## Reality 与 VLESS/WS

~~~bash
sudo ss -lntp | grep -E ':(443|8080|8082|10086) '
sudo journalctl -u xray -n 100 --no-pager
sudo journalctl -u nginx -n 100 --no-pager
sudo journalctl -u cloudflared -n 100 --no-pager
~~~

Reality 的关键参数：

~~~bash
sudo sed -n 's/^REALITY_SERVER_NAME=//p' /etc/self-vps/reality.env
sudo sed -n 's/^REALITY_DEST=//p' /etc/self-vps/reality.env
sudo sed -n 's/^REALITY_PUBLIC_KEY=//p' /etc/self-vps/reality.env
~~~

私钥只用于服务端，不要复制到客户端或聊天。

本地 WebSocket 检查必须用 HTTP/1.1：

~~~bash
path="$(sudo sed -n 's/^VLESS_WS_PATH=//p' /etc/self-vps/vless-ws.env)"
cdn="$(sudo sed -n 's/^CDN_DOMAIN=//p' /etc/self-vps/vless-ws.env)"
curl --http1.1 -s -o /dev/null -w 'ws=%{http_code}\n' \
  -H "Host: $cdn" \
  -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Version: 13' \
  "http://127.0.0.1:8082$path"
~~~

预期 `101`；不带 Upgrade 应为 `404`；根路径伪装页应为 `200`。

Cloudflare Public Hostname 的 Service 必须是 HTTP，不能填 HTTPS；`cdn`/`edge` 不要加 Access，`ssh` 建议加 Access。

## Docker 与监控

监控可能分别部署在：

~~~text
/opt/uptime-kuma
/opt/beszel
/opt/self-vps-monitoring   # 旧版合并部署
~~~

查看：

~~~bash
sudo docker ps
sudo docker compose -f /opt/uptime-kuma/compose.yml ps 2>/dev/null || true
sudo docker compose -f /opt/beszel/compose.yml ps 2>/dev/null || true
curl -fsS http://127.0.0.1:3001/ >/dev/null
curl -fsS http://127.0.0.1:8090/api/health
~~~

如果 3001/8090 不再监听、外部页面 502，但容器显示 healthy，优先检查 Docker 防火墙链：

~~~bash
sudo iptables -S DOCKER
sudo ss -lntp | grep -E ':(3001|8090) '
~~~

`DOCKER` 链存在时再检查端口映射。恢复顺序：

~~~bash
sudo systemctl restart docker
sudo docker compose -f /opt/uptime-kuma/compose.yml up -d --force-recreate uptime-kuma
sudo docker compose -f /opt/beszel/compose.yml up -d
~~~

同时安装了 `self-vps-docker-watchdog.timer`，每 2 分钟检查链、端口和 HTTP 健康接口；链丢失且端口失效时会自动恢复：

~~~bash
systemctl status self-vps-docker-watchdog.timer --no-pager
journalctl -u self-vps-docker-watchdog -n 100 --no-pager
~~~

Docker 重启会短暂影响所有容器；先确认当前没有正在进行的监控数据库写入。

## 证书续期

Reality 不使用 Let's Encrypt 证书；证书只用于可选的 8443/网站入口。检查：

~~~bash
sudo certbot renew --dry-run --run-deploy-hooks
sudo systemctl status certbot.timer --no-pager
sudo certbot certificates
~~~

不要为了让 Xray 读取证书而把 Let's Encrypt 私钥权限放宽到全局可读。

## 配置变更

先备份，再修改仓库 `.env` 并重新运行安装脚本：

~~~bash
sudo bash scripts/backup.sh
sudo bash scripts/install.sh
sudo bash scripts/verify.sh
~~~

安装脚本只会覆盖带有 `/etc/self-vps/managed` 标记的本项目配置。它不会接管其他已有 Xray 或 Nginx 配置。

修改 `REALITY_DEST`/`REALITY_SERVER_NAME` 后必须同时验证客户端 Reality 握手，不能只看 443 端口是否监听。

## 升级

核心组件升级前先创建云厂商快照和脚本备份，然后拉取仓库更新、检查差异，再重新运行安装与验证。Xray 官方安装器固定到仓库审核过的提交；只有本仓库更新该引用后才会改变安装逻辑。

监控容器升级：

~~~bash
sudo docker compose -f /opt/uptime-kuma/compose.yml pull
sudo docker compose -f /opt/uptime-kuma/compose.yml up -d
sudo docker compose -f /opt/beszel/compose.yml pull
sudo docker compose -f /opt/beszel/compose.yml up -d
sudo docker compose -f /opt/uptime-kuma/compose.yml ps
sudo docker compose -f /opt/beszel/compose.yml ps
~~~

Uptime Kuma 使用主版本标签 2；Beszel 采用其官方 Compose 示例使用的 latest 标签。升级前必须备份数据并查看上游发布说明。

## 回滚

~~~bash
sudo bash scripts/restore.sh --check /path/to/self-vps-TIMESTAMP.tar.gz
sudo bash scripts/restore.sh --confirm /path/to/self-vps-TIMESTAMP.tar.gz
sudo bash scripts/verify.sh
~~~

数据库格式升级后，旧容器镜像不一定能读取新数据库。回滚监控版本前应同时恢复升级前的数据备份。

## 停用

~~~bash
sudo systemctl disable --now xray
sudo systemctl disable --now nginx
sudo docker compose -f /opt/uptime-kuma/compose.yml stop
sudo docker compose -f /opt/beszel/compose.yml stop
~~~

这些命令保留配置、证书和监控数据。永久删除数据不属于自动流程。
