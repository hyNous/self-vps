# 日常运维

## SSH 入口

服务端默认只允许公钥登录。Cloudflare Tunnel 可用时，本机使用 `~/.ssh/config` 里的 `hynous` 主机：

~~~bash
ssh hynous
sudo -i
~~~

如果还没配置 `ProxyCommand`，可以手动：

~~~bash
cloudflared access tcp --hostname ssh.example.com --url 127.0.0.1:12222
ssh -p 12222 ubuntu@127.0.0.1
~~~

不要依赖密码登录；`PermitRootLogin` 和 `PasswordAuthentication` 已经关闭。OrcaTerm / 腾讯云 VNC 作为 break-glass。`ssh.example.com` 应加 Cloudflare Access；`cdn.example.com` 不要加。

## VLESS/WS 与 Cloudflare Tunnel

~~~bash
sudo ss -lntp | grep -E ':(443|8080|8082|10086) '
sudo journalctl -u xray -n 100 --no-pager
sudo journalctl -u cloudflared -n 100 --no-pager
~~~

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

预期 `101`；不带 Upgrade 应为 `404`；根路径伪装页应为 `200`。HTTP/2 手工测试返回 404 是正常的。

Cloudflare Public Hostname 的 Service 必须是 HTTP，不能填 HTTPS；`cdn` 不要加 Access，`ssh` 必须加 Access。

## SSH 加固

~~~bash
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|x11forwarding|maxauthtries|logingracetime) '
sudo ls -l /etc/ssh/sshd_config.d/00-hynous-hardening.conf
~~~

预期：`passwordauthentication no`、`permitrootlogin without-password` 或 `no`、`x11forwarding no`。回滚：

~~~bash
sudo rm /etc/ssh/sshd_config.d/00-hynous-hardening.conf
sudo sshd -t && sudo systemctl reload ssh
~~~

改 SSH 前保留一个可用的 Cloudflare Tunnel 会话，并确认 OrcaTerm 或 VNC 可用。

## 状态与日志

~~~bash
sudo bash scripts/verify.sh
sudo systemctl status xray nginx certbot.timer --no-pager
sudo journalctl -u xray -u nginx -n 100 --no-pager
sudo ss -lntp
sudo ufw status verbose
~~~

可选监控：

~~~bash
cd /opt/self-vps-monitoring
sudo docker compose ps
sudo docker compose logs --tail 100
~~~

## 证书续期

~~~bash
sudo certbot renew --dry-run --run-deploy-hooks
sudo systemctl status certbot.timer --no-pager
~~~

部署钩子会把续期证书复制到 Xray 目录并重启 Xray。不要让 Xray 直接读取 root-only 的 Let's Encrypt 私钥。

## 配置变更

先备份，再修改仓库的 .env 并重新运行安装脚本：

~~~bash
sudo bash scripts/backup.sh
sudo bash scripts/install.sh
sudo bash scripts/verify.sh
~~~

安装脚本只会覆盖带有 /etc/self-vps/managed 标记的本项目配置。它不会接管其他已有 Xray 或 self-vps Nginx 配置。

## 升级

核心组件升级前先创建云厂商快照和脚本备份，然后拉取仓库更新、检查差异，再重新运行安装与验证。Xray 官方安装器固定到仓库审核过的提交；只有本仓库更新该引用后才会改变安装逻辑。

监控容器升级：

~~~bash
cd /opt/self-vps-monitoring
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
~~~

Uptime Kuma 使用主版本标签 2；Beszel 采用其官方 Compose 示例使用的 latest 标签。因此 Beszel 更新前必须备份数据并查看上游发布说明。

## 回滚

恢复最近一次完整备份：

~~~bash
sudo bash scripts/restore.sh --confirm /path/to/self-vps-TIMESTAMP.tar.gz
sudo bash scripts/verify.sh
~~~

数据库格式升级后，旧容器镜像不一定能读取新数据库。回滚监控版本前应同时恢复升级前的数据备份。

## 停用

~~~bash
sudo systemctl disable --now xray
sudo systemctl disable --now nginx
cd /opt/self-vps-monitoring
sudo docker compose stop
~~~

这些命令保留配置、证书和监控数据。永久删除数据不属于自动流程。
